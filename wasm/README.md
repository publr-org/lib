# Publr WebAssembly

A WebAssembly runtime for a host that runs code it does not trust: the vendored
[WAMR](https://github.com/bytecodealliance/wasm-micro-runtime) fast interpreter,
compiled into the module, behind a thin binding declared by hand against its C ABI.
Consumers import the module; the interpreter rides along.

```zig
const wasm = @import("publr_wasm");

var runtime: wasm.Runtime = undefined;
try runtime.init(heap, &.{.{
    .name = "host_log",
    .signature = "(ii)",
    .function = &host_log,
}}, .{});
defer runtime.deinit();

var problem: wasm.Problem = .{};
var module = try wasm.Module.load(&runtime, bytes, &problem);
defer module.unload();

var instance = try wasm.Instance.init(&module, 256, &problem, .{});
defer instance.deinit();

const sum = try instance.call("add", &.{ 40, 2 }, 1_000_000, &problem, .{});
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
`*Env` first; `Env.read(offset, target)` and `Env.write(offset, source)` copy between the
guest's memory and the host's, false when any of it is outside (`Instance.read`/`write`
outside a call). `Env.bytes(offset, len)` answers the guest's memory itself, natively only. `Env.call` calls another export from inside a host function, within the same
budget, as does an `Instance.call` made while a call into the instance has not returned. `Env.user_data` answers what the host passed to `Instance.call`.

**What a call cost.** `Instance.instructions_used` adds up the instructions every call into
the instance executed, work nested in host functions included: the budget less what the
interpreter left as each outermost call returned (`src/metering.c` reads it; WAMR exports
only the setter). `Instance.memory_pages()` is the linear memory now, which never shrinks.
A host reads both to say what a module cost; neither is counted in the browser.

**A handful of errors.** `Load` (not a module, or it imports what the host does not
give), `Instantiate`, `Trap`, `Exhausted`, `NotFound` (no such export), `OutOfMemory`;
`Problem` holds WAMR's reason. After a trap the guest's memory is whatever it left; a
host that cannot trust that drops the instance.

**Custom sections without loading.** `section.find` reads a module's custom section by
name, `section.write` appends one: what a host inspects before it runs anything.

**Vendored, and the flags are part of the contract.** `vendor/wamr/` is WAMR 2.4.5,
the files the interpreter needs, as released (Apache-2.0 WITH LLVM-exception,
`vendor/wamr/LICENSE`), with one change of ours, below. It is compiled with the fast interpreter only: no AOT, no JIT,
no WASI, no threads; reference types and bulk memory, which toolchains emit by default;
instruction metering; software bounds checks. macOS and Linux, on aarch64 and x86_64.

**One change to the vendored interpreter.** As released, WAMR reads the instruction limit
into a local when the interpreter is entered and never writes it back, so a call a host
function makes into the same instance starts on the whole budget again, and the outer call
goes on with its own count: nested work is not counted. `wasm_interp_fast.c` here hands
what is left to the execution environment before a host function runs, takes it back
after, and writes it when the interpreter returns (three places, each marked `Publr:`).
A call nested in a host function then counts against the outer call's budget, which
`Instance.call` sets only for the outermost call. When WAMR is imported again, carry the
change over; `tests/root.zig` ("work nested in a host function counts against the outer
call's budget") fails without it.

**In the browser.** Built for `wasm32` (a host that is itself WebAssembly in a page), the
same API runs each module on the browser's WebAssembly through the page's functions in
the import module `publr_wasm` (`src/browser.zig`); guests call back through the export
`publr_wasm_host`. WAMR is not compiled in. There is no instruction budget, the memory
ceiling is checked after each call, and `bytes` does not exist.

## Tests

```bash
zig build test
```

Integration tests run a real module, `tests/guest.zig`, built for `wasm32-freestanding`
by the test build: calls, host functions and their user data, nested calls, the budget
(nested work included), traps, the memory ceiling, refused bytes.
