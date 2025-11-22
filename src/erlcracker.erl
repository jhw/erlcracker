-module(erlcracker).

%%% ErlCracker Public API
%%%
%%% A Firecracker/Lambda-inspired execution environment manager for Erlang.
%%% Manages pre-warmed persistent runtimes (Python, Go, etc.) with fire-and-forget invocation.

%% Pool management API
-export([start_pool/3, stop_pool/1]).

%% Runtime invocation API
-export([call/4, call/5, call_async/4]).

%%====================================================================
%% Pool Management API
%%====================================================================

%% Start a runtime pool
%%
%% PoolName - Atom to register the pool (e.g., my_python_pool)
%% RuntimeModule - Module implementing erlcracker_runtime behaviour (e.g., erlcracker_python_runtime)
%% PoolConfig - Configuration map:
%%   - pool_size: Number of workers (default: 2)
%%   - worker_timeout_ms: Worker-side timeout (default: 45000)
%%   - Runtime-specific config (e.g., python_path for Python)
%%
%% Returns: {ok, PoolSupPid} | {error, Reason}
%%
%% Example:
%%   erlcracker:start_pool(
%%       my_pool,
%%       erlcracker_python_runtime,
%%       #{pool_size => 4, worker_timeout_ms => 30000, python_path => "priv/python"}
%%   ).
%%
-spec start_pool(PoolName :: atom(), RuntimeModule :: module(), PoolConfig :: map()) ->
    {ok, pid()} | {error, term()}.
start_pool(PoolName, RuntimeModule, PoolConfig) ->
    erlcracker_pool_sup:start_link(PoolName, RuntimeModule, PoolConfig).

%% Stop a runtime pool
%%
%% Terminates the pool supervisor and all workers.
%% Returns: ok | {error, Reason}
%%
-spec stop_pool(PoolName :: atom()) -> ok | {error, term()}.
stop_pool(PoolName) ->
    SupName = list_to_atom(atom_to_list(PoolName) ++ "_sup"),
    case whereis(SupName) of
        undefined ->
            {error, not_found};
        Pid ->
            exit(Pid, shutdown),
            ok
    end.

%%====================================================================
%% Runtime Invocation API
%%====================================================================

%% Call runtime function with default timeout (5 seconds)
%%
%% PoolName - The pool to use
%% Module - Module/namespace in the runtime (atom or binary)
%% Function - Function to call (atom or binary)
%% Args - List of arguments
%%
%% Returns: {ok, Result} | {error, Reason}
%%
%% Example:
%%   erlcracker:call(my_pool, math, fibonacci, [10]).
%%
-spec call(PoolName :: atom(), Module :: atom() | binary(), Function :: atom() | binary(), Args :: list()) ->
    {ok, term()} | {error, term()}.
call(PoolName, Module, Function, Args) ->
    call(PoolName, Module, Function, Args, 5000).

%% Call runtime function with custom timeout
%%
%% PoolName - The pool to use
%% Module - Module/namespace in the runtime
%% Function - Function to call
%% Args - List of arguments
%% Timeout - Caller-side timeout in milliseconds
%%
%% Returns: {ok, Result} | {error, Reason}
%%
%% Example:
%%   erlcracker:call(my_pool, mymodule, expensive_function, [Data], 30000).
%%
-spec call(
    PoolName :: atom(),
    Module :: atom() | binary(),
    Function :: atom() | binary(),
    Args :: list(),
    Timeout :: non_neg_integer()
) -> {ok, term()} | {error, term()}.
call(PoolName, Module, Function, Args, Timeout) ->
    erlcracker_pool:call_and_await(PoolName, {Module, Function, Args}, Timeout).

%% Call runtime function asynchronously
%%
%% Result will be sent as {runtime_result, WorkerPid, Result} message.
%% Caller is responsible for receiving the message.
%%
%% Returns: ok
%%
%% Example:
%%   erlcracker:call_async(my_pool, mymodule, myfunction, [Arg1, Arg2]),
%%   receive
%%       {runtime_result, _, {ok, Result}} -> Result;
%%       {runtime_result, _, {error, Reason}} -> {error, Reason}
%%   after 10000 ->
%%       {error, timeout}
%%   end.
%%
-spec call_async(PoolName :: atom(), Module :: atom() | binary(), Function :: atom() | binary(), Args :: list()) -> ok.
call_async(PoolName, Module, Function, Args) ->
    erlcracker_pool:call_runtime(PoolName, {Module, Function, Args}, self()),
    ok.
