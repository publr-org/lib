//! The comptime layer: ties an application together upfront. `Server(...)` takes the
//! extension set as a compile-time struct of extension modules and generates the app
//! type — its `Context` (with one typed field per extension under `ctx.extensions`),
//! its `Router`, and its handler contract `fn (req, res, ctx) !void`. The runtime
//! engine (engine.zig) stays non-generic underneath; this layer reaches into it
//! through the single `on_request` hook, where it builds the context, routes, and
//! serializes the response.
//!
//! ```zig
//! const App = http.Server(.{
//!     .websocket = http.extensions.websocket,
//! });
//!
//! var app = try App.init(gpa, .{ .port = 8080 });
//! defer app.deinit();
//! app.router().get("/stats", &stats);
//! try app.listen();
//!
//! fn stats(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
//!     _ = req;
//!     try res.json(.ok, .{ .requests = ctx.counters.requests_total });
//! }
//! ```
const std = @import("std");
const engine_module = @import("engine.zig");
const connection = @import("connection.zig");
const router_module = @import("http/router.zig");
const request_module = @import("http/request.zig");
const response_module = @import("http/response.zig");
const websocket_module = @import("extensions/websocket.zig");

/// The runtime engine type; extension hook signatures are written against it.
pub const Engine = engine_module.Engine;

/// The in-tree extensions and their engine vtables, keyed by the `State` type the
/// consumer-facing `http.extensions.<name>` namespace re-exports. The consumer
/// passes that namespace; the engine-side plumbing is looked up here rather than
/// read off it, so the namespace carries nothing a handler has no use for.
const registry = .{
    .{ .State = websocket_module.State, .vtable = &websocket_module.extension },
};

fn vtable_for(comptime State: type) *const engine_module.Extension {
    inline for (registry) |entry| {
        if (entry.State == State) return entry.vtable;
    }
    @compileError("not a registered extension: " ++ @typeName(State));
}

/// Generates the app type for a comptime extension set: a struct literal mapping a
/// field name to an entry of `http.extensions` (`.{ .websocket =
/// http.extensions.websocket }`, or `.{}` for none). The field name is what the
/// handler sees the extension's state under — `ctx.extensions.websocket` — and the
/// engine-side plumbing for each entry is found in this file's registry.
///
/// The type it returns is the app: `init` it, register routes on `router()`, and
/// `listen` — or hand all of that to `cli.serve`. `Context` is the third parameter
/// of every handler; `Error` is what starting and serving can fail with.
pub fn Server(comptime extension_modules: anytype) type {
    const mod_fields = std.meta.fields(@TypeOf(extension_modules));

    return struct {
        const App = @This();

        /// One typed pointer per registered extension, named by the field names of
        /// the comptime extension set.
        const Extensions = blk: {
            var field_names: [mod_fields.len][]const u8 = undefined;
            var field_types: [mod_fields.len]type = undefined;

            for (mod_fields, 0..) |field, index| {
                const Module = @field(extension_modules, field.name);
                field_names[index] = field.name;
                field_types[index] = *Module.State;
            }

            const attrs: [mod_fields.len]std.builtin.Type.StructField.Attributes = @splat(.{});
            break :blk @Struct(.auto, null, &field_names, &field_types, &attrs);
        };

        /// The handler context: everything environmental about a request that is not
        /// wire data. Handlers receive it as their third parameter.
        pub const Context = struct {
            /// Per-request scratch allocator, valid until the response has been
            /// serialized. Anything the response references must live at least
            /// that long, so allocate it here — `res.json` already does.
            arena: std.mem.Allocator,
            /// The application state set on `App.user_data`: cast it back to your
            /// type with `@ptrCast(@alignCast(ctx.user_data.?))`.
            user_data: ?*anyopaque,
            /// The server's always-on tallies, live: `ctx.counters.requests_total`.
            /// Serialize the struct as-is for a `/stats` endpoint.
            counters: *const engine_module.Counters,
            /// The options the server was started with — `response_bytes_max` is
            /// the one a handler sizes things against.
            options: *const engine_module.Options,
            /// Typed access to every registered extension, by the name it was
            /// declared under: `ctx.extensions.websocket`.
            extensions: Extensions,
            /// The engine. Only an extension taking over the connection reads it;
            /// a handler has nothing to do with it.
            engine: *Engine,
            /// This connection's slot. Only an extension taking over the connection
            /// reads it; a handler has nothing to do with it.
            slot: *engine_module.Slot,
        };

        /// This app's route table type, generic over its `Context`; the value
        /// lives at `routes` and is reached with `router()`.
        pub const Router = router_module.Router(Context);
        /// The handler signature: `fn (req, res, ctx: *App.Context) anyerror!void`.
        pub const Handler = App.Router.Handler;
        /// The middleware signature: a `Handler` plus a `next` continuation.
        pub const Middleware = App.Router.Middleware;
        /// What `init`, `listen`, and `enable_shutdown_signals` can fail with; see
        /// `engine.Error`.
        pub const Error = engine_module.Error;

        const vtables = blk: {
            var list: [mod_fields.len]*const engine_module.Extension = undefined;

            for (mod_fields, 0..) |field, index| {
                list[index] = vtable_for(@field(extension_modules, field.name).State);
            }

            const frozen = list;
            break :blk frozen;
        };

        /// The runtime underneath. Not for an app to touch: handlers get
        /// `ctx.counters` and `ctx.options`, and the CLI prints the counters.
        engine: Engine,
        /// The route table; register through `router()`.
        routes: App.Router = .{},
        /// Typed pointers to each extension's state, filled by `init` and handed
        /// to every handler as `ctx.extensions`.
        extension_states: Extensions = undefined,
        /// Application state passed to every handler as `ctx.user_data`.
        user_data: ?*anyopaque = null,
        /// Called after every dispatch with the request and the response about
        /// to be written — an access log, a metric — and nothing else: the
        /// response is already final. Handler errors have become the 500 by
        /// then. Null logs nothing.
        on_response: ?OnResponse = null,
        /// The path everything is served under (`/environments/dev`), empty at the root.
        /// It comes off a request's path before routing, so routes and handlers match as at
        /// the root; a request outside it is not this app's (404).
        path_base: []const u8 = "",
        /// Paths answered as they are whether or not they carry `path_base`: what clients
        /// beside the server call on its own port (`/_publr/`), never the public site.
        path_base_exempt: []const u8 = "",

        pub const OnResponse = *const fn (req: *const router_module.Request, res: *const Response) void;

        /// Binds, listens, and preallocates everything the app will ever use,
        /// including the state of every extension in the comptime set. Nothing
        /// is allocated after this call returns.
        ///
        /// The embedded shape — the CLI does the same with flags on top:
        ///
        /// ```zig
        /// var app = try App.init(gpa, .{ .port = 8080 });
        /// defer app.deinit();
        /// app.user_data = &state;
        /// app.router().get("/", &home);
        /// try app.listen();
        /// ```
        ///
        /// Fails with any member of `Error` — `error.AddressInUse` when the port
        /// is taken and `error.FileLimitTooLow` when `connections_max` outruns
        /// the open-file limit are the two worth handling by name. On failure
        /// nothing is left allocated.
        pub fn init(gpa: std.mem.Allocator, options: engine_module.Options) Error!App {
            var app: App = .{
                .engine = try Engine.init(gpa, options, &vtables, &on_request),
            };

            app.engine.stream_hooks = &stream_hooks;

            inline for (mod_fields, 0..) |field, index| {
                @field(app.extension_states, field.name) =
                    @ptrCast(@alignCast(app.engine.registered[index].context));
            }

            return app;
        }

        /// Closes every open connection and the listener, and frees all state.
        pub fn deinit(app: *App) void {
            app.engine.deinit();
            app.* = undefined;
        }

        /// An app with no listener: the caller hands requests in with `handle`
        /// and gets responses back, for a program whose requests arrive some
        /// other way — a browser build fed by JavaScript, an in-process test.
        /// Nothing is allocated and there is nothing to `deinit`; register
        /// routes and set `user_data` exactly as for `init`.
        ///
        /// ```zig
        /// var app = App.offline(.{});
        /// app.user_data = &state;
        /// app.router().get("/posts/:slug", &get_post);
        ///
        /// const parsed = try http.parse("GET /posts/hello HTTP/1.1\r\nHost: h\r\n\r\n");
        /// var req: http.Request = .{ .inner = &parsed.complete, .body = "" };
        /// const response = app.handle(arena, &req);
        /// ```
        ///
        /// Handlers see `ctx.counters` (counting `requests_total`) and
        /// `ctx.options`; there is no connection, so an extension that takes one
        /// over cannot be used — an offline app has an empty extension set
        /// (compile error otherwise).
        pub fn offline(options: engine_module.Options) App {
            comptime if (mod_fields.len != 0) {
                @compileError("an offline app cannot carry extensions: nothing to upgrade");
            };

            var app: App = .{ .engine = undefined };

            app.engine.options = options;
            app.engine.counters = .{};

            return app;
        }

        /// Runs one request through the middleware and the router exactly as
        /// `listen` does, and returns the response, on an app made by `offline`.
        /// The response borrows `arena`, like a handler's would; a handler error
        /// becomes a plain 500, the error name staying on this side.
        ///
        /// ```zig
        /// var req: http.Request = .{ .inner = &head, .body = body };
        /// const response = app.handle(arena, &req);
        /// try std.testing.expectEqual(http.Status.ok, response.status);
        /// ```
        pub fn handle(app: *App, arena: std.mem.Allocator, req: *router_module.Request) Response {
            var response = response_module.init(arena);
            // No connection: a streamed route gets the whole body in one piece, at once.
            var slot: engine_module.Slot = .{ .read_buffer = &.{}, .write_buffer = &.{} };
            var ctx: Context = .{
                .arena = arena,
                .user_data = app.user_data,
                .counters = &app.engine.counters,
                .options = &app.engine.options,
                .extensions = app.extension_states,
                .engine = &app.engine,
                .slot = &slot,
            };

            app.engine.counters.requests_total += 1;

            if (stream_of(app, req)) |stream| {
                stream_whole(app, stream, req, &response, &ctx);
                return response;
            }

            dispatch_into(app, req, &response, &ctx);

            return response;
        }

        /// The streamed route `req` is for, if any, under the base path.
        fn stream_of(app: *App, req: *router_module.Request) ?*const App.Router.Stream {
            if (app.routes.streams_len == 0) {
                return null;
            }

            var stripped: request_module.Request = req.inner.*;

            if (!within_base(app.path_base, req, &stripped)) {
                return null;
            }

            const original = req.inner;
            req.inner = &stripped;
            defer req.inner = original;

            const found = app.routes.resolve_stream(req) orelse return null;

            req.inner = original;

            return found;
        }

        /// An offline streamed request: open, the body in one piece, finish.
        fn stream_whole(
            app: *App,
            stream: *const App.Router.Stream,
            req: *router_module.Request,
            response: *Response,
            ctx: *Context,
        ) void {
            if (req.body.len > stream.bytes_max) {
                response.text(.payload_too_large, "Payload Too Large") catch {};
                return;
            }

            const state = open_stream(app, stream, req, response, ctx) orelse return;

            stream.write(state, req.body) catch {
                stream.abort(state);
                server_error(response, ctx);
                return;
            };
            stream.finish(state, response, ctx) catch {
                server_error(response, ctx);
            };
        }

        /// Runs `open` inside the middleware chain; the stream's state, or null when it
        /// (or a middleware) answered instead.
        fn open_stream(
            app: *App,
            stream: *const App.Router.Stream,
            req: *router_module.Request,
            response: *Response,
            ctx: *Context,
        ) ?*anyopaque {
            ctx.slot.stream = stream;
            ctx.slot.stream_state = null;

            var stripped: request_module.Request = req.inner.*;
            _ = within_base(app.path_base, req, &stripped);
            const original = req.inner;
            req.inner = &stripped;
            defer req.inner = original;

            const next: App.Router.Next = .{ .router = &app.routes, .index = 0, .handler = &open_handler };

            next.run(req, response, ctx) catch |err| {
                std.log.scoped(.publr_http).debug("stream open error: {s} -> {t}", .{ req.inner.path, err });
                if (ctx.slot.stream_state) |state| stream.abort(state);
                ctx.slot.stream_state = null;
                server_error(response, ctx);
            };

            return ctx.slot.stream_state;
        }

        fn open_handler(req: *router_module.Request, res: *Response, ctx: *Context) anyerror!void {
            const stream: *const App.Router.Stream = @ptrCast(@alignCast(ctx.slot.stream.?));

            ctx.slot.stream_state = try stream.open(req, res, ctx);
        }

        fn server_error(response: *Response, ctx: *Context) void {
            response.* = response_module.init(ctx.arena);
            response.text(.internal_server_error, "Internal Server Error") catch {
                response.body = "";
                response.status = .internal_server_error;
            };
        }

        const stream_hooks: engine_module.StreamHooks = .{
            .head = &stream_head,
            .data = &stream_data,
            .end = &stream_end,
            .abort = &stream_abort,
        };

        fn context_for(engine: *Engine, slot: *engine_module.Slot, arena: std.mem.Allocator) Context {
            const app: *App = @fieldParentPtr("engine", engine);

            return .{
                .arena = arena,
                .user_data = app.user_data,
                .counters = &engine.counters,
                .options = &engine.options,
                .extensions = app.extension_states,
                .engine = engine,
                .slot = slot,
            };
        }

        fn stream_head(
            engine: *Engine,
            slot: *engine_module.Slot,
            request: *const request_module.Request,
        ) engine_module.HeadAnswer {
            const app: *App = @fieldParentPtr("engine", engine);
            var req: router_module.Request = .{ .inner = request, .body = "" };
            const stream = stream_of(app, &req) orelse return .none;
            var arena_state = std.heap.FixedBufferAllocator.init(engine.arena_buffer);
            const arena = arena_state.allocator();
            var response = response_module.init(arena);
            var ctx = context_for(engine, slot, arena);

            if (request.content_length > stream.bytes_max) {
                connection.respond_error(engine, slot, .payload_too_large);
                return .answered;
            }

            if (open_stream(app, stream, &req, &response, &ctx) != null) {
                return .streaming;
            }

            if (app.on_response) |on_response| on_response(&req, &response);
            send(engine, slot, &response, false, slot.read_len);

            return .answered;
        }

        fn stream_data(engine: *Engine, slot: *engine_module.Slot, bytes: []const u8) bool {
            _ = engine;
            const stream: *const App.Router.Stream = @ptrCast(@alignCast(slot.stream.?));
            const state = slot.stream_state.?;

            stream.write(state, bytes) catch |err| {
                std.log.scoped(.publr_http).debug("stream write error: {t}", .{err});
                stream.abort(state);
                slot.stream_state = null;
                return false;
            };

            return true;
        }

        fn stream_end(engine: *Engine, slot: *engine_module.Slot) void {
            const stream: *const App.Router.Stream = @ptrCast(@alignCast(slot.stream.?));
            const state = slot.stream_state.?;
            var arena_state = std.heap.FixedBufferAllocator.init(engine.arena_buffer);
            const arena = arena_state.allocator();
            var response = response_module.init(arena);
            var ctx = context_for(engine, slot, arena);

            slot.stream_state = null;
            stream.finish(state, &response, &ctx) catch |err| {
                std.log.scoped(.publr_http).debug("stream finish error: {t}", .{err});
                server_error(&response, &ctx);
            };

            const draining = engine.phase != .running;
            const worn_out = slot.served >= engine_module.requests_per_connection_max;

            slot.state = .reading;
            send(engine, slot, &response, slot.keep_alive and !draining and !worn_out, 0);
        }

        fn stream_abort(engine: *Engine, slot: *engine_module.Slot) void {
            _ = engine;
            const stream: *const App.Router.Stream = @ptrCast(@alignCast(slot.stream.?));

            if (slot.stream_state) |state| stream.abort(state);
            slot.stream_state = null;
        }

        /// Serializes and starts writing a response the slot answers with.
        fn send(
            engine: *Engine,
            slot: *engine_module.Slot,
            response: *Response,
            keep_alive: bool,
            consumed: u32,
        ) void {
            response.keep_alive = keep_alive;

            var writer: std.Io.Writer = .fixed(slot.write_buffer);
            response_module.write_to(response, &writer, false) catch {
                connection.respond_error(engine, slot, .internal_server_error);
                return;
            };

            connection.start_writing(engine, slot, @intCast(writer.buffered().len), keep_alive, consumed);
        }

        /// The port actually bound — the answer when `Options.port` was 0 and the
        /// kernel picked one, and what to print in a startup line.
        ///
        /// ```zig
        /// std.debug.print("listening on http://127.0.0.1:{d}\n", .{try app.bound_port()});
        /// ```
        pub fn bound_port(app: *const App) Error!u16 {
            return app.engine.bound_port();
        }

        /// The route table, to register on before serving. Routes match in
        /// registration order, by method and pattern, and the first match wins;
        /// HEAD is served by the GET route; an unmatched request gets
        /// `Router.not_found`, a plain 404 unless replaced.
        ///
        /// Patterns are `/`-separated: a literal segment matches itself, `:name`
        /// captures one non-empty segment (read it with `req.param("name")`),
        /// and a trailing `*` matches the rest of the path:
        ///
        /// ```zig
        /// fn setup(app: *App) !void {
        ///     var router = app.router();
        ///     router.get("/", &home);
        ///     router.get("/posts/:slug", &get_post);
        ///     router.post("/posts", &create_post);
        ///     router.delete("/posts/:slug", &delete_post);
        ///     router.get("/assets/*", &serve_assets);
        ///     router.not_found = &custom_404;
        /// }
        /// ```
        ///
        /// Middleware registered with `use` wraps every dispatch in registration
        /// order — including dispatches that end at `not_found` — and
        /// short-circuits by not calling `next`:
        ///
        /// ```zig
        /// fn require_token(req: *http.Request, res: *http.Response, ctx: *App.Context, next: App.Router.Next) !void {
        ///     if (req.header("authorization") == null) {
        ///         return res.text(.unauthorized, "token required");
        ///     }
        ///     try next.run(req, res, ctx);
        /// }
        ///
        /// router.use(&require_token);
        /// ```
        ///
        /// Patterns are stored by reference and must outlive the app — string
        /// literals always do. Registration is not synchronized against a
        /// running `listen`; do it all in `setup` (or before `listen`).
        pub fn router(app: *App) *App.Router {
            return &app.routes;
        }

        /// Serves until stopped. Blocks; graceful shutdown comes from a signal
        /// (`enable_shutdown_signals`), then the drain, then the drain deadline.
        pub fn listen(app: *App) Error!void {
            return app.engine.listen();
        }

        /// Begins graceful shutdown: stop accepting, close idle connections, drain
        /// in-flight responses until done or the shutdown timeout.
        fn stop(app: *App) void {
            app.engine.stop();
        }

        /// Routes SIGINT/SIGTERM (Ctrl-C on Windows) into graceful shutdown. A second
        /// signal during the drain stops immediately.
        pub fn enable_shutdown_signals(app: *App) Error!void {
            return app.engine.enable_shutdown_signals();
        }

        fn on_request(
            engine: *Engine,
            slot: *engine_module.Slot,
            request: *const request_module.Request,
        ) void {
            const app: *App = @fieldParentPtr("engine", engine);

            var arena_state = std.heap.FixedBufferAllocator.init(engine.arena_buffer);
            const arena = arena_state.allocator();
            var response = response_module.init(arena);
            var req: router_module.Request = .{
                .inner = request,
                .body = slot.read_buffer[request.head_len..][0..@intCast(request.content_length)],
            };
            var ctx: Context = .{
                .arena = arena,
                .user_data = app.user_data,
                .counters = &engine.counters,
                .options = &engine.options,
                .extensions = app.extension_states,
                .engine = engine,
                .slot = slot,
            };

            dispatch_into(app, &req, &response, &ctx);

            // An extension took over inside the handler and already queued its own
            // response; the HTTP response object is abandoned.
            if (slot.state != .reading) {
                return;
            }

            const draining = engine.phase != .running;
            const worn_out = slot.served >= engine_module.requests_per_connection_max;
            response.keep_alive = request.keep_alive and !draining and !worn_out;

            var writer: std.Io.Writer = .fixed(slot.write_buffer);
            response_module.write_to(&response, &writer, request.method == .head) catch {
                connection.respond_error(engine, slot, .internal_server_error);
                return;
            };

            const consumed: u32 = request.head_len + @as(u32, @intCast(request.content_length));
            connection.start_writing(
                engine,
                slot,
                @intCast(writer.buffered().len),
                response.keep_alive,
                consumed,
            );
        }

        fn dispatch_into(
            app: *App,
            req: *router_module.Request,
            response: *Response,
            ctx: *Context,
        ) void {
            // Lives through the dispatch, the only time the request is read.
            var stripped: request_module.Request = req.inner.*;

            const exempt = app.path_base_exempt.len > 0 and
                std.mem.startsWith(u8, req.inner.path, app.path_base_exempt);

            if (!exempt and !within_base(app.path_base, req, &stripped)) {
                response.text(.not_found, "Not Found") catch {
                    response.body = "";
                    response.status = .not_found;
                };
                if (app.on_response) |on_response| on_response(req, response);
                return;
            }

            router_module.dispatch(&app.routes, req, response, ctx) catch |err| {
                // The error name stays server-side: internal names (OutOfMemory,
                // app-specific errors) are reconnaissance material on the wire.
                std.log.scoped(.publr_http).debug(
                    "handler error: {s} {s} -> {t}",
                    .{ @tagName(req.inner.method), req.inner.path, err },
                );

                response.* = response_module.init(ctx.arena);
                response.text(.internal_server_error, "Internal Server Error") catch {
                    response.body = "";
                    response.status = .internal_server_error;
                };
            };

            if (app.on_response) |on_response| on_response(req, response);
        }
    };
}

/// Whether the request is under `base`, its path then taken off: `/environments/dev/admin`
/// is `/admin`, `/environments/dev` is `/`. Always at the root.
fn within_base(
    base: []const u8,
    req: *router_module.Request,
    stripped: *request_module.Request,
) bool {
    if (base.len == 0) return true;

    const path = req.inner.path;

    if (!std.mem.startsWith(u8, path, base)) return false;

    const rest = path[base.len..];

    if (rest.len != 0 and rest[0] != '/') return false;

    stripped.path = if (rest.len == 0) "/" else rest;
    req.inner = stripped;
    return true;
}

const harness = @import("testing.zig");

const TestApp = Server(.{});
const Request = router_module.Request;
const Response = response_module.Response;
const Status = @import("http/status.zig").Status;

const testing_routes = struct {
    fn hello(req: *Request, res: *Response, ctx: *TestApp.Context) anyerror!void {
        const name = req.param("name") orelse "world";
        const body = try std.fmt.allocPrint(ctx.arena, "hello {s}", .{name});
        try res.text(.ok, body);
    }

    fn echo(req: *Request, res: *Response, ctx: *TestApp.Context) anyerror!void {
        _ = ctx;
        try res.text(.ok, req.body);
    }

    fn boom(req: *Request, res: *Response, ctx: *TestApp.Context) anyerror!void {
        _ = req;
        _ = res;
        _ = ctx;
        return error.Boom;
    }
};

fn test_app(connections_max: u32) !TestApp {
    var app = try TestApp.init(std.testing.allocator, harness.options(connections_max));

    app.router().get("/:name", &testing_routes.hello);
    app.router().post("/echo", &testing_routes.echo);

    return app;
}

test "an offline app routes, fills the context, and turns handler errors into 500s" {
    var app = TestApp.offline(.{});
    app.router().get("/boom", &testing_routes.boom);
    app.router().get("/:name", &testing_routes.hello);
    app.router().post("/echo", &testing_routes.echo);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hello = try request_module.parse("GET /zig HTTP/1.1\r\nHost: h\r\n\r\n");
    var hello_request: Request = .{ .inner = &hello.complete, .body = "" };
    const greeted = app.handle(arena, &hello_request);
    try std.testing.expectEqual(Status.ok, greeted.status);
    try std.testing.expectEqualStrings("hello zig", greeted.body);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", greeted.header("Content-Type").?);

    const echo = try request_module.parse("POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n");
    var echo_request: Request = .{ .inner = &echo.complete, .body = "abc" };
    try std.testing.expectEqualStrings("abc", app.handle(arena, &echo_request).body);

    const boom = try request_module.parse("GET /boom HTTP/1.1\r\nHost: h\r\n\r\n");
    var boom_request: Request = .{ .inner = &boom.complete, .body = "" };
    const failed = app.handle(arena, &boom_request);
    try std.testing.expectEqual(Status.internal_server_error, failed.status);
    try std.testing.expectEqualStrings("Internal Server Error", failed.body);

    try std.testing.expectEqual(@as(u64, 3), app.engine.counters.requests_total);
}

const response_log = struct {
    var lines: std.ArrayList(u8) = .empty;

    fn record(req: *const Request, res: *const Response) void {
        lines.print(std.testing.allocator, "{t} {s} {d}\n", .{ req.method(), req.path(), @intFromEnum(res.status) }) catch {};
    }
};

test "on_response sees every dispatched request with its final response, the 500 included" {
    var app = TestApp.offline(.{});
    app.router().get("/boom", &testing_routes.boom);
    app.router().get("/:name", &testing_routes.hello);
    app.on_response = &response_log.record;
    defer response_log.lines.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hello = try request_module.parse("GET /zig HTTP/1.1\r\nHost: h\r\n\r\n");
    var hello_request: Request = .{ .inner = &hello.complete, .body = "" };
    _ = app.handle(arena, &hello_request);
    const boom = try request_module.parse("GET /boom HTTP/1.1\r\nHost: h\r\n\r\n");
    var boom_request: Request = .{ .inner = &boom.complete, .body = "" };
    _ = app.handle(arena, &boom_request);

    try std.testing.expectEqualStrings("get /zig 200\nget /boom 500\n", response_log.lines.items);
}

test "under a base path, routes match without it, and nothing outside it is served" {
    var app = TestApp.offline(.{});
    app.router().get("/:name", &testing_routes.hello);
    app.path_base = "/environments/dev";
    app.on_response = &response_log.record;
    response_log.lines = .empty;
    defer {
        response_log.lines.deinit(std.testing.allocator);
        response_log.lines = .empty;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    app.path_base_exempt = "/_internal";

    for ([_][]const u8{
        "GET /environments/dev/zig HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /zig HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /environments/devx/zig HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET /_internal HTTP/1.1\r\nHost: h\r\n\r\n",
    }) |raw| {
        var parsed = try request_module.parse(raw);
        var request: Request = .{ .inner = &parsed.complete, .body = "" };
        _ = app.handle(arena, &request);
    }

    try std.testing.expectEqualStrings(
        "get /zig 200\nget /zig 404\nget /environments/devx/zig 404\nget /_internal 200\n",
        response_log.lines.items,
    );
}

test "serves pipelined keep-alive requests and echoes bodies" {
    var app = try test_app(4);
    defer app.deinit();

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "GET /zig HTTP/1.1\r\nHost: h\r\n\r\n" ++
            "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc",
    };

    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 50);
    thread.join();

    try std.testing.expect(!client.failed);

    const output = client.response[0..client.response_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Connection: keep-alive") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Connection: close") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "abc"));
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
    try std.testing.expectEqual(@as(u64, 2), app.engine.counters.requests_total);
}

test "pool exhaustion sheds load with a 503 instead of a silent drop" {
    var app = try test_app(1);
    defer app.deinit();

    const port = try app.engine.bound_port();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const holder = try address.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp });
    defer holder.close(std.testing.io);

    var holder_buffer: [64]u8 = undefined;
    var holder_writer = holder.writer(std.testing.io, &holder_buffer);
    try holder_writer.interface.writeAll("GET /x HTTP/1.1\r\n");
    try holder_writer.interface.flush();
    try harness.serve_until(&app, 10);
    try std.testing.expectEqual(@as(u32, 1), app.engine.active());

    var refused: harness.Client = .{
        .port = port,
        .request = "GET /y HTTP/1.1\r\nHost: h\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&refused});

    harness.sleep_ms(50);
    try harness.serve_until(&app, 50);
    thread.join();

    const output = refused.response[0..refused.response_len];
    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 503"));
    try std.testing.expectEqual(@as(u64, 1), app.engine.counters.refused_total);
}

test "malformed request gets a 400-class response and the connection closes" {
    var app = try test_app(2);
    defer app.deinit();

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "BREW / HTTP/1.1\r\nHost: h\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 50);
    thread.join();

    const output = client.response[0..client.response_len];
    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 501 Not Implemented"));
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "a deep pipeline is served fairly across ticks via the pending list" {
    var app = try test_app(2);
    defer app.deinit();

    const single = "GET /p HTTP/1.1\r\nHost: h\r\n\r\n";
    const depth = 40;

    std.debug.assert(depth > engine_module.pipeline_batch);

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = single ** (depth - 1) ++
            "GET /p HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
        .response = undefined,
    };

    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 100);
    thread.join();

    try std.testing.expect(!client.failed);
    try std.testing.expectEqual(@as(u64, depth), app.engine.counters.requests_total);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "a second pipeline wave arriving while a slot is pending is served in full" {
    var app = try test_app(2);
    defer app.deinit();

    const single = "GET /p HTTP/1.1\r\nHost: h\r\n\r\n";
    const wave = 40;

    std.debug.assert(wave > engine_module.pipeline_batch);

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = single ** wave,
        .request_second = single ** (wave - 1) ++
            "GET /p HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
    };

    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 100);
    thread.join();

    try std.testing.expect(!client.failed);
    try std.testing.expectEqual(@as(u64, 2 * wave), app.engine.counters.requests_total);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
    try std.testing.expectEqual(@as(u32, 0), app.engine.pending_total);
}

test "a handler error becomes a 500 carrying the error name" {
    var app = try TestApp.init(std.testing.allocator, harness.options(2));
    defer app.deinit();

    app.router().get("/boom", &testing_routes.boom);

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "GET /boom HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 50);
    thread.join();

    const output = client.response[0..client.response_len];
    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 500 Internal Server Error"));
    // The internal error name must never reach the wire — generic body only.
    try std.testing.expect(std.mem.indexOf(u8, output, "Boom") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\n\r\nInternal Server Error") != null);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "HEAD reaches the GET route with the body suppressed" {
    var app = try test_app(2);
    defer app.deinit();

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "HEAD /zig HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 50);
    thread.join();

    const output = client.response[0..client.response_len];
    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, output, "Content-Length: 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello zig") == null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\r\n\r\n"));
}

test "a declared body larger than the read buffer is refused with 413" {
    var app = try test_app(2);
    defer app.deinit();

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 20000\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 50);
    thread.join();

    const output = client.response[0..client.response_len];
    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 413"));
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "an idle connection is closed once the idle timeout expires" {
    var options = harness.options(2);
    options.idle_timeout_ms = 1000;

    var app = try TestApp.init(std.testing.allocator, options);
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", try app.engine.bound_port());
    const idler = try address.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp });
    defer idler.close(std.testing.io);

    try harness.serve_until(&app, 10);
    try std.testing.expectEqual(@as(u32, 1), app.engine.active());

    var ticks: u32 = 0;

    while (ticks < 200 and app.engine.counters.timed_out_total == 0) : (ticks += 1) {
        try app.engine.tick(20);
    }

    try std.testing.expectEqual(@as(u64, 1), app.engine.counters.timed_out_total);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "graceful shutdown drains and stops" {
    var app = try test_app(2);
    defer app.deinit();

    try std.testing.expectEqual(engine_module.Phase.running, app.engine.phase);

    app.stop();

    try std.testing.expectEqual(engine_module.Phase.draining, app.engine.phase);
    try harness.serve_until(&app, 5);
    try std.testing.expectEqual(engine_module.Phase.stopped, app.engine.phase);
}

const tally_stream = struct {
    const Tally = struct {
        opened: u32 = 0,
        bytes: u64 = 0,
        sum: u64 = 0,
        finished: u32 = 0,
        aborted: u32 = 0,
    };

    fn open(req: *Request, res: *Response, ctx: *TestApp.Context) anyerror!?*anyopaque {
        if (req.header("x-refuse") != null) {
            try res.text(.forbidden, "refused");
            return null;
        }

        const tally: *Tally = @ptrCast(@alignCast(ctx.user_data.?));
        tally.opened += 1;
        return tally;
    }

    fn write(state: *anyopaque, bytes: []const u8) anyerror!void {
        const tally: *Tally = @ptrCast(@alignCast(state));
        tally.bytes += bytes.len;
        for (bytes) |byte| tally.sum += byte;
    }

    fn finish(state: *anyopaque, res: *Response, ctx: *TestApp.Context) anyerror!void {
        const tally: *Tally = @ptrCast(@alignCast(state));
        tally.finished += 1;
        try res.text(.created, try std.fmt.allocPrint(ctx.arena, "got {d}", .{tally.bytes}));
    }

    fn abort(state: *anyopaque) void {
        const tally: *Tally = @ptrCast(@alignCast(state));
        tally.aborted += 1;
    }

    const handlers: TestApp.Router.Stream = .{
        .bytes_max = 1 << 20,
        .open = &open,
        .write = &write,
        .finish = &finish,
        .abort = &abort,
    };
};

test "a streamed route takes a body far larger than the read buffer, piece by piece" {
    var app = try test_app(4);
    defer app.deinit();

    var tally: tally_stream.Tally = .{};
    app.user_data = &tally;
    app.router().stream(.post, "/upload", &tally_stream.handlers);

    const body_len: u32 = 200 << 10;
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, index| byte.* = @intCast(index % 251);

    const head = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /upload HTTP/1.1\r\nHost: h\r\nContent-Length: {d}\r\n\r\n",
        .{body_len},
    );
    defer std.testing.allocator.free(head);
    const request = try std.mem.concat(std.testing.allocator, u8, &.{
        head, body, "GET /after HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
    });
    defer std.testing.allocator.free(request);

    var client: harness.Client = .{ .port = try app.engine.bound_port(), .request = request };
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 200);
    thread.join();

    var sum: u64 = 0;
    for (body) |byte| sum += byte;

    const output = client.response[0..client.response_len];
    try std.testing.expect(!client.failed);
    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP/1.1 201 Created") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "got 204800") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "hello after"));
    try std.testing.expectEqual(@as(u64, body_len), tally.bytes);
    try std.testing.expectEqual(sum, tally.sum);
    try std.testing.expectEqual(@as(u32, 1), tally.finished);
    try std.testing.expectEqual(@as(u32, 0), tally.aborted);
}

test "a streamed route refuses in open, and past its size, without reading the body" {
    var app = try test_app(4);
    defer app.deinit();

    var tally: tally_stream.Tally = .{};
    app.user_data = &tally;
    app.router().stream(.post, "/upload", &tally_stream.handlers);

    var refused: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "POST /upload HTTP/1.1\r\nHost: h\r\nX-Refuse: 1\r\nContent-Length: 5\r\n\r\nhello",
    };
    const first = try std.Thread.spawn(.{}, harness.Client.run, .{&refused});
    try harness.serve_until(&app, 50);
    first.join();

    try std.testing.expect(std.mem.indexOf(u8, refused.response[0..refused.response_len], "403") != null);

    var large: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "POST /upload HTTP/1.1\r\nHost: h\r\nContent-Length: 99999999\r\n\r\n",
    };
    const second = try std.Thread.spawn(.{}, harness.Client.run, .{&large});
    try harness.serve_until(&app, 50);
    second.join();

    try std.testing.expect(std.mem.indexOf(u8, large.response[0..large.response_len], "413") != null);
    try std.testing.expectEqual(@as(u32, 0), tally.opened);
    try std.testing.expectEqual(@as(u64, 0), tally.bytes);
}

test "a stream cut off before its body ends is aborted" {
    var app = try test_app(4);
    defer app.deinit();

    var tally: tally_stream.Tally = .{};
    app.user_data = &tally;
    app.router().stream(.post, "/upload", &tally_stream.handlers);

    var client: harness.Client = .{
        .port = try app.engine.bound_port(),
        .request = "POST /upload HTTP/1.1\r\nHost: h\r\nContent-Length: 50000\r\n\r\nonly this",
    };
    // The client stops writing and waits; the request's deadline closes the slot, or the
    // client giving up does. Either way the stream never finishes.
    app.engine.options.request_timeout_ms = 1000;
    const thread = try std.Thread.spawn(.{}, harness.Client.run, .{&client});
    try harness.serve_until(&app, 120);
    thread.join();

    try std.testing.expectEqual(@as(u32, 1), tally.opened);
    try std.testing.expectEqual(@as(u32, 1), tally.aborted);
    try std.testing.expectEqual(@as(u32, 0), tally.finished);
}

test "an offline app streams a body in one piece" {
    var app = TestApp.offline(.{});
    var tally: tally_stream.Tally = .{};
    app.user_data = &tally;
    app.router().stream(.post, "/upload", &tally_stream.handlers);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const head = try request_module.parse("POST /upload HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n");
    var request: Request = .{ .inner = &head.complete, .body = "abc" };
    const answered = app.handle(arena_state.allocator(), &request);

    try std.testing.expectEqual(Status.created, answered.status);
    try std.testing.expectEqualStrings("got 3", answered.body);
    try std.testing.expectEqual(@as(u32, 1), tally.finished);
}
