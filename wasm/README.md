# Publr WebAssembly

A WebAssembly runtime for a host that runs code it does not trust: the vendored
[WAMR](https://github.com/bytecodealliance/wasm-micro-runtime) fast interpreter,
compiled into the module, behind a thin binding declared by hand against its C ABI.
Consumers import the module; the interpreter rides along.

```zig
const wasm = @import("publr_wasm");

var runtime: wasm.Runtime = undefined;
try runtime.init(.{ .heap = heap, .imports = &.{.{
    .name = "host_log",
    .signature = "(ii)",
    .function = &host_log,
}} });
defer runtime.deinit();

var problem: wasm.Problem = .{};
var module = try wasm.Module.load(&runtime, bytes, &problem);
defer module.unload();

var instance = try wasm.Instance.init(&module, .{ .memory_pages_max = 256 }, &problem);
defer instance.deinit();

const sum = try instance.call("add", &.{ 40, 2 }, .{ .instructions_max = 1_000_000 }, &problem);
```

## The contract

**One runtime per process.** WAMR's state is process-global; `Runtime` is that state
made explicit, created first and passed by pointer. Every allocation WAMR makes for
itself (modules, instances' bookkeeping, stacks) comes out of the fixed `heap` it is
given. It also holds the host functions, which WAMR sorts in place and keeps.

**A ceiling on memory, a budget on time.** An instance's linear memory is mapped apart
and never grows past `memory_pages_max`; a module whose own initial memory is above it is
refused, where WAMR would quietly raise the ceiling. Each call gets `instructions_max`
instructions and stops as `error.Exhausted` past them. Bounds are checked in software:
no signal handler is installed in the host.

**Guest pointers are never trusted.** A host function receives the calling instance's
`*Env` first; `Env.bytes(offset, len)` answers the guest's memory or null when any of it
is outside. `Env.call` calls another export from inside a host function, within the same
budget. `Env.user_data` answers what the host passed to `Instance.call`.

**A handful of errors.** `Load` (not a module, or it imports what the host does not
give), `Instantiate`, `Trap`, `Exhausted`, `NotFound` (no such export), `OutOfMemory`;
`Problem` holds WAMR's reason. After a trap the guest's memory is whatever it left; a
host that cannot trust that drops the instance.

**Custom sections without loading.** `section.find` reads a module's custom section by
name, `section.write` appends one: what a host inspects before it runs anything.

**Vendored, and the flags are part of the contract.** `vendor/wamr/` is WAMR 2.4.5,
the files the interpreter needs, as released (Apache-2.0 WITH LLVM-exception,
`vendor/wamr/LICENSE`). It is compiled with the fast interpreter only: no AOT, no JIT,
no WASI, no threads; reference types and bulk memory, which toolchains emit by default;
instruction metering; software bounds checks. macOS and Linux, on aarch64 and x86_64.

## Tests

```bash
zig build test
```

Integration tests run a real module, `tests/guest.zig`, built for `wasm32-freestanding`
by the test build: calls, host functions and their user data, nested calls, the budget,
traps, the memory ceiling, refused bytes.
