const std = @import("std");

/// Pure Zig over `std`: nothing to link, nothing vendored.
pub fn build(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    return b.addModule("publr_groq", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
}
