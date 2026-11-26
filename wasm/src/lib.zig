//! A thin binding over the vendored WAMR interpreter (compiled into this module by
//! build.zig): load a WebAssembly module, instantiate it with its own linear memory and a
//! ceiling on it, call its exports under an instruction budget, and give it the host
//! functions it imports. Declared by hand against WAMR's C ABI, no @cImport.
//!
//! ```zig
//! const wasm = @import("publr_wasm");
//!
//! var runtime: wasm.Runtime = undefined;
//! try runtime.init(heap, &.{.{
//!     .name = "host_log",
//!     .signature = "(ii)",
//!     .function = &host_log,
//! }}, .{});
//! defer runtime.deinit();
//!
//! var problem: wasm.Problem = .{};
//! var module = try wasm.Module.load(&runtime, bytes, &problem);
//! defer module.unload();
//!
//! var instance = try wasm.Instance.init(&module, 256, &problem, .{});
//! defer instance.deinit();
//!
//! const answer = try instance.call("run", &.{ 1, 2 }, 1_000_000, &problem, .{});
//! ```
//!
//! Threading: none. WAMR's runtime is process-global, so there is one `Runtime` per process,
//! and an instance is only ever called from the thread that created it.
//!
//! Built for `wasm32` (Publr in the browser), the same API runs each module on the browser's
//! own WebAssembly through the host page's functions (`browser.zig`); there an instruction
//! budget is not kept, and a memory ceiling is checked after each call.
const std = @import("std");
const builtin = @import("builtin");

pub const section = @import("section.zig");
pub const names = @import("names.zig");

pub const imports_max: u32 = 32;
pub const params_max: u32 = 8;
pub const problem_len_max: u32 = 256;
/// The smallest pool `Runtime.init` accepts: WAMR's own bookkeeping, modules and stacks.
pub const heap_bytes_min: u64 = 1 << 20;
pub const page_bytes: u32 = 64 << 10;

const abi = @import("abi.zig");
const instance = @import("instance.zig");
const browser = @import("browser.zig");

/// Whether this build runs modules on the browser's WebAssembly rather than WAMR.
pub const in_browser = builtin.cpu.arch == .wasm32;

/// What a host function receives first: the calling instance's execution environment.
pub const Env = if (in_browser) browser.Env else instance.Env;
pub const Instance = if (in_browser) browser.Instance else instance.Instance;
pub const Runtime = if (in_browser) browser.Runtime else NativeRuntime;
pub const Module = if (in_browser) browser.Module else NativeModule;

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

    /// "it imports env.publr_frame, which this Publr does not give".
    fn set_unlinked(problem: *Problem, import: abi.ImportType) void {
        std.debug.assert(import.kind == abi.import_kind_function);
        std.debug.assert(!import.linked);

        const module_name = if (import.module_name) |name| std.mem.span(name) else "";
        const name = if (import.name) |given| std.mem.span(given) else "";
        var buffer: [problem_len_max]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "it imports {s}.{s}, which this Publr does not give",
            .{ module_name, name },
        ) catch buffer[0..problem_len_max];

        problem.set(message);
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
pub const NativeRuntime = struct {
    natives: [imports_max]abi.NativeSymbol,

    pub const Options = struct {
        module_name: [:0]const u8 = "env",
    };

    pub fn init(
        runtime: *NativeRuntime,
        heap: []u8,
        imports: []const Import,
        options: Options,
    ) Error!void {
        std.debug.assert(heap.len >= heap_bytes_min);
        std.debug.assert(imports.len <= imports_max);

        for (imports, 0..) |import, index| {
            runtime.natives[index] = .{
                .symbol = import.name.ptr,
                .function = import.function,
                .signature = import.signature.ptr,
                .attachment = null,
            };
        }

        var args = std.mem.zeroes(abi.RuntimeInitArgs);

        args.mem_alloc_type = abi.alloc_with_pool;
        args.mem_alloc_option = .{
            .pool = .{
                .heap_buf = heap.ptr,
                .heap_size = @intCast(@min(heap.len, std.math.maxInt(u32))),
            },
        };
        args.native_module_name = options.module_name.ptr;
        args.native_symbols = &runtime.natives;
        args.n_native_symbols = @intCast(imports.len);
        args.running_mode = abi.running_mode_interp;

        if (!abi.wasm_runtime_full_init(&args)) {
            return error.OutOfMemory;
        }

        // Every failure reaches the caller as an error and a `Problem`; WAMR's own logging
        // would only repeat it on stdout.
        abi.wasm_runtime_set_log_level(abi.log_level_fatal);
    }

    pub fn deinit(runtime: *NativeRuntime) void {
        std.debug.assert(runtime.natives.len == imports_max);
        abi.wasm_runtime_destroy();
    }
};

pub const NativeModule = struct {
    handle: *abi.ModuleHandle,

    /// Validates and loads `bytes`, which must outlive the module: WAMR keeps pointers into
    /// them. Imports are resolved here, so a module asking for a host function the runtime
    /// does not give fails now, not at its first call.
    pub fn load(runtime: *NativeRuntime, bytes: []u8, problem: *Problem) Error!NativeModule {
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

        // WAMR loads a module whose imports are not all given and traps only when one is
        // called; refused here instead, naming the first.
        if (unlinked(handle)) |import| {
            abi.wasm_runtime_unload(handle);
            problem.set_unlinked(import);
            return error.Load;
        }

        return .{
            .handle = handle,
        };
    }

    /// The first function the module imports that the runtime does not give.
    fn unlinked(handle: *abi.ModuleHandle) ?abi.ImportType {
        const count = abi.wasm_runtime_get_import_count(handle);

        std.debug.assert(count >= -1);

        var index: i32 = 0;

        while (index < count) : (index += 1) {
            var import = std.mem.zeroes(abi.ImportType);

            abi.wasm_runtime_get_import_type(handle, index, &import);

            if (import.kind == abi.import_kind_function and !import.linked) {
                std.debug.assert(import.name != null);
                return import;
            }
        }

        return null;
    }

    pub fn unload(module: *NativeModule) void {
        std.debug.assert(@intFromPtr(module.handle) != 0);
        abi.wasm_runtime_unload(module.handle);
    }
};

test {
    std.testing.refAllDecls(@This());
}
