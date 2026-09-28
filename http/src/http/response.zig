//! The response a handler fills and the writer that serializes it. The writer owns all
//! framing headers (Content-Length, Connection, Transfer-Encoding): handlers cannot set
//! them, so a response can never desynchronize the connection. Header names and values
//! are validated at set time so handler-supplied bytes cannot inject headers or split
//! responses on the wire.
const std = @import("std");
const status_module = @import("status.zig");
const Status = status_module.Status;

/// Most headers one response can carry (framing headers not included).
pub const headers_max: u32 = 32;
/// Longest settable header name.
pub const header_name_len_max: u32 = 128;
/// Longest settable header value.
pub const header_value_len_max: u32 = 8 << 10;
/// Largest settable body. The effective limit is usually the server's per-slot write
/// buffer (`Options.response_bytes_max`), enforced at serialization time.
pub const body_bytes_max: u32 = 8 << 20;

/// One response header, both halves borrowed from whoever set them.
pub const Header = struct {
    /// The name as given to `set_header`; already validated as a token.
    name: []const u8,
    /// The value as given; already validated as wire-safe.
    value: []const u8,
};

/// The response under construction. Slices assigned to it (body, header names and
/// values) are borrowed until serialization: allocate anything computed per request
/// from the request's arena.
pub const Response = struct {
    /// What filling or serializing a response can fail with — the error set of
    /// every setter below, and so the natural error set of a helper that only
    /// builds responses. From a handler any of these propagates as a 500; none
    /// of them is a client's fault.
    ///
    /// ```zig
    /// fn not_found_page(res: *http.Response, arena: std.mem.Allocator) http.Response.Error!void {
    ///     try res.html(.not_found, try render(arena, "No such page"));
    /// }
    /// ```
    pub const Error = error{
        /// `set_header` past `headers_max` distinct names.
        TooManyHeaders,
        /// A header name over `header_name_len_max` or a value over
        /// `header_value_len_max`.
        HeaderTooLarge,
        /// A header name or value with bytes that could split the response (CR, LF,
        /// NUL, non-token characters), an empty name, or a framing header the writer
        /// owns: Content-Length, Connection, Transfer-Encoding.
        InvalidHeader,
        /// A body over `body_bytes_max`. The server's per-slot cap,
        /// `Options.response_bytes_max`, is usually smaller and is checked later, at
        /// serialization.
        BodyTooLarge,
        /// `json` could not allocate the serialized body from the request arena.
        OutOfMemory,
        /// `write_to` ran out of room in the slot's write buffer: the serialized
        /// response is over `Options.response_bytes_max`.
        WriteFailed,
    };

    /// The request's scratch arena, used by `json` for the serialized body. The
    /// same allocator as the handler's `ctx.arena`.
    arena: std.mem.Allocator,
    /// The status line; `.ok` until a body setter or `redirect` sets it.
    status: Status = .ok,
    /// The headers set so far, `headers[0..headers_len]`, in first-set order.
    /// Framing headers are never in here; the writer adds them.
    headers: [headers_max]Header = undefined,
    /// How many of `headers` are live.
    headers_len: u32 = 0,
    /// The body, borrowed; empty until set.
    body: []const u8 = "",
    /// Owned by the connection layer; handlers should not touch it.
    keep_alive: bool = true,

    /// Sets a header, replacing an existing one of the same name (case-insensitive).
    /// A name or value containing wire-unsafe bytes (CR, LF, NUL, ...), an empty
    /// name, or a framing header (Content-Length, Connection, Transfer-Encoding —
    /// the writer owns framing) is rejected with `error.InvalidHeader`. These are
    /// runtime checks, not assertions, because the name may carry attacker input
    /// (a header built from user data would otherwise smuggle framing or inject
    /// headers — in every release mode, not just debug).
    pub fn set_header(response: *Response, name: []const u8, value: []const u8) Error!void {
        std.debug.assert(response.headers_len <= headers_max);

        try check_header(name, value);

        for (response.headers[0..response.headers_len]) |*existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, name)) {
                existing.value = value;
                return;
            }
        }

        try response.append_header(name, value);
    }

    /// Adds a header beside any of the same name: what a second `Set-Cookie` needs, which
    /// cannot share a line with the first. Checked as `set_header` checks.
    pub fn add_header(response: *Response, name: []const u8, value: []const u8) Error!void {
        std.debug.assert(response.headers_len <= headers_max);

        try check_header(name, value);
        try response.append_header(name, value);
    }

    fn append_header(response: *Response, name: []const u8, value: []const u8) Error!void {
        std.debug.assert(name.len > 0);

        if (response.headers_len == headers_max) {
            return error.TooManyHeaders;
        }

        response.headers[response.headers_len] = .{ .name = name, .value = value };
        response.headers_len += 1;
    }

    /// The current value of a set header (case-insensitive), or null — what a
    /// test reads back after driving an offline app.
    ///
    /// ```zig
    /// const response = app.handle(arena, &req);
    /// const cookie = response.header("Set-Cookie").?;
    /// ```
    pub fn header(response: *const Response, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(response.headers_len <= headers_max);

        for (response.headers[0..response.headers_len]) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) {
                return candidate.value;
            }
        }

        return null;
    }

    /// Sets a plain-text body and status.
    pub fn text(response: *Response, status: Status, body: []const u8) Error!void {
        try response.set_body(status, "text/plain; charset=utf-8", body);
    }

    /// Sets an HTML body and status.
    pub fn html(response: *Response, status: Status, body: []const u8) Error!void {
        try response.set_body(status, "text/html; charset=utf-8", body);
    }

    /// Serializes `value` as JSON into the arena and sets it as the body.
    pub fn json(response: *Response, status: Status, value: anytype) Error!void {
        const body = std.json.Stringify.valueAlloc(response.arena, value, .{}) catch
            return error.OutOfMemory;
        try response.set_body(status, "application/json", body);
    }

    /// Sets a 3xx status and the Location header. `location` is validated like any
    /// header value, so attacker-controlled bytes cannot split the response.
    pub fn redirect(response: *Response, status: Status, location: []const u8) Error!void {
        std.debug.assert(status.code() >= 300 and status.code() < 400);
        try response.set_header("Location", location);
        try response.set_body(status, "text/plain; charset=utf-8", "");
    }

    /// Sets status, Content-Type, and body in one step — the primitive under `text`,
    /// `html`, and `json`, for a type they do not cover. The case that comes up is
    /// an asset compiled into the binary, with `static.content_type` naming it.
    ///
    /// In full:
    ///
    /// ```zig
    /// const stylesheet = @embedFile("app.css");
    ///
    /// fn css(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    ///     _ = req;
    ///     _ = ctx;
    ///     try res.set_body(.ok, http.static.content_type("app.css"), stylesheet);
    /// }
    /// ```
    pub fn set_body(
        response: *Response,
        status: Status,
        content_type: []const u8,
        body: []const u8,
    ) Error!void {
        if (body.len > body_bytes_max) {
            return error.BodyTooLarge;
        }

        response.status = status;
        response.body = body;
        try response.set_header("Content-Type", content_type);
    }
};

/// An empty 200 response whose `json` allocates from `arena`. The engine creates
/// one per request; a handler only ever receives it.
pub fn init(arena: std.mem.Allocator) Response {
    return .{ .arena = arena };
}

/// Serializes a response to the wire format: status line, the set headers, then
/// the headers this writer owns (`X-Content-Type-Options: nosniff` on every
/// response, `Content-Length` from the body, `Connection` from `keep_alive`),
/// the blank line, and the body unless `head_only` (a HEAD request keeps the
/// `Content-Length` but sends no body) or the status forbids one (204 and 304
/// go out with `Content-Length: 0`, so a body set on them cannot desynchronize
/// the client). The
/// engine calls this into the slot's write buffer; fails with `error.WriteFailed`
/// if the response does not fit.
pub fn write_to(response: *const Response, writer: *std.Io.Writer, head_only: bool) Response.Error!void {
    std.debug.assert(response.headers_len <= headers_max);
    std.debug.assert(response.body.len <= body_bytes_max);

    const status = response.status;

    writer.print("HTTP/1.1 {d} {s}\r\n", .{ status.code(), status_module.reason(status) }) catch
        return error.WriteFailed;

    for (response.headers[0..response.headers_len]) |entry| {
        writer.print("{s}: {s}\r\n", .{ entry.name, entry.value }) catch
            return error.WriteFailed;
    }

    const bodiless = status == .no_content or status == .not_modified;
    const body = if (bodiless) "" else response.body;

    writer.print("X-Content-Type-Options: nosniff\r\nContent-Length: {d}\r\n", .{body.len}) catch
        return error.WriteFailed;
    writer.print("Connection: {s}\r\n\r\n", .{
        if (response.keep_alive) "keep-alive" else "close",
    }) catch return error.WriteFailed;

    if (!head_only) {
        writer.writeAll(body) catch return error.WriteFailed;
    }
}

fn header_name_valid(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= header_name_len_max);

    for (name) |char| {
        const alnum = std.ascii.isAlphanumeric(char);
        const special = std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", char) != null;

        if (!alnum and !special) {
            return false;
        }
    }

    return true;
}

fn header_value_valid(value: []const u8) bool {
    std.debug.assert(value.len <= header_value_len_max);

    for (value) |char| {
        if (char < ' ' and char != '\t') {
            return false;
        }

        if (char == 0x7f) {
            return false;
        }
    }

    return true;
}

fn check_header(name: []const u8, value: []const u8) Response.Error!void {
    std.debug.assert(header_name_len_max > 0);

    if (name.len == 0 or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding"))
    {
        return error.InvalidHeader;
    }

    if (name.len > header_name_len_max) {
        return error.HeaderTooLarge;
    }

    if (value.len > header_value_len_max) {
        return error.HeaderTooLarge;
    }

    if (!header_name_valid(name) or !header_value_valid(value)) {
        return error.InvalidHeader;
    }
}

test "header injection attempts are rejected at runtime" {
    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());

    try std.testing.expectError(
        error.InvalidHeader,
        response.set_header("X-Evil", "ok\r\nContent-Length: 0"),
    );
    try std.testing.expectError(
        error.InvalidHeader,
        response.set_header("X-Evil", "a\x00b"),
    );
    try std.testing.expectError(
        error.InvalidHeader,
        response.set_header("Bad Name", "value"),
    );
    try std.testing.expectError(
        error.InvalidHeader,
        response.redirect(.see_other, "/x\r\nSet-Cookie: pwn=1"),
    );
    try std.testing.expectEqual(@as(u32, 0), response.headers_len);
}

test "framing headers and empty names are rejected in every build mode" {
    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());

    try std.testing.expectError(
        error.InvalidHeader,
        response.set_header("Content-Length", "0"),
    );
    try std.testing.expectError(
        error.InvalidHeader,
        response.set_header("transfer-ENCODING", "chunked"),
    );
    try std.testing.expectError(
        error.InvalidHeader,
        response.set_header("Connection", "close"),
    );
    try std.testing.expectError(error.InvalidHeader, response.set_header("", "x"));
    try std.testing.expectError(error.InvalidHeader, response.add_header("Connection", "x"));
    try std.testing.expectEqual(@as(u32, 0), response.headers_len);
}

test "add_header keeps both of a repeated name, set_header replaces the first" {
    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());

    try response.set_header("Set-Cookie", "a=1");
    try response.add_header("Set-Cookie", "b=2");
    try std.testing.expectEqual(@as(u32, 2), response.headers_len);
    try std.testing.expectEqualStrings("a=1", response.header("Set-Cookie").?);

    try response.set_header("Set-Cookie", "a=3");
    try std.testing.expectEqual(@as(u32, 2), response.headers_len);
    try std.testing.expectEqualStrings("b=2", response.headers[1].value);
}

test "text response serialises with content-length and keep-alive" {
    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());

    try response.text(.ok, "hello");
    try response.set_header("X-Test", "1");
    try response.set_header("x-test", "2");

    var out_buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try write_to(&response, &out, false);

    const expected = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\nX-Test: 2\r\n" ++
        "X-Content-Type-Options: nosniff\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello";
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "204 and 304 never carry a body, whatever was set" {
    var buffer: [1024]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());
    try response.set_body(.no_content, "text/plain; charset=utf-8", "hello");

    var out_buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try write_to(&response, &out, false);

    const expected = "HTTP/1.1 204 No Content\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "X-Content-Type-Options: nosniff\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "size limits: long names, long values, oversized bodies" {
    var buffer: [64]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());

    const long_name = [_]u8{'a'} ** (header_name_len_max + 1);
    try std.testing.expectError(error.HeaderTooLarge, response.set_header(&long_name, "v"));

    const long_value = try std.testing.allocator.alloc(u8, header_value_len_max + 1);
    defer std.testing.allocator.free(long_value);
    @memset(long_value, 'v');
    try std.testing.expectError(error.HeaderTooLarge, response.set_header("X-Long", long_value));

    const big_body = try std.testing.allocator.alloc(u8, body_bytes_max + 1);
    defer std.testing.allocator.free(big_body);
    try std.testing.expectError(error.BodyTooLarge, response.text(.ok, big_body));

    try std.testing.expectEqual(@as(u32, 0), response.headers_len);
}

test "json, redirect, head-only and limits" {
    var buffer: [4096]u8 = undefined;
    var arena_state = std.heap.FixedBufferAllocator.init(&buffer);
    var response = init(arena_state.allocator());

    try response.json(.created, .{ .id = "e_1", .ok = true });
    try std.testing.expectEqualStrings("{\"id\":\"e_1\",\"ok\":true}", response.body);
    try std.testing.expectEqualStrings("application/json", response.header("content-type").?);

    try response.redirect(.see_other, "/admin");
    try std.testing.expectEqualStrings("/admin", response.header("Location").?);
    try std.testing.expectEqual(Status.see_other, response.status);

    var out_buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    response.keep_alive = false;
    try write_to(&response, &out, true);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "Connection: close\r\n\r\n"));

    var many = init(arena_state.allocator());
    var name_buffer: [8]u8 = undefined;

    for (0..headers_max) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "H{d}", .{index});
        try many.set_header(try arena_state.allocator().dupe(u8, name), "v");
    }

    try std.testing.expectError(error.TooManyHeaders, many.set_header("one-more", "v"));
}
