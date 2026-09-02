const std = @import("std");

pub fn build(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const library = b.addModule("publr_http", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();

    options.addOption(?[]const u8, "event_backend", b.option(
        []const u8,
        "event-backend",
        "Force an event backend: kqueue, epoll, poll",
    ));

    library.addOptions("build_options", options);

    return library;
}
