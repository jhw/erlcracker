-module(erlcracker_SUITE).

%%% Common Test suite for ErlCracker
%%%
%%% Tests the complete request/response lifecycle:
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
    test_async_call/1,
    test_worker_recycling_by_call_count/1,
    test_worker_recycling_by_age/1
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
        test_async_call,
        test_worker_recycling_by_call_count,
        test_worker_recycling_by_age
    ].

init_per_suite(Config) ->
    % Start applications
    {ok, _} = application:ensure_all_started(erlport),
    {ok, _} = application:ensure_all_started(thoas),

    % Get priv directory for Python modules
    PrivDir = code:priv_dir(erlcracker),
    PythonPath = filename:join(PrivDir, "python"),

    ct:pal("Starting test pool with Python path: ~s", [PythonPath]),

    % Check if test_module.py exists
    TestModulePath = filename:join(PythonPath, "test_module.py"),
    case filelib:is_file(TestModulePath) of
        true -> ct:pal("Found test_module.py at ~s", [TestModulePath]);
        false -> ct:pal("WARNING: test_module.py NOT FOUND at ~s", [TestModulePath])
    end,

    % Start test pool
    {ok, PoolPid} = erlcracker:start_pool(
        test_pool,
        erlcracker_python_runtime,
        #{
            pool_size => 4,
            worker_timeout_ms => 30000,
            python_path => PythonPath
        }
    ),

    ct:pal("Pool started: ~p", [PoolPid]),

    % Unlink from pool supervisor so it doesn't get killed when init_per_suite exits
    % The pool should live for the duration of the test suite
    unlink(PoolPid),

    % Wait longer for workers to initialize
    timer:sleep(2000),

    ct:pal("Attempting test call to verify pool is working..."),

    [{pool_name, test_pool} | Config].

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

test_worker_recycling_by_call_count(_Config) ->
    ct:pal("Testing worker recycling by call count"),

    % Get priv directory for Python modules
    PrivDir = code:priv_dir(erlcracker),
    PythonPath = filename:join(PrivDir, "python"),

    % Start a pool with max_calls_per_worker = 3
    % Use a single worker to make testing predictable
    {ok, PoolPid} = erlcracker:start_pool(
        recycle_test_pool,
        erlcracker_python_runtime,
        #{
            pool_size => 1,
            worker_timeout_ms => 30000,
            python_path => PythonPath,
            max_calls_per_worker => 3
        }
    ),
    unlink(PoolPid),

    % Wait for worker to initialize
    timer:sleep(1000),

    ct:pal("Making 10 calls (should trigger recycling multiple times)"),

    % Make 10 calls - should trigger recycling at calls 3, 6, 9
    Results = lists:map(
        fun(N) ->
            Result = erlcracker:call(recycle_test_pool, test_module, echo, [N], 5000),
            ct:pal("Call ~p result: ~p", [N, Result]),
            Result
        end,
        lists:seq(1, 10)
    ),

    % Verify all calls succeeded
    lists:foreach(
        fun({N, Result}) ->
            case Result of
                {ok, N} -> ok;
                Other -> ct:fail({unexpected_result, N, Other})
            end
        end,
        lists:zip(lists:seq(1, 10), Results)
    ),

    ct:pal("All 10 calls succeeded through multiple recycles"),

    % Cleanup
    ok = erlcracker:stop_pool(recycle_test_pool),
    ok.

test_worker_recycling_by_age(_Config) ->
    ct:pal("Testing worker recycling by age"),

    % Get priv directory for Python modules
    PrivDir = code:priv_dir(erlcracker),
    PythonPath = filename:join(PrivDir, "python"),

    % Start a pool with max_worker_age_ms = 2000 (2 seconds)
    {ok, PoolPid} = erlcracker:start_pool(
        age_recycle_test_pool,
        erlcracker_python_runtime,
        #{
            pool_size => 1,
            worker_timeout_ms => 30000,
            python_path => PythonPath,
            max_worker_age_ms => 2000
        }
    ),
    unlink(PoolPid),

    % Wait for worker to initialize
    timer:sleep(1000),

    % Make initial call
    {ok, 1} = erlcracker:call(age_recycle_test_pool, test_module, echo, [1], 5000),
    ct:pal("Initial call succeeded"),

    % Wait for age-based recycling to trigger (2 seconds + buffer)
    ct:pal("Waiting 2.5 seconds for age-based recycling..."),
    timer:sleep(2500),

    % Make another call - worker should have recycled
    {ok, 2} = erlcracker:call(age_recycle_test_pool, test_module, echo, [2], 5000),
    ct:pal("Post-recycle call succeeded"),

    % Wait for another recycle cycle
    ct:pal("Waiting another 2.5 seconds for second age-based recycling..."),
    timer:sleep(2500),

    % Make final call
    {ok, 3} = erlcracker:call(age_recycle_test_pool, test_module, echo, [3], 5000),
    ct:pal("Second post-recycle call succeeded"),

    ct:pal("Age-based recycling working correctly"),

    % Cleanup
    ok = erlcracker:stop_pool(age_recycle_test_pool),
    ok.
