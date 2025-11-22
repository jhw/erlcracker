-module(erlcracker_runtime).

%%% Runtime Behaviour
%%%
%%% Defines the callback interface that all runtime implementations must provide.
%%% Runtime modules (Python, Go, Node.js, etc.) implement these callbacks to integrate
%%% with ErlCracker's execution environment management.

%% Callback definitions
-callback start_runtime(Config :: map()) ->
    {ok, RuntimeHandle :: term()} | {error, Reason :: term()}.

-callback call_function(
    RuntimeHandle :: term(),
    Module :: atom() | binary(),
    Function :: atom() | binary(),
    Args :: list()
) ->
    term().

-callback stop_runtime(RuntimeHandle :: term()) -> ok.

%%====================================================================
%% Callback Documentation
%%====================================================================

%% start_runtime/1
%%
%% Initialize a new runtime instance with the provided configuration.
%% This is called once per worker during initialization.
%%
%% Config - Configuration map that may include:
%%   - Runtime-specific paths (e.g., python_path, go_binary_path)
%%   - Environment variables
%%   - Initialization parameters
%%   - Timeout settings
%%
%% Returns:
%%   {ok, RuntimeHandle} - Opaque handle to the runtime instance
%%   {error, Reason} - If initialization fails
%%
%% Example Python implementation:
%%   start_runtime(Config) ->
%%       PythonPath = maps:get(python_path, Config, "priv/python"),
%%       case python:start([{python_path, PythonPath}]) of
%%           {ok, Pid} -> {ok, Pid};
%%           {error, Reason} -> {error, Reason}
%%       end.

%% call_function/4
%%
%% Execute a function in the runtime with the given arguments.
%% This is the core execution primitive called for each invocation.
%%
%% RuntimeHandle - Handle returned from start_runtime/1
%% Module - Module/namespace in the runtime (atom or binary)
%% Function - Function to call (atom or binary)
%% Args - List of arguments to pass to the function
%%
%% Returns:
%%   Any term - The result of the function execution
%%   May throw/raise on errors
%%
%% Example Python implementation:
%%   call_function(Pid, Module, Function, Args) ->
%%       python:call(Pid, Module, Function, Args).

%% stop_runtime/1
%%
%% Gracefully shut down the runtime instance.
%% Called during worker termination.
%%
%% RuntimeHandle - Handle returned from start_runtime/1
%%
%% Returns: ok
%%
%% Example Python implementation:
%%   stop_runtime(Pid) ->
%%       python:stop(Pid).
