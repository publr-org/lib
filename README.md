# cmsv2

```
lib/        the libraries — each with its own build, tests, amalgamation, and API reference
  http-server/   publr_http
  sqlite/        publr_sqlite
  auth/          publr_auth
demos/      their consumers — showcase pieces, no docs of their own
  mini-cms/        http-server + sqlite: a dynamic CMS, no users
  mini-cms-auth/   the same, signed into with auth: login screen, CSRF-guarded writes, add-user CLI
  mini-cms-auth-pjsx-jit/   the same again, views authored as PJSX (lowered to Zig, no ZSX) and styled by the Publr JIT
  mini-cms-auth-pjsx-jit-theme/   the public site becomes a theme: .publr templates compiled to typed Zig
  full-cms-deps/   static-first: pages built to files, publishes rebuild exactly what the dependency index names
  full-cms-dynamic-islands/   islands: static and dynamic fragments a page fetches, nesting freely
  full-cms-ui/     the admin on design-system-v2 components, reactive() views hydrated by PublrJS
zig-tools/  build-time tooling the libraries share: amalgamation, docs, the docs site
build.zig   the workspace: one documentation site for everything in lib/
```

```bash
zig build docs    # zig-out/docs: a home page, and each library's reference under <name>/
zig build serve   # the same site at http://127.0.0.1:8100, served by publr-http itself
```

`zig build serve -- --port 9000` passes flags through to the server.

Every library under `lib/` documents its amalgamation — the whole library as one
generated file in which `pub` means exactly "a consumer can call this" — so what
the site lists is what a program can name, by construction. To add a library to
the site: give it `build_docs(b, amalgamation, .{})` in its `build.zig`, list it in
`build.zig.zon` here, and add one entry to `libraries` in `build.zig`.

What earns a place under `lib/`: a mechanism whose README's first example can be
written without a single Publr noun (no record, content type, user, operation),
that stands on `std` alone, and whose surface is already frozen by something
outside us — a wire protocol, a C ABI, a crypto primitive. Everything that owns a
noun stays in the application that owns it; a library boundary turns a one-commit
change into two, so it is bought only where the API would not move anyway. The
consumer that proves it is `../../cmsv2`, whose `src/lib/{db,http,auth}.zig` are
the app's faces on the three libraries.
