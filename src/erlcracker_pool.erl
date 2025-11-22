-module(erlcracker_pool).
-behaviour(gen_server).

%%% Runtime Pool Manager
%%%
%%% Manages a pool of runtime workers for concurrent task execution.
%%% Implements fire-and-forget invocation pattern with automatic lifecycle management.
%%%
%%% ARCHITECTURE:
%%%   erlcracker_pool_sup (rest_for_one)
%%%     ├─ erlcracker_worker_sup (simple_one_for_one) - Manages worker lifecycle
%%%     └─ erlcracker_pool (gen_server) - Manages work distribution
%%%
%%% WORKER LIFECYCLE:
%%%   1. Pool requests workers from supervisor during init
%%%   2. Supervisor spawns workers (permanent restart strategy)
%%%   3. Workers initialize runtime, send {worker_available, self()} to pool
%%%   4. Pool monitors workers and adds to available queue
%%%   5. If worker dies: supervisor auto-restarts, pool updates tracking
%%%   6. New worker re-registers, pool assigns queued work

%% API
-export([start_link/3, call_runtime/3, call_and_await/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    pool_name :: atom(),
    runtime_module :: module(),
    pool_size :: integer(),
    worker_timeout_ms :: integer(),
    worker_sup_pid :: pid(),
    request_queue :: queue:queue(),
    available_workers :: queue:queue(),
    busy_workers :: sets:set()
}).

%%====================================================================
%% API functions
%%====================================================================

start_link(PoolName, RuntimeModule, PoolConfig) ->
    gen_server:start_link({local, PoolName}, ?MODULE, [PoolName, RuntimeModule, PoolConfig], []).

%% Call runtime function asynchronously - result sent as {runtime_result, WorkerPid, Result}
call_runtime(PoolName, {Module, Function, Args}, CallerPid) ->
    gen_server:cast(PoolName, {call_runtime, Module, Function, Args, CallerPid}).

%% Call runtime function and await result synchronously
%% Returns {ok, Result} | {error, Reason}
%%
%% Example:
%%   case erlcracker_pool:call_and_await(my_pool, {mymodule, myfunction, [Arg1]}, 5000) of
%%       {ok, Result} -> ...;
%%       {error, timeout} -> ...;
%%       {error, Reason} -> ...
%%   end
%%
call_and_await(PoolName, {Module, Function, Args}, Timeout) ->
    call_runtime(PoolName, {Module, Function, Args}, self()),
    receive
        {runtime_result, _WorkerPid, Result} -> Result
    after Timeout ->
        {error, timeout}
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([PoolName, RuntimeModule, PoolConfig]) ->
    process_flag(trap_exit, true),

    % Extract configuration
    PoolSize = maps:get(pool_size, PoolConfig, 2),
    WorkerTimeoutMs = maps:get(worker_timeout_ms, PoolConfig, 45000),

    % Find worker supervisor by registered name
    % Standard OTP pattern - rest_for_one ensures it's already started
    WorkerSupName = list_to_atom(atom_to_list(PoolName) ++ "_worker_sup"),
    WorkerSupPid = case whereis(WorkerSupName) of
        Pid when is_pid(Pid) -> Pid;
        undefined ->
            logger:error("~p: Could not find worker_sup ~p", [PoolName, WorkerSupName]),
            error({worker_sup_not_found, WorkerSupName})
    end,

    % Request workers from supervisor - they will auto-register when ready
    lists:foreach(
        fun(_) ->
            {ok, _WorkerPid} = erlcracker_worker_sup:start_worker(WorkerSupPid)
        end,
        lists:seq(1, PoolSize)
    ),

    logger:info("ErlCracker pool ~p started with ~p runtime (~p workers, timeout: ~pms)",
        [PoolName, RuntimeModule, PoolSize, WorkerTimeoutMs]),

    {ok, #state{
        pool_name = PoolName,
        runtime_module = RuntimeModule,
        pool_size = PoolSize,
        worker_timeout_ms = WorkerTimeoutMs,
        worker_sup_pid = WorkerSupPid,
        request_queue = queue:new(),
        available_workers = queue:new(),
        busy_workers = sets:new()
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({call_runtime, Module, Function, Args, CallerPid}, State) ->
    logger:debug("~p: Request ~p:~p from ~p", [State#state.pool_name, Module, Function, CallerPid]),

    case queue:out(State#state.available_workers) of
        {{value, Worker}, NewAvailable} ->
            % Worker available, assign immediately
            erlcracker_worker:call_runtime(Worker, Module, Function, Args, CallerPid, self(), State#state.worker_timeout_ms),
            NewBusy = sets:add_element(Worker, State#state.busy_workers),
            {noreply, State#state{
                available_workers = NewAvailable,
                busy_workers = NewBusy
            }};
        {empty, _} ->
            % No workers available, queue the request
            QueueLen = queue:len(State#state.request_queue),
            logger:warning("~p: All workers busy, queuing request (queue length: ~p)",
                [State#state.pool_name, QueueLen + 1]),
            Request = {Module, Function, Args, CallerPid},
            NewQueue = queue:in(Request, State#state.request_queue),
            {noreply, State#state{request_queue = NewQueue}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({worker_done, WorkerPid, _Result}, State) ->
    % Worker finished, handle result and reassign or mark available
    case sets:is_element(WorkerPid, State#state.busy_workers) of
        true ->
            NewBusy = sets:del_element(WorkerPid, State#state.busy_workers),

            % Check if there are queued requests
            case queue:out(State#state.request_queue) of
                {{value, {Module, Function, Args, CallerPid}}, NewQueue} ->
                    % Assign queued request to this worker
                    logger:info("~p: Assigning queued request ~p:~p to worker ~p",
                        [State#state.pool_name, Module, Function, WorkerPid]),
                    erlcracker_worker:call_runtime(WorkerPid, Module, Function, Args, CallerPid, self(), State#state.worker_timeout_ms),
                    {noreply, State#state{
                        request_queue = NewQueue,
                        busy_workers = sets:add_element(WorkerPid, NewBusy)
                    }};
                {empty, _} ->
                    % No queued requests, mark worker as available
                    NewAvailable = queue:in(WorkerPid, State#state.available_workers),
                    {noreply, State#state{
                        available_workers = NewAvailable,
                        busy_workers = NewBusy
                    }}
            end;
        false ->
            % Worker wasn't tracked as busy, ignore
            {noreply, State}
    end;

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    % Worker died - supervisor will automatically restart it
    % Pool's responsibility: Update work tracking (remove from busy/available sets)
    WasBusy = sets:is_element(Pid, State#state.busy_workers),
    QueueLen = queue:len(State#state.request_queue),

    case Reason of
        normal ->
            logger:debug("~p: Worker ~p terminated normally", [State#state.pool_name, Pid]);
        {runtime_died, RuntimeReason} ->
            logger:error("~p: Worker ~p died due to runtime crash: ~p~n"
                        "    Worker state: ~s, Queued requests: ~p~n"
                        "    Supervisor will auto-restart worker",
                        [State#state.pool_name, Pid, RuntimeReason,
                         case WasBusy of true -> "busy"; false -> "idle" end,
                         QueueLen]);
        _ ->
            logger:error("~p: Worker ~p died unexpectedly: ~p~n"
                        "    Worker state: ~s, Queued requests: ~p~n"
                        "    Supervisor will auto-restart worker",
                        [State#state.pool_name, Pid, Reason,
                         case WasBusy of true -> "busy"; false -> "idle" end,
                         QueueLen])
    end,

    % Remove dead worker from tracking
    NewBusy = sets:del_element(Pid, State#state.busy_workers),
    AvailableList = queue:to_list(State#state.available_workers),
    NewAvailableList = lists:delete(Pid, AvailableList),
    NewAvailable = queue:from_list(NewAvailableList),

    {noreply, State#state{
        available_workers = NewAvailable,
        busy_workers = NewBusy
    }};

handle_info({worker_available, WorkerPid}, State) ->
    % New worker started and is ready for work
    logger:info("~p: Worker ~p available", [State#state.pool_name, WorkerPid]),

    % Monitor worker for work tracking
    erlang:monitor(process, WorkerPid),

    % Check if there are queued requests
    case queue:out(State#state.request_queue) of
        {{value, {Module, Function, Args, CallerPid}}, NewQueue} ->
            % Assign queued request immediately
            logger:info("~p: Worker ~p immediately assigned queued request ~p:~p",
                [State#state.pool_name, WorkerPid, Module, Function]),
            erlcracker_worker:call_runtime(WorkerPid, Module, Function, Args, CallerPid, self(), State#state.worker_timeout_ms),
            {noreply, State#state{
                request_queue = NewQueue,
                busy_workers = sets:add_element(WorkerPid, State#state.busy_workers)
            }};
        {empty, _} ->
            % No queued work, add to available pool
            {noreply, State#state{
                available_workers = queue:in(WorkerPid, State#state.available_workers)
            }}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
