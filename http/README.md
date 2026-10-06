# Publr HTTP Server

A high-throughput, memory-efficient HTTP/1.1 server library written in Zig, with no external dependencies.

Great for serving static resources and handling APIs.

Similar API to most of the existing HTTP servers out there.

```zig
const std = @import("std");
const http = @import("publr_http");

const App = http.Server(.{});

pub fn main(init: std.process.Init) !u8 {
    return http.cli.serve(App, init, .{ .setup = &setup });
}

fn setup(app: *App) !void {
    app.router().get("/user/:id", &getUser);
}

fn getUser(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = ctx;
    try res.json(.ok, .{ .id = req.param("id").? });
}
```

## Philosophy

Publr HTTP Server exists for exactly one reason: to power the Publr platform.

That focus is a feature. The server is deliberately configurable only to the extent Publr needs: one options struct, a handful of flags, and everything else derived or fixed as named constants in the source.

That restraint is exactly what keeps it fast, small enough to audit in an afternoon, and simple enough to trust under load.

It's open source and free for anyone to use. At the same time we do not accept any code related contributions. We are open for suggestions. For security related stuff read this section.

If it doesn't fit your needs, it is probably not the right tool for you, and that's by design. Fork it freely, or reach for a general-purpose server.

## Running the standalone server

Serve a folder over HTTP with no code of your own — the `publr-http` binary is the
library's own consumer: one wildcard route serving `--root`:

```bash
zig build
./zig-out/bin/publr-http --root ./public

# or build-and-run in one step:
zig build serve -- --root ./public
```

The bind address is decided at compile time: a debug build (what `zig build` produces)
binds `127.0.0.1` — private to your machine, no firewall prompts — while a release
build (`-Doptimize=ReleaseSafe`, what you deploy or download) binds `0.0.0.0` and is
reachable out of the box. `--address` overrides either way; the startup banner always
prints what was bound.

Directory paths serve their `index.html`; dotfiles, `..`, and backslashes never
resolve (404); URL paths are taken literally (no percent-decoding). A file must fit
`--response-bytes-max` (default 32 KiB) — raise it for larger assets:

```bash
./zig-out/bin/publr-http --root ./public --response-bytes-max 8388608
```

Every server flag applies (`--help` lists them); routes beyond "serve this folder"
are what the library is for.

Example servers showing the library patterns:

```bash
./zig-out/bin/hello    # routes, /health, /stats
./zig-out/bin/ingest   # params, app state
./zig-out/bin/chat     # WebSockets
```

## Using it in your Zig project

Add Publr HTTP server to your `build.zig` to start it with your program:

```zig
// build.zig.zon
.dependencies = .{
    .http_server = .{ .url = "<git url or tarball>", .hash = "..." },
},

// build.zig
const http_server = b.dependency("http_server", .{ .target = target, .optimize = optimize });
exe_module.addImport("publr_http", http_server.module("publr_http"));
```

Compose your app at compile time — the extension set is the complete inventory of
what your server can do — and mount the CLI from your main:

```zig
const std = @import("std");
const http = @import("publr_http");

const App = http.Server(.{
    .websocket = http.extensions.websocket,   // opt-in, per app
});

pub fn main(init: std.process.Init) !u8 {
    var state: MyApp = .{};
    return http.cli.serve(App, init, .{ .setup = &setup, .user_data = &state });
}

fn setup(app: *App) !void {
    var router = app.router();
    router.get("/api/user/:id", &getUser);
    router.get("/ws/room/:id", &joinRoom);
}
```

Handlers get three arguments: `req` is pure wire data (method, path, query, headers,
`:param` captures, body), `res` is the response (`text`/`html`/`json`/`redirect`,
header injection rejected at runtime), and `ctx` carries everything environmental —
your state (`ctx.user_data`), a per-request scratch arena (`ctx.arena`), the server's
options and always-on counters (`ctx.options`, `ctx.counters` — the counters serialize
straight into a response: `res.json(.ok, .{ .stats = ctx.counters.* })`), and one
typed field per declared extension (`ctx.extensions.websocket`). Middleware chains via
`router.use`; patterns support `:param` captures and a trailing `*` wildcard.

An access log is one option: `.on_response = &log` (on `cli.serve`'s config, or
`app.on_response` when embedding) is called after every dispatch with the request
and the final response — the 500 a failing handler became included — and writes
whatever line the app wants. Handlers never know it is there.

Serving files from your own app is one wildcard route calling `http.static.serve_file`
— the same code the standalone binary is built from (see `src/static.zig` for the
contract: safe path resolution, MIME by extension, files capped by the response size).
A browser form's body is read with `http.Form.parse(ctx.arena, req.body)` and then by
name (`form.text("title")`); `http.Form.query_param` does the same for `req.query()`.

Embedding without the CLI (your program owns the lifecycle):

```zig
var app = try App.init(gpa, .{ .port = 8080 });
defer app.deinit();
app.router().get("/", &home);
try app.enable_shutdown_signals();
try app.listen(); // blocks; drains gracefully on SIGINT/SIGTERM
```

A program whose requests do not come from a socket — a browser build fed by
JavaScript, an in-process test — makes the app with `App.offline(.{})` and hands
requests to `App.handle`, which runs the same middleware and router and returns the
`Response`; `http.parse` turns HTTP text into the `Head` a request wraps. The
route table, `user_data` and `ctx` are exactly as under `listen`; only `ctx.engine`
and `ctx.slot` are not real, so an offline app cannot carry extensions.

## Docker: TLS, HTTP/2 and HTTP/3 behind a reverse proxy

The backend speaks HTTP/1.1 only, on purpose: TLS termination and newer protocol
fronts belong to a reverse proxy, which downgrades to plain HTTP/1.1 keep-alive on
localhost — the exact traffic shape this server is fastest at. Two reference images
live in `docker/`, both running the hello server behind a proxy on the same origin:
static files under `/static/` served by the proxy directly, everything else proxied
to the backend.

Caddy (HTTP/1.1, /2, and /3 — note the UDP port for QUIC):

```bash
docker build -f docker/caddy/Dockerfile -t http-server-caddy .
docker run --rm -p 8443:8443/tcp -p 8443:8443/udp http-server-caddy

curl -vk https://localhost:8443/health          # negotiates h2
curl -vk --http3 https://localhost:8443/health  # h3, with an HTTP/3-enabled curl
open https://localhost:8443/static/index.html   # shows which protocol you got
```

nginx (HTTP/1.1 and /2, self-signed cert generated at image build):

```bash
docker build -f docker/nginx/Dockerfile -t http-server-nginx .
docker run --rm -p 8443:8443 http-server-nginx

curl -vk --http2 https://localhost:8443/stats
```

Both certs are self-signed for localhost (hence `-k`); in production, point your real
proxy at the backend the same way: `reverse_proxy 127.0.0.1:8090` and keep the
backend bound to localhost with `--address 127.0.0.1`.

## Benchmarks

Requests per second by machine size, serving process at 95–99% CPU, zero socket
errors (wrk over a private network, ReleaseSafe):

| machine | config | req/s |
|---|---|---|
| $4/mo VPS (1 shared vCPU, 512 MB) | one instance, 2000 connections | **54,935** |
| $109/mo server (4 dedicated vCPU), single core | one instance | **89,420** (p50 2 ms, p99 6.5 ms) |

Across all stress runs, **90+ million requests were served with zero failed requests** — zero refusals under capacity, clean graceful drains, and server counters reconciling with the client exactly. Overload sheds load loudly (a delivered 503 with `Retry-After`), never silently.

Reproduce with the artillery configs in `stress/`, or wrk against
`./zig-out/bin/hello`. Remember that localhost numbers are a ceiling, not a deploy
claim, and that a saturated load generator lies about latency — measure from a second
machine and trust the server-side `/stats` counters.

## Configuration reference

One options struct, three ways in, strict precedence: **defaults < `--config`
.zon file < CLI flags**. The same struct configures an embedded server
(`http.Options`). See `config.example.zon`.

| flag | .zon field | default | valid range |
|---|---|---|---|
| `--address <a.b.c.d>` | `.address` | debug builds: `127.0.0.1`; release builds: `0.0.0.0` | — |
| `--port <n>` | `.port` | `8080` | 0 = ephemeral |
| `--connections <n>` | `.connections_max` | `4096` | 1..65536 |
| `--request-bytes-max <n>` | `.request_bytes_max` | `16384` | 16 KiB..16 MiB; caps one request, head+body |
| `--response-bytes-max <n>` | `.response_bytes_max` | `32768` | 1 KiB..64 MiB; caps one response |
| `--idle-timeout-ms <n>` | `.idle_timeout_ms` | `15000` | 1 s..10 min |
| `--request-timeout-ms <n>` | `.request_timeout_ms` | `30000` | 1 s..10 min |
| `--shutdown-timeout-ms <n>` | `.shutdown_timeout_ms` | `5000` | 1 s..60 s; drain budget after SIGINT/SIGTERM |
| `--config <path>` | — | — | .zon file whose fields mirror this table |
| `--help` | — | — | prints this table's live version |

Memory is sized by these values and reserved once at startup: each connection slot
owns its request and response buffers (~48 KiB per connection at the defaults, ~469
MiB for 10,000 slots), plus one shared per-request arena. Reserved is not resident:
the buffers are taken without being written, so a slot's pages are only committed
once a connection uses them, and an idle server costs its code and state. The startup banner prints
the resolved memory estimate, fd requirement, and the kernel's real backlog cap; the
process raises its own fd limit or fails with an actionable message.

Everything else is derived or deliberately fixed: listen backlog, accept/pipeline
batching, event batch sizes (named constants in `src/engine.zig`), and the API-shape
limits (256 routes, 8 `:params` per pattern, 16 middleware — compile-time constants
in `src/http/router.zig`). Exposing those was judged a way to misconfigure the
server, not to configure it.

## API reference

```bash
zig build docs        # writes zig-out/docs, then serve that folder
```

The doc comments in `src/` are the reference — every public declaration carries
its contract and a usage example. `zig build docs` renders them into a
browsable, searchable site via [`../tools`](../tools), which is shared
with the other libraries here. It documents the amalgamation, not the source
tree: `zig build amalgamate` writes the whole library as one file,
`zig-out/publr_http.zig`, tests stripped, in which `pub` means exactly "you can
call this". What the reference shows and what your program can name are the
same set — see [ARCHITECTURE.md](ARCHITECTURE.md), design rule 8. That file is
also what to vendor when a project wants the library as a file rather than a
dependency.

Two conventions keep those comments readable once rendered. Nothing enforces
them, so they are worth knowing before you write one:

- **The first paragraph must stand on its own.** Listings show only the text up
  to the first blank `///` line, so a paragraph ending in a lead-in ("the
  calling shape is:") renders as a sentence cut in half. Put the lead-in in its
  own paragraph, directly above the example.
- **Examples go in ` ```zig ` fences, never indented blocks.** The renderer's
  markdown strips leading whitespace before looking for block structure, so an
  indented example collapses into a run-on paragraph.

## Known limits (deliberate scope, not oversights)

- HTTP/1.1 only. No TLS (terminate at a proxy — see the Docker section), no chunked
  transfer encoding. WebSockets are an opt-in extension
  (`src/extensions/websocket.zig`), upgraded from an ordinary route handler; no
  message fragmentation and no permessage-deflate in v1.
- A request (head + body) must fit `--request-bytes-max`; a response must fit
  `--response-bytes-max`. The limits are the contract: oversized traffic gets 431/413,
  never a partial read. The one exception is a streamed route
  (`router.stream(.post, "/upload", &handlers)`): its body may be as large as the route
  says, and arrives at the handler a read buffer at a time (`open` with the head, then
  `write` per piece, then `finish` to answer, or `abort` when the connection goes),
  so an upload of any size costs one buffer. A stream's answer is written without
  middleware.
- Single threaded and single process by design, permanently: no locks, no data races,
  and the shared arena plus every state-machine assertion depend on it. One instance
  is one core; everything in it — counters, WebSocket rooms, app state — is globally
  true because nothing is sharded. Scaling past one core means running more instances
  behind your own balancer and treating them as the separate servers they are.
- Server counters are always on: a struct of tallies on the engine, bumped with plain
  integer increments — too cheap to need an off switch, never on the wire unless a
  handler serves them.
- Windows is a development platform, not a deployment target: poll backend, no
  fd-limit raising. Production is POSIX.
- Not WASM: a readiness-based server has no meaning on wasm32-wasi; the library is
  native-only.
- A handler's *error* is caught and answered with a generic 500; a handler's *panic*
  or failed assertion ends the process, as in any Zig program. Nothing is isolated
  per request, so keep handlers to code that returns errors, and let the supervisor
  restart the process.
- No per-client accounting: the engine does not record the peer address, so it cannot
  cap connections per source or log who sent a request. One client can occupy every
  slot. Put a reverse proxy in front that rate-limits and forwards the address.
