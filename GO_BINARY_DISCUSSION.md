# Go Binary vs Source Compilation Discussion

## Context

During implementation of Go runtime support in erlcracker, we discovered that erlport's current Go implementation compiles Go source code at runtime, similar to how it manages Python/Ruby interpreters. This raised the question: is this the right approach?

## Current erlport Go Approach

```erlang
go:start([{go_src, "path/to/source.go"}])
```

- Erlport compiles Go source at runtime using `go build`
- Caches compiled binary in `.erlport_cache/`
- Auto-recompiles when source mtime changes
- Manages binary lifecycle (spawn, monitor, communicate)

## The Problem

### Go is Fundamentally Different

**Python/Ruby (Interpreted):**
- erlport spawns: `python3 -m erlport.cli --flags...`
- The `cli.py` wrapper parses flags, sets up port communication, starts message loop
- User code is just functions - no boilerplate needed
- erlport truly manages the runtime

**Go (Compiled):**
- erlport compiles source, then spawns: `./binary --flags...`
- User MUST write `main()` with all boilerplate:
  - Flag parsing (`flag.IntVar(&packet, "packet", 4, ...)`)
  - Port creation (`erlproto.NewPort(...)`)
  - Message handler creation (`erlang.NewMessageHandler(...)`)
  - Function registration (`handler.Register("func_name", func)`)
  - Message loop start (`handler.Start()`)
- erlport just runs shell commands and manages the resulting process

### Why Runtime Compilation is a Code Smell

1. **False Equivalence**
   - Pretends Go is "just like Python" from Erlang's perspective
   - Hides fundamental paradigm difference
   - Creates complexity trying to make different things look the same

2. **Loss of Build Control**
   - User can't specify Go version
   - No control over build flags (`-ldflags`, `-tags`, optimization, etc.)
   - Can't control cross-compilation
   - Can't use custom vendoring strategies
   - Limited to erlport's simple mtime-based cache invalidation

3. **Production/Deployment Issues**
   - **Requires Go toolchain in production** (major issue!)
   - Compilation happens at application startup
   - What if compilation fails in production?
   - Security concern: compiling code at runtime
   - Slower startup (compilation overhead)

4. **Lambda Pattern**
   - AWS Lambda doesn't recompile Go on every cold start
   - You upload pre-built binaries
   - Proven pattern at scale
   - Separates build-time from runtime concerns

## Recommended Approach: Binary-Only

### What It Looks Like

```erlang
% Erlang side
go:start([{go_binary, "/path/to/compiled/binary"}])
```

```erlang
% rebar.config - build Go as part of compile step
{pre_hooks, [
    {compile, "cd priv/go && go build -o ../bin/test_module test_module.go"}
]}.
```

### User Workflow

1. Write Go code with required `main()` boilerplate
2. Run `rebar3 compile` - builds both Erlang and Go
3. Runtime just spawns the pre-built binary
4. No Go toolchain needed in production

### Benefits

1. **Honest About Differences**
   - Go IS different from Python/Ruby
   - Don't pretend otherwise
   - Users understand they're working with compiled code

2. **Build Control**
   - User controls Go version
   - Can use build flags, tags, cross-compilation
   - Full control over dependencies and vendoring
   - Standard Go tooling

3. **Production Ready**
   - No compilation at runtime
   - No Go toolchain needed in production
   - Faster startup
   - Build failures happen at build time, not runtime

4. **Matches Mental Model**
   - ErlCracker provides "Lambda-like" semantics
   - Lambda uses pre-built binaries
   - Consistent with that model

5. **Separation of Concerns**
   - Build-time: compile Go binaries
   - Runtime: spawn and manage processes
   - Clean separation

## Implementation for erlcracker

Since erlcracker is production-oriented and follows Lambda patterns, we should embrace Go as compiled:

```erlang
% erlcracker_go_runtime.erl
start_runtime(Config) ->
    GoBinary = maps:get(go_binary, Config),
    go:start([{go_binary, GoBinary}]).
```

This forces users to think about Go correctly: as a compiled language that produces binaries, not as "Python with different syntax."

## Required erlport Changes

Need to modify erlport to support binary-only mode:

1. Add `{go_binary, Path}` option support
2. Skip compilation step when binary provided
3. Validate binary exists and is executable
4. Spawn binary directly with flags

Alternatively, keep both options and let users choose:
- `{go_src, Path}` - current behavior (development convenience)
- `{go_binary, Path}` - binary-only (production deployment)

## The Boilerplate Question

**Question:** Why does Go need `main()` boilerplate when Python doesn't?

**Answer:** Python has `erlport.cli` wrapper that handles all setup. But Go can't have this because:
- Go is compiled (no dynamic imports)
- No runtime introspection to discover functions
- User must explicitly register functions in `main()`

The `main()` boilerplate IS the compiled equivalent of Python's `cli.py` - it's required and unavoidable for Go.

## Conclusion

**Runtime source compilation creates a false equivalence between Go and interpreted languages.**

Better approach:
- Be honest that Go is different
- Let users manage their builds
- Runtime just spawns binaries
- Matches Lambda pattern
- Production-appropriate

The fact that Go requires `main()` boilerplate (unlike Python) is a symptom of this deeper difference. Once we accept Go is fundamentally different, the question becomes: should we hide or embrace the difference?

**Recommendation: Embrace it.** Use binary-only mode for production systems like erlcracker.
