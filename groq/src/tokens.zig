//! GROQ's tokens (GROQ-1.revision5, "Syntax"): strings with their escapes decoded, numbers
//! with fractions and exponents, every operator, `//` comments skipped.

const std = @import("std");

pub const Kind = enum {
    star,
    star_star,
    at,
    caret,
    dot,
    dot_dot,
    dot_dot_dot,
    comma,
    colon,
    colon_colon,
    pipe,
    arrow,
    pair_arrow,
    left_bracket,
    right_bracket,
    left_brace,
    right_brace,
    left_paren,
    right_paren,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    and_,
    or_,
    not_,
    plus,
    minus,
    slash,
    percent,
    identifier,
    string,
    number,
    param,
    end,
};

pub const Token = struct {
    kind: Kind,
    /// An identifier's or parameter's name; a string's decoded contents; a number as written.
    text: []const u8,
    at: u32,
};

pub const tokens_max: u32 = 8192;
pub const query_bytes_max: u32 = 1 << 20;

pub const Error = error{ Invalid, OutOfMemory };

pub fn tokenize(arena: std.mem.Allocator, query: []const u8) Error![]const Token {
    std.debug.assert(tokens_max > 0);

    if (query.len > query_bytes_max) {
        return error.Invalid;
    }

    var tokens: std.ArrayList(Token) = .empty;
    var at: u32 = 0;

    while (true) {
        at = skip_space(query, at);

        if (tokens.items.len == tokens_max) {
            return error.Invalid;
        }

        var length: u32 = 0;
        const token = try next(arena, query, at, &length);

        try tokens.append(arena, token);

        if (token.kind == .end) {
            break;
        }

        at += length;
    }

    return tokens.items;
}

fn skip_space(query: []const u8, start: u32) u32 {
    std.debug.assert(start <= query.len);

    var at = start;

    while (at < query.len) {
        const width = space_width(query[at..]);

        if (width > 0) {
            at += width;
        } else if (query[at] == '/' and at + 1 < query.len and query[at + 1] == '/') {
            const end = std.mem.indexOfScalarPos(u8, query, at, '\n') orelse query.len;

            at = @intCast(end);
        } else {
            break;
        }
    }

    return at;
}

/// Tab, newline, vertical tab, form feed, carriage return, space; U+0085 and U+00A0.
fn space_width(rest: []const u8) u32 {
    std.debug.assert(rest.len > 0);

    switch (rest[0]) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => return 1,
        0xc2 => {
            const wide = rest.len > 1 and (rest[1] == 0x85 or rest[1] == 0xa0);

            return if (wide) 2 else 0;
        },
        else => return 0,
    }
}

const Symbol = struct { text: []const u8, kind: Kind };

/// Longest first, so `...` is not read as `..` and `.`.
const symbols = [_]Symbol{
    .{ .text = "...", .kind = .dot_dot_dot },
    .{ .text = "..", .kind = .dot_dot },
    .{ .text = "**", .kind = .star_star },
    .{ .text = "::", .kind = .colon_colon },
    .{ .text = "->", .kind = .arrow },
    .{ .text = "=>", .kind = .pair_arrow },
    .{ .text = "==", .kind = .equal },
    .{ .text = "!=", .kind = .not_equal },
    .{ .text = "<=", .kind = .less_equal },
    .{ .text = ">=", .kind = .greater_equal },
    .{ .text = "&&", .kind = .and_ },
    .{ .text = "||", .kind = .or_ },
    .{ .text = "*", .kind = .star },
    .{ .text = "@", .kind = .at },
    .{ .text = "^", .kind = .caret },
    .{ .text = ".", .kind = .dot },
    .{ .text = ",", .kind = .comma },
    .{ .text = ":", .kind = .colon },
    .{ .text = "|", .kind = .pipe },
    .{ .text = "[", .kind = .left_bracket },
    .{ .text = "]", .kind = .right_bracket },
    .{ .text = "{", .kind = .left_brace },
    .{ .text = "}", .kind = .right_brace },
    .{ .text = "(", .kind = .left_paren },
    .{ .text = ")", .kind = .right_paren },
    .{ .text = "<", .kind = .less },
    .{ .text = ">", .kind = .greater },
    .{ .text = "!", .kind = .not_ },
    .{ .text = "+", .kind = .plus },
    .{ .text = "-", .kind = .minus },
    .{ .text = "/", .kind = .slash },
    .{ .text = "%", .kind = .percent },
};

fn next(arena: std.mem.Allocator, query: []const u8, at: u32, length: *u32) Error!Token {
    std.debug.assert(at <= query.len);

    if (at == query.len) {
        length.* = 0;
        return .{ .kind = .end, .text = "", .at = at };
    }

    const rest = query[at..];
    const char = rest[0];

    if (char == '"' or char == '\'') {
        return string(arena, query, at, length);
    }

    if (std.ascii.isDigit(char)) {
        return number(query, at, length);
    }

    if (char == '$' or std.ascii.isAlphabetic(char) or char == '_') {
        const start: u32 = if (char == '$') at + 1 else at;
        var end = start;

        while (end < query.len and (std.ascii.isAlphanumeric(query[end]) or query[end] == '_')) {
            end += 1;
        }

        if (end == start or std.ascii.isDigit(query[start])) {
            return error.Invalid;
        }

        length.* = end - at;

        const kind: Kind = if (char == '$') .param else .identifier;

        return .{ .kind = kind, .text = query[start..end], .at = at };
    }

    for (symbols) |symbol| {
        if (std.mem.startsWith(u8, rest, symbol.text)) {
            length.* = @intCast(symbol.text.len);

            return .{ .kind = symbol.kind, .text = symbol.text, .at = at };
        }
    }

    return error.Invalid;
}

/// Digits, an optional fraction, an optional exponent: `3`, `3.14`, `1e-5`, `2.5E10`.
fn number(query: []const u8, at: u32, length: *u32) Error!Token {
    std.debug.assert(std.ascii.isDigit(query[at]));

    var end = digits(query, at);
    const dotted = end + 1 < query.len and query[end] == '.' and std.ascii.isDigit(query[end + 1]);

    if (dotted) {
        end = digits(query, end + 1);
    }

    if (end < query.len and (query[end] == 'e' or query[end] == 'E')) {
        var exponent = end + 1;

        if (exponent < query.len and (query[exponent] == '+' or query[exponent] == '-')) {
            exponent += 1;
        }

        if (exponent >= query.len or !std.ascii.isDigit(query[exponent])) {
            return error.Invalid;
        }

        end = digits(query, exponent);
    }

    length.* = end - at;

    return .{ .kind = .number, .text = query[at..end], .at = at };
}

fn digits(query: []const u8, start: u32) u32 {
    std.debug.assert(start <= query.len);

    var end = start;

    while (end < query.len and std.ascii.isDigit(query[end])) {
        end += 1;
    }

    return end;
}

/// A string's contents with its escapes decoded; a surrogate pair is one code point; an
/// invalid code point is an error.
fn string(arena: std.mem.Allocator, query: []const u8, at: u32, length: *u32) Error!Token {
    std.debug.assert(at < query.len);

    const quote = query[at];
    var out: std.ArrayList(u8) = .empty;
    var index = at + 1;

    while (true) {
        if (index >= query.len) {
            return error.Invalid;
        }

        const char = query[index];

        if (char == quote) {
            break;
        }

        if (char != '\\') {
            try out.append(arena, char);
            index += 1;
            continue;
        }

        index = try escape(arena, query, index + 1, &out);
    }

    length.* = index + 1 - at;

    return .{ .kind = .string, .text = out.items, .at = at };
}

fn escape(
    arena: std.mem.Allocator,
    query: []const u8,
    start: u32,
    out: *std.ArrayList(u8),
) Error!u32 {
    std.debug.assert(start <= query.len);

    if (start >= query.len) {
        return error.Invalid;
    }

    const simple: ?u8 = switch (query[start]) {
        '\'' => '\'',
        '"' => '"',
        '\\' => '\\',
        '/' => '/',
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => null,
        else => return error.Invalid,
    };

    if (simple) |byte| {
        try out.append(arena, byte);
        return start + 1;
    }

    var after: u32 = 0;
    var code = try unicode_escape(query, start + 1, &after);

    if (code >= 0xD800 and code <= 0xDBFF) {
        const low_start = after;
        const paired = low_start + 1 < query.len and query[low_start] == '\\' and
            query[low_start + 1] == 'u';

        if (!paired) {
            return error.Invalid;
        }

        const low = try unicode_escape(query, low_start + 2, &after);

        if (low < 0xDC00 or low > 0xDFFF) {
            return error.Invalid;
        }

        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
    }

    var buffer: [4]u8 = undefined;
    const point = std.math.cast(u21, code) orelse return error.Invalid;
    const written = std.unicode.utf8Encode(point, &buffer) catch return error.Invalid;

    try out.appendSlice(arena, buffer[0..written]);

    return after;
}

/// After `\u`: four hex digits, or `{` hex digits `}`.
fn unicode_escape(query: []const u8, start: u32, after: *u32) Error!u32 {
    std.debug.assert(start <= query.len);

    if (start < query.len and query[start] == '{') {
        const close = std.mem.indexOfScalarPos(u8, query, start, '}') orelse return error.Invalid;
        const hex = query[start + 1 .. close];

        if (hex.len == 0 or hex.len > 6) {
            return error.Invalid;
        }

        after.* = @intCast(close + 1);

        return std.fmt.parseInt(u32, hex, 16) catch error.Invalid;
    }

    if (start + 4 > query.len) {
        return error.Invalid;
    }

    after.* = start + 4;

    return std.fmt.parseInt(u32, query[start .. start + 4], 16) catch error.Invalid;
}

test "tokens: escapes decoded, exponents, longest symbols, comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tokens = try tokenize(arena,
        \\"a\nb\u00e9\u{1F600}\uD83D\uDE00" 1.5e3 ** ... => :: // x
    );

    try std.testing.expectEqualStrings("a\nbé😀😀", tokens[0].text);
    try std.testing.expectEqualStrings("1.5e3", tokens[1].text);
    try std.testing.expectEqual(Kind.star_star, tokens[2].kind);
    try std.testing.expectEqual(Kind.dot_dot_dot, tokens[3].kind);
    try std.testing.expectEqual(Kind.pair_arrow, tokens[4].kind);
    try std.testing.expectEqual(Kind.colon_colon, tokens[5].kind);
    try std.testing.expectEqual(Kind.end, tokens[6].kind);
    try std.testing.expectError(error.Invalid, tokenize(arena, "\"\\uD800\""));
    try std.testing.expectError(error.Invalid, tokenize(arena, "1e"));
}
