-module(erlcracker_worker).
-behaviour(gen_server).

%%% Runtime Worker
%%%
%%% Manages individual runtime process and executes function calls with timeout protection.
%%% Uses double-spawn pattern to isolate execution from worker lifecycle.

%% API
-export([start_link/3, call_runtime/7]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    runtime_handle :: term(),
    runtime_module :: module(),
    pool_name :: atom(),
    pool_config :: map(),
    call_count = 0 :: non_neg_integer(),
    started_at :: integer(),
    max_calls :: non_neg_integer() | undefined,
    max_age_ms :: non_neg_integer() | undefined,
    age_timer_ref :: reference() | undefined
}).

%%====================================================================
%% API functions
%%====================================================================

start_link(PoolName, RuntimeModule, PoolConfig) ->
    gen_server:start_link(?MODULE, [PoolName, RuntimeModule, PoolConfig], []).

%% Call runtime function - result sent to CallerPid, completion notification to PoolPid
call_runtime(WorkerPid, Module, Function, Args, CallerPid, PoolPid, TimeoutMs) ->
    gen_server:cast(WorkerPid, {call_runtime, Module, Function, Args, CallerPid, PoolPid, TimeoutMs}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([PoolName, RuntimeModule, PoolConfig]) ->
    process_flag(trap_exit, true),

    % Extract recycling config
    MaxCalls = maps:get(max_calls_per_worker, PoolConfig, undefined),
    MaxAgeMs = maps:get(max_worker_age_ms, PoolConfig, undefined),

    % Start runtime using runtime module
    case RuntimeModule:start_runtime(PoolConfig) of
        {ok, RuntimeHandle} ->
            logger:info("ErlCracker worker ~p started with ~p runtime (handle: ~p, pool: ~p)",
                [self(), RuntimeModule, RuntimeHandle, PoolName]),

            % Set up age-based recycling timer if configured
            AgeTimerRef = case MaxAgeMs of
                undefined -> undefined;
                Ms when is_integer(Ms), Ms > 0 ->
                    erlang:send_after(Ms, self(), recycle_age_limit)
            end,

            % Notify pool we're ready
            PoolName ! {worker_available, self()},

            {ok, #state{
                runtime_handle = RuntimeHandle,
                runtime_module = RuntimeModule,
                pool_name = PoolName,
                pool_config = PoolConfig,
                call_count = 0,
                started_at = erlang:monotonic_time(millisecond),
                max_calls = MaxCalls,
                max_age_ms = MaxAgeMs,
                age_timer_ref = AgeTimerRef
            }};
        {error, Reason} ->
            logger:error("ErlCracker worker ~p failed to start runtime ~p: ~p",
                [self(), RuntimeModule, Reason]),
            {stop, {runtime_start_failed, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({call_runtime, Module, Function, Args, CallerPid, PoolPid, TimeoutMs}, State) ->
    WorkerPid = self(),
    RuntimeModule = State#state.runtime_module,
    RuntimeHandle = State#state.runtime_handle,

    % Execute in a separate process with timeout protection (double-spawn pattern)
    spawn_link(fun() ->
        CallRef = make_ref(),
        OuterPid = self(),

        % Spawn the actual runtime call in a separate process
        CallPid = spawn_link(fun() ->
            logger:debug("ErlCracker worker ~p: Starting ~p:call_function for ~p:~p",
                [WorkerPid, RuntimeModule, Module, Function]),
            try
                Result = RuntimeModule:call_function(RuntimeHandle, Module, Function, Args),
                logger:debug("ErlCracker worker ~p: call_function completed", [WorkerPid]),
                OuterPid ! {CallRef, {ok, Result}}
            catch
                Error:Reason:Stacktrace ->
                    logger:error("Runtime call failed: ~p:~p~nStacktrace: ~p",
                        [Error, Reason, Stacktrace]),
                    OuterPid ! {CallRef, {error, {Error, Reason}}}
            end
        end),

        % Wait for result or timeout
        receive
            {CallRef, Result} ->
                % Call completed in time - notify worker for call counting
                WorkerPid ! call_completed,
                case Result of
                    {ok, Value} ->
                        CallerPid ! {runtime_result, WorkerPid, {ok, Value}},
                        PoolPid ! {worker_done, WorkerPid, {ok, Value}};
                    {error, ErrorReason} ->
                        CallerPid ! {runtime_result, WorkerPid, {error, ErrorReason}},
                        PoolPid ! {worker_done, WorkerPid, {error, ErrorReason}}
                end
        after TimeoutMs ->
            % Timeout - kill the call process
            logger:error("ErlCracker worker ~p: Call to ~p:~p timed out after ~pms, killing call process ~p",
                [WorkerPid, Module, Function, TimeoutMs, CallPid]),
            exit(CallPid, kill),
            % Notify worker for call counting (timeouts still count)
            WorkerPid ! call_completed,
            % Send timeout error to caller and pool
            CallerPid ! {runtime_result, WorkerPid, {error, worker_timeout}},
            PoolPid ! {worker_done, WorkerPid, {error, worker_timeout}}
        end
    end),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(call_completed, State) ->
    NewCallCount = State#state.call_count + 1,
    NewState = State#state{call_count = NewCallCount},

    % Check if we need to recycle due to call count limit
    case State#state.max_calls of
        undefined ->
            {noreply, NewState};
        MaxCalls when NewCallCount >= MaxCalls ->
            logger:info("ErlCracker worker ~p: Recycling after ~p calls (limit: ~p)",
                [self(), NewCallCount, MaxCalls]),
            recycle_worker(NewState);
        _ ->
            {noreply, NewState}
    end;

handle_info(recycle_age_limit, State) ->
    Age = erlang:monotonic_time(millisecond) - State#state.started_at,
    logger:info("ErlCracker worker ~p: Recycling due to age limit (~pms, limit: ~pms, calls: ~p)",
        [self(), Age, State#state.max_age_ms, State#state.call_count]),
    recycle_worker(State);

handle_info({'EXIT', _Pid, normal}, State) ->
    % Linked process finished normally
    {noreply, State};

handle_info({'EXIT', _Pid, Reason}, State) ->
    % A task process died
    logger:warning("ErlCracker worker ~p: Task process died: ~p", [self(), Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    % Stop runtime gracefully
    case Reason of
        normal ->
            logger:info("ErlCracker worker ~p shutting down normally", [self()]);
        shutdown ->
            logger:info("ErlCracker worker ~p shutting down (supervisor shutdown)", [self()]);
        {runtime_died, _} ->
            ok;  % Already logged
        _ ->
            logger:warning("ErlCracker worker ~p terminating unexpectedly: ~p", [self(), Reason])
    end,
    catch (State#state.runtime_module):stop_runtime(State#state.runtime_handle),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% Recycle worker by stopping old runtime and starting fresh one
recycle_worker(State) ->
    RuntimeModule = State#state.runtime_module,
    PoolConfig = State#state.pool_config,
    PoolName = State#state.pool_name,

    % Cancel any existing age timer
    case State#state.age_timer_ref of
        undefined -> ok;
        TimerRef -> erlang:cancel_timer(TimerRef)
    end,

    % Stop old runtime gracefully
    catch RuntimeModule:stop_runtime(State#state.runtime_handle),

    % Start fresh runtime
    case RuntimeModule:start_runtime(PoolConfig) of
        {ok, NewRuntimeHandle} ->
            logger:info("ErlCracker worker ~p: Recycled successfully with fresh ~p runtime",
                [self(), RuntimeModule]),

            % Set up new age timer if configured
            NewAgeTimerRef = case State#state.max_age_ms of
                undefined -> undefined;
                Ms when is_integer(Ms), Ms > 0 ->
                    erlang:send_after(Ms, self(), recycle_age_limit)
            end,

            % Re-register with pool
            PoolName ! {worker_available, self()},

            {noreply, State#state{
                runtime_handle = NewRuntimeHandle,
                call_count = 0,
                started_at = erlang:monotonic_time(millisecond),
                age_timer_ref = NewAgeTimerRef
            }};
        {error, Reason} ->
            logger:error("ErlCracker worker ~p: Failed to recycle runtime ~p: ~p",
                [self(), RuntimeModule, Reason]),
            {stop, {recycle_failed, Reason}, State}
    end.
