-module(erlcracker_python_runtime).
-behaviour(erlcracker_runtime).

%%% Python Runtime Implementation
%%%
%%% Implements the erlcracker_runtime behaviour for Python using ErlPort.
%%% Manages Python interpreter instances and executes Python function calls.
%%%
%%% DATA MARSHALLING:
%%% All data exchange with Python uses JSON:
%%%   - Args are JSON-encoded before sending to Python
%%%   - Results are JSON-decoded after receiving from Python
%%% This provides a simple, universal format that works across all runtimes.

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
    logger:debug("Starting Python runtime with opts: ~p", [ErlPortOptsWithInterpreter]),
    case python:start(ErlPortOptsWithInterpreter) of
        {ok, PythonPid} ->
            logger:info("Python runtime started successfully: ~p (path: ~s)", [PythonPid, PythonPath]),
            {ok, PythonPid};
        {error, Reason} ->
            logger:error("Failed to start Python runtime: ~p (path: ~s)", [Reason, PythonPath]),
            {error, Reason}
    end.

%% Call a Python function
%%
%% RuntimeHandle - Python process PID from start_runtime/1
%% Module - Python module name (atom or binary)
%% Function - Function name (atom or binary)
%% Args - List of Erlang terms to pass as arguments
%%
%% Returns: Erlang term (decoded from JSON response)
%% May throw/raise on errors
%%
%% IMPORTANT: Python functions must return JSON strings.
%% If Args is a single-element list [Data], we encode Data as JSON and pass it.
%% The Python function receives a JSON string and must return a JSON string.
%%
call_function(PythonPid, Module, Function, Args) ->
    logger:debug("Python call starting: ~p:~p with args: ~p", [Module, Function, Args]),

    % Encode arguments as JSON
    % For single argument [Data], encode Data directly
    % For multiple arguments, encode as JSON array
    % Note: thoas:encode returns the binary directly (not {ok, Binary})
    JsonArgs = case Args of
        [SingleArg] ->
            % Single argument - encode it directly
            try thoas:encode(SingleArg) of
                Json -> [Json]
            catch
                error:Reason -> error({json_encode_failed, Reason})
            end;
        MultipleArgs ->
            % Multiple arguments - encode each one
            lists:map(fun(Arg) ->
                try thoas:encode(Arg) of
                    Json -> Json
                catch
                    error:Reason -> error({json_encode_failed, Reason})
                end
            end, MultipleArgs)
    end,

    % Call Python function with JSON arguments
    logger:debug("Calling Python ~p:~p with JSON args: ~p", [Module, Function, JsonArgs]),
    JsonResult = python:call(PythonPid, Module, Function, JsonArgs),
    logger:debug("Python call completed, JSON result: ~p", [JsonResult]),

    % Decode JSON response back to Erlang term
    % Note: thoas:decode returns {ok, Term} | {error, Reason}
    case thoas:decode(JsonResult) of
        {ok, Result} ->
            logger:debug("Python result decoded successfully: ~p", [Result]),
            Result;
        {error, DecodeReason} ->
            logger:error("JSON decode failed: ~p, raw result: ~p", [DecodeReason, JsonResult]),
            error({json_decode_failed, DecodeReason, JsonResult})
    end.

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
