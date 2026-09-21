# publr_tools

Build-time tooling for any Zig library in this workspace: the amalgamation and
the API reference. It ships nothing into the library it works on.

```zig
const amalgamate = @import("publr_tools").amalgamate;
const build_docs = @import("publr_tools").docs;

pub fn build(b: *std.Build) void {
    const library = b.addModule("publr_sqlite", .{
        .root_source_file = b.path("src/lib.zig"),
        // …
    });

    const amalgamation = amalgamate(b, library, .{});
    build_tests(b, library, amalgamation.module);
    build_docs(b, amalgamation, .{});
}
```

```zon
.dependencies = .{
    .publr_tools = .{ .path = "../tools" },
},
```

Two steps come out of that:

- `zig build amalgamate` writes `zig-out/<name>.zig` — the whole library as one
  file, tests stripped.
- `zig build docs` writes a self-contained, searchable reference into `zig-out/docs`.

There is nothing to configure. The module's name, its tagline and the whole API
index come from the module's own analysis, so this package holds no per-library
state and adding a second library is the same three lines.

## The amalgamation

Zig has one visibility level. In a multi-file library every declaration another
file calls is `pub`, whether or not a consumer should see it — `engine.zig`
reaching into `connection.zig`, a per-OS socket shim, the test harness. Nothing in
the language distinguishes "public to the engine" from "public to the world", so
the source tree cannot say which is which, and a docs generator indexing `pub`
shows all of it.

Inside *one* file, though, sibling containers reach each other's non-`pub`
members freely: `pub` only gates access from other files. So `amalgamate`
regenerates the library as one file — the root's body at the top level, every
other source file inlined as `const <stem>_module = struct { … }` — with `pub`
recomputed to mean exactly "reachable from the root through its `pub` aliases":
an alias to an imported declaration keeps that declaration `pub`; a container
keeps its `pub` members; a type function keeps the `pub` members of the struct it
returns; a bare `@import("x.zig")` re-export keeps every `pub` top-level
declaration of that file. Everything else becomes a plain declaration — a
consumer cannot name it, and the reference does not index it.

Tests do not ship. Every `test` block is removed, and then every declaration
nothing live references is removed too — the harness file, a fuzz helper, `std`
in a file that only tested with it — iterated to a fixpoint from the public
surface.

The file is three things at once:

- **The vendoring artifact.** Copy it into a project that wants the library as
  a file rather than a dependency.
- **What the tests run against.** `amalgamation.module` is a module rooted at the
  generated file, configured like the source module (target, optimize, imports,
  libc, linked objects). A test that passes only in the source tree is a test
  that leans on something the library does not actually expose.
- **What the reference documents.** So what the docs show and what a consumer
  can name are the same set, by construction rather than convention.

### Names

Two Zig rules shape the output, and they put a small obligation on the source.

A name declared in two enclosing container scopes is an "ambiguous reference"
wherever it is used. The root's `pub const Request = …` encloses the namespace
that defines `Request`, so every bare use of `Request` inside that namespace is
rewritten to `router_module.Request`; when the two declarations are the same
import (`const std = @import("std")` at the root and in a file), the nested one
is dropped instead. That handles top-level declarations mechanically. A
declaration inside a *nested* container that shares a root name — `Router`
inside the struct `Server()` returns — cannot be qualified by path, so the tool
reports it and the source refers to it through the container's Self alias
(`App.Router`).

A parameter or local may not shadow an enclosing declaration at all, so no
parameter or local may be named like anything the root exports (`extensions`,
`process`, `static`, …). The tool reports those too, with a location; the fix
is a rename.

Namespaces are `<file>_module`, never the bare stem, for the same reason:
`server`/`engine` are parameter names throughout an engine. The suffix matches
the `const engine_module = @import("engine.zig")` convention, so those aliases
become self-references and are dropped. A file that imports the root gets
`const <name> = @This();` to refer to.

The tool reads every file the root imports, transitively, and declares them all
in a depfile, so the build reruns it when any of them changes.

## What the docs build fixes

`zig build docs` on its own emits the compiler's `main.wasm` and a
`sources.tar`, wrapped in an `index.html` copied verbatim out of the Zig
installation. Three things are wrong with that for a library reference.

**The shell is Zig's.** Zig logo, "Zig Documentation" in the title bar. It is
also pure presentation: `main.js` only ever touches a fixed set of element ids,
so `shell/index.html` replaces it wholesale. On top of the reskin it adds a
persistent API index in the sidebar, puts the declaration's *name* in the page
heading (upstream shows only its category — "struct" on every page), hides the
empty boxes the renderer emits for undocumented fields and error cases, and
rewrites breadcrumbs and search results to the path a consumer writes
(`Response.text`) rather than where the declaration is defined
(`publr_http.response_module.Response.text`).

**The tar carries all of `std`.** The compiler tars up every module the docs
object can reach, so ~525 files of `std` ride along with yours — 99.8% of a
16 MB payload, and the viewer indexes it as a second module, which is why
searching `std` returns the entire standard library. `tools/trim_sources.zig`
rewrites the tar down to the module's own file.

**The module root is chosen by tar order.** The viewer takes a module's *first*
file as its root, overriding that only for the names `root.zig` and
`<module>.zig`. The amalgamation is `<module>.zig`, so this is moot for it; the
trim tool still writes the root first as a belt-and-braces measure.

Because std is no longer indexed but the renderer still linkifies `std.*` paths
it sees in a signature, the shell redirects those anchors to the upstream
reference. The version is stamped into a generated `docs-config.js` from the
toolchain that produced the docs.

## One site for the workspace

`docs` also publishes each library's reference as the named lazy path `"docs"`,
and `hub` assembles any number of those into one site — a home page listing the
libraries, each reference under `<name>/`. The workspace's root `build.zig` is
the whole of it:

```zig
const site = tools.hub(b, .{ .packages = &.{
    .{ .name = "publr_http", .description = "…", .docs = http_server.namedLazyPath("docs") },
    .{ .name = "publr_sqlite", .description = "…", .docs = sqlite.namedLazyPath("docs") },
} });
```

`hub` installs the site on `zig build docs` and returns its directory, so the
workspace serves it straight from the cache with the workspace's own server:
`zig build serve` runs `publr-http --root <site>` on port 8100, with the response
cap raised for the few-hundred-KB `main.wasm` and `sources.tar`.

One constraint this surfaced: `b.dependency` is generic over every package in the
manifest tree, so the runner compiles `build(b)` for all of them — which is why
this package has a no-op `build` and the docs helper is named `docs`.

## Writing doc comments that survive this

**The first paragraph must stand on its own.** Listings show only the text up to
the first blank `///` line, so a paragraph that ends by introducing what follows
("the calling shape is always the same three lines:") renders as a sentence cut
in half.

**Examples go in ` ```zig ` fences, never indented blocks.** The renderer's
markdown strips leading whitespace before looking for block structure and has no
indented-code-block rule at all, so an indented example silently collapses into
a run-on paragraph.

**A function only the engine calls is a free function, not a method.** Methods
of a public type are reachable and so documented; a free function in the file's
namespace is not, unless the root re-exports the namespace. `response.init` and
`response.write_to` are free functions for exactly this reason.

## Options

`amalgamate` takes `name` (defaults to the name the module was registered under
with `b.addModule`), `step_name` (`"amalgamate"`), `step_description`, and
`install_subdir` (`""`, the prefix itself). `docs` takes `step_name`
(`"docs"`), `step_description`, and `install_subdir` (`"docs"`).

A module not created with `b.addModule` has no name to derive; pass one as
`.name`.

## Layout

    build.zig              `amalgamate` and `build`; carries the three files below by @embedFile
    shell/index.html       the replacement viewer shell
    tools/amalgamate.zig   generates the single-file amalgamation
    tools/trim_sources.zig rewrites sources.tar

`amalgamate` and `docs` take the module they work on, which is not the
signature `zig build` calls on a dependency's build script. That is why the
package carries its own files by `@embedFile` rather than reaching for them
through a `std.Build.Dependency`: it is only ever imported, never instantiated
as a dependency, so its functions are free to take what they need.
