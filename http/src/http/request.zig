//! The HTTP/1.1 request parser: a pure function from bytes to a `Request`, with no
//! I/O and no allocation. The engine calls `parse` on each slot's read buffer as
//! bytes arrive; `.incomplete` means wait for more, an error means answer with
//! `status_for(err)` and close. Handlers never see this type directly — the router
//! wraps it as `http.Request` — but its limits are the wire contract every client
//! lives under.
//!
//! Framing is Content-Length only: a `Transfer-Encoding` header is refused with 501,
//! and a body is accepted only on methods that carry one. HTTP/1.1 requires `Host`;
//! HTTP/1.0 defaults to close unless `Connection: keep-alive` is sent, and
//! `Connection: close` wins over any keep-alive on either version.
const std = @import("std");
const status_module = @import("status.zig");
const Status = status_module.Status;

/// Most bytes a request head (request line plus headers, through the blank line)
/// may occupy. Past it, 431. Also the floor for `Options.request_bytes_max`.
pub const head_bytes_max: u32 = 16 << 10;
/// Longest request line; past it, 414.
pub const request_line_bytes_max: u32 = 8 << 10;
/// Most headers one request may carry; the one past it makes the head 431.
pub const headers_max: u32 = 64;
/// Longest header name; past it, 400.
pub const header_name_len_max: u32 = 256;
/// Longest header value; past it, 431.
pub const header_value_len_max: u32 = 8 << 10;
/// Largest `Content-Length` the parser accepts; past it, 400. The engine applies
/// the much smaller `Options.request_bytes_max` afterwards, with 413.
pub const content_length_max: u64 = 1 << 40;

/// The methods this server recognizes. Anything else on the wire is 501, not 405:
/// the server does not implement it for any route.
pub const Method = enum {
    /// Reads. No body allowed: a GET with `Content-Length` is 400.
    get,
    /// Dispatched to the GET route with the response body suppressed. No body
    /// allowed, as for GET.
    head,
    /// Creates or submits; may carry a body.
    post,
    /// Replaces; may carry a body.
    put,
    /// Partially updates; may carry a body.
    patch,
    /// Removes; may carry a body.
    delete,
    /// May carry a body. Also the one method allowed the asterisk-form target,
    /// `OPTIONS *`.
    options,
};

/// The protocol versions accepted; anything else is 505.
pub const Version = enum {
    /// Closes after one request unless `Connection: keep-alive` was sent.
    http_1_0,
    /// Keep-alive by default; `Host` required.
    http_1_1,
};

/// One request header, both halves borrowed from the read buffer. Names keep the
/// case they arrived in; `Request.header` compares case-insensitively.
pub const Header = struct {
    /// The name as sent, a valid token (no spaces, no separators).
    name: []const u8,
    /// The value with surrounding spaces and tabs trimmed; may be empty.
    value: []const u8,
};

/// Why a request was refused. Each maps to exactly one status via `status_for`;
/// the engine sends that status and closes the connection.
pub const Error = error{
    /// Malformed: a bad request line, a header without a colon or with invalid
    /// bytes, a missing or duplicate `Host`, conflicting `Content-Length`s, a
    /// body on GET/HEAD, or a `Content-Length` past `content_length_max`. 400.
    BadRequest,
    /// The head is over `head_bytes_max`, has more than `headers_max` headers,
    /// or a header value is over `header_value_len_max`. 431.
    HeadTooLarge,
    /// The request line is over `request_line_bytes_max`. 414.
    UriTooLong,
    /// An unknown method, or `Transfer-Encoding` (chunked bodies are out of
    /// scope). 501.
    NotImplemented,
    /// A version other than HTTP/1.0 or HTTP/1.1. 505.
    VersionNotSupported,
};

/// The status the engine answers a parse error with, before closing.
pub fn status_for(err: Error) Status {
    const status: Status = switch (err) {
        error.BadRequest => .bad_request,
        error.HeadTooLarge => .header_fields_too_large,
        error.UriTooLong => .uri_too_long,
        error.NotImplemented => .not_implemented,
        error.VersionNotSupported => .http_version_not_supported,
    };

    std.debug.assert(status_module.is_error(status));
    std.debug.assert(status.code() < 600);

    return status;
}

/// A parsed request head. Every slice borrows from the bytes given to `parse`, so
/// the value is valid exactly as long as the slot's read buffer holds them — which
/// for the engine is the duration of one dispatch.
pub const Request = struct {
    /// The method, already validated against `Method`.
    method: Method,
    /// The path part of the target, up to `?`; never empty, always starts with
    /// '/' (or is `*` for `OPTIONS *`). Not percent-decoded.
    path: []const u8,
    /// The query string after `?`, or an empty slice. Not parsed further.
    query: []const u8,
    /// HTTP/1.0 or HTTP/1.1.
    version: Version,
    /// The headers in arrival order, `headers[0..headers_len]`.
    headers: [headers_max]Header,
    /// How many of `headers` are live.
    headers_len: u32,
    /// The declared body length, 0 when there is none. The body itself is the
    /// `content_length` bytes after `head_len` in the same buffer.
    content_length: u64,
    /// Whether the connection should stay open after this request, from the
    /// version and `Connection` headers.
    keep_alive: bool,
    /// Bytes the head occupied, blank line included — where the body starts.
    head_len: u32,

    /// The first header named `name`, compared case-insensitively, or null.
    pub fn header(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(request.headers_len <= headers_max);

        for (request.headers[0..request.headers_len]) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) {
                return candidate.value;
            }
        }

        return null;
    }
};

/// What `parse` found in the bytes so far.
pub const Parsed = union(enum) {
    /// No blank line yet, and the head is still under `head_bytes_max`: read
    /// more and parse again from the start.
    incomplete,
    /// A complete head. Whether the body has arrived too is the caller's check,
    /// against `content_length`.
    complete: Request,
};

/// Parses one request head from the front of `bytes`, which may hold more than one
/// pipelined request. Pure: no I/O, no allocation, and no state between calls — a
/// buffer that grows is simply parsed again.
///
/// Returns `.incomplete` until the blank line ending the head has arrived, and
/// fails with the member of `Error` whose status the request deserves.
pub fn parse(bytes: []const u8) Error!Parsed {
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        if (bytes.len >= head_bytes_max) {
            return error.HeadTooLarge;
        }

        return .incomplete;
    };
    const head_len: u32 = @intCast(head_end + 4);

    if (head_len > head_bytes_max) {
        return error.HeadTooLarge;
    }

    std.debug.assert(head_len <= bytes.len);
    std.debug.assert(head_len >= 4);

    var lines = std.mem.splitSequence(u8, bytes[0..head_end], "\r\n");
    const request_line = lines.first();
    var request = try parse_request_line(request_line);

    request.head_len = head_len;
    try parse_headers(&request, &lines);
    try validate_framing(&request);

    return .{ .complete = request };
}

fn parse_request_line(line: []const u8) Error!Request {
    if (line.len > request_line_bytes_max) {
        return error.UriTooLong;
    }

    var parts = std.mem.splitScalar(u8, line, ' ');
    const method_text = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version_text = parts.next() orelse return error.BadRequest;

    if (parts.next() != null) {
        return error.BadRequest;
    }

    const method = parse_method(method_text) orelse return error.NotImplemented;
    const version = parse_version(version_text) orelse return error.VersionNotSupported;

    if (target.len == 0) {
        return error.BadRequest;
    }

    for (target) |char| {
        if (char <= ' ' or char == 0x7f) {
            return error.BadRequest;
        }
    }

    const asterisk_form = method == .options and std.mem.eql(u8, target, "*");

    if (target[0] != '/' and !asterisk_form) {
        return error.BadRequest;
    }

    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_start) |index| target[0..index] else target;
    const query = if (query_start) |index| target[index + 1 ..] else target[0..0];

    std.debug.assert(path.len + query.len <= target.len);
    std.debug.assert(path.len > 0);

    return .{
        .method = method,
        .path = path,
        .query = query,
        .version = version,
        .headers = undefined,
        .headers_len = 0,
        .content_length = 0,
        .keep_alive = version == .http_1_1,
        .head_len = 0,
    };
}

fn parse_headers(request: *Request, lines: *std.mem.SplitIterator(u8, .sequence)) Error!void {
    std.debug.assert(request.headers_len == 0);
    std.debug.assert(request.head_len > 0);

    var content_length: ?u64 = null;
    var host_seen = false;
    var close_seen = false;
    var keep_alive_seen = false;

    while (lines.next()) |line| {
        if (line.len == 0) {
            return error.BadRequest;
        }
        if (request.headers_len == headers_max) {
            return error.HeadTooLarge;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (name.len == 0 or name.len > header_name_len_max) {
            return error.BadRequest;
        }
        if (value.len > header_value_len_max) {
            return error.HeadTooLarge;
        }
        if (!is_token(name)) {
            return error.BadRequest;
        }

        for (value) |char| {
            if (char < ' ' and char != '\t') {
                return error.BadRequest;
            }
            if (char == 0x7f) {
                return error.BadRequest;
            }
        }

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const parsed = parse_content_length(value) orelse return error.BadRequest;
            if (content_length != null and content_length.? != parsed) {
                return error.BadRequest;
            }
            content_length = parsed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.NotImplemented;
        } else if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (host_seen) {
                return error.BadRequest;
            }
            host_seen = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (connection_has_token(value, "close")) {
                close_seen = true;
            }
            if (connection_has_token(value, "keep-alive")) {
                keep_alive_seen = true;
            }
        }

        request.headers[request.headers_len] = .{ .name = name, .value = value };
        request.headers_len += 1;
    }

    if (request.version == .http_1_1 and !host_seen) {
        return error.BadRequest;
    }

    const wants_alive = request.version == .http_1_1 or keep_alive_seen;
    request.keep_alive = wants_alive and !close_seen;

    request.content_length = content_length orelse 0;
}

fn validate_framing(request: *const Request) Error!void {
    std.debug.assert(request.headers_len <= headers_max);
    std.debug.assert(request.path.len > 0);

    if (request.content_length > content_length_max) {
        return error.BadRequest;
    }

    const body_allowed = switch (request.method) {
        .post, .put, .patch, .delete, .options => true,
        .get, .head => request.content_length == 0,
    };

    if (!body_allowed) {
        return error.BadRequest;
    }
}

fn parse_method(text: []const u8) ?Method {
    std.debug.assert(text.len <= request_line_bytes_max);

    const table = [_]struct { []const u8, Method }{
        .{ "GET", .get },         .{ "HEAD", .head },   .{ "POST", .post },
        .{ "PUT", .put },         .{ "PATCH", .patch }, .{ "DELETE", .delete },
        .{ "OPTIONS", .options },
    };

    std.debug.assert(table.len == @typeInfo(Method).@"enum".fields.len);

    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], text)) {
            return entry[1];
        }
    }

    return null;
}

fn parse_version(text: []const u8) ?Version {
    std.debug.assert(text.len <= request_line_bytes_max);
    std.debug.assert(@typeInfo(Version).@"enum".fields.len == 2);

    if (std.mem.eql(u8, text, "HTTP/1.1")) {
        return .http_1_1;
    }

    if (std.mem.eql(u8, text, "HTTP/1.0")) {
        return .http_1_0;
    }

    return null;
}

fn parse_content_length(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 20) {
        return null;
    }

    var value: u64 = 0;

    for (text) |char| {
        if (char < '0' or char > '9') {
            return null;
        }
        value = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, value, char - '0') catch return null;
    }

    std.debug.assert(text.len > 0);
    std.debug.assert(text[0] != '-');

    return value;
}

fn connection_has_token(value: []const u8, wanted: []const u8) bool {
    std.debug.assert(value.len <= header_value_len_max);
    std.debug.assert(wanted.len > 0);

    var tokens = std.mem.splitScalar(u8, value, ',');

    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");

        if (std.ascii.eqlIgnoreCase(token, wanted)) {
            return true;
        }
    }

    return false;
}

fn is_token(text: []const u8) bool {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= header_name_len_max);

    for (text) |char| {
        const alnum = std.ascii.isAlphanumeric(char);
        const special = std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", char) != null;
        if (!alnum and !special) {
            return false;
        }
    }

    return true;
}

test "complete GET with query, headers, keep-alive by default" {
    const raw = "GET /posts?page=2 HTTP/1.1\r\nHost: example.test\r\nAccept: */*\r\n\r\n";
    const parsed = try parse(raw);
    const request = parsed.complete;

    try std.testing.expectEqual(Method.get, request.method);
    try std.testing.expectEqualStrings("/posts", request.path);
    try std.testing.expectEqualStrings("page=2", request.query);
    try std.testing.expectEqual(Version.http_1_1, request.version);
    try std.testing.expectEqualStrings("example.test", request.header("HOST").?);
    try std.testing.expectEqual(@as(u32, 2), request.headers_len);
    try std.testing.expect(request.keep_alive);
    try std.testing.expectEqual(@as(u32, raw.len), request.head_len);
    try std.testing.expectEqual(@as(u64, 0), request.content_length);
}

test "incomplete head, then complete with body length and pipelined tail" {
    try std.testing.expectEqual(Parsed.incomplete, try parse("POST /x HTTP/1.1\r\nHost: h\r\n"));

    const raw = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\n";
    const request = (try parse(raw)).complete;

    try std.testing.expectEqual(Method.post, request.method);
    try std.testing.expectEqual(@as(u64, 5), request.content_length);
    try std.testing.expectEqualStrings("hello", raw[request.head_len..][0..5]);
}

test "connection close and HTTP/1.0 defaults" {
    const closed = (try parse("GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")).complete;
    try std.testing.expect(!closed.keep_alive);

    const old = (try parse("GET / HTTP/1.0\r\n\r\n")).complete;
    try std.testing.expect(!old.keep_alive);

    const old_kept = (try parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")).complete;
    try std.testing.expect(old_kept.keep_alive);
}

test "rejections map to statuses" {
    const cases = [_]struct { []const u8, Error }{
        .{ "BREW / HTTP/1.1\r\nHost: h\r\n\r\n", error.NotImplemented },
        .{ "GET / HTTP/2.0\r\nHost: h\r\n\r\n", error.VersionNotSupported },
        .{ "GET / HTTP/1.1\r\n\r\n", error.BadRequest },
        .{ "GET /a b HTTP/1.1\r\nHost: h\r\n\r\n", error.BadRequest },
        .{ "GET example.test/ HTTP/1.1\r\nHost: h\r\n\r\n", error.BadRequest },
        .{ "GET / HTTP/1.1\r\nHost : h\r\n\r\n", error.BadRequest },
        .{ "GET / HTTP/1.1\r\nHost: h\r\nX: a\x00b\r\n\r\n", error.BadRequest },
        .{ "GET / HTTP/1.1\r\nHost: h\r\n bad: fold\r\n\r\n", error.BadRequest },
        .{
            "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            error.BadRequest,
        },
        .{ "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n", error.BadRequest },
        .{
            "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n",
            error.NotImplemented,
        },
        .{ "GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n", error.BadRequest },
        .{ "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", error.BadRequest },
    };

    for (cases) |case| {
        try std.testing.expectError(case[1], parse(case[0]));
        try std.testing.expect(status_module.is_error(status_for(case[1])));
    }
}

test "repeated HTTP/1.0 connection headers are order-free" {
    const kept = (try parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n" ++
        "Connection: foo\r\n\r\n")).complete;
    try std.testing.expect(kept.keep_alive);
}

test "connection close is sticky and cannot be re-enabled" {
    const mixed = (try parse("GET / HTTP/1.1\r\nHost: h\r\nConnection: close, keep-alive\r\n\r\n"))
        .complete;
    try std.testing.expect(!mixed.keep_alive);

    const stacked = (try parse("GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n" ++
        "Connection: keep-alive\r\n\r\n")).complete;
    try std.testing.expect(!stacked.keep_alive);
}

test "limits: too many headers and oversized head" {
    var buffer: [head_bytes_max + 64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("GET / HTTP/1.1\r\nHost: h\r\n");

    for (0..headers_max) |index| try writer.print("X-{d}: v\r\n", .{index});

    try writer.writeAll("\r\n");
    try std.testing.expectError(error.HeadTooLarge, parse(writer.buffered()));

    var huge: [head_bytes_max + 1]u8 = undefined;
    @memset(&huge, 'a');
    try std.testing.expectError(error.HeadTooLarge, parse(&huge));
}

test "OPTIONS accepts the asterisk-form target" {
    const request = (try parse("OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n")).complete;

    try std.testing.expectEqual(Method.options, request.method);
    try std.testing.expectEqualStrings("*", request.path);
}

test "content-length at the cap parses, one above is rejected" {
    const at_cap = (try parse("POST / HTTP/1.1\r\nHost: h\r\n" ++
        "Content-Length: 1099511627776\r\n\r\n")).complete;
    try std.testing.expectEqual(@as(u64, 1 << 40), at_cap.content_length);

    try std.testing.expectError(error.BadRequest, parse("POST / HTTP/1.1\r\nHost: h\r\n" ++
        "Content-Length: 1099511627777\r\n\r\n"));
}

test "header values are trimmed of surrounding spaces and tabs" {
    const request = (try parse("GET / HTTP/1.1\r\nHost: h\r\nX-Pad: \t v \t\r\n\r\n")).complete;

    try std.testing.expectEqualStrings("v", request.header("x-pad").?);
}

test "an empty query after ? parses as an empty slice" {
    const request = (try parse("GET /p? HTTP/1.1\r\nHost: h\r\n\r\n")).complete;

    try std.testing.expectEqualStrings("/p", request.path);
    try std.testing.expectEqualStrings("", request.query);
}

test "fuzz: the parser never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, fuzz_parse, .{ .corpus = &.{
        "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
        "POST /x?y=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc",
        "GET / HTTP/1.1\r\n",
        "\r\n\r\n",
    } });
}

fn fuzz_parse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [head_bytes_max + 128]u8 = undefined;
    const len = smith.slice(&buffer);

    _ = parse(buffer[0..len]) catch return;
}
