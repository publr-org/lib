const std = @import("std");

/// Unit tests live inline in `src/`; integration tests — everything that opens
/// a real database — live under `tests/`, grouped by topic. Both run against
/// the amalgamation as well, since that is the library consumers get: the one
/// in which everything outside the public surface is truly private.
pub fn build(b: *std.Build, library: *std.Build.Module, amalgamation: *std.Build.Module) void {
    const test_step = b.step("test", "Run all tests (unit + integration), on the source tree and on the amalgamation");

    for ([_]*std.Build.Module{ library, amalgamation }) |module| {
        const unit_tests = b.addTest(.{ .root_module = module });

        const integration_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = library.resolved_target.?,
            .optimize = library.optimize.?,
            .imports = &.{
                .{ .name = "publr_sqlite", .module = module },
            },
        });
        const integration_tests = b.addTest(.{ .root_module = integration_module });

        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
        test_step.dependOn(&b.addRunArtifact(integration_tests).step);
    }
}
