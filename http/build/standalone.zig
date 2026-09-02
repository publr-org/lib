const std = @import("std");

/// The standalone file-server binary: the library's own consumer, so serving a
/// folder needs no program of your own. `zig build serve -- --local --root ./public`.
pub fn build(b: *std.Build, library: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "publr-http",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = library.resolved_target.?,
            .optimize = library.optimize.?,
            .imports = &.{
                .{ .name = "publr_http", .module = library },
            },
        }),
    });

    b.installArtifact(exe);

    const serve_step = b.step("serve", "Run the standalone file server");
    const serve_command = b.addRunArtifact(exe);

    if (b.args) |args| {
        serve_command.addArgs(args);
    }

    serve_step.dependOn(&serve_command.step);
}
