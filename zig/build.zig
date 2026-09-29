const std = @import("std");
const build_toolchain = @import("build/toolchain.zig").build;
const build_tests = @import("build/tests.zig").build;

pub fn build(b: *std.Build) void {
    const toolchain = build_toolchain(b);

    build_tests(b, toolchain);
}
