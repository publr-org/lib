# lib

The Zig mechanisms Publr is built on. Each one has no Publr noun in it — no
record, content type, user or operation — stands on `std` alone, and has a
surface already fixed by something outside us: a wire protocol, a C ABI, a
crypto primitive. Anything that owns a noun stays in the application.

```
auth/     publr_auth    argon2id hashing, login throttling, CSRF, origin checks
deps/     publr_deps    a dependency index for build artifacts, in your SQLite database
http/     publr_http    a fixed-capacity, single-threaded HTTP/1.1 server, composed at compile time
sqlite/   publr_sqlite  SQLite, vendored and compiled in, one connection, one thread
tools/    publr_tools   build-time tooling the others share: amalgamation, tests, docs
build.zig               one documentation site for every library
```

Each library builds and tests itself:

```bash
cd http
zig build test          # that library's tests
zig build amalgamate    # zig-out/publr_http.zig: the whole library as one file, tests stripped
zig build docs          # zig-out/docs: the reference, rendered from the amalgamation
```

For `auth`, `http` and `sqlite` the amalgamation is the contract: in it, `pub`
means exactly "a consumer can call this", and the tests run against that file
too. It is also what to vendor. `deps` has no amalgamation yet; its contract is
the test matrix in `deps/TESTS.md`.

The workspace build renders one site for all of them:

```bash
zig build docs          # zig-out/docs: a home page, and each library under <name>/
zig build serve         # the same site at http://127.0.0.1:8100, served by publr_http
```

`zig build serve -- --port 9000` passes flags through to the server.

Consumers depend on a library by path (`.path = "../lib/sqlite"`); nothing is
fetched. The CMS in `../publr` is the consumer that proves each one.
