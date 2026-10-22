//! Reading text by position. Positions and lengths count code points, never bytes, so no
//! answer cuts a character in half; what comes back is a slice of the text itself.

const std = @import("std");
const utf8 = @import("utf8.zig");

/// How many characters (code points) `text` holds. JS's `length`, which counts UTF-16
/// units instead: `"😀".length` is 2, `length("😀")` is 1.
pub fn length(text: []const u8) u32 {
    return utf8.count(text);
}

/// The characters from `start` up to, not including, `end`; null `end` is the end of the
/// text. Negative positions count back from the end. JS's `slice`.
pub fn slice(text: []const u8, start: i64, end: ?i64) []const u8 {
    const total: i64 = length(text);
    const from = clamp(if (start < 0) total + start else start, total);
    const to = clamp(if (end) |given| (if (given < 0) total + given else given) else total, total);

    if (from >= to) {
        return "";
    }

    return between(text, @intCast(from), @intCast(to));
}

fn clamp(position: i64, total: i64) i64 {
    std.debug.assert(total >= 0);

    return @max(0, @min(position, total));
}

fn between(text: []const u8, from: u32, to: u32) []const u8 {
    std.debug.assert(from <= to);

    const from_offset = utf8.offset_of(text, from).?;
    const to_offset = from_offset + utf8.offset_of(text[from_offset..], to - from).?;

    std.debug.assert(to_offset <= text.len);

    return text[from_offset..to_offset];
}

test "length counts characters" {
    try std.testing.expectEqual(@as(u32, 0), length(""));
    try std.testing.expectEqual(@as(u32, 6), length("Zażółć"));
    try std.testing.expectEqual(@as(u32, 1), length("😀"));
}

test "slice" {
    try std.testing.expectEqualStrings("żół", slice("Zażółć", 2, 5));
    try std.testing.expectEqualStrings("łć", slice("Zażółć", -2, null));
    try std.testing.expectEqualStrings("Zażół", slice("Zażółć", 0, -1));
    try std.testing.expectEqualStrings("", slice("Zażółć", 4, 2));
    try std.testing.expectEqualStrings("", slice("Zażółć", 100, null));
}
