const std = @import("std");

/// publr_deps: the dependency index (see TESTS.md — the contract is the test
/// matrix). One module, one dependency (publr_sqlite). Unit tests live inline
/// in src/; everything that opens a real database lives under tests/, grouped
/// by matrix section.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const sqlite = b.dependency("publr_sqlite", .{ .target = target, .release = optimize != .Debug });

    const library = b.addModule("publr_deps", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "publr_sqlite", .module = sqlite.module("publr_sqlite") },
        },
    });

    const test_step = b.step("test", "Run all tests (unit + integration)");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = library })).step);

    const integration = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "publr_deps", .module = library },
            .{ .name = "publr_sqlite", .module = sqlite.module("publr_sqlite") },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = integration })).step);
}
