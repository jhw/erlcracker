-module(erlcracker_python_runtime).
-behaviour(erlcracker_runtime).

%%% Python Runtime Implementation
%%%
%%% Implements the erlcracker_runtime behaviour for Python using ErlPort.
%%% Manages Python interpreter instances and executes Python function calls.

%% erlcracker_runtime callbacks
-export([start_runtime/1, call_function/4, stop_runtime/1]).

%%====================================================================
%% erlcracker_runtime callbacks
%%====================================================================

%% Start a Python runtime instance
%%
%% Config may include:
%%   - python_path: Path to Python modules directory (default: "priv/python")
%%   - python: Python interpreter command (default: "python3")
%%
%% Returns: {ok, PythonPid} | {error, Reason}
%%
start_runtime(Config) ->
    % Extract Python configuration
    PythonPath = maps:get(python_path, Config, "priv/python"),

    % Build ErlPort options
    ErlPortOpts = [{python_path, PythonPath}],

    % Optionally specify Python interpreter
    ErlPortOptsWithInterpreter = case maps:get(python, Config, undefined) of
        undefined -> ErlPortOpts;
        PythonCmd -> [{python, PythonCmd} | ErlPortOpts]
    end,

    % Start Python instance
    case python:start(ErlPortOptsWithInterpreter) of
        {ok, PythonPid} ->
            logger:debug("Python runtime started: ~p (path: ~s)", [PythonPid, PythonPath]),
            {ok, PythonPid};
        {error, Reason} ->
            logger:error("Failed to start Python runtime: ~p", [Reason]),
            {error, Reason}
    end.

%% Call a Python function
%%
%% RuntimeHandle - Python process PID from start_runtime/1
%% Module - Python module name (atom or binary)
%% Function - Function name (atom or binary)
%% Args - List of arguments
%%
%% Returns: Result of the Python function call
%% May throw/raise on errors
%%
call_function(PythonPid, Module, Function, Args) ->
    % ErlPort's python:call/4 handles the communication
    python:call(PythonPid, Module, Function, Args).

%% Stop a Python runtime instance
%%
%% RuntimeHandle - Python process PID from start_runtime/1
%%
%% Returns: ok
%%
stop_runtime(PythonPid) ->
    logger:debug("Stopping Python runtime: ~p", [PythonPid]),
    python:stop(PythonPid),
    ok.
