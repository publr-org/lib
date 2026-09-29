const std = @import("std");
const build_library = @import("build/library.zig").build;
const build_tests = @import("build/tests.zig").build;

pub fn build(b: *std.Build) void {
    const library = build_library(b);

    build_tests(b, library);
}
