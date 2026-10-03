//! The `match` operator's tokens and patterns (GROQ-1.revision5 leaves them to the
//! implementation; these follow the reference one). Text is split into tokens at
//! punctuation and white space, after dots touching a letter or digit are removed
//! (`ding.dong` is `dingdong`); a pattern's terms may hold `*`, any run of characters; every
//! term must match a whole token, ignoring case.

const std = @import("std");
const value_module = @import("value.zig");

const Value = value_module.Value;

pub const term_bytes_max: u32 = 1024;

/// Characters that end a token; `*` ends a token in text but is a wildcard in a pattern.
fn separates(char: u21, pattern: bool) bool {
    std.debug.assert(char <= 0x10FFFF);

    if (char == '*') {
        return !pattern;
    }

    return switch (char) {
        '!',
        '@',
        '#',
        '$',
        '%',
        '^',
        '&',
        '(',
        ')',
        ',',
        '\\',
        '/',
        '?',
        '"',
        ';',
        ':',
        '{',
        '}',
        '|',
        '[',
        ']',
        '+',
        '<',
        '>',
        '-',
        => true,
        else => is_space(char),
    };
}

/// JavaScript's `\s`.
fn is_space(char: u21) bool {
    std.debug.assert(char <= 0x10FFFF);

    return switch (char) {
        '\t',
        '\n',
        0x0b,
        0x0c,
        '\r',
        ' ',
        0xa0,
        0x1680,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
        => true,
        0x2000...0x200a => true,
        else => false,
    };
}

/// JavaScript's `\w`, which `\b` is defined by: ASCII letters, digits and `_`.
fn is_word(char: u21) bool {
    return char < 128 and (std.ascii.isAlphanumeric(@intCast(char)) or char == '_');
}

/// The tokens of a text, or the terms of a pattern.
pub fn tokens_of(arena: std.mem.Allocator, text: []const u8, pattern: bool) ![]const []const u8 {
    std.debug.assert(text.len <= 1 << 30);

    const points = try decode(arena, text);
    var kept: std.ArrayList(u21) = .empty;
    var index: u32 = 0;

    while (index < points.len) {
        if (points[index] != '.') {
            try kept.append(arena, points[index]);
            index += 1;
            continue;
        }

        var end = index;

        while (end < points.len and points[end] == '.') {
            end += 1;
        }

        const after_word = index > 0 and is_word(points[index - 1]);
        const before_word = end < points.len and is_word(points[end]);

        if (!after_word and !before_word) {
            try kept.appendSlice(arena, points[index..end]);
        }

        index = end;
    }

    return split(arena, kept.items, pattern);
}

fn split(arena: std.mem.Allocator, points: []const u21, pattern: bool) ![]const []const u8 {
    std.debug.assert(points.len <= 1 << 30);

    var tokens: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;

    for (points) |point| {
        if (separates(point, pattern)) {
            if (current.items.len > 0) {
                try tokens.append(arena, current.items);
                current = .empty;
            }

            continue;
        }

        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(point, &buffer) catch continue;

        try current.appendSlice(arena, buffer[0..length]);
    }

    if (current.items.len > 0) {
        try tokens.append(arena, current.items);
    }

    return tokens.items;
}

fn decode(arena: std.mem.Allocator, text: []const u8) ![]const u21 {
    std.debug.assert(text.len <= 1 << 30);

    var points: std.ArrayList(u21) = .empty;
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |byte| {
            try points.append(arena, byte);
        }

        return points.items;
    };
    var iterator = view.iterator();

    while (iterator.nextCodepoint()) |point| {
        try points.append(arena, point);
    }

    return points.items;
}

/// The text's tokens: from a string, or from each string of an array.
fn text_tokens(arena: std.mem.Allocator, left: Value) ![]const []const u8 {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    var tokens: std.ArrayList([]const u8) = .empty;

    switch (left) {
        .string => |text| try tokens.appendSlice(arena, try tokens_of(arena, text, false)),
        .array => |items| for (items) |item| {
            if (item == .string) {
                try tokens.appendSlice(arena, try tokens_of(arena, item.string, false));
            }
        },
        else => {},
    }

    return tokens.items;
}

/// The pattern's terms, or null when an array holds something other than strings.
fn pattern_terms(arena: std.mem.Allocator, right: Value) !?[]const []const u8 {
    std.debug.assert(right != .number or std.math.isFinite(right.number));

    var terms: std.ArrayList([]const u8) = .empty;

    switch (right) {
        .string => |text| try terms.appendSlice(arena, try tokens_of(arena, text, true)),
        .array => |items| for (items) |item| {
            if (item != .string) {
                return null;
            }

            try terms.appendSlice(arena, try tokens_of(arena, item.string, true));
        },
        else => {},
    }

    return terms.items;
}

pub fn matches(arena: std.mem.Allocator, left: Value, right: Value) !bool {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    const tokens = try text_tokens(arena, left);
    const terms = try pattern_terms(arena, right) orelse return false;

    if (tokens.len == 0 or terms.len == 0) {
        return false;
    }

    for (terms) |term| {
        const found = for (tokens) |token| {
            if (try term_matches(arena, term, token)) break true;
        } else false;

        if (!found) {
            return false;
        }
    }

    return true;
}

/// The score a `match` adds: the share of its terms found, each found term counting once
/// per token it matches.
pub fn score(arena: std.mem.Allocator, left: Value, right: Value) !f64 {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (!try matches(arena, left, right)) {
        return 0;
    }

    const tokens = try text_tokens(arena, left);
    const terms = (try pattern_terms(arena, right)).?;
    var hits: f64 = 0;

    for (terms) |term| {
        for (tokens) |token| {
            if (try term_matches(arena, term, token)) {
                hits += 1;
            }
        }
    }

    return hits;
}

/// A term against a whole token, ignoring case; `*` stands for any run of characters.
fn term_matches(arena: std.mem.Allocator, term: []const u8, token: []const u8) !bool {
    std.debug.assert(term.len <= 1 << 30);

    if (term.len > term_bytes_max) {
        return false;
    }

    const wanted = try folded(arena, term);
    const given = try folded(arena, token);

    return wildcard(wanted, given);
}

fn folded(arena: std.mem.Allocator, text: []const u8) ![]const u21 {
    std.debug.assert(text.len <= 1 << 30);

    const points = try decode(arena, text);
    const lowered = try arena.alloc(u21, points.len);

    for (points, lowered) |point, *lower| {
        lower.* = to_lower(point);
    }

    return lowered;
}

/// Lower case for the scripts text is commonly in: ASCII, Latin-1, Latin Extended-A, Greek,
/// Cyrillic.
fn to_lower(point: u21) u21 {
    std.debug.assert(point <= 0x10FFFF);

    return switch (point) {
        'A'...'Z' => point + 32,
        0xc0...0xd6, 0xd8...0xde => point + 32,
        0x100...0x17f => if (point % 2 == 0) point + 1 else point,
        0x391...0x3a1, 0x3a3...0x3ab => point + 32,
        0x400...0x40f => point + 80,
        0x410...0x42f => point + 32,
        else => point,
    };
}

/// `*` in the pattern matches any run; everything else one character the same.
fn wildcard(pattern: []const u21, text: []const u21) bool {
    std.debug.assert(pattern.len <= 1 << 30);

    var pattern_at: u32 = 0;
    var text_at: u32 = 0;
    var star: ?u32 = null;
    var resume_at: u32 = 0;

    while (text_at < text.len) {
        if (pattern_at < pattern.len and pattern[pattern_at] == '*') {
            star = pattern_at;
            pattern_at += 1;
            resume_at = text_at;
        } else if (pattern_at < pattern.len and pattern[pattern_at] == text[text_at]) {
            pattern_at += 1;
            text_at += 1;
        } else if (star) |at| {
            pattern_at = at + 1;
            resume_at += 1;
            text_at = resume_at;
        } else {
            return false;
        }
    }

    while (pattern_at < pattern.len and pattern[pattern_at] == '*') {
        pattern_at += 1;
    }

    return pattern_at == pattern.len;
}

test "match: tokens, dots, wildcards, case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text: Value = .{ .string = "hello world FOO-bar ding.dong A.B.C.s! посчастливится!" };

    try std.testing.expect(try matches(arena, text, .{ .string = "foo" }));
    try std.testing.expect(try matches(arena, text, .{ .string = "foo-bar" }));
    try std.testing.expect(try matches(arena, text, .{ .string = "dingdong" }));
    try std.testing.expect(try matches(arena, text, .{ .string = "wor*" }));
    try std.testing.expect(try matches(arena, text, .{ .string = "ПОСЧАСТЛИВИТСЯ" }));
    try std.testing.expect(!try matches(arena, text, .{ .string = "worl" }));
    try std.testing.expect(!try matches(arena, text, .{ .string = "" }));
}
