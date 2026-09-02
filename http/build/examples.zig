const std = @import("std");

pub fn build(b: *std.Build, library: *std.Build.Module) void {
    const examples = [_]struct {
        name: []const u8,
        root: []const u8,
        step: []const u8,
        description: []const u8,
    }{
        .{
            .name = "hello",
            .root = "examples/hello.zig",
            .step = "run",
            .description = "Run the hello-world example server",
        },
        .{
            .name = "ingest",
            .root = "examples/ingest.zig",
            .step = "run-ingest",
            .description = "Run the ingest example server",
        },
        .{
            .name = "chat",
            .root = "examples/chat.zig",
            .step = "run-chat",
            .description = "Run the WebSocket chat example server",
        },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.root),
                .target = library.resolved_target.?,
                .optimize = library.optimize.?,
                .imports = &.{
                    .{ .name = "publr_http", .module = library },
                },
            }),
        });

        b.installArtifact(exe);

        const run_step = b.step(example.step, example.description);
        const run_command = b.addRunArtifact(exe);

        if (b.args) |args| {
            run_command.addArgs(args);
        }

        run_step.dependOn(&run_command.step);
    }
}
