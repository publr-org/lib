const std = @import("std");

/// Every test is a unit test, inline in `src/`. The suite runs twice: against the source
/// tree, and against the amalgamation consumers get.
pub fn build(b: *std.Build, library: *std.Build.Module, amalgamation: *std.Build.Module) void {
    const tests = b.addTest(.{ .root_module = library, .name = "groq-tests" });
    const amalgamation_tests = b.addTest(.{
        .root_module = amalgamation,
        .name = "groq-amalgamation-tests",
    });

    const test_step = b.step("test", "Run all tests, on the source tree and on the amalgamation");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(amalgamation_tests).step);
}
