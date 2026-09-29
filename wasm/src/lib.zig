//! A thin binding over the vendored WAMR interpreter (compiled into this module by
//! build.zig): load a WebAssembly module, instantiate it with its own linear memory and a
//! ceiling on it, call its exports under an instruction budget, and give it the host
//! functions it imports. Declared by hand against WAMR's C ABI, no @cImport.
//!
//! ```zig
//! const wasm = @import("publr_wasm");
//!
//! var runtime: wasm.Runtime = undefined;
//! try runtime.init(.{ .heap = heap, .imports = &.{.{
//!     .name = "host_log",
//!     .signature = "(ii)",
//!     .function = &host_log,
//! }} });
//! defer runtime.deinit();
//!
//! var problem: wasm.Problem = .{};
//! var module = try wasm.Module.load(&runtime, bytes, &problem);
//! defer module.unload();
//!
//! var instance = try wasm.Instance.init(&module, .{ .memory_pages_max = 256 }, &problem);
//! defer instance.deinit();
//!
//! const answer = try instance.call("run", &.{ 1, 2 }, .{ .instructions_max = 1_000_000 }, &problem);
//! ```
//!
//! Threading: none. WAMR's runtime is process-global, so there is one `Runtime` per process,
//! and an instance is only ever called from the thread that created it.
const std = @import("std");

pub const section = @import("section.zig");

pub const imports_max: u32 = 16;
pub const params_max: u32 = 8;
pub const problem_len_max: u32 = 256;
/// The smallest pool `Runtime.init` accepts: WAMR's own bookkeeping, modules and stacks.
pub const heap_bytes_min: u64 = 1 << 20;
pub const page_bytes: u32 = 64 << 10;

const abi = @import("abi.zig");
const instance = @import("instance.zig");

/// What a host function receives first: the calling instance's execution environment.
pub const Env = instance.Env;
pub const Instance = instance.Instance;

pub const Error = error{
    /// The bytes are not a module WAMR accepts, or they import what the host does not give.
    Load,
    /// The module could not be instantiated: its memory or stack could not be made.
    Instantiate,
    /// The guest trapped: an unreachable, an out-of-bounds access, a stack overflow.
    Trap,
    /// The call ran out of the instructions it was given.
    Exhausted,
    /// The export does not exist.
    NotFound,
    /// WAMR's pool is full.
    OutOfMemory,
};

/// Why the last call failed, as WAMR words it; filled on every error.
pub const Problem = struct {
    buffer: [problem_len_max]u8 = undefined,
    len: u32 = 0,

    pub fn text(problem: *const Problem) []const u8 {
        std.debug.assert(problem.len <= problem_len_max);

        return problem.buffer[0..problem.len];
    }

    pub fn set(problem: *Problem, message: []const u8) void {
        std.debug.assert(problem_len_max > 0);

        const len: u32 = @intCast(@min(message.len, problem_len_max));

        @memcpy(problem.buffer[0..len], message[0..len]);
        problem.len = len;

        std.debug.assert(problem.len <= problem_len_max);
    }

    pub fn set_c(problem: *Problem, message: [*:0]const u8) void {
        problem.set(std.mem.span(message));
    }
};

/// A function the host gives every module: `name` in the import module `env`, WAMR's
/// signature string (`"(iii)i"`), and a `fn (env: *Env, ...) callconv(.c)` to run.
pub const Import = struct {
    name: [:0]const u8,
    signature: [:0]const u8,
    function: *const anyopaque,
};

/// WAMR's process-global state: `wasm_runtime_full_init` on `init`, `wasm_runtime_destroy`
/// on `deinit`, every allocation WAMR makes for itself carved from `heap` (linear memories
/// are mapped apart, each held to its instance's ceiling). It also holds the host functions,
/// which WAMR sorts in place and keeps for the runtime's life.
pub const Runtime = struct {
    natives: [imports_max]abi.NativeSymbol,

    pub const Options = struct {
        heap: []u8,
        module_name: [:0]const u8 = "env",
        imports: []const Import,
    };

    pub fn init(runtime: *Runtime, options: Options) Error!void {
        std.debug.assert(options.heap.len >= heap_bytes_min);
        std.debug.assert(options.imports.len <= imports_max);

        for (options.imports, 0..) |import, index| {
            runtime.natives[index] = .{
                .symbol = import.name.ptr,
                .function = import.function,
                .signature = import.signature.ptr,
                .attachment = null,
            };
        }

        var args = std.mem.zeroes(abi.RuntimeInitArgs);

        args.mem_alloc_type = abi.alloc_with_pool;
        args.mem_alloc_option = .{ .pool = .{
            .heap_buf = options.heap.ptr,
            .heap_size = @intCast(@min(options.heap.len, std.math.maxInt(u32))),
        } };
        args.native_module_name = options.module_name.ptr;
        args.native_symbols = &runtime.natives;
        args.n_native_symbols = @intCast(options.imports.len);
        args.running_mode = abi.running_mode_interp;

        if (!abi.wasm_runtime_full_init(&args)) {
            return error.OutOfMemory;
        }

        // Every failure reaches the caller as an error and a `Problem`; WAMR's own logging
        // would only repeat it on stdout.
        abi.wasm_runtime_set_log_level(abi.log_level_fatal);
    }

    pub fn deinit(runtime: *Runtime) void {
        std.debug.assert(runtime.natives.len == imports_max);
        abi.wasm_runtime_destroy();
    }
};

pub const Module = struct {
    handle: *abi.ModuleHandle,

    /// Validates and loads `bytes`, which must outlive the module: WAMR keeps pointers into
    /// them. Imports are resolved here, so a module asking for a host function the runtime
    /// does not give fails now, not at its first call.
    pub fn load(runtime: *Runtime, bytes: []u8, problem: *Problem) Error!Module {
        std.debug.assert(bytes.len > 0);
        std.debug.assert(runtime.natives.len == imports_max);

        var error_buffer: [problem_len_max]u8 = undefined;
        const handle = abi.wasm_runtime_load(
            bytes.ptr,
            @intCast(bytes.len),
            &error_buffer,
            problem_len_max,
        ) orelse {
            problem.set_c(@ptrCast(&error_buffer));
            return error.Load;
        };

        return .{ .handle = handle };
    }

    pub fn unload(module: *Module) void {
        std.debug.assert(@intFromPtr(module.handle) != 0);
        abi.wasm_runtime_unload(module.handle);
    }
};

test {
    std.testing.refAllDecls(@This());
}
