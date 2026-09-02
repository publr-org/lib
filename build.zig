//! The workspace: `lib/` holds the libraries, each with its own build, tests,
//! amalgamation, and reference; `demos/` holds their consumers. This build does
//! the one thing that spans them — one documentation site for every library:
//!
//!     zig build docs    # zig-out/docs: a home page, and each library under <name>/
//!     zig build serve   # the same site at http://127.0.0.1:8100, served by publr-http
//!
//! Each library's reference comes in as the named lazy path `"docs"` its build
//! publishes (see lib/zig-tools). Adding a library to the site is one entry in
//! `libraries` below, after its `build.zig` calls `build_docs`.
const std = @import("std");
const tools = @import("publr_tools");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Debug builds on purpose: the libraries pick ReleaseSafe only under
    // `-Drelease`, and a debug `publr-http` binds 127.0.0.1, which is what a
    // local docs server should do.
    const http_server = b.dependency("http_server", .{ .target = target });
    const sqlite = b.dependency("publr_sqlite", .{ .target = target });
    const auth = b.dependency("publr_auth", .{ .target = target });

    const site = tools.hub(b, .{ .packages = &.{
        .{
            .name = "publr_http",
            .description = "A fixed-capacity, single-threaded HTTP/1.1 server, composed at compile time.",
            .docs = http_server.namedLazyPath("docs"),
        },
        .{
            .name = "publr_sqlite",
            .description = "SQLite, fully self-contained, behind a deliberately thin binding.",
            .docs = sqlite.namedLazyPath("docs"),
        },
        .{
            .name = "publr_auth",
            .description = "Password hashing, sign-in throttling and CSRF tokens, allocating only at startup.",
            .docs = auth.namedLazyPath("docs"),
        },
    } });

    // The site is static files, and the workspace has a static file server:
    // serve the docs with it. The response cap is raised because a reference's
    // sources.tar and main.wasm are a few hundred KB each.
    const serve = b.addRunArtifact(http_server.artifact("publr-http"));
    serve.addArg("--root");
    serve.addDirectoryArg(site);
    serve.addArgs(&.{ "--response-bytes-max", "8388608", "--port", "8100" });
    if (b.args) |args| serve.addArgs(args);

    b.step("serve", "Serve the docs of every library at http://127.0.0.1:8100").dependOn(&serve.step);
}
