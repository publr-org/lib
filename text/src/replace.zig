//! Splitting and replacing by plain text, as JS's `split`, `replace` and `replaceAll` do
//! when given text rather than a pattern.

const std = @import("std");
const utf8 = @import("utf8.zig");

/// The pieces of `text` between each `separator`; an empty separator gives each
/// character. JS's `split(separator)`.
pub fn split(
    allocator: std.mem.Allocator,
    text: []const u8,
    separator: []const u8,
) error{OutOfMemory}![]const []const u8 {
    var pieces: std.ArrayList([]const u8) = .empty;
    errdefer pieces.deinit(allocator);

    if (separator.len == 0) {
        var iterator = utf8.iterate(text);

        while (iterator.next()) |item| {
            try pieces.append(allocator, text[item.offset..][0..item.len]);
        }

        return pieces.toOwnedSlice(allocator);
    }

    var rest = std.mem.splitSequence(u8, text, separator);

    while (rest.next()) |piece| {
        try pieces.append(allocator, piece);
    }

    std.debug.assert(pieces.items.len > 0);

    return pieces.toOwnedSlice(allocator);
}

/// `text` with the first `part` replaced by `with`. JS's `replace(part, with)`, without
/// the `$` patterns.
pub fn replace(
    allocator: std.mem.Allocator,
    text: []const u8,
    part: []const u8,
    with: []const u8,
) error{OutOfMemory}![]u8 {
    const found = std.mem.indexOf(u8, text, part) orelse return allocator.dupe(u8, text);

    std.debug.assert(found + part.len <= text.len);

    return std.mem.concat(allocator, u8, &.{ text[0..found], with, text[found + part.len ..] });
}

/// `text` with every `part` replaced by `with`. JS's `replaceAll(part, with)`, without the
/// `$` patterns; an empty `part` puts `with` between every character, as JS does.
pub fn replace_all(
    allocator: std.mem.Allocator,
    text: []const u8,
    part: []const u8,
    with: []const u8,
) error{OutOfMemory}![]u8 {
    if (part.len > 0) {
        return std.mem.replaceOwned(u8, allocator, text, part, with);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var iterator = utf8.iterate(text);

    try out.appendSlice(allocator, with);

    while (iterator.next()) |item| {
        try out.appendSlice(allocator, text[item.offset..][0..item.len]);
        try out.appendSlice(allocator, with);
    }

    std.debug.assert(out.items.len >= text.len);

    return out.toOwnedSlice(allocator);
}

test "split by text" {
    const allocator = std.testing.allocator;
    const pieces = try split(allocator, "a, b,, c", ", ");
    defer allocator.free(pieces);
    const letters = try split(allocator, "żab", "");
    defer allocator.free(letters);

    try std.testing.expectEqual(3, pieces.len);
    try std.testing.expectEqualStrings("b,", pieces[1]);
    try std.testing.expectEqualStrings("ż", letters[0]);
    try std.testing.expectEqual(3, letters.len);
}

test "replace and replace_all by text" {
    const allocator = std.testing.allocator;
    const once = try replace(allocator, "a-b-c", "-", "+");
    defer allocator.free(once);
    const every = try replace_all(allocator, "a-b-c", "-", "+");
    defer allocator.free(every);
    const between = try replace_all(allocator, "ab", "", ".");
    defer allocator.free(between);
    const none = try replace(allocator, "abc", "x", "y");
    defer allocator.free(none);

    try std.testing.expectEqualStrings("a+b-c", once);
    try std.testing.expectEqualStrings("a+b+c", every);
    try std.testing.expectEqualStrings(".a.b.", between);
    try std.testing.expectEqualStrings("abc", none);
}
