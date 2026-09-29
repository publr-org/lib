const std = @import("std");

const root = "vendor/wamr/core/";

/// The vendored WAMR interpreter compiled into the module itself, so a consumer importing
/// `publr_wasm` gets a self-contained binary.
pub fn build(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const library = b.addModule("publr_wasm", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    add_runtime(b, library, target.result);

    return library;
}

fn add_runtime(b: *std.Build, library: *std.Build.Module, target: std.Target) void {
    const platform = switch (target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => @panic("publr_wasm: WAMR is built for macOS and Linux only"),
    };
    const flags = b.allocator.dupe([]const u8, &(common_flags ++ [_][]const u8{
        if (target.os.tag == .macos) "-DBH_PLATFORM_DARWIN" else "-DBH_PLATFORM_LINUX",
        if (target.os.tag == .linux) "-DWASM_HAVE_MREMAP=1" else "-DWASM_HAVE_MREMAP=0",
    })) catch @panic("OOM");

    inline for (include_paths) |path| {
        library.addIncludePath(b.path(root ++ path));
    }

    library.addIncludePath(b.path(b.fmt(root ++ "shared/platform/{s}", .{platform})));

    inline for (sources) |source| {
        library.addCSourceFile(.{ .file = b.path(root ++ source), .flags = flags });
    }

    library.addCSourceFile(.{
        .file = b.path(b.fmt(root ++ "shared/platform/{s}/platform_init.c", .{platform})),
        .flags = flags,
    });

    // The invoker is assembly behind the preprocessor's platform guards, so it goes through
    // the C preprocessor like a `.S` file would.
    const invoker = switch (target.cpu.arch) {
        .aarch64 => "iwasm/common/arch/invokeNative_aarch64.s",
        .x86_64 => "iwasm/common/arch/invokeNative_em64.s",
        else => "iwasm/common/arch/invokeNative_general.c",
    };
    const is_assembly = std.mem.endsWith(u8, invoker, ".s");

    library.addCSourceFile(.{
        .file = b.path(b.fmt("{s}{s}", .{ root, invoker })),
        .flags = flags,
        .language = if (is_assembly) .assembly_with_preprocessor else null,
    });
}

const include_paths = [_][]const u8{
    "",
    "iwasm/include",
    "iwasm/interpreter",
    "iwasm/common",
    "shared/platform/include",
    "shared/utils",
    "shared/utils/uncommon",
    "shared/mem-alloc",
};

const sources = [_][]const u8{
    "iwasm/interpreter/wasm_interp_fast.c",
    "iwasm/interpreter/wasm_runtime.c",
    "iwasm/interpreter/wasm_loader.c",
    "iwasm/common/wasm_runtime_common.c",
    "iwasm/common/wasm_native.c",
    "iwasm/common/wasm_exec_env.c",
    "iwasm/common/wasm_memory.c",
    "iwasm/common/wasm_loader_common.c",
    "iwasm/common/wasm_application.c",
    "iwasm/common/wasm_blocking_op.c",
    "iwasm/common/wasm_c_api.c",
    "shared/mem-alloc/mem_alloc.c",
    "shared/mem-alloc/ems/ems_kfc.c",
    "shared/mem-alloc/ems/ems_alloc.c",
    "shared/mem-alloc/ems/ems_hmu.c",
    "shared/mem-alloc/ems/ems_gc.c",
    "shared/utils/bh_assert.c",
    "shared/utils/bh_bitmap.c",
    "shared/utils/bh_common.c",
    "shared/utils/bh_hashmap.c",
    "shared/utils/bh_leb128.c",
    "shared/utils/bh_list.c",
    "shared/utils/bh_log.c",
    "shared/utils/bh_queue.c",
    "shared/utils/bh_vector.c",
    "shared/utils/runtime_timer.c",
    "shared/utils/uncommon/bh_read_file.c",
    "shared/platform/common/posix/posix_thread.c",
    "shared/platform/common/posix/posix_time.c",
    "shared/platform/common/posix/posix_sleep.c",
    "shared/platform/common/posix/posix_malloc.c",
    "shared/platform/common/posix/posix_memmap.c",
    "shared/platform/common/posix/posix_blocking_op.c",
    "shared/platform/common/memory/mremap.c",
};

/// The flags are part of the library's contract: the fast interpreter and nothing else
/// (no AOT, no JIT, no WASI, no threads), reference types and bulk memory because toolchains
/// emit them by default (Zig lowers `@memcpy` to
/// `memory.copy`), instruction metering so a call can be given a budget, and software
/// bounds checks so no signal handler is installed in the host process.
const common_flags = [_][]const u8{
    "-DWASM_ENABLE_INTERP=1",
    "-DWASM_ENABLE_FAST_INTERP=1",
    "-DWASM_ENABLE_AOT=0",
    "-DWASM_ENABLE_JIT=0",
    "-DWASM_ENABLE_FAST_JIT=0",
    "-DWASM_ENABLE_LIBC_WASI=0",
    "-DWASM_ENABLE_LIBC_BUILTIN=0",
    "-DWASM_ENABLE_INSTRUCTION_METERING=1",
    "-DBH_MALLOC=wasm_runtime_malloc",
    "-DBH_FREE=wasm_runtime_free",
    "-DWASM_ENABLE_SHARED_MEMORY=0",
    "-DWASM_ENABLE_BULK_MEMORY=1",
    "-DWASM_ENABLE_THREAD_MGR=0",
    "-DWASM_ENABLE_TAIL_CALL=0",
    "-DWASM_ENABLE_SIMD=0",
    "-DWASM_ENABLE_REF_TYPES=1",
    "-DWASM_ENABLE_GC=0",
    "-DWASM_ENABLE_MULTI_MODULE=0",
    "-DWASM_ENABLE_LIB_PTHREAD=0",
    "-DWASM_ENABLE_LIB_WASI_THREADS=0",
    "-DWASM_ENABLE_DEBUG_INTERP=0",
    "-DWASM_ENABLE_DUMP_CALL_STACK=0",
    "-DWASM_ENABLE_PERF_PROFILING=0",
    "-DWASM_ENABLE_MEMORY_PROFILING=0",
    "-DWASM_ENABLE_LOAD_CUSTOM_SECTION=0",
    "-DWASM_ENABLE_CUSTOM_NAME_SECTION=0",
    "-DWASM_ENABLE_EXCE_HANDLING=0",
    "-DWASM_ENABLE_TAGS=0",
    "-DWASM_ENABLE_MINI_LOADER=0",
    "-DWASM_DISABLE_HW_BOUND_CHECK=1",
    "-DWASM_DISABLE_STACK_HW_BOUND_CHECK=1",
    // The fast interpreter stores pointers unaligned on purpose.
    "-fno-sanitize=alignment",
};
