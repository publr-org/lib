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
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .safe,
    });
    const prebuilt = b.option(
        []const u8,
        "toolchain-archive",
        "A toolchain.tar.gz built before for the same target and Zig, used instead of building one",
    );
    const pack = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/pack.zig"),
            .target = b.graph.host,
            .optimize = .fast,
        }),
    });
    // Consumers pack their own files the same way (`dependency.artifact("pack")`).
    b.installArtifact(pack);

    const archive: std.Build.LazyPath = if (prebuilt) |path|
        b.graph.cwdRelativePath(path)
    else
        build_archive(b, target, pack);

    // `zig build toolchain -Dtarget=…` writes the archive to zig-out/, for CI to keep.
    const install = b.addInstallFile(archive, "toolchain.tar.gz");
    b.step("toolchain", "Build the toolchain archive into zig-out/").dependOn(&install.step);

    const module = b.addModule("publr_zig", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addAnonymousImport("toolchain_archive", .{
        .root_source_file = archive,
    });

    return .{
        .module = module,
        .archive = archive,
    };
}

fn build_archive(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    pack: *std.Build.Step.Compile,
) std.Build.LazyPath {
    // Zig's own build, untouched: the full compiler, which without LLVM builds for `wasm32`
    // with its own backend. Its wasm-only preset (`-Ddev=wasm`) is under a third of the
    // size and has the `legalize` pass since 0.17; not used until installed plugins are
    // checked with it.
    const zig = b.dependency("zig", .{
        .target = target,
        .optimize = .small,
        .@"no-lib" = true,
        .@"version-string" = @as([]const u8, "0.17.0"),
    });
    const compiler = zig.artifact("zig");

    // The wasm backend cannot compile compiler_rt yet (0.17 without LLVM emits a linked
    // module, not an object to link), so the Zig building this one does, once.
    const compiler_rt = b.addLibrary(.{
        .name = "compiler_rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = zig.path("lib/compiler_rt.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .small,
        }),
    });

    compiler_rt.bundle_compiler_rt = false;

    const run = b.addRunArtifact(pack);
    const archive = run.addOutputFileArg2("toolchain.tar.gz", .{});

    run.addArtifactArg2(compiler, .{
        .prefix = "+zig=",
    });
    run.addArtifactArg2(compiler_rt, .{
        .prefix = "lib/libcompiler_rt.a=",
    });
    run.addDirectoryArg2(zig.path("lib/std"), .{
        .prefix = "lib/std/=",
    });
    add_inputs(b, run, zig, "lib/std");

    return archive;
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
    const path = zig.builder.root.join(b.allocator, dir) catch @panic("OOM");
    var root = path.root_dir.handle.openDir(io, path.sub_path, .{
        .iterate = true,
    }) catch |err| {
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
