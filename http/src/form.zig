//! What a browser form sends: `application/x-www-form-urlencoded` bodies and query
//! strings, percent-decoded into name/value pairs a handler reads by name.
//!
//! A form POST, in full:
//!
//! ```zig
//! fn create_post(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
//!     const form = http.Form.parse(ctx.arena, req.body) orelse
//!         return res.text(.bad_request, "bad form");
//!     const title = form.text("title") orelse
//!         return res.text(.bad_request, "title is required");
//!     const draft = form.get("draft") != null;
//!     …
//! }
//! ```
//!
//! Fixed capacity, like everything else here: a body past `Form.body_bytes_max` or
//! with more than `Form.pairs_max` pairs does not parse. Decoding allocates from
//! the request arena, so the pairs live exactly as long as the response.
const std = @import("std");

/// The pairs of one parsed body, in arrival order; also home to the two
/// decoders a handler uses on their own, `query_param` and `decode`.
pub const Form = struct {
    /// Most name/value pairs one form may carry; one more and `parse` answers null.
    pub const pairs_max: u32 = 128;
    /// Largest body `parse` accepts.
    pub const body_bytes_max: u32 = 1 << 20;

    /// The pairs, `pairs[0..len]`, both halves decoded into the arena.
    pairs: [pairs_max]Pair = undefined,
    /// How many of `pairs` are live.
    len: u32 = 0,

    /// One decoded pair.
    pub const Pair = struct {
        /// The field name, percent-decoded.
        name: []const u8,
        /// The value, percent-decoded; empty for `name=` and for a bare `name`.
        value: []const u8,
    };

    /// Parses a urlencoded body into pairs, or answers null when it is too large,
    /// has too many pairs, or contains a malformed percent escape.
    ///
    /// ```zig
    /// const form = http.Form.parse(ctx.arena, req.body) orelse
    ///     return res.text(.bad_request, "bad form");
    /// ```
    pub fn parse(arena: std.mem.Allocator, body: []const u8) ?Form {
        std.debug.assert(pairs_max > 0);

        if (body.len > body_bytes_max) {
            return null;
        }

        var form: Form = .{};
        var pairs = std.mem.splitScalar(u8, body, '&');

        while (pairs.next()) |pair| {
            if (pair.len == 0) {
                continue;
            }

            if (form.len == pairs_max) {
                return null;
            }

            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_value = if (equals < pair.len) pair[equals + 1 ..] else "";

            form.pairs[form.len] = .{
                .name = decode(arena, pair[0..equals]) orelse return null,
                .value = decode(arena, raw_value) orelse return null,
            };
            form.len += 1;
        }

        return form;
    }

    /// The first value under `name` exactly as sent (empty included), or null when
    /// the field is absent — which is how a checkbox reads: present or not.
    ///
    /// ```zig
    /// const draft = form.get("draft") != null;
    /// ```
    pub fn get(form: *const Form, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(form.len <= pairs_max);

        for (form.pairs[0..form.len]) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                return pair.value;
            }
        }

        return null;
    }

    /// The value under `name` trimmed of surrounding whitespace, or null when the
    /// field is absent or blank — how a required text input reads.
    ///
    /// ```zig
    /// const title = form.text("title") orelse return res.text(.bad_request, "title is required");
    /// ```
    pub fn text(form: *const Form, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(form.len <= pairs_max);

        const value = form.get(name) orelse return null;
        const trimmed = std.mem.trim(u8, value, " \r\n\t");

        return if (trimmed.len == 0) null else trimmed;
    }

    /// One parameter of a query string (`req.query()`), percent-decoded into the
    /// arena, or null when it is absent, empty, or malformed.
    ///
    /// ```zig
    /// const page = http.Form.query_param(ctx.arena, req.query(), "page") orelse "1";
    /// ```
    pub fn query_param(arena: std.mem.Allocator, query: []const u8, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        var pairs = std.mem.splitScalar(u8, query, '&');

        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

            if (std.mem.eql(u8, pair[0..equals], name)) {
                const value = decode(arena, pair[equals + 1 ..]) orelse return null;

                return if (value.len == 0) null else value;
            }
        }

        return null;
    }

    /// Percent-decodes one urlencoded component into the arena: `+` becomes a
    /// space, `%XX` a byte. Null on a truncated or non-hex escape, or when the
    /// arena is full.
    ///
    /// ```zig
    /// const slug = http.Form.decode(ctx.arena, req.param("slug").?) orelse
    ///     return res.text(.bad_request, "bad slug");
    /// ```
    pub fn decode(arena: std.mem.Allocator, encoded: []const u8) ?[]const u8 {
        if (encoded.len > body_bytes_max) {
            return null;
        }

        var out = arena.alloc(u8, encoded.len) catch return null;
        var len: u32 = 0;
        var index: u32 = 0;

        while (index < encoded.len) : (index += 1) {
            const char = encoded[index];

            if (char == '+') {
                out[len] = ' ';
            } else if (char == '%') {
                if (index + 2 >= encoded.len) {
                    return null;
                }

                const escape = encoded[index + 1 .. index + 3];

                const high = std.fmt.charToDigit(escape[0], 16) catch return null;
                const low = std.fmt.charToDigit(escape[1], 16) catch return null;
                out[len] = high << 4 | low;
                index += 2;
            } else {
                out[len] = char;
            }

            len += 1;
        }

        std.debug.assert(len <= encoded.len);

        return out[0..len];
    }
};

test "decode: plus, percent escapes, and the malformed cases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("a b&c", Form.decode(arena, "a+b%26c").?);
    try std.testing.expectEqualStrings("plain", Form.decode(arena, "plain").?);
    try std.testing.expectEqualStrings("", Form.decode(arena, "").?);
    try std.testing.expect(Form.decode(arena, "bad%2") == null);
    try std.testing.expect(Form.decode(arena, "bad%zz") == null);
}

test "Form.parse: pairs by name, get versus text, and the limits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const form = Form.parse(arena, "title=Hello+world&draft=&note=+%0A+&&x=1%3D2").?;
    try std.testing.expectEqual(@as(u32, 4), form.len);
    try std.testing.expectEqualStrings("Hello world", form.get("title").?);
    try std.testing.expectEqualStrings("", form.get("draft").?);
    try std.testing.expect(form.text("draft") == null);
    try std.testing.expect(form.text("note") == null);
    try std.testing.expectEqualStrings("1=2", form.text("x").?);
    try std.testing.expect(form.get("missing") == null);

    try std.testing.expect(Form.parse(arena, "bad=%2") == null);

    var too_many: std.Io.Writer.Allocating = .init(arena);

    for (0..Form.pairs_max + 1) |index| {
        try too_many.writer.print("k{d}=v&", .{index});
    }

    try std.testing.expect(Form.parse(arena, too_many.written()) == null);
}

test "query_param: decoded value, empty is absent, missing is null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const query_param = Form.query_param;

    try std.testing.expectEqualStrings("post", query_param(arena, "type=post&status=", "type").?);
    try std.testing.expectEqualStrings("a b", query_param(arena, "q=a+b", "q").?);
    try std.testing.expect(query_param(arena, "type=post&status=", "status") == null);
    try std.testing.expect(query_param(arena, "type=post", "page") == null);
    try std.testing.expect(query_param(arena, "", "page") == null);
}
