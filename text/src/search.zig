//! Finding and comparing text: what JS writes as `===`, `includes` and `indexOf`.
//! Positions count code points.

const std = @import("std");
const utf8 = @import("utf8.zig");

/// The same text, byte for byte. JS's `===`. Text that looks the same but is composed
/// differently (`ą` as one code point or as `a` and a mark) is not equal.
pub fn equals(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether `text` holds `part` anywhere. JS's `includes`.
pub fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

/// JS's `startsWith`.
pub fn starts_with(text: []const u8, part: []const u8) bool {
    return std.mem.startsWith(u8, text, part);
}

/// JS's `endsWith`.
pub fn ends_with(text: []const u8, part: []const u8) bool {
    return std.mem.endsWith(u8, text, part);
}

/// Where `part` first starts, in code points; null where JS answers -1. JS's `indexOf`.
pub fn index_of(text: []const u8, part: []const u8) ?u32 {
    const found = std.mem.indexOf(u8, text, part) orelse return null;

    std.debug.assert(found + part.len <= text.len);

    return utf8.count(text[0..found]);
}

/// Where `part` last starts. JS's `lastIndexOf`.
pub fn last_index_of(text: []const u8, part: []const u8) ?u32 {
    const found = std.mem.lastIndexOf(u8, text, part) orelse return null;

    std.debug.assert(found + part.len <= text.len);

    return utf8.count(text[0..found]);
}

/// Whether `text` has no characters: JS's `text === ""`, or `!text`.
pub fn is_empty(text: []const u8) bool {
    return text.len == 0;
}

/// The same text ignoring the case of the plain Latin letters A to Z: enough for emails,
/// slugs and codes. `"ŁÓDŹ"` and `"łódź"` differ: other letters are compared as they are.
pub fn equals_ignore_case(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "equals" {
    try std.testing.expect(equals("łąka", "łąka"));
    try std.testing.expect(!equals("ą", "a\u{328}"));
}

test "contains, starts_with and ends_with" {
    try std.testing.expect(contains("Zażółć gęślą", "gęś"));
    try std.testing.expect(contains("abc", ""));
    try std.testing.expect(!contains("abc", "abcd"));
    try std.testing.expect(starts_with("https://x", "https:"));
    try std.testing.expect(ends_with("plik.zig", ".zig"));
    try std.testing.expect(!ends_with("", "a"));
}

test "index_of and last_index_of count code points" {
    try std.testing.expectEqual(@as(?u32, 3), index_of("żółw żółw", "w"));
    try std.testing.expectEqual(@as(?u32, null), index_of("abc", "d"));
    try std.testing.expectEqual(@as(?u32, 0), index_of("abc", ""));
    try std.testing.expectEqual(@as(?u32, 8), last_index_of("żółw żółw", "w"));
    try std.testing.expectEqual(@as(?u32, 3), last_index_of("abc", ""));
}

test "ignoring case" {
    try std.testing.expect(equals_ignore_case("Ada@Example.COM", "ada@example.com"));
    try std.testing.expect(!equals_ignore_case("ŁÓDŹ", "łódź"));
    try std.testing.expect(!equals_ignore_case("a", "ab"));
}
