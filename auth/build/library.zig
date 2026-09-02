const std = @import("std");

/// Pure Zig over `std.crypto`: nothing to link, nothing vendored. The module is
/// the four source files and their tests.
pub fn build(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const library = b.addModule("publr_auth", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The one name the library owns, chosen by the app that builds it:
    // `-Dcookie_prefix=tyik` makes the session cookie `tyik_publr_session`.
    const options = b.addOptions();

    options.addOption([]const u8, "cookie_prefix", b.option(
        []const u8,
        "cookie_prefix",
        "Prefix for the session cookie name (<prefix>_publr_session)",
    ) orelse "");

    library.addOptions("build_options", options);

    return library;
}
