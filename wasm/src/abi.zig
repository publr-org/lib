//! WAMR's C ABI, declared by hand: the handles, the init arguments, the calls this binding
//! makes. Nothing else in the library declares an extern.
const Env = @import("instance.zig").Env;

pub const ModuleHandle = opaque {};
pub const InstanceHandle = opaque {};
pub const FunctionHandle = opaque {};
pub const ArgsHandle = opaque {};
pub const MemoryHandle = opaque {};

pub const NativeSymbol = extern struct {
    symbol: [*:0]const u8,
    function: *const anyopaque,
    signature: [*:0]const u8,
    attachment: ?*anyopaque,
};

pub const MemAllocOption = extern union {
    pool: extern struct { heap_buf: ?*anyopaque, heap_size: u32 },
    allocator: extern struct {
        malloc_func: ?*anyopaque,
        realloc_func: ?*anyopaque,
        free_func: ?*anyopaque,
        user_data: ?*anyopaque,
    },
};

pub const alloc_with_pool: c_int = 0;
pub const running_mode_interp: c_int = 1;
pub const log_level_fatal: c_int = 0;

pub const RuntimeInitArgs = extern struct {
    mem_alloc_type: c_int,
    mem_alloc_option: MemAllocOption,
    native_module_name: ?[*:0]const u8,
    native_symbols: ?[*]NativeSymbol,
    n_native_symbols: u32,
    max_thread_num: u32,
    ip_addr: [128]u8,
    unused: c_int,
    instance_port: c_int,
    fast_jit_code_cache_size: u32,
    gc_heap_size: u32,
    running_mode: c_int,
    llvm_jit_opt_level: u32,
    llvm_jit_size_level: u32,
    segue_flags: u32,
    enable_linux_perf: bool,
};

pub extern fn wasm_runtime_full_init(args: *RuntimeInitArgs) bool;
pub extern fn wasm_runtime_destroy() void;
pub extern fn wasm_runtime_set_log_level(level: c_int) void;
pub extern fn wasm_runtime_load(
    buf: [*]u8,
    size: u32,
    error_buf: [*]u8,
    error_buf_size: u32,
) ?*ModuleHandle;
pub extern fn wasm_runtime_unload(module: *ModuleHandle) void;
pub extern fn wasm_runtime_instantiation_args_create(args: *?*ArgsHandle) bool;
pub extern fn wasm_runtime_instantiation_args_destroy(args: *ArgsHandle) void;
pub extern fn wasm_runtime_instantiation_args_set_default_stack_size(args: *ArgsHandle, size: u32) void;
pub extern fn wasm_runtime_instantiation_args_set_max_memory_pages(args: *ArgsHandle, pages: u32) void;
pub extern fn wasm_runtime_instantiate_ex2(
    module: *ModuleHandle,
    args: *const ArgsHandle,
    error_buf: [*]u8,
    error_buf_size: u32,
) ?*InstanceHandle;
pub extern fn wasm_runtime_deinstantiate(instance: *InstanceHandle) void;
pub extern fn wasm_runtime_create_exec_env(instance: *InstanceHandle, stack_size: u32) ?*Env;
pub extern fn wasm_runtime_destroy_exec_env(env: *Env) void;
pub extern fn wasm_runtime_get_module_inst(env: *Env) *InstanceHandle;
pub extern fn wasm_runtime_lookup_function(instance: *InstanceHandle, name: [*:0]const u8) ?*FunctionHandle;
pub extern fn wasm_runtime_call_wasm(env: *Env, function: *FunctionHandle, argc: u32, argv: [*]u32) bool;
pub extern fn wasm_runtime_get_exception(instance: *InstanceHandle) ?[*:0]const u8;
pub extern fn wasm_runtime_clear_exception(instance: *InstanceHandle) void;
pub extern fn wasm_runtime_set_user_data(env: *Env, user_data: ?*anyopaque) void;
pub extern fn wasm_runtime_get_user_data(env: *Env) ?*anyopaque;
pub extern fn wasm_runtime_set_instruction_count_limit(env: *Env, count: c_int) void;
pub extern fn wasm_runtime_get_default_memory(instance: *InstanceHandle) ?*MemoryHandle;
pub extern fn wasm_memory_get_base_address(memory: *MemoryHandle) ?[*]u8;
pub extern fn wasm_memory_get_cur_page_count(memory: *MemoryHandle) u64;
pub extern fn wasm_memory_get_bytes_per_page(memory: *MemoryHandle) u64;
