# ErlCracker

> A Firecracker/Lambda-inspired execution environment manager for Erlang.

**ErlCracker** manages pre-warmed persistent runtimes (Python, Go, etc.) with fire-and-forget invocation. Like AWS Firecracker manages microVMs and Lambda invokes functions, ErlCracker manages runtime processes and executes calls with automatic lifecycle management.

## Features

- **Fire-and-Forget Invocation** - Call runtime functions without managing worker lifecycle
- **Pre-Warmed Runtimes** - Persistent interpreters eliminate cold-start overhead (~100ms → 30-40ms)
- **Async Initialization** - Workers register when ready, pool assigns queued work automatically
- **Execution Isolation** - Double-spawn timeout pattern protects pool from hung calls
- **Automatic Recovery** - OTP supervision restarts failed runtimes transparently
- **Queue Management** - Requests queue when workers busy, process when available
- **Runtime Agnostic** - Pluggable runtime backend via behaviour (Python, Go, Node.js, WASM)

## Architecture

```
erlcracker_pool_sup (rest_for_one)
  ├─ erlcracker_worker_sup (simple_one_for_one) - Worker lifecycle
  └─ erlcracker_pool (gen_server) - Work distribution

Workers:
  - Initialize runtime asynchronously
  - Send {worker_available, self()} when ready
  - Execute calls in isolated double-spawn processes
  - Auto-restart on crash with new runtime
```

### Why Not Poolboy?

**Poolboy**: Manual lifecycle (checkout → use → checkin), designed for stateless workers (DB connections)

**ErlCracker**: Automatic lifecycle (fire-and-forget), designed for stateful runtimes (persistent interpreters)

Poolboy requires callers to manage worker lifecycle. ErlCracker handles lifecycle automatically, providing a Lambda-like execution model.

## Installation

Add to `rebar.config`:

```erlang
{deps, [
    {erlcracker, {git, "https://github.com/yourusername/erlcracker.git", {branch, "main"}}}
]}.
```

## Quick Start

### 1. Start a Python Pool

```erlang
% Start pool with 4 Python workers
erlcracker:start_pool(
    my_python_pool,
    erlcracker_python_runtime,
    #{
        pool_size => 4,
        worker_timeout_ms => 30000,
        python_path => "priv/python"
    }
).
```

### 2. Call Python Functions

**Synchronous** (with 5 second timeout):

```erlang
{ok, Result} = erlcracker:call(my_python_pool, math_utils, fibonacci, [10]).
```

**Synchronous with custom timeout** (30 seconds):

```erlang
{ok, Result} = erlcracker:call(my_python_pool, data_processor, expensive_task, [Data], 30000).
```

**Asynchronous** (fire-and-forget):

```erlang
erlcracker:call_async(my_python_pool, notifier, send_email, [Recipient, Subject, Body]),
receive
    {runtime_result, _WorkerPid, {ok, Result}} -> Result;
    {runtime_result, _WorkerPid, {error, Reason}} -> {error, Reason}
after 10000 ->
    {error, timeout}
end.
```

### 3. Stop the Pool

```erlang
erlcracker:stop_pool(my_python_pool).
```

## Python Runtime Example

**Python module** (`priv/python/math_utils.py`):

```python
def fibonacci(n):
    """Calculate the nth Fibonacci number."""
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)

def factorial(n):
    """Calculate n!"""
    if n <= 1:
        return 1
    return n * factorial(n-1)
```

**Erlang usage**:

```erlang
% Fibonacci
{ok, 55} = erlcracker:call(my_python_pool, math_utils, fibonacci, [10]).

% Factorial
{ok, 120} = erlcracker:call(my_python_pool, math_utils, factorial, [5]).
```

## Configuration

### Pool Configuration

```erlang
#{
    pool_size => 4,              % Number of workers (default: 2)
    worker_timeout_ms => 45000   % Worker-side timeout (default: 45000)
    % ... runtime-specific config below
}
```

### Python Runtime Configuration

```erlang
#{
    python_path => "priv/python",  % Path to Python modules (default: "priv/python")
    python => "python3"            % Python interpreter (default: auto-detect)
}
```

**Example**:

```erlang
erlcracker:start_pool(
    my_pool,
    erlcracker_python_runtime,
    #{
        pool_size => 8,
        worker_timeout_ms => 60000,
        python_path => "/opt/myapp/python",
        python => "/usr/bin/python3.11"
    }
).
```

## Implementing Custom Runtimes

To add support for other languages (Go, Node.js, WASM), implement the `erlcracker_runtime` behaviour:

```erlang
-module(my_custom_runtime).
-behaviour(erlcracker_runtime).

-export([start_runtime/1, call_function/4, stop_runtime/1]).

%% Initialize runtime with config
start_runtime(Config) ->
    % Start your runtime process
    {ok, RuntimeHandle}.

%% Execute function call
call_function(RuntimeHandle, Module, Function, Args) ->
    % Execute and return result
    Result.

%% Shutdown runtime
stop_runtime(RuntimeHandle) ->
    % Clean up
    ok.
```

See `src/erlcracker_python_runtime.erl` for a complete reference implementation.

## API Reference

### Pool Management

#### `start_pool/3`

```erlang
-spec start_pool(PoolName, RuntimeModule, PoolConfig) ->
    {ok, pid()} | {error, term()}
  when
    PoolName :: atom(),
    RuntimeModule :: module(),
    PoolConfig :: map().
```

Start a runtime pool.

**Example**:

```erlang
erlcracker:start_pool(
    my_pool,
    erlcracker_python_runtime,
    #{pool_size => 4, worker_timeout_ms => 30000, python_path => "priv/python"}
).
```

#### `stop_pool/1`

```erlang
-spec stop_pool(PoolName) -> ok | {error, term()}
  when PoolName :: atom().
```

Stop a runtime pool.

### Runtime Invocation

#### `call/4`

```erlang
-spec call(PoolName, Module, Function, Args) ->
    {ok, term()} | {error, term()}
  when
    PoolName :: atom(),
    Module :: atom() | binary(),
    Function :: atom() | binary(),
    Args :: list().
```

Call runtime function with default timeout (5 seconds).

#### `call/5`

```erlang
-spec call(PoolName, Module, Function, Args, Timeout) ->
    {ok, term()} | {error, term()}
  when
    PoolName :: atom(),
    Module :: atom() | binary(),
    Function :: atom() | binary(),
    Args :: list(),
    Timeout :: non_neg_integer().
```

Call runtime function with custom timeout (milliseconds).

#### `call_async/4`

```erlang
-spec call_async(PoolName, Module, Function, Args) -> ok
  when
    PoolName :: atom(),
    Module :: atom() | binary(),
    Function :: atom() | binary(),
    Args :: list().
```

Call runtime function asynchronously. Result sent as `{runtime_result, WorkerPid, Result}` message.

## Error Handling

### Timeout Errors

```erlang
case erlcracker:call(my_pool, slow_module, slow_function, [Args], 1000) of
    {ok, Result} -> Result;
    {error, timeout} -> handle_timeout();
    {error, worker_timeout} -> handle_worker_timeout()
end.
```

- `{error, timeout}` - Caller-side timeout (waiting for result)
- `{error, worker_timeout}` - Worker-side timeout (execution exceeded limit)

### Runtime Errors

```erlang
case erlcracker:call(my_pool, my_module, my_function, [Args]) of
    {ok, Result} -> Result;
    {error, {Reason, Details}} -> handle_runtime_error(Reason, Details)
end.
```

### Worker Crashes

Workers automatically restart on crash. The pool manager:

1. Detects worker death via monitor
2. Removes from tracking (busy/available sets)
3. Supervisor restarts worker with fresh runtime
4. New worker registers when ready
5. Queued work assigned automatically

## Performance

Based on real-world HTML parsing workload:

- **With ErlCracker** (persistent Python): 30-40ms per parse
- **Without ErlCracker** (spawn per call): ~100ms per parse (cold start overhead)
- **Throughput**: 4 workers handle ~100 req/sec with 40ms latency

The persistent runtime eliminates cold-start overhead, providing consistent low-latency execution.

## Inspiration

**AWS Firecracker + Lambda**:

- Firecracker: Manages lightweight microVMs
- Lambda: Fire-and-forget function invocation
- **ErlCracker**: Combines both patterns for runtime management

**Heroku (circa 2011)**:

- "Hermes" router (Erlang) managed Ruby dynos
- Same pattern: Erlang managing execution environments

## License

MIT

## Contributing

Contributions welcome! See CONTRIBUTING.md for guidelines.

## Roadmap

- **v1.1**: Overflow queues with circuit breaking
- **v1.2**: Per-pool metrics (latency histograms, error rates)
- **v1.3**: Go runtime implementation (port-based)
- **v1.4**: Node.js runtime implementation
- **v1.5**: WebAssembly runtime (wasmtime integration)
