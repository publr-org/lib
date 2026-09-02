//! Amalgamation and API reference for any library in this workspace.
//!
//!     const amalgamate = @import("publr_tools").amalgamate;
//!     const build_docs = @import("publr_tools").docs;
//!
//!     pub fn build(b: *std.Build) void {
//!         const library = b.addModule("publr_sqlite", .{ ... });
//!         const amalgamation = amalgamate(b, library, .{});
//!         build_tests(b, library, amalgamation.module);
//!         build_docs(b, amalgamation, .{});
//!     }
//!
//! `zig build amalgamate` writes `zig-out/<name>.zig`: the library as one file in
//! which `pub` means exactly "part of the consumer surface", with no tests in it
//! (tools/amalgamate.zig explains how). That file is the vendoring artifact, the
//! thing the tests also run against, and the source the reference is built from —
//! so what the docs show and what a consumer can name are the same set by
//! construction.
//!
//! `zig build docs` writes `zig-out/docs`. What the compiler emits on its own is
//! its `main.wasm` plus a `sources.tar`, wrapped in a stock `index.html` copied
//! verbatim out of the Zig installation. That shell is Zig-branded, and the tar
//! carries every module the docs object can reach (all of `std`, ~16 MB). This
//! swaps in a neutral shell and trims the tar to the amalgamation. Everything
//! the shell shows — name, tagline, API index — comes from the module's own
//! analysis, so there is nothing to configure.
//!
//! `docs` and `amalgamate` take the module they work on, which is not the
//! signature `zig build` calls on a dependency's build script. That is why this
//! package carries its own files by `@embedFile` rather than reaching for them
//! through a `std.Build.Dependency`: it is only ever imported, never instantiated
//! as a dependency, so its functions are free to take what they need.
const std = @import("std");
const builtin = @import("builtin");

const shell_html = @embedFile("shell/index.html");
const trim_sources_zig = @embedFile("tools/trim_sources.zig");
const amalgamate_zig = @embedFile("tools/amalgamate.zig");

pub const AmalgamateOptions = struct {
    /// The module's import name, as passed to `b.addModule`. Defaults to looking
    /// `module` up among the build's public modules, which is right whenever the
    /// module being amalgamated is the package's own.
    name: ?[]const u8 = null,
    /// Build step to expose, and its `zig build --help` line.
    step_name: []const u8 = "amalgamate",
    step_description: []const u8 = "Amalgamate the library into zig-out/<name>.zig",
    /// Install directory, relative to the install prefix; "" is the prefix itself.
    install_subdir: []const u8 = "",
};

pub const Amalgamation = struct {
    /// The import name; also the tar directory the reference is rooted at.
    name: []const u8,
    /// The generated single file, `<name>.zig`.
    file: std.Build.LazyPath,
    /// A module rooted at the generated file, configured like the source module
    /// (target, optimize, imports, libc, linked objects). Run the tests against
    /// it, and `build` documents it.
    module: *std.Build.Module,
};

pub fn amalgamate(b: *std.Build, library: *std.Build.Module, options: AmalgamateOptions) Amalgamation {
    const name = options.name orelse moduleName(b, library);
    const root_source = library.root_source_file orelse std.debug.panic(
        "publr_tools: module has no root source file to amalgamate",
        .{},
    );

    const files = b.addWriteFiles();
    const tool = b.addRunArtifact(b.addExecutable(.{
        .name = "publr_tools_amalgamate",
        .root_module = b.createModule(.{
            .root_source_file = files.add("amalgamate.zig", amalgamate_zig),
            .target = b.graph.host,
        }),
    }));
    tool.addFileArg(root_source);
    tool.addArg(name);
    const out_dir = tool.addOutputDirectoryArg("amalgamation");
    // The tool reads every file the root imports, transitively; the depfile is
    // how the build learns to rerun it when any of them changes.
    _ = tool.addDepFileOutputArg("amalgamation.d");

    const file = out_dir.path(b, b.fmt("{s}.zig", .{name}));

    const module = b.createModule(.{
        .root_source_file = file,
        .target = library.resolved_target,
        .optimize = library.optimize,
        .link_libc = library.link_libc,
    });
    for (library.import_table.keys(), library.import_table.values()) |import_name, import| {
        module.addImport(import_name, import);
    }
    module.link_objects.appendSlice(b.allocator, library.link_objects.items) catch @panic("OOM");

    const step = b.step(options.step_name, options.step_description);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = out_dir,
        .install_dir = .prefix,
        .install_subdir = options.install_subdir,
    }).step);

    return .{ .name = name, .file = file, .module = module };
}

pub const Options = struct {
    /// Build step to expose, and its `zig build --help` line.
    step_name: []const u8 = "docs",
    step_description: []const u8 = "Generate the API reference into zig-out/docs",
    /// Install directory, relative to the install prefix.
    install_subdir: []const u8 = "docs",
};

/// Builds the reference as one self-contained directory, installs it on the
/// `docs` step, and publishes it as the named lazy path `"docs"` — which is how a
/// workspace build pulls every package's reference into one site; see `hub`.
/// Nothing to build on its own: this package exists for `amalgamate`, `docs`, and
/// `hub`. The entry point has to exist anyway — `b.dependency` is generic over
/// every package in the manifest tree, so the runner compiles `build(b)` for all
/// of them, and a helper could not be called `build` for that reason.
pub fn build(b: *std.Build) void {
    _ = b;
}

pub fn docs(b: *std.Build, amalgamation: Amalgamation, options: Options) void {
    const site = docsSite(b, amalgamation);
    b.addNamedLazyPath("docs", site);

    const step = b.step(options.step_name, options.step_description);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = site,
        .install_dir = .prefix,
        .install_subdir = options.install_subdir,
    }).step);
}

/// The reference for one amalgamation as a directory: the compiler's viewer
/// (`main.js`, `main.wasm`), the replacement shell, the trimmed sources, and the
/// generated config.
fn docsSite(b: *std.Build, amalgamation: Amalgamation) std.Build.LazyPath {
    const name = amalgamation.name;

    // The compiler emits docs for an object, not for a module. The tar directory
    // takes the object's name, which is what the viewer shows as the module.
    const docs_object = b.addObject(.{ .name = name, .root_module = amalgamation.module });
    const emitted = docs_object.getEmittedDocs();

    const tools = b.addWriteFiles();
    const trim = b.addRunArtifact(b.addExecutable(.{
        .name = "publr_tools_trim_sources",
        .root_module = b.createModule(.{
            .root_source_file = tools.add("trim_sources.zig", trim_sources_zig),
            .target = b.graph.host,
        }),
    }));
    trim.addFileArg(emitted.path(b, "sources.tar"));
    const trimmed = trim.addOutputFileArg("sources.tar");
    trim.addArg(name);
    trim.addArg(b.fmt("{s}.zig", .{name}));

    const site = b.addWriteFiles();
    _ = site.addCopyFile(emitted.path(b, "main.js"), "main.js");
    _ = site.addCopyFile(emitted.path(b, "main.wasm"), "main.wasm");
    _ = site.addCopyFile(trimmed, "sources.tar");
    _ = site.add("index.html", shell_html);
    // The only thing the shell cannot work out at runtime is which Zig
    // reference to send `std.*` links to: the trimmed tar deliberately no
    // longer contains std, but the renderer still linkifies those paths.
    _ = site.add("docs-config.js", b.fmt(
        \\// Generated by publr_tools. Edit build.zig, not this file.
        \\window.PUBLR_DOCS = {{
        \\  zigStdDocs: "https://ziglang.org/documentation/{f}/std/",
        \\}};
        \\
    , .{builtin.zig_version}));

    return site.getDirectory();
}

pub const HubPackage = struct {
    /// The import name; also the directory the package's reference lands in.
    name: []const u8,
    /// One line for the home page.
    description: []const u8,
    /// The package's reference directory: `dependency.namedLazyPath("docs")`.
    docs: std.Build.LazyPath,
};

pub const HubOptions = struct {
    title: []const u8 = "Publr",
    packages: []const HubPackage,
    step_name: []const u8 = "docs",
    step_description: []const u8 = "Build the docs of every package into one site in zig-out/docs",
    /// Install directory, relative to the install prefix.
    install_subdir: []const u8 = "docs",
};

/// One site for a workspace: a home page listing every package, each package's
/// reference under `<name>/`. Installs on the `docs` step and returns the site
/// directory, so the caller can also serve it straight from the cache.
pub fn hub(b: *std.Build, options: HubOptions) std.Build.LazyPath {
    const site = b.addWriteFiles();

    var cards = std.ArrayList(u8).empty;
    var manifest = std.ArrayList(u8).empty;
    for (options.packages, 0..) |package, index| {
        cards.appendSlice(b.allocator, b.fmt(
            \\      <a class="card" href="./{s}/">
            \\        <span class="name">{s}</span>
            \\        <span class="description">{s}</span>
            \\      </a>
            \\
        , .{ package.name, package.name, package.description })) catch @panic("OOM");
        manifest.appendSlice(b.allocator, b.fmt(
            \\{s}    {{ "name": "{s}", "description": "{s}" }}
        , .{ if (index == 0) "" else ",\n", package.name, jsonEscape(b, package.description) })) catch @panic("OOM");
        _ = site.addCopyDirectory(package.docs, package.name, .{});
    }
    _ = site.add("index.html", b.fmt(hub_html, .{ options.title, options.title, cards.items }));

    // Each reference's shell fetches `../hub.json`; when it is there the module
    // name in the sidebar becomes a switcher between libraries. A standalone
    // `zig build docs` in a library has no such file, and no switcher.
    _ = site.add("hub.json", b.fmt(
        \\{{
        \\  "title": "{s}",
        \\  "packages": [
        \\{s}
        \\  ]
        \\}}
        \\
    , .{ jsonEscape(b, options.title), manifest.items }));

    const step = b.step(options.step_name, options.step_description);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = site.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = options.install_subdir,
    }).step);

    return site.getDirectory();
}

fn jsonEscape(b: *std.Build, text: []const u8) []const u8 {
    var out = std.ArrayList(u8).empty;
    for (text) |byte| switch (byte) {
        '"' => out.appendSlice(b.allocator, "\\\"") catch @panic("OOM"),
        '\\' => out.appendSlice(b.allocator, "\\\\") catch @panic("OOM"),
        '\n' => out.appendSlice(b.allocator, "\\n") catch @panic("OOM"),
        else => out.append(b.allocator, byte) catch @panic("OOM"),
    };
    return out.items;
}

/// The home page. Same tokens as the reference shell so the two read as one site.
const hub_html =
    \\<!doctype html>
    \\<html lang="en">
    \\  <head>
    \\    <meta charset="utf-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\    <title>{s} — API references</title>
    \\    <style>
    \\      :root {{
    \\        color-scheme: light dark;
    \\        --bg: #fbfbfd; --bg-raised: #ffffff; --fg: #14161a; --fg-muted: #5b6270;
    \\        --border: #e3e5ea; --accent: #246bfd;
    \\        --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    \\        --mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, monospace;
    \\      }}
    \\      @media (prefers-color-scheme: dark) {{
    \\        :root {{
    \\          --bg: #0e1014; --bg-raised: #15181e; --fg: #e7e9ee; --fg-muted: #99a1b0;
    \\          --border: #262b34; --accent: #6f9bff;
    \\        }}
    \\      }}
    \\      *, *::before, *::after {{ box-sizing: border-box; }}
    \\      body {{
    \\        margin: 0; background: var(--bg); color: var(--fg); font-family: var(--sans);
    \\        font-size: 15px; line-height: 1.6; -webkit-font-smoothing: antialiased;
    \\      }}
    \\      main {{ max-width: 44rem; margin: 0 auto; padding: 4rem 1.5rem 6rem; }}
    \\      h1 {{ margin: 0 0 0.4rem; font-size: 1.6rem; font-weight: 640; letter-spacing: -0.02em; }}
    \\      .lede {{ margin: 0 0 2.5rem; color: var(--fg-muted); }}
    \\      .cards {{ display: grid; gap: 0.75rem; }}
    \\      .card {{
    \\        display: grid; gap: 0.2rem; padding: 1rem 1.2rem; color: inherit; text-decoration: none;
    \\        background: var(--bg-raised); border: 1px solid var(--border); border-radius: 10px;
    \\        transition: border-color .12s;
    \\      }}
    \\      .card:hover {{ border-color: var(--accent); }}
    \\      .name {{ font-family: var(--mono); font-weight: 620; }}
    \\      .description {{ color: var(--fg-muted); font-size: 0.9rem; }}
    \\    </style>
    \\  </head>
    \\  <body>
    \\    <main>
    \\      <h1>{s}</h1>
    \\      <p class="lede">API references, one per package. Each is built from that package's amalgamation, so what is listed is exactly what a consumer can call.</p>
    \\      <div class="cards">
    \\{s}      </div>
    \\    </main>
    \\  </body>
    \\</html>
    \\
;

/// The name the module was registered under, which is also the name the viewer
/// shows and the top-level directory in `sources.tar`.
fn moduleName(b: *std.Build, module: *std.Build.Module) []const u8 {
    var it = b.modules.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == module) return entry.key_ptr.*;
    }
    std.debug.panic(
        "publr_tools: this module was not created with b.addModule, so it has no " ++
            "name to amalgamate it under — pass one as `.name` in the options",
        .{},
    );
}
