const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const module = builder.addModule("publr_api", .{
        .root_source_file = builder.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = builder.addTest(.{
        .root_module = module,
    });
    const run = builder.addRunArtifact(tests);

    builder.step("test", "The API's shape, read and written").dependOn(&run.step);
}
