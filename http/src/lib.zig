//! A fixed-capacity, single-threaded HTTP/1.1 server, composed at compile time.
//! Everything a server can do is declared upfront; nothing is allocated after
//! startup; one instance is one core.
//!
//! ## Compose the app
//!
//! `Server` takes the extension set as a comptime struct and generates the app
//! type — its handler context, its router, its error set. `.{}` is a plain HTTP
//! server; `.websocket` adds WebSocket upgrades on routes that ask for them:
//!
//! ```zig
//! const http = @import("publr_http");
//!
//! const App = http.Server(.{
//!     .websocket = http.extensions.websocket,
//! });
//! ```
//!
//! ## Write handlers
//!
//! Every handler has the same three parameters: the wire data in `req`, the
//! response to fill in `res`, and everything environmental in `ctx` — the app's
//! state, a per-request arena, the server's counters and options, and typed
//! access to each extension. Returning an error sends a generic 500.
//!
//! ```zig
//! fn get_post(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
//!     const slug = req.param("slug").?;
//!     const post = try state_of(ctx).posts.find(slug) orelse
//!         return res.text(.not_found, "no such post");
//!     try res.json(.ok, post);
//! }
//! ```
//!
//! ## Register routes
//!
//! Routes are registered once, before serving, on the app's `Router` — by method,
//! with `:param` captures and a trailing `*` wildcard; middleware wraps every
//! dispatch. `App.router` documents the whole registration surface:
//!
//! ```zig
//! fn setup(app: *App) !void {
//!     var router = app.router();
//!     router.use(&require_token);
//!     router.get("/posts/:slug", &get_post);
//!     router.post("/posts", &create_post);
//!     router.get("/assets/*", &serve_assets);
//! }
//! ```
//!
//! ## Run it
//!
//! As a command-line program, `cli.serve` is the whole `main`: flags, a `.zon`
//! config file, shutdown signals, the startup banner, and exit counters:
//!
//! ```zig
//! pub fn main(init: std.process.Init) u8 {
//!     var state: MyState = .{};
//!     return http.cli.serve(App, init, .{ .setup = &setup, .user_data = &state });
//! }
//! ```
//!
//! Embedded in a program that owns its own lifecycle, drive the app directly:
//! `App.init`, register routes, `listen`. A program whose requests do not come
//! from a socket at all — a browser build fed by JavaScript, an in-process test —
//! makes the app with `App.offline` and hands requests to `App.handle`.
//!
//! ## Then
//!
//! `static.serve_file` serves a folder from any handler; `Form` reads what a
//! browser form posted. `ctx.counters` is the always-on `Counters` struct — serve
//! it as JSON for a `/stats` endpoint, with `process.id` and `process.cpu_micros`
//! alongside. `Status` is the enum every response carries. examples/ holds
//! complete programs for each of these.
const impl_server = @import("server.zig");
const impl_engine = @import("engine.zig");
const impl_router = @import("http/router.zig");
const impl_request = @import("http/request.zig");
const impl_response = @import("http/response.zig");
const impl_status = @import("http/status.zig");
const impl_websocket = @import("extensions/websocket.zig");

/// Generates the app type for a comptime extension set; see the module doc.
pub const Server = impl_server.Server;
/// The configuration `App.init` takes: address, port, capacity, limits, timeouts.
pub const Options = impl_engine.Options;
/// The always-on tallies, read by handlers as `ctx.counters`.
pub const Counters = impl_engine.Counters;
/// The route table type `Server` instantiates for each app — the registration
/// surface reached with `app.router()`.
pub const Router = impl_router.Router;
/// The handler-facing request: method, path, query, headers, captures, body.
pub const Request = impl_router.Request;
/// The parsed wire head behind `Request.inner`. The engine produces it from the
/// socket; an offline app's caller makes one — by hand from whatever carried the
/// request (a browser build's JSON), or from HTTP text with `parse`.
pub const Head = impl_request.Request;
/// Parses one request head from HTTP text, for an offline app: `.complete` holds
/// the `Head`, and the body is whatever follows it.
pub const parse = impl_request.parse;
/// The methods a request can carry, as `req.method()` reports them.
pub const Method = impl_request.Method;
/// The response a handler fills: status, headers, body.
pub const Response = impl_response.Response;
/// The statuses a response can carry.
pub const Status = impl_status.Status;

/// The command-line face: `cli.serve` and its `Config`.
pub const cli = @import("cli.zig");
/// Process introspection for `/stats`-style endpoints: pid and CPU time.
pub const process = @import("process.zig");
/// Static file serving from any handler.
pub const static = @import("static.zig");
/// A urlencoded form body decoded into pairs read by name; also the query-string
/// and percent decoders.
pub const Form = @import("form.zig").Form;

/// The extensions, for the comptime set passed to `Server`:
/// `http.Server(.{ .websocket = http.extensions.websocket })`. Each entry is
/// what a handler sees as `ctx.extensions.<name>` plus the types its callbacks
/// use; `Server` finds the engine-side plumbing for it on its own.
pub const extensions = struct {
    /// WebSocket support, RFC 6455: an ordinary route whose handler calls
    /// `ctx.extensions.websocket.upgrade` and, from then on, the callbacks in
    /// `Handlers` own the connection.
    pub const websocket = struct {
        /// The per-server extension state, `ctx.extensions.websocket`; its one
        /// method is `upgrade`.
        pub const State = impl_websocket.State;
        /// A live connection: send to it, close it, hold it in a `Group`.
        pub const Connection = impl_websocket.Connection;
        /// A fixed-capacity room of connections with broadcast.
        pub const Group = impl_websocket.Group;
        /// The callbacks one `upgrade` installs.
        pub const Handlers = impl_websocket.Handlers;
        /// One delivered message.
        pub const Message = impl_websocket.Message;
        /// Why a send did not happen.
        pub const SendError = impl_websocket.SendError;
        pub const OnOpen = impl_websocket.OnOpen;
        pub const OnMessage = impl_websocket.OnMessage;
        pub const OnClose = impl_websocket.OnClose;
    };
};

test {
    _ = @import("server.zig");
    _ = @import("engine.zig");
    _ = @import("connection.zig");
    _ = @import("http/router.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("http/status.zig");
    _ = @import("platform/event.zig");
    _ = @import("platform/socket.zig");
    _ = @import("cli.zig");
    _ = @import("extensions/websocket.zig");
    _ = @import("process.zig");
    _ = @import("static.zig");
    _ = @import("form.zig");
}
