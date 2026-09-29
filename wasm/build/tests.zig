const std = @import("std");

/// Unit tests live inline in `src/`; integration tests run a real module under `tests/`,
/// built here from `tests/guest.zig` for `wasm32-freestanding`, the target a guest is built for.
pub fn build(b: *std.Build, library: *std.Build.Module) void {
    const test_step = b.step("test", "Run all tests (unit + integration)");
    const guest = b.addExecutable(.{
        .name = "guest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/guest.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });

    guest.entry = .disabled;
    guest.rdynamic = true;

    const integration = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = library.resolved_target.?,
        .optimize = library.optimize.?,
        .imports = &.{.{ .name = "publr_wasm", .module = library }},
    });

    integration.addAnonymousImport("guest.wasm", .{ .root_source_file = guest.getEmittedBin() });

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = library })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = integration })).step);
}
