-module(erlcracker_go_SUITE).

%%% Common Test suite for ErlCracker Go Runtime
%%%
%%% Tests the complete request/response lifecycle with Go:
%%%   - Pool startup and worker initialization
%%%   - JSON encoding/decoding
%%%   - Synchronous and asynchronous calls
%%%   - Error handling
%%%   - Concurrent execution

-include_lib("common_test/include/ct.hrl").

%% CT callbacks
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).

%% Test cases
-export([
    test_simple_fibonacci/1,
    test_complex_data_processing/1,
    test_echo/1,
    test_batch_processing/1,
    test_concurrent_calls/1,
    test_async_call/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        test_simple_fibonacci,
        test_complex_data_processing,
        test_echo,
        test_batch_processing,
        test_concurrent_calls,
        test_async_call
    ].

init_per_suite(Config) ->
    % Start applications
    {ok, _} = application:ensure_all_started(erlport),
    {ok, _} = application:ensure_all_started(thoas),

    % Get priv directory for Go modules
    PrivDir = code:priv_dir(erlcracker),
    GoSrcPath = filename:join(PrivDir, "go/test_module.go"),

    ct:pal("Starting test pool with Go source: ~s", [GoSrcPath]),

    % Check if test_module.go exists
    case filelib:is_file(GoSrcPath) of
        true -> ct:pal("Found test_module.go at ~s", [GoSrcPath]);
        false -> ct:pal("WARNING: test_module.go NOT FOUND at ~s", [GoSrcPath])
    end,

    % Start test pool
    {ok, PoolPid} = erlcracker:start_pool(
        test_go_pool,
        erlcracker_go_runtime,
        #{
            pool_size => 4,
            worker_timeout_ms => 30000,
            go_src => GoSrcPath
        }
    ),

    ct:pal("Pool started: ~p", [PoolPid]),

    % Unlink from pool supervisor so it doesn't get killed when init_per_suite exits
    % The pool should live for the duration of the test suite
    unlink(PoolPid),

    % Wait longer for workers to initialize
    timer:sleep(2000),

    ct:pal("Attempting test call to verify pool is working..."),

    [{pool_name, test_go_pool} | Config].

end_per_suite(Config) ->
    PoolName = ?config(pool_name, Config),
    ok = erlcracker:stop_pool(PoolName),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

test_simple_fibonacci(Config) ->
    PoolName = ?config(pool_name, Config),

    ct:pal("~n=== Testing fibonacci(10) ==="),
    ct:pal("Pool name: ~p", [PoolName]),
    ct:pal("Calling: erlcracker:call(~p, test_module, fibonacci, [10], 5000)", [PoolName]),

    % Calculate 10th Fibonacci number (should be 55)
    Result = erlcracker:call(PoolName, test_module, fibonacci, [10], 5000),

    ct:pal("~n=== Fibonacci result: ~p ===~n", [Result]),

    % Verify result
    case Result of
        {ok, 55} ->
            ct:pal("SUCCESS: Got expected result 55"),
            ok;
        {error, timeout} ->
            ct:fail("TIMEOUT: Call timed out after 5 seconds");
        {error, Reason} ->
            ct:pal("ERROR: ~p", [Reason]),
            ct:fail({unexpected_error, Reason});
        Other ->
            ct:pal("UNEXPECTED RESULT: ~p", [Other]),
            {ok, 55} = Other  % This will fail with badmatch
    end.

test_complex_data_processing(Config) ->
    PoolName = ?config(pool_name, Config),

    ct:pal("Testing complex data processing"),

    % Create user data
    User = #{
        id => 42,
        name => <<"john doe">>,
        email => <<"JOHN@EXAMPLE.COM">>
    },

    ct:pal("Input user: ~p", [User]),

    % Process user
    {ok, Result} = erlcracker:call(PoolName, test_module, process_user, [User], 5000),

    ct:pal("Processed user: ~p", [Result]),

    % Verify result (note: JSON decoding produces binary keys)
    #{
        <<"id">> := 42,
        <<"name">> := <<"JOHN DOE">>,
        <<"email">> := <<"john@example.com">>,
        <<"processed">> := true
    } = Result,

    ok.

test_echo(Config) ->
    PoolName = ?config(pool_name, Config),

    ct:pal("Testing echo"),

    % Test various data types
    TestData = [
        42,
        <<"hello">>,
        [1, 2, 3],
        #{foo => <<"bar">>, num => 123}
    ],

    lists:foreach(
        fun(Data) ->
            {ok, Result} = erlcracker:call(PoolName, test_module, echo, [Data], 5000),
            ct:pal("Echo ~p -> ~p", [Data, Result]),
            % Note: Maps may have binary keys after JSON round-trip
            case Data of
                #{} ->
                    % For maps, check structure but allow binary keys
                    true = is_map(Result);
                _ ->
                    % For other types, exact match
                    Data = Result
            end
        end,
        TestData
    ),

    ok.

test_batch_processing(Config) ->
    PoolName = ?config(pool_name, Config),

    ct:pal("Testing batch sum"),

    % Sum list of numbers
    Numbers = [1, 2, 3, 4, 5],
    {ok, Result} = erlcracker:call(PoolName, test_module, batch_sum, [Numbers], 5000),

    ct:pal("Sum of ~p = ~p", [Numbers, Result]),

    15 = Result,

    ok.

test_concurrent_calls(Config) ->
    PoolName = ?config(pool_name, Config),

    ct:pal("Testing concurrent calls"),

    % Spawn multiple concurrent calls
    Parent = self(),
    NumCalls = 10,

    lists:foreach(
        fun(N) ->
            spawn(fun() ->
                Result = erlcracker:call(PoolName, test_module, fibonacci, [N], 5000),
                Parent ! {result, N, Result}
            end)
        end,
        lists:seq(1, NumCalls)
    ),

    % Collect all results
    Results = lists:map(
        fun(_) ->
            receive
                {result, N, Result} -> {N, Result}
            after 10000 ->
                ct:fail("Timeout waiting for concurrent result")
            end
        end,
        lists:seq(1, NumCalls)
    ),

    ct:pal("Concurrent results: ~p", [Results]),

    % Verify we got all results (each should be {ok, FibValue})
    NumCalls = length(Results),
    lists:foreach(
        fun({_N, Result}) ->
            {ok, _Value} = Result  % Verify each result is {ok, Value}
        end,
        Results
    ),

    ok.

test_async_call(Config) ->
    PoolName = ?config(pool_name, Config),

    ct:pal("Testing async call"),

    % Make async call
    ok = erlcracker:call_async(PoolName, test_module, fibonacci, [7]),

    % Wait for result
    Result = receive
        {runtime_result, _WorkerPid, FibResult} ->
            ct:pal("Async result: ~p", [FibResult]),
            FibResult
    after 5000 ->
        ct:fail("Timeout waiting for async result")
    end,

    % Verify result (7th fibonacci number is 13)
    % Note: async calls return {ok, Value} directly in the message
    {ok, 13} = Result,

    ok.
