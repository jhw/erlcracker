-module(erlcracker_go_runtime).
-behaviour(erlcracker_runtime).

%%% Go Runtime Implementation
%%%
%%% Implements the erlcracker_runtime behaviour for Go using ErlPort.
%%% Manages Go process instances and executes Go function calls.
%%%
%%% DATA MARSHALLING:
%%% All data exchange with Go uses JSON:
%%%   - Args are JSON-encoded before sending to Go
%%%   - Results are JSON-decoded after receiving from Go
%%% This provides a simple, universal format that works across all runtimes.
%%%
%%% NOTE: ErlPort uses Erlang's external term format at the protocol level,
%%% but we layer JSON on top for consistency with the Python runtime and to
%%% avoid type mapping quirks (e.g., strings vs binaries).

%% erlcracker_runtime callbacks
-export([start_runtime/1, call_function/4, stop_runtime/1]).

%%====================================================================
%% erlcracker_runtime callbacks
%%====================================================================

%% Start a Go runtime instance
%%
%% Config may include:
%%   - go_src: Path to Go source file to compile and run (REQUIRED)
%%   - go_path: Additional GOPATH directories
%%   - go: Go executable command (default: "go")
%%
%% Returns: {ok, GoPid} | {error, Reason}
%%
start_runtime(Config) ->
    % Extract Go configuration
    GoSrc = maps:get(go_src, Config),

    % Build ErlPort options - go_src is required
    ErlPortOpts = [{go_src, GoSrc}],

    % Add optional go_path
    ErlPortOptsWithPath = case maps:get(go_path, Config, undefined) of
        undefined -> ErlPortOpts;
        GoPath -> [{go_path, GoPath} | ErlPortOpts]
    end,

    % Add optional go executable
    ErlPortOptsWithGo = case maps:get(go, Config, undefined) of
        undefined -> ErlPortOptsWithPath;
        GoCmd -> [{go, GoCmd} | ErlPortOptsWithPath]
    end,

    % Start Go instance
    logger:debug("Starting Go runtime with opts: ~p", [ErlPortOptsWithGo]),
    case go:start(ErlPortOptsWithGo) of
        {ok, GoPid} ->
            logger:info("Go runtime started successfully: ~p (source: ~s)", [GoPid, GoSrc]),
            {ok, GoPid};
        {error, Reason} ->
            logger:error("Failed to start Go runtime: ~p (source: ~s)", [Reason, GoSrc]),
            {error, Reason}
    end.

%% Call a Go function
%%
%% RuntimeHandle - Go process PID from start_runtime/1
%% Module - Module name (atom or binary) - IGNORED by Go (flat namespace)
%% Function - Function name (atom or binary)
%% Args - List of Erlang terms to pass as arguments
%%
%% Returns: Erlang term (decoded from JSON response)
%% May throw/raise on errors
%%
%% IMPORTANT: Go functions must accept []byte and return []byte.
%% If Args is a single-element list [Data], we encode Data as JSON and pass it.
%% The Go function receives a JSON binary and must return a JSON binary.
%%
call_function(GoPid, Module, Function, Args) ->
    logger:debug("Go call starting: ~p:~p with args: ~p", [Module, Function, Args]),

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

    % Call Go function with JSON arguments
    % Note: Module parameter is ignored by Go (flat namespace)
    logger:debug("Calling Go ~p:~p with JSON args: ~p", [Module, Function, JsonArgs]),
    JsonResult = go:call(GoPid, Module, Function, JsonArgs),
    logger:debug("Go call completed, JSON result: ~p", [JsonResult]),

    % Decode JSON response back to Erlang term
    % Note: thoas:decode returns {ok, Term} | {error, Reason}
    case thoas:decode(JsonResult) of
        {ok, Result} ->
            logger:debug("Go result decoded successfully: ~p", [Result]),
            Result;
        {error, DecodeReason} ->
            logger:error("JSON decode failed: ~p, raw result: ~p", [DecodeReason, JsonResult]),
            error({json_decode_failed, DecodeReason, JsonResult})
    end.

%% Stop a Go runtime instance
%%
%% RuntimeHandle - Go process PID from start_runtime/1
%%
%% Returns: ok
%%
stop_runtime(GoPid) ->
    logger:debug("Stopping Go runtime: ~p", [GoPid]),
    go:stop(GoPid),
    ok.
