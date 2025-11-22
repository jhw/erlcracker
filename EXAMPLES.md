# ErlCracker Usage Examples

Practical examples showing common usage patterns for ErlCracker.

## Table of Contents

- [Basic Python Integration](#basic-python-integration)
- [Error Handling](#error-handling)
- [Concurrent Execution](#concurrent-execution)
- [Timeout Management](#timeout-management)
- [Custom Runtime Implementation](#custom-runtime-implementation)

## Basic Python Integration

### Simple Function Calls

**Python module** (`priv/python/calculator.py`):

```python
def add(a, b):
    return a + b

def multiply(a, b):
    return a * b

def divide(a, b):
    if b == 0:
        raise ValueError("Cannot divide by zero")
    return a / b
```

**Erlang usage**:

```erlang
start() ->
    % Start pool
    {ok, _Pid} = erlcracker:start_pool(
        calc_pool,
        erlcracker_python_runtime,
        #{pool_size => 2, python_path => "priv/python"}
    ),

    % Call functions
    {ok, 10} = erlcracker:call(calc_pool, calculator, add, [4, 6]),
    {ok, 24} = erlcracker:call(calc_pool, calculator, multiply, [4, 6]),
    {ok, 2.0} = erlcracker:call(calc_pool, calculator, divide, [10, 5]),

    % Error handling
    {error, _} = erlcracker:call(calc_pool, calculator, divide, [10, 0]),

    % Stop pool
    ok = erlcracker:stop_pool(calc_pool).
```

### Working with Complex Data

**Python module** (`priv/python/data_processor.py`):

```python
import json

def process_user(user_dict):
    """Process user data and return enhanced version."""
    return {
        'id': user_dict['id'],
        'name': user_dict['name'].upper(),
        'email': user_dict['email'].lower(),
        'processed': True
    }

def batch_process(users_list):
    """Process multiple users."""
    return [process_user(user) for user in users_list]

def analyze_text(text):
    """Return text analysis."""
    return {
        'length': len(text),
        'words': len(text.split()),
        'upper': text.upper(),
        'reversed': text[::-1]
    }
```

**Erlang usage**:

```erlang
process_data() ->
    % Start pool
    erlcracker:start_pool(
        data_pool,
        erlcracker_python_runtime,
        #{pool_size => 4, python_path => "priv/python"}
    ),

    % Process single user
    User = #{id => 1, name => <<"john doe">>, email => <<"JOHN@EXAMPLE.COM">>},
    {ok, ProcessedUser} = erlcracker:call(data_pool, data_processor, process_user, [User]),
    % ProcessedUser = #{id => 1, name => <<"JOHN DOE">>, email => <<"john@example.com">>, ...}

    % Batch process
    Users = [
        #{id => 1, name => <<"alice">>, email => <<"ALICE@TEST.COM">>},
        #{id => 2, name => <<"bob">>, email => <<"BOB@TEST.COM">>}
    ],
    {ok, ProcessedUsers} = erlcracker:call(data_pool, data_processor, batch_process, [Users]),

    % Text analysis
    {ok, Analysis} = erlcracker:call(data_pool, data_processor, analyze_text, [<<"Hello World">>]),
    % Analysis = #{length => 11, words => 2, upper => <<"HELLO WORLD">>, ...}

    ok.
```

## Error Handling

### Handling Runtime Errors

```erlang
safe_call(PoolName, Module, Function, Args) ->
    case erlcracker:call(PoolName, Module, Function, Args, 5000) of
        {ok, Result} ->
            logger:info("Success: ~p", [Result]),
            {ok, Result};

        {error, timeout} ->
            logger:error("Caller timeout waiting for result"),
            {error, caller_timeout};

        {error, worker_timeout} ->
            logger:error("Worker timeout executing function"),
            {error, execution_timeout};

        {error, {python_error, Reason}} ->
            logger:error("Python error: ~p", [Reason]),
            {error, {runtime_error, Reason}};

        {error, Reason} ->
            logger:error("Unknown error: ~p", [Reason]),
            {error, Reason}
    end.
```

### Retry Logic

```erlang
call_with_retry(PoolName, Module, Function, Args, MaxRetries) ->
    call_with_retry(PoolName, Module, Function, Args, MaxRetries, 0).

call_with_retry(_PoolName, _Module, _Function, _Args, MaxRetries, MaxRetries) ->
    {error, max_retries_exceeded};

call_with_retry(PoolName, Module, Function, Args, MaxRetries, Attempt) ->
    case erlcracker:call(PoolName, Module, Function, Args, 5000) of
        {ok, Result} ->
            {ok, Result};
        {error, worker_timeout} ->
            logger:warning("Attempt ~p/~p timed out, retrying...", [Attempt + 1, MaxRetries]),
            timer:sleep(1000),  % Backoff
            call_with_retry(PoolName, Module, Function, Args, MaxRetries, Attempt + 1);
        {error, Reason} ->
            {error, Reason}
    end.

% Usage
{ok, Result} = call_with_retry(my_pool, my_module, my_function, [Args], 3).
```

## Concurrent Execution

### Parallel Processing

```erlang
parallel_process(Items) ->
    % Start pool
    erlcracker:start_pool(
        worker_pool,
        erlcracker_python_runtime,
        #{pool_size => 8, python_path => "priv/python"}
    ),

    % Process items concurrently
    Parent = self(),
    lists:foreach(
        fun(Item) ->
            spawn(fun() ->
                Result = erlcracker:call(worker_pool, processor, process_item, [Item], 10000),
                Parent ! {result, Item, Result}
            end)
        end,
        Items
    ),

    % Collect results
    Results = collect_results(length(Items), []),

    erlcracker:stop_pool(worker_pool),
    Results.

collect_results(0, Acc) ->
    lists:reverse(Acc);
collect_results(N, Acc) ->
    receive
        {result, Item, Result} ->
            collect_results(N - 1, [{Item, Result} | Acc])
    after 30000 ->
        {error, timeout}
    end.
```

### Async Fire-and-Forget

```erlang
send_notifications(Users) ->
    % Start pool
    erlcracker:start_pool(
        notifier_pool,
        erlcracker_python_runtime,
        #{pool_size => 4, python_path => "priv/python"}
    ),

    % Send all notifications asynchronously (fire-and-forget)
    lists:foreach(
        fun(User) ->
            Email = maps:get(email, User),
            Name = maps:get(name, User),
            erlcracker:call_async(
                notifier_pool,
                email_sender,
                send_welcome_email,
                [Email, Name]
            )
        end,
        Users
    ),

    % Optionally collect results
    collect_notification_results(length(Users)).

collect_notification_results(0) ->
    ok;
collect_notification_results(N) ->
    receive
        {runtime_result, _WorkerPid, {ok, _Result}} ->
            logger:info("Notification sent successfully"),
            collect_notification_results(N - 1);
        {runtime_result, _WorkerPid, {error, Reason}} ->
            logger:error("Notification failed: ~p", [Reason]),
            collect_notification_results(N - 1)
    after 10000 ->
        logger:warning("~p notifications timed out", [N]),
        {error, timeout}
    end.
```

## Timeout Management

### Different Timeout Scenarios

```erlang
timeout_examples() ->
    erlcracker:start_pool(
        timeout_pool,
        erlcracker_python_runtime,
        #{
            pool_size => 2,
            worker_timeout_ms => 45000,  % Worker-side timeout: 45s
            python_path => "priv/python"
        }
    ),

    % Fast operation - 5 second caller timeout is plenty
    {ok, Result1} = erlcracker:call(
        timeout_pool,
        quick_ops,
        fast_function,
        [Args],
        5000  % Caller timeout: 5s
    ),

    % Slow operation - needs longer caller timeout
    {ok, Result2} = erlcracker:call(
        timeout_pool,
        slow_ops,
        expensive_function,
        [BigData],
        30000  % Caller timeout: 30s
    ),

    % Very slow operation - configure worker_timeout_ms > 45s in pool config
    % This will hit worker_timeout_ms (45s) before caller timeout (60s)
    case erlcracker:call(
        timeout_pool,
        very_slow_ops,
        extremely_expensive_function,
        [HugeData],
        60000  % Caller timeout: 60s
    ) of
        {ok, Result3} -> Result3;
        {error, worker_timeout} ->
            logger:error("Hit worker timeout (45s)"),
            {error, too_slow}
    end.
```

### Adaptive Timeout

```erlang
adaptive_call(PoolName, Module, Function, Args, EstimatedMs) ->
    % Add 50% buffer to estimated time
    Timeout = trunc(EstimatedMs * 1.5),

    logger:info("Calling ~p:~p with timeout ~pms", [Module, Function, Timeout]),

    case erlcracker:call(PoolName, Module, Function, Args, Timeout) of
        {ok, Result} ->
            {ok, Result};
        {error, timeout} ->
            logger:error("Exceeded estimated time of ~pms", [EstimatedMs]),
            {error, timeout};
        {error, Reason} ->
            {error, Reason}
    end.

% Usage
{ok, Result} = adaptive_call(my_pool, processor, process, [Data], 5000).
```

## Custom Runtime Implementation

### Simple Echo Runtime (for testing)

```erlang
-module(erlcracker_echo_runtime).
-behaviour(erlcracker_runtime).

-export([start_runtime/1, call_function/4, stop_runtime/1]).

%% Start runtime - just return a dummy handle
start_runtime(_Config) ->
    Handle = make_ref(),
    logger:info("Echo runtime started: ~p", [Handle]),
    {ok, Handle}.

%% Echo back the arguments
call_function(_Handle, Module, Function, Args) ->
    logger:info("Echo: ~p:~p(~p)", [Module, Function, Args]),
    {echo, Module, Function, Args}.

%% Stop runtime
stop_runtime(Handle) ->
    logger:info("Echo runtime stopped: ~p", [Handle]),
    ok.
```

**Usage**:

```erlang
test_echo_runtime() ->
    % Start pool with echo runtime
    erlcracker:start_pool(
        echo_pool,
        erlcracker_echo_runtime,
        #{pool_size => 2}
    ),

    % All calls echo back
    {ok, {echo, test, foo, [1, 2, 3]}} =
        erlcracker:call(echo_pool, test, foo, [1, 2, 3]),

    erlcracker:stop_pool(echo_pool).
```

### Port-Based Runtime (for Go, Node.js, etc.)

```erlang
-module(erlcracker_port_runtime).
-behaviour(erlcracker_runtime).

-export([start_runtime/1, call_function/4, stop_runtime/1]).

start_runtime(Config) ->
    Command = maps:get(command, Config),
    Args = maps:get(args, Config, []),

    % Open port to external program
    Port = erlang:open_port(
        {spawn_executable, Command},
        [{args, Args}, {packet, 4}, binary, use_stdio, exit_status]
    ),

    logger:info("Port runtime started: ~p", [Port]),
    {ok, Port}.

call_function(Port, Module, Function, Args) ->
    % Encode request as term
    Request = {call, Module, Function, Args},
    Bin = term_to_binary(Request),

    % Send to port
    Port ! {self(), {command, Bin}},

    % Wait for response
    receive
        {Port, {data, ResponseBin}} ->
            binary_to_term(ResponseBin);
        {Port, {exit_status, Status}} ->
            {error, {port_exit, Status}}
    after 5000 ->
        {error, port_timeout}
    end.

stop_runtime(Port) ->
    erlang:port_close(Port),
    ok.
```

This can interface with Go, Node.js, or any program that speaks the port protocol.
