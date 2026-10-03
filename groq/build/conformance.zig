const std = @import("std");

/// `zig build conformance -- <suite.ndjson> [--show N] [--movies <path>]`: the GROQ
/// conformance suite (github.com/sanity-io/groq-test-suite) against the engine, built
/// optimised whatever the build's mode: the movies dataset is half a million documents.
pub fn build(b: *std.Build, library: *std.Build.Module) void {
    const engine = b.createModule(.{
        .root_source_file = library.root_source_file,
        .target = library.resolved_target,
        .optimize = .ReleaseSafe,
    });
    const runner = b.addExecutable(.{
        .name = "groq-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/run.zig"),
            .target = library.resolved_target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "groq", .module = engine }},
        }),
    });
    const run = b.addRunArtifact(runner);

    if (b.args) |arguments| {
        run.addArgs(arguments);
    }

    const step = b.step("conformance", "Run the GROQ conformance suite: -- <suite.ndjson>");
    step.dependOn(&run.step);
}
