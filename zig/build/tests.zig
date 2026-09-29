const std = @import("std");
const Toolchain = @import("toolchain.zig").Toolchain;

/// Integration tests unpack the real toolchain and build `tests/guest.zig` with it.
pub fn build(b: *std.Build, toolchain: Toolchain) void {
    const test_step = b.step("test", "Run all tests");
    const integration = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = toolchain.module.resolved_target.?,
        .optimize = toolchain.module.optimize.?,
        .imports = &.{.{ .name = "publr_zig", .module = toolchain.module }},
    });

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = integration })).step);
}
