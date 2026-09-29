//! An instance of a module: its own linear memory under a ceiling, the calls into its
//! exports under an instruction budget, and the execution environment host functions see.
const std = @import("std");
const abi = @import("abi.zig");
const lib = @import("lib.zig");

const Error = lib.Error;
const Problem = lib.Problem;
const Module = lib.Module;
const params_max = lib.params_max;
const problem_len_max = lib.problem_len_max;
const page_bytes = lib.page_bytes;
const InstanceHandle = abi.InstanceHandle;

/// What a host function receives first: the calling instance's execution environment.
pub const Env = opaque {
    /// What the host passed to `Instance.call`, for the host function to find its state.
    pub fn user_data(env: *Env) ?*anyopaque {
        std.debug.assert(@intFromPtr(env) != 0);

        return abi.wasm_runtime_get_user_data(env);
    }

    /// `len` bytes of the caller's linear memory at `offset`, or null when any of it is
    /// outside: a guest's pointer is never trusted.
    pub fn bytes(env: *Env, offset: u32, len: u32) ?[]u8 {
        std.debug.assert(@intFromPtr(env) != 0);

        const handle = abi.wasm_runtime_get_module_inst(env);

        return memory_slice(handle, offset, len);
    }

    /// Calls another export of the same instance from inside a host function, within the
    /// budget the outer call was given.
    pub fn call(
        env: *Env,
        name: [:0]const u8,
        params: []const u32,
        problem: *Problem,
    ) Error!u32 {
        std.debug.assert(name.len > 0);
        std.debug.assert(params.len <= params_max);

        return invoke(env, abi.wasm_runtime_get_module_inst(env), name, params, problem);
    }
};

pub const Instance = struct {
    handle: *InstanceHandle,
    env: *Env,

    pub const Options = struct {
        /// The ceiling on the instance's linear memory, in 64 KiB pages.
        memory_pages_max: u32,
        /// The interpreter's operand and frame stack.
        stack_bytes: u32 = 64 << 10,
    };

    pub const CallOptions = struct {
        /// How many instructions the call may execute before it stops as `Exhausted`.
        instructions_max: u31,
        /// What `Env.user_data` answers inside host functions during this call.
        user_data: ?*anyopaque = null,
    };

    pub fn init(module: *const Module, options: Options, problem: *Problem) Error!Instance {
        std.debug.assert(options.memory_pages_max > 0);
        std.debug.assert(options.stack_bytes >= 4096);

        var args: ?*abi.ArgsHandle = null;

        if (!abi.wasm_runtime_instantiation_args_create(&args)) {
            return error.OutOfMemory;
        }

        defer abi.wasm_runtime_instantiation_args_destroy(args.?);

        abi.wasm_runtime_instantiation_args_set_default_stack_size(args.?, options.stack_bytes);
        abi.wasm_runtime_instantiation_args_set_max_memory_pages(args.?, options.memory_pages_max);

        var error_buffer: [problem_len_max]u8 = undefined;
        const handle = abi.wasm_runtime_instantiate_ex2(
            module.handle,
            args.?,
            &error_buffer,
            problem_len_max,
        ) orelse {
            problem.set_c(@ptrCast(&error_buffer));
            return error.Instantiate;
        };
        errdefer abi.wasm_runtime_deinstantiate(handle);

        // WAMR quietly raises a ceiling below the module's own initial memory to meet it.
        if (pages_of(handle) > options.memory_pages_max) {
            problem.set("the module's initial memory is over the instance's ceiling");
            return error.Instantiate;
        }

        const env = abi.wasm_runtime_create_exec_env(handle, options.stack_bytes) orelse {
            problem.set("no memory for the execution environment");
            return error.OutOfMemory;
        };

        return .{ .handle = handle, .env = env };
    }

    pub fn deinit(instance: *Instance) void {
        std.debug.assert(@intFromPtr(instance.handle) != 0);
        std.debug.assert(@intFromPtr(instance.env) != 0);

        abi.wasm_runtime_destroy_exec_env(instance.env);
        abi.wasm_runtime_deinstantiate(instance.handle);
    }

    /// Calls the export `name` with i32 parameters and answers its i32 result (0 for none).
    /// A trap leaves the instance's memory in whatever state the guest left it: a host that
    /// cannot trust that discards the instance.
    pub fn call(
        instance: *Instance,
        name: [:0]const u8,
        params: []const u32,
        options: CallOptions,
        problem: *Problem,
    ) Error!u32 {
        std.debug.assert(name.len > 0);
        std.debug.assert(options.instructions_max > 0);

        abi.wasm_runtime_set_user_data(instance.env, options.user_data);
        abi.wasm_runtime_set_instruction_count_limit(instance.env, options.instructions_max);
        defer abi.wasm_runtime_set_user_data(instance.env, null);
        defer abi.wasm_runtime_set_instruction_count_limit(instance.env, -1);

        return invoke(instance.env, instance.handle, name, params, problem);
    }

    pub fn bytes(instance: *Instance, offset: u32, len: u32) ?[]u8 {
        std.debug.assert(@intFromPtr(instance.handle) != 0);

        return memory_slice(instance.handle, offset, len);
    }
};

fn invoke(
    env: *Env,
    handle: *InstanceHandle,
    name: [:0]const u8,
    params: []const u32,
    problem: *Problem,
) Error!u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(params.len <= params_max);

    const function = abi.wasm_runtime_lookup_function(handle, name.ptr) orelse {
        problem.set(name);
        return error.NotFound;
    };
    var argv: [params_max]u32 = @splat(0);

    @memcpy(argv[0..params.len], params);

    if (!abi.wasm_runtime_call_wasm(env, function, @intCast(params.len), &argv)) {
        const message = abi.wasm_runtime_get_exception(handle) orelse "unknown trap";
        const text = std.mem.span(message);

        problem.set(text);
        abi.wasm_runtime_clear_exception(handle);

        if (std.mem.indexOf(u8, text, "instruction limit exceeded") != null) {
            return error.Exhausted;
        }

        return error.Trap;
    }

    return argv[0];
}

fn pages_of(handle: *InstanceHandle) u64 {
    std.debug.assert(@intFromPtr(handle) != 0);

    const memory = abi.wasm_runtime_get_default_memory(handle) orelse return 0;
    const pages = abi.wasm_memory_get_cur_page_count(memory);

    std.debug.assert(abi.wasm_memory_get_bytes_per_page(memory) == page_bytes);

    return pages;
}

/// Bounds are checked here rather than by WAMR's own validation, which raises an exception on
/// the instance as a side effect.
fn memory_slice(handle: *InstanceHandle, offset: u32, len: u32) ?[]u8 {
    std.debug.assert(@intFromPtr(handle) != 0);
    std.debug.assert(page_bytes == 65536);

    const memory = abi.wasm_runtime_get_default_memory(handle) orelse return null;
    const base = abi.wasm_memory_get_base_address(memory) orelse return null;
    const size = abi.wasm_memory_get_cur_page_count(memory) * abi.wasm_memory_get_bytes_per_page(memory);
    const end = @as(u64, offset) + len;

    if (end > size) {
        return null;
    }

    return base[offset..@intCast(end)];
}
