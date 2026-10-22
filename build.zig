//! The workspace: each library has its own build, tests, amalgamation, and
//! reference. This build does the one thing that spans them — one
//! documentation site for every library:
//!
//!     zig build docs    # zig-out/docs: a home page, and each library under <name>/
//!     zig build serve   # the same site at http://127.0.0.1:8100, served by publr-http
//!
//! Each library's reference comes in as the named lazy path `"docs"` its build
//! publishes (see tools/). Adding a library to the site is one entry in
//! `libraries` below, after its `build.zig` calls `build_docs`.
const std = @import("std");
const tools = @import("publr_tools");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Debug builds on purpose: the libraries pick ReleaseSafe only under
    // `-Drelease`, and a debug `publr-http` binds 127.0.0.1, which is what a
    // local docs server should do.
    const http_server = b.dependency("http_server", .{
        .target = target,
    });
    const sqlite = b.dependency("publr_sqlite", .{
        .target = target,
    });
    const auth = b.dependency("publr_auth", .{
        .target = target,
    });
    const groq = b.dependency("publr_groq", .{
        .target = target,
    });
    const ai = b.dependency("publr_ai", .{
        .target = target,
    });
    const text = b.dependency("publr_text", .{
        .target = target,
    });

    const site = tools.hub(b, &.{
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
        .{
            .name = "publr_groq",
            .description = "GROQ, the query language, from text to value over any dataset.",
            .docs = groq.namedLazyPath("docs"),
        },
        .{
            .name = "publr_ai",
            .description = "Messages, tools and providers for language models, and the loop that runs a turn.",
            .docs = ai.namedLazyPath("docs"),
        },
        .{
            .name = "publr_text",
            .description = "Text as JS's String handles it: Unicode 17 case, normalization, collation and patterns.",
            .docs = text.namedLazyPath("docs"),
        },
    }, .{});

    // The site is static files, and the workspace has a static file server:
    // serve the docs with it. The response cap is raised because a reference's
    // sources.tar and main.wasm are a few hundred KB each.
    const serve = b.addRunArtifact(http_server.artifact("publr-http"));
    serve.addArg("--root");
    serve.addDirectoryArg(site);
    serve.addArgs(&.{ "--response-bytes-max", "8388608", "--port", "8100" });
    if (b.args) |args| serve.addArgs(args);

    b.step("serve", "Serve the docs of every library at http://127.0.0.1:8100").dependOn(&serve.step);

    add_tidy(b);
}

/// `zig build tidy`: the options rule of Publr's tidy (`STYLE.md`), alone, over every
/// library's sources. Each library's tests stay in its own build, so this is a step of
/// its own rather than a dependency of one.
fn add_tidy(b: *std.Build) void {
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = .{
                .cwd_relative = b.pathFromRoot("../publr/scripts/tidy.zig"),
            },
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tidy);

    run.addArgs(&.{ "--only=options", "build.zig" });
    run.addArgs(&.{ "ai/build", "ai/build.zig", "ai/src" });
    run.addArgs(&.{ "auth/build", "auth/build.zig", "auth/src" });
    run.addArgs(&.{ "deps/build.zig", "deps/src", "deps/tests" });
    run.addArgs(&.{ "groq/build", "groq/build.zig", "groq/conformance", "groq/src" });
    run.addArgs(&.{ "http/build", "http/build.zig", "http/examples", "http/src", "http/stress" });
    run.addArgs(&.{ "sqlite/build", "sqlite/build.zig", "sqlite/src", "sqlite/tests" });
    run.addArgs(&.{ "text/build", "text/build.zig", "text/src" });
    run.addArgs(&.{ "tools/build.zig", "tools/tools" });
    run.addArgs(&.{ "wasm/build", "wasm/build.zig", "wasm/src", "wasm/tests" });
    run.addArgs(&.{ "zig/build", "zig/build.zig", "zig/src", "zig/tests" });
    run.setCwd(b.path("."));
    run.has_side_effects = true;

    b.step("tidy", "The options rule of Publr's tidy over every library").dependOn(&run.step);
}
