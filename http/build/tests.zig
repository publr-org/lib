const std = @import("std");

/// The suite runs twice: against the source tree, and against the amalgamation
/// that consumers get — the one in which everything outside the public surface
/// is truly private. A test that passes only in the source tree is a test that
/// leans on something the library does not actually expose.
pub fn build(b: *std.Build, library: *std.Build.Module, amalgamation: *std.Build.Module) void {
    const tests = b.addTest(.{
        .root_module = library,
        .name = "http-server-tests",
    });
    const amalgamation_tests = b.addTest(.{
        .root_module = amalgamation,
        .name = "http-server-amalgamation-tests",
    });

    const test_step = b.step("test", "Run all tests, on the source tree and on the amalgamation");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(amalgamation_tests).step);

    const test_exe_step = b.step("test-exe", "Build the test binary for the debugger");
    test_exe_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
}
