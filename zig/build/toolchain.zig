const std = @import("std");

pub const Toolchain = struct {
    module: *std.Build.Module,
    archive: std.Build.LazyPath,
};

/// The `publr_zig` module: the vendored compiler built for `target`, without LLVM, packed
/// with its standard library and a compiler_rt for `wasm32-freestanding` into the archive
/// the module embeds.
pub fn build(b: *std.Build) Toolchain {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Zig's own build, untouched: the full compiler, which without LLVM builds for `wasm32`
    // with its own backend. Its wasm-only preset (`-Ddev=wasm`) would be a quarter of the
    // size, but 0.16's lacks the `legalize` pass that backend needs.
    const zig = b.dependency("zig", .{
        .target = target,
        .optimize = .ReleaseSmall,
        .@"no-lib" = true,
        .@"version-string" = @as([]const u8, "0.16.0"),
    });
    const compiler = zig.artifact("zig");

    // The wasm backend cannot compile compiler_rt yet (0.16 builds it for `wasm32` with
    // LLVM only), so the Zig building this one does, once.
    const compiler_rt = b.addLibrary(.{
        .name = "compiler_rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = zig.path("lib/compiler_rt.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });

    compiler_rt.bundle_compiler_rt = false;

    const pack = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/pack.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    // Consumers pack their own files the same way (`dependency.artifact("pack")`).
    b.installArtifact(pack);

    const run = b.addRunArtifact(pack);
    const archive = run.addOutputFileArg("toolchain.tar.gz");

    run.addPrefixedArtifactArg("+zig=", compiler);
    run.addPrefixedArtifactArg("lib/libcompiler_rt.a=", compiler_rt);
    run.addPrefixedDirectoryArg("lib/std/=", zig.path("lib/std"));
    add_inputs(b, run, zig, "lib/std");

    const module = b.addModule("publr_zig", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addAnonymousImport("toolchain_archive", .{ .root_source_file = archive });

    return .{ .module = module, .archive = archive };
}

/// A folder argument is cached by its path alone: each file under `dir` is an input, so a
/// changed standard library (a new vendored Zig) packs it again.
fn add_inputs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    zig: *std.Build.Dependency,
    dir: []const u8,
) void {
    const io = b.graph.io;
    var root = zig.builder.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("publr_zig: cannot open {s}: {t}", .{ dir, err });
    };
    defer root.close(io);

    var walker = root.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    while (walker.next(io) catch |err| std.debug.panic("publr_zig: {t}", .{err})) |entry| {
        if (entry.kind == .file) {
            run.addFileInput(zig.path(b.pathJoin(&.{ dir, entry.path })));
        }
    }
}
