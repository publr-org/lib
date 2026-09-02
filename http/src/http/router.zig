//! Method + pattern routing with the three-argument handler contract:
//! `fn (req: *Request, res: *Response, ctx: *Context) !void`, where `Context` is the
//! comptime-generated per-app context (see server.zig) carrying application state, the
//! per-request arena, and typed access to registered extensions. Patterns support
//! literal segments, `:param` captures (read back via `req.param`), and a trailing `*`
//! wildcard. Fixed capacity throughout: routes and middleware are registered at
//! startup and never allocated.
//!
//! The capacity limits below are compile-time constants rather than `Options` fields on
//! purpose. They size arrays embedded directly in `Router` and `Params`, which is what
//! makes registration and matching allocation-free; a runtime knob would trade that away
//! to tune numbers no real consumer approaches. Raising one is a one-line edit and a
//! recompile.
//!
//! Middleware wraps every dispatch. It runs in registration order, and short-circuits
//! by not calling `next`:
//!
//! ```zig
//! fn require_token(req: *http.Request, res: *http.Response, ctx: *App.Context, next: App.Router.Next) !void {
//!     if (req.header("authorization") == null) {
//!         return res.text(.unauthorized, "token required");
//!     }
//!     try next.run(req, res, ctx);
//! }
//!
//! app.router().use(&require_token);
//! ```
const std = @import("std");
const request_module = @import("request.zig");
const response_module = @import("response.zig");
const Status = @import("status.zig").Status;

/// The request methods this server routes; see `request.Method`.
pub const Method = request_module.Method;
/// The response a handler fills; see `response.Response`.
pub const Response = response_module.Response;

/// Most routes one router can hold; sizes the route table embedded in `Router`.
/// Registering past it is a programmer error caught by assertion.
pub const routes_max: u32 = 256;
/// Most middleware functions one router can hold.
pub const middleware_max: u32 = 16;
/// Most `:param` captures one matched route can produce; sizes `Params`. A pattern
/// needing more than 8 captures does not match.
pub const params_max: u32 = 8;
/// Most path segments compared before a pattern is declared non-matching.
pub const segments_max: u32 = 32;
/// Longest registerable pattern, asserted at registration time.
pub const pattern_len_max: u32 = 256;

/// The `:param` captures of a matched route, in pattern order.
pub const Params = struct {
    /// The captures, `entries[0..len]`, in the order their `:name` segments
    /// appear in the pattern.
    entries: [params_max]Param = undefined,
    /// How many of `entries` are live.
    len: u32 = 0,

    /// One capture, both halves borrowed.
    pub const Param = struct {
        /// The `:name` from the pattern, without the colon.
        name: []const u8,
        /// The path segment it matched; never empty, not percent-decoded.
        value: []const u8,
    };

    /// Returns the capture named `name`, or null when the pattern has no such param.
    pub fn get(params: *const Params, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(params.len <= params_max);

        for (params.entries[0..params.len]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }

        return null;
    }
};

/// The handler-facing request: pure wire data. Everything environmental — application
/// state, the scratch arena, the serving server, extensions — arrives in the handler's
/// `ctx` parameter instead.
pub const Request = struct {
    /// The parsed wire request; usually read through the accessors below.
    inner: *const request_module.Request,
    /// Captures filled by the matched route's `:param` segments.
    params: Params = .{},
    /// The request body, fully buffered before dispatch. Empty when there is none.
    body: []const u8,

    /// The request method. A handler registered with `get` already knows it; this
    /// is for middleware that sees every request.
    ///
    /// An access log:
    ///
    /// ```zig
    /// fn access_log(req: *http.Request, res: *http.Response, ctx: *App.Context, next: App.Router.Next) !void {
    ///     try next.run(req, res, ctx);
    ///     std.log.info("{t} {s} -> {d}", .{ req.method(), req.path(), res.status.code() });
    /// }
    /// ```
    ///
    /// HEAD requests are dispatched to GET handlers but still report `.head` here.
    pub fn method(req: *const Request) Method {
        return req.inner.method;
    }

    /// The URL path exactly as received, without the query string.
    pub fn path(req: *const Request) []const u8 {
        return req.inner.path;
    }

    /// The raw query string after `?`, or an empty slice.
    pub fn query(req: *const Request) []const u8 {
        return req.inner.query;
    }

    /// First request header with this name (case-insensitive), or null.
    pub fn header(req: *const Request, name: []const u8) ?[]const u8 {
        return req.inner.header(name);
    }

    /// The `:name` capture from the matched pattern, or null.
    pub fn param(req: *const Request, name: []const u8) ?[]const u8 {
        return req.params.get(name);
    }
};

/// The route table type, generic over the app's `Context` — `Server` instantiates
/// one per app as `App.Router`, and `app.router()` hands out the app's instance.
/// Register everything at startup: routes by method with `get`/`post`/…/`add`,
/// middleware with `use`, the 404 by assigning `not_found`. `App.router` documents
/// patterns, matching order, and middleware with examples.
pub fn Router(comptime Context: type) type {
    return struct {
        const Self = @This();

        /// A route handler. A returned error becomes a generic 500 — the error
        /// name is logged server-side, never sent, so internal names stay off
        /// the wire.
        pub const Handler = *const fn (req: *Request, res: *Response, ctx: *Context) anyerror!void;

        /// Middleware wraps dispatch: run code before and after
        /// `next.run(req, res, ctx)`, or skip the call entirely to short-circuit
        /// (auth, rate limiting). Registered with `use`; the chain runs in
        /// registration order around every dispatch, including dispatches that end at
        /// the `not_found` handler.
        pub const Middleware = *const fn (req: *Request, res: *Response, ctx: *Context, next: Next) anyerror!void;

        /// One registered route.
        const Route = struct {
            method: Method,
            pattern: []const u8,
            handler: Handler,
        };

        /// The continuation handed to middleware: `run` invokes the rest of the
        /// chain, ending at the matched handler.
        pub const Next = struct {
            /// The router whose chain is running.
            router: *const Self,
            /// Position in the middleware chain this continuation resumes from.
            index: u32,
            /// The matched route's handler (or `not_found`), reached when the
            /// chain is exhausted.
            handler: Handler,

            /// Runs the rest of the chain: the next middleware if any remain,
            /// otherwise the handler. Returns whatever they return; not calling
            /// it is how middleware short-circuits.
            pub fn run(next: Next, req: *Request, res: *Response, ctx: *Context) anyerror!void {
                std.debug.assert(next.index <= next.router.middleware_len);
                std.debug.assert(next.router.middleware_len <= middleware_max);

                if (next.index == next.router.middleware_len) {
                    return next.handler(req, res, ctx);
                }

                const middleware = next.router.middleware[next.index];
                return middleware(req, res, ctx, .{
                    .router = next.router,
                    .index = next.index + 1,
                    .handler = next.handler,
                });
            }
        };

        /// The route table, `routes[0..routes_len]`, in registration order —
        /// which is match order.
        routes: [routes_max]Route = undefined,
        /// How many routes are registered.
        routes_len: u32 = 0,
        /// The middleware chain, `middleware[0..middleware_len]`, in
        /// registration order — which is run order.
        middleware: [middleware_max]Middleware = undefined,
        /// How many middleware are registered.
        middleware_len: u32 = 0,
        /// Handler for requests no route matches. Replace it to customize the 404.
        not_found: Handler = &default_not_found,

        /// Registers a GET route. GET routes also answer HEAD; see `dispatch`.
        pub fn get(router: *Self, pattern: []const u8, handler: Handler) void {
            router.add(.get, pattern, handler);
        }

        /// Registers a POST route.
        pub fn post(router: *Self, pattern: []const u8, handler: Handler) void {
            router.add(.post, pattern, handler);
        }

        /// Registers a PUT route.
        pub fn put(router: *Self, pattern: []const u8, handler: Handler) void {
            router.add(.put, pattern, handler);
        }

        /// Registers a PATCH route.
        pub fn patch(router: *Self, pattern: []const u8, handler: Handler) void {
            router.add(.patch, pattern, handler);
        }

        /// Registers a DELETE route.
        pub fn delete(router: *Self, pattern: []const u8, handler: Handler) void {
            router.add(.delete, pattern, handler);
        }

        /// Registers an OPTIONS route.
        pub fn options(router: *Self, pattern: []const u8, handler: Handler) void {
            router.add(.options, pattern, handler);
        }

        /// Registers a route for an explicit method. `pattern` must start with '/'
        /// and is stored by reference, so it must outlive the router (string literals
        /// always do).
        fn add(router: *Self, method: Method, pattern: []const u8, handler: Handler) void {
            std.debug.assert(router.routes_len < routes_max);
            std.debug.assert(pattern.len > 0 and pattern.len <= pattern_len_max);
            std.debug.assert(pattern[0] == '/');

            router.routes[router.routes_len] = .{
                .method = method,
                .pattern = pattern,
                .handler = handler,
            };
            router.routes_len += 1;
        }

        /// Appends `middleware` to the chain wrapped around every dispatch.
        pub fn use(router: *Self, middleware: Middleware) void {
            std.debug.assert(router.middleware_len < middleware_max);

            router.middleware[router.middleware_len] = middleware;
            router.middleware_len += 1;
        }

        fn resolve(router: *const Self, req: *Request) ?Handler {
            std.debug.assert(router.routes_len <= routes_max);
            std.debug.assert(req.inner.path.len > 0);

            const method = effective_method(req.inner.method);

            for (router.routes[0..router.routes_len]) |route| {
                if (route.method != method) {
                    continue;
                }

                var params: Params = .{};

                if (match(route.pattern, req.inner.path, &params)) {
                    req.params = params;
                    return route.handler;
                }
            }

            return null;
        }

        fn default_not_found(req: *Request, res: *Response, ctx: *Context) anyerror!void {
            _ = req;
            _ = ctx;
            try res.text(.not_found, "Not Found");
        }
    };
}

/// The engine's entry point for one request: the first matching route in
/// registration order wins, the middleware chain runs around its handler, and an
/// unmatched request gets `not_found`. HEAD resolves against GET routes; the
/// response writer suppresses the body. `router` is a `*const Router(Context)`.
pub fn dispatch(router: anytype, req: *Request, res: *Response, ctx: anytype) anyerror!void {
    const handler = router.resolve(req) orelse router.not_found;
    const next: @TypeOf(router.*).Next = .{ .router = router, .index = 0, .handler = handler };

    return next.run(req, res, ctx);
}

fn effective_method(method: Method) Method {
    return if (method == .head) .get else method;
}

/// Matches `path` against `pattern`, filling `params` with `:param` captures. Segments
/// match literally, `:name` captures any single non-empty segment, and a `*` segment
/// matches the entire rest of the path.
fn match(pattern: []const u8, path: []const u8, params: *Params) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(path.len > 0);

    var pattern_segments = std.mem.splitScalar(u8, pattern[1..], '/');
    var path_segments = std.mem.splitScalar(u8, path[1..], '/');
    var depth: u32 = 0;

    while (pattern_segments.next()) |expected| : (depth += 1) {
        if (depth == segments_max) {
            return false;
        }

        if (std.mem.eql(u8, expected, "*")) {
            return true;
        }

        const actual = path_segments.next() orelse return false;

        if (expected.len > 1 and expected[0] == ':') {
            if (actual.len == 0) {
                return false;
            }
            if (params.len == params_max) {
                return false;
            }

            params.entries[params.len] = .{ .name = expected[1..], .value = actual };
            params.len += 1;
        } else if (!std.mem.eql(u8, expected, actual)) {
            return false;
        }
    }

    return path_segments.next() == null;
}

const TestContext = struct { marker: u32 = 0 };
const TestRouter = Router(TestContext);

const dispatch_test = struct {
    var order: [8]u8 = undefined;
    var order_len: usize = 0;

    fn record(mark: u8) void {
        order[order_len] = mark;
        order_len += 1;
    }

    fn handler_a(req: *Request, res: *Response, ctx: *TestContext) anyerror!void {
        _ = req;
        ctx.marker += 1;
        record('H');
        try res.text(.ok, "a");
    }

    fn param_echo(req: *Request, res: *Response, ctx: *TestContext) anyerror!void {
        _ = ctx;
        try res.text(.ok, req.param("id") orelse "none");
    }

    fn outer(req: *Request, res: *Response, ctx: *TestContext, next: TestRouter.Next) anyerror!void {
        record('1');
        try next.run(req, res, ctx);
        record('2');
    }

    fn inner(req: *Request, res: *Response, ctx: *TestContext, next: TestRouter.Next) anyerror!void {
        record('3');
        try next.run(req, res, ctx);
        record('4');
    }

    fn block(req: *Request, res: *Response, ctx: *TestContext, next: TestRouter.Next) anyerror!void {
        _ = req;
        _ = ctx;
        _ = next;
        record('B');
        try res.text(.forbidden, "no");
    }

    fn custom_404(req: *Request, res: *Response, ctx: *TestContext) anyerror!void {
        _ = req;
        _ = ctx;
        try res.text(.not_found, "custom");
    }
};

fn test_inner_request(method: Method, path_text: []const u8) request_module.Request {
    return .{
        .method = method,
        .path = path_text,
        .query = "",
        .version = .http_1_1,
        .headers = undefined,
        .headers_len = 0,
        .content_length = 0,
        .keep_alive = true,
        .head_len = 0,
    };
}

test "pattern matching: literals, params, wildcard, trailing segments" {
    var params: Params = .{};

    try std.testing.expect(match("/", "/", &params));
    try std.testing.expect(match("/posts", "/posts", &params));
    try std.testing.expect(!match("/posts", "/posts/1", &params));
    try std.testing.expect(match("/posts/:id", "/posts/42", &params));
    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expect(!match("/posts/:id", "/posts/", &params));
    try std.testing.expect(match("/static/*", "/static/css/app.css", &params));
    try std.testing.expect(!match("/a/:x/c", "/a/b/d", &params));
}

test "multiple params are captured in order and misses return null" {
    var params: Params = .{};

    try std.testing.expect(match("/a/:x/b/:y", "/a/1/b/2", &params));
    try std.testing.expectEqualStrings("1", params.get("x").?);
    try std.testing.expectEqualStrings("2", params.get("y").?);
    try std.testing.expect(params.get("z") == null);
}

test "a pattern needing more than params_max captures does not match" {
    var params: Params = .{};

    try std.testing.expect(!match("/:a/:b/:c/:d/:e/:f/:g/:h/:i", "/1/2/3/4/5/6/7/8/9", &params));
}

test "a pattern deeper than segments_max does not match" {
    var params: Params = .{};
    const deep = "/x" ** (segments_max + 1);

    try std.testing.expect(!match(deep, deep, &params));
}

test "dispatch runs middleware around the matched handler in registration order" {
    var router: TestRouter = .{};
    router.use(&dispatch_test.outer);
    router.use(&dispatch_test.inner);
    router.get("/a", &dispatch_test.handler_a);

    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = response_module.init(arena_state.allocator());
    const inner = test_inner_request(.get, "/a");
    var request: Request = .{ .inner = &inner, .body = "" };
    var ctx: TestContext = .{};

    dispatch_test.order_len = 0;
    try dispatch(&router, &request, &response, &ctx);

    try std.testing.expectEqualStrings("13H42", dispatch_test.order[0..dispatch_test.order_len]);
    try std.testing.expectEqualStrings("a", response.body);
    try std.testing.expectEqual(@as(u32, 1), ctx.marker);
}

test "middleware can short-circuit by not calling next" {
    var router: TestRouter = .{};
    router.use(&dispatch_test.block);
    router.get("/a", &dispatch_test.handler_a);

    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = response_module.init(arena_state.allocator());
    const inner = test_inner_request(.get, "/a");
    var request: Request = .{ .inner = &inner, .body = "" };
    var ctx: TestContext = .{};

    dispatch_test.order_len = 0;
    try dispatch(&router, &request, &response, &ctx);

    try std.testing.expectEqualStrings("B", dispatch_test.order[0..dispatch_test.order_len]);
    try std.testing.expectEqual(Status.forbidden, response.status);
    try std.testing.expectEqual(@as(u32, 0), ctx.marker);
}

test "HEAD dispatches to the GET route" {
    var router: TestRouter = .{};
    router.get("/a", &dispatch_test.handler_a);

    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = response_module.init(arena_state.allocator());
    const inner = test_inner_request(.head, "/a");
    var request: Request = .{ .inner = &inner, .body = "" };
    var ctx: TestContext = .{};

    dispatch_test.order_len = 0;
    try dispatch(&router, &request, &response, &ctx);

    try std.testing.expectEqualStrings("a", response.body);
    try std.testing.expectEqual(Status.ok, response.status);
}

test "unmatched requests get the default, replaceable not_found handler" {
    var router: TestRouter = .{};
    router.get("/a", &dispatch_test.handler_a);

    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = response_module.init(arena_state.allocator());
    const inner = test_inner_request(.get, "/missing");
    var request: Request = .{ .inner = &inner, .body = "" };
    var ctx: TestContext = .{};

    try dispatch(&router, &request, &response, &ctx);
    try std.testing.expectEqual(Status.not_found, response.status);
    try std.testing.expectEqualStrings("Not Found", response.body);

    router.not_found = &dispatch_test.custom_404;
    try dispatch(&router, &request, &response, &ctx);
    try std.testing.expectEqualStrings("custom", response.body);
}

test "the first matching route in registration order wins" {
    var router: TestRouter = .{};
    router.get("/x/:id", &dispatch_test.param_echo);
    router.get("/x/static", &dispatch_test.handler_a);

    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = response_module.init(arena_state.allocator());
    const inner = test_inner_request(.get, "/x/static");
    var request: Request = .{ .inner = &inner, .body = "" };
    var ctx: TestContext = .{};

    try dispatch(&router, &request, &response, &ctx);
    try std.testing.expectEqualStrings("static", response.body);
}
