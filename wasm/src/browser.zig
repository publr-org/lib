//! The same API run on the browser's own WebAssembly, for Publr built for the browser: each
//! module is compiled and instantiated by the page hosting Publr (its functions in the
//! import module `publr_wasm`), and a guest's call to a host function comes back through the
//! export `publr_wasm_host`. A guest's memory is not Publr's here, so the host reads and
//! writes it only by copy (`Env.read`, `Env.write`).
//!
//! What WAMR keeps and the browser cannot: an instruction budget (a guest that loops holds
//! the tab), and a memory ceiling enforced as the guest grows; here the ceiling is checked
//! after each call, and an instance past it is discarded as a trap.
const std = @import("std");
const lib = @import("lib.zig");

const Error = lib.Error;
const Problem = lib.Problem;
const Import = lib.Import;

/// Instances alive at once: one per installed plugin.
pub const instances_max: u32 = 64;
/// The longest name a host function has, its newline included.
const name_len_max: u32 = 64;

const Status = enum(i32) {
    ok = 0,
    trap = 1,
    not_found = 2,
    exhausted = 3,
};

extern "publr_wasm" fn publr_wasm_load(
    bytes_ptr: [*]const u8,
    bytes_len: u32,
    problem_ptr: [*]u8,
    problem_len: *u32,
) i32;
extern "publr_wasm" fn publr_wasm_unload(module: i32) void;
extern "publr_wasm" fn publr_wasm_host_functions(names_ptr: [*]const u8, names_len: u32) void;
extern "publr_wasm" fn publr_wasm_instantiate(
    module: i32,
    env: *Env,
    memory_pages_max: u32,
    problem_ptr: [*]u8,
    problem_len: *u32,
) i32;
extern "publr_wasm" fn publr_wasm_deinstantiate(instance: i32) void;
extern "publr_wasm" fn publr_wasm_call(
    instance: i32,
    name_ptr: [*]const u8,
    name_len: u32,
    params_ptr: [*]const u32,
    params_len: u32,
    result: *u32,
    problem_ptr: [*]u8,
    problem_len: *u32,
) i32;
extern "publr_wasm" fn publr_wasm_read(instance: i32, offset: u32, target: [*]u8, len: u32) i32;
extern "publr_wasm" fn publr_wasm_write(
    instance: i32,
    offset: u32,
    source: [*]const u8,
    len: u32,
) i32;

/// One instance as host functions see it: its id in the page, and what the call passed.
pub const Env = struct {
    id: i32 = 0,
    runtime: ?*Runtime = null,
    data: ?*anyopaque = null,

    pub fn user_data(env: *Env) ?*anyopaque {
        std.debug.assert(env.id > 0);

        return env.data;
    }

    pub fn read(env: *Env, offset: u32, target: []u8) bool {
        std.debug.assert(env.id > 0);
        std.debug.assert(target.len <= std.math.maxInt(u32));

        if (target.len == 0) {
            return true;
        }

        return publr_wasm_read(env.id, offset, target.ptr, @intCast(target.len)) == 1;
    }

    pub fn write(env: *Env, offset: u32, source: []const u8) bool {
        std.debug.assert(env.id > 0);
        std.debug.assert(source.len <= std.math.maxInt(u32));

        if (source.len == 0) {
            return true;
        }

        return publr_wasm_write(env.id, offset, source.ptr, @intCast(source.len)) == 1;
    }

    /// Another export of the same instance, from inside a host function.
    pub fn call(
        env: *Env,
        name: [:0]const u8,
        params: []const u32,
        problem: *Problem,
    ) Error!u32 {
        std.debug.assert(env.id > 0);
        std.debug.assert(params.len <= lib.params_max);

        return invoke(env.id, name, params, problem);
    }

    pub fn bytes(env: *Env, offset: u32, len: u32) ?[]u8 {
        _ = env;
        _ = offset;
        _ = len;
        @compileError("a guest's memory is not Publr's in the browser: use `read` and `write`");
    }
};

/// The host functions every module may import, and the instances' environments, which
/// stay where they are for as long as the runtime does.
pub const Runtime = struct {
    imports: []const Import = &.{},
    envs: [instances_max]Env = @splat(.{}),

    pub const Options = struct {
        module_name: [:0]const u8 = "env",
    };

    comptime {
        @export(&dispatch, .{
            .name = "publr_wasm_host",
        });
    }

    /// `heap` is unused here: the page holds the instances' memory.
    pub fn init(
        runtime: *Runtime,
        heap: []u8,
        imports: []const Import,
        options: Options,
    ) Error!void {
        std.debug.assert(imports.len <= lib.imports_max);
        std.debug.assert(std.mem.eql(u8, options.module_name, "env"));

        _ = heap;
        runtime.* = .{
            .imports = imports,
        };

        // The page learns the host functions' names once, in order: a guest's import of
        // `env.<name>` calls back with its index.
        var names: [lib.imports_max * name_len_max]u8 = undefined;
        var len: u32 = 0;

        for (imports) |import| {
            std.debug.assert(import.name.len < name_len_max);

            @memcpy(names[len..][0..import.name.len], import.name);
            names[len + import.name.len] = '\n';
            len += @intCast(import.name.len + 1);
        }

        publr_wasm_host_functions(&names, len);
    }

    pub fn deinit(runtime: *Runtime) void {
        std.debug.assert(runtime.imports.len <= lib.imports_max);

        for (&runtime.envs) |*env| {
            if (env.id > 0) {
                publr_wasm_deinstantiate(env.id);
                env.* = .{};
            }
        }
    }

    fn free_env(runtime: *Runtime) ?*Env {
        std.debug.assert(runtime.envs.len == instances_max);

        for (&runtime.envs) |*env| {
            if (env.runtime == null) {
                return env;
            }
        }

        return null;
    }
};

pub const Module = struct {
    id: i32,
    runtime: *Runtime,

    /// Compiles `bytes` in the page; a module importing a host function the runtime does
    /// not give fails when it is instantiated.
    pub fn load(runtime: *Runtime, bytes: []u8, problem: *Problem) Error!Module {
        std.debug.assert(bytes.len > 0);
        std.debug.assert(runtime.imports.len <= lib.imports_max);

        problem.len = lib.problem_len_max;

        const id = publr_wasm_load(bytes.ptr, @intCast(bytes.len), &problem.buffer, &problem.len);

        if (id <= 0) {
            return error.Load;
        }

        problem.len = 0;

        return .{
            .id = id,
            .runtime = runtime,
        };
    }

    pub fn unload(module: *Module) void {
        std.debug.assert(module.id > 0);

        publr_wasm_unload(module.id);
        module.id = 0;
    }
};

pub const Instance = struct {
    env: *Env,

    pub const Options = struct {
        stack_bytes: u32 = 64 << 10,
    };

    pub const CallOptions = struct {
        user_data: ?*anyopaque = null,
    };

    pub fn init(
        module: *const Module,
        memory_pages_max: u32,
        problem: *Problem,
        options: Options,
    ) Error!Instance {
        std.debug.assert(module.id > 0);
        std.debug.assert(memory_pages_max > 0);

        _ = options;

        const env = module.runtime.free_env() orelse {
            problem.set("too many instances");
            return error.OutOfMemory;
        };

        problem.len = lib.problem_len_max;

        const id = publr_wasm_instantiate(
            module.id,
            env,
            memory_pages_max,
            &problem.buffer,
            &problem.len,
        );

        if (id <= 0) {
            return error.Instantiate;
        }

        problem.len = 0;
        env.* = .{
            .id = id,
            .runtime = module.runtime,
        };

        return .{
            .env = env,
        };
    }

    pub fn deinit(instance: *Instance) void {
        std.debug.assert(instance.env.id > 0);

        publr_wasm_deinstantiate(instance.env.id);
        instance.env.* = .{};
    }

    pub fn call(
        instance: *Instance,
        name: [:0]const u8,
        params: []const u32,
        instructions_max: u31,
        problem: *Problem,
        options: CallOptions,
    ) Error!u32 {
        std.debug.assert(name.len > 0);
        // Not kept in the browser: a guest's loop runs until it ends.
        std.debug.assert(instructions_max > 0);

        const outer = instance.env.data;

        instance.env.data = options.user_data;
        defer instance.env.data = outer;

        return invoke(instance.env.id, name, params, problem);
    }

    pub fn read(instance: *Instance, offset: u32, target: []u8) bool {
        return instance.env.read(offset, target);
    }

    pub fn write(instance: *Instance, offset: u32, source: []const u8) bool {
        return instance.env.write(offset, source);
    }

    pub fn bytes(instance: *Instance, offset: u32, len: u32) ?[]u8 {
        _ = instance;
        _ = offset;
        _ = len;
        @compileError("a guest's memory is not Publr's in the browser: use `read` and `write`");
    }
};

fn invoke(id: i32, name: [:0]const u8, params: []const u32, problem: *Problem) Error!u32 {
    std.debug.assert(id > 0);
    std.debug.assert(params.len <= lib.params_max);

    var result: u32 = 0;

    problem.len = lib.problem_len_max;

    const status = publr_wasm_call(
        id,
        name.ptr,
        @intCast(name.len),
        params.ptr,
        @intCast(params.len),
        &result,
        &problem.buffer,
        &problem.len,
    );

    switch (status) {
        @intFromEnum(Status.ok) => {
            problem.len = 0;
            return result;
        },
        @intFromEnum(Status.not_found) => return error.NotFound,
        @intFromEnum(Status.exhausted) => return error.Exhausted,
        else => return error.Trap,
    }
}

/// A guest calling a host function, back from the page: the environment it was
/// instantiated with, which import, and its arguments, all 32-bit integers.
fn dispatch(
    env: *Env,
    index: u32,
    first: u32,
    second: u32,
    third: u32,
    fourth: u32,
    fifth: u32,
) callconv(.c) u32 {
    std.debug.assert(env.id > 0);

    const runtime = env.runtime orelse return 0;

    if (index >= runtime.imports.len) {
        return 0;
    }

    const import = runtime.imports[index];
    const shape = shape_of(import.signature);
    const arguments = [_]u32{ first, second, third, fourth, fifth };

    return if (shape.answers)
        call_answering(import.function, env, shape.params, arguments)
    else
        call_silent(import.function, env, shape.params, arguments);
}

fn call_answering(function: *const anyopaque, env: *Env, count: u32, arguments: [5]u32) u32 {
    std.debug.assert(count <= arguments.len);
    std.debug.assert(@intFromPtr(function) != 0);

    const c_abi: std.builtin.CallingConvention = .c;
    const values = arguments;

    return switch (count) {
        0 => cast(fn (*Env) callconv(c_abi) u32, function)(env),
        1 => cast(fn (*Env, u32) callconv(c_abi) u32, function)(env, values[0]),
        2 => cast(fn (*Env, u32, u32) callconv(c_abi) u32, function)(env, values[0], values[1]),
        3 => cast(fn (*Env, u32, u32, u32) callconv(c_abi) u32, function)(env, values[0], values[1], values[2]),
        4 => cast(fn (*Env, u32, u32, u32, u32) callconv(c_abi) u32, function)(
            env,
            values[0],
            values[1],
            values[2],
            values[3],
        ),
        else => cast(fn (*Env, u32, u32, u32, u32, u32) callconv(c_abi) u32, function)(
            env,
            values[0],
            values[1],
            values[2],
            values[3],
            values[4],
        ),
    };
}

fn call_silent(function: *const anyopaque, env: *Env, count: u32, arguments: [5]u32) u32 {
    std.debug.assert(count <= arguments.len);
    std.debug.assert(@intFromPtr(function) != 0);

    const c_abi: std.builtin.CallingConvention = .c;
    const values = arguments;

    switch (count) {
        0 => cast(fn (*Env) callconv(c_abi) void, function)(env),
        1 => cast(fn (*Env, u32) callconv(c_abi) void, function)(env, values[0]),
        2 => cast(fn (*Env, u32, u32) callconv(c_abi) void, function)(env, values[0], values[1]),
        3 => cast(fn (*Env, u32, u32, u32) callconv(c_abi) void, function)(env, values[0], values[1], values[2]),
        4 => cast(fn (*Env, u32, u32, u32, u32) callconv(c_abi) void, function)(
            env,
            values[0],
            values[1],
            values[2],
            values[3],
        ),
        else => cast(fn (*Env, u32, u32, u32, u32, u32) callconv(c_abi) void, function)(
            env,
            values[0],
            values[1],
            values[2],
            values[3],
            values[4],
        ),
    }

    return 0;
}

fn cast(comptime Function: type, function: *const anyopaque) *const Function {
    return @ptrCast(@alignCast(function));
}

const Shape = struct {
    params: u32,
    answers: bool,
};

/// WAMR's signature string, read the same way: `(iiiii)i` takes five and answers one.
fn shape_of(signature: []const u8) Shape {
    std.debug.assert(signature.len >= 2);
    std.debug.assert(signature[0] == '(');

    const close = std.mem.indexOfScalar(u8, signature, ')') orelse signature.len;

    return .{
        .params = @intCast(close - 1),
        .answers = close + 1 < signature.len,
    };
}

test "signatures read as WAMR reads them" {
    try std.testing.expectEqual(Shape{ .params = 5, .answers = true }, shape_of("(iiiii)i"));
    try std.testing.expectEqual(Shape{ .params = 2, .answers = false }, shape_of("(ii)"));
}
