//! White space as JS's `trim` knows it: its WhiteSpace and LineTerminator, which is every
//! space separator (Zs) plus tab, the line breaks, vertical tab, form feed and U+FEFF.

const std = @import("std");
const utf8 = @import("utf8.zig");

/// Whether JS's `trim` removes `code_point`.
pub fn is_whitespace(code_point: u21) bool {
    std.debug.assert(code_point <= utf8.code_point_max);

    return switch (code_point) {
        '\t', '\n', 0x0B, 0x0C, '\r', 0x2028, 0x2029, 0xFEFF => true,
        // The space separators (Zs), Unicode 17.
        0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `text` without white space at either end. JS's `trim`.
pub fn trim(text: []const u8) []const u8 {
    return trim_end(trim_start(text));
}

/// JS's `trimStart`.
pub fn trim_start(text: []const u8) []const u8 {
    var iterator = utf8.iterate(text);

    while (iterator.next()) |item| {
        if (!is_whitespace(item.code_point)) {
            return text[item.offset..];
        }
    }

    std.debug.assert(iterator.offset == text.len);

    return text[text.len..];
}

/// JS's `trimEnd`.
pub fn trim_end(text: []const u8) []const u8 {
    var iterator: utf8.Iterator = .{
        .bytes = text,
        .offset = @intCast(text.len),
    };

    while (iterator.previous()) |item| {
        if (!is_whitespace(item.code_point)) {
            return text[0 .. item.offset + item.len];
        }
    }

    std.debug.assert(iterator.offset == 0);

    return text[0..0];
}

/// Whether `text` is empty or only white space: JS's `!text.trim()`.
pub fn is_blank(text: []const u8) bool {
    return trim_start(text).len == 0;
}

test "trim removes JS white space and nothing else" {
    try std.testing.expectEqualStrings("a b", trim(" \t\n a b \u{3000}\u{FEFF}"));
    try std.testing.expectEqualStrings("a ", trim_start("\u{A0}a "));
    try std.testing.expectEqualStrings(" a", trim_end(" a\u{2028}"));
    try std.testing.expectEqualStrings("\u{200B}a", trim(" \u{200B}a"));
    try std.testing.expectEqualStrings("", trim("  "));
    try std.testing.expectEqualStrings("\xFF", trim(" \xFF "));
}

test "is_blank" {
    try std.testing.expect(is_blank(""));
    try std.testing.expect(is_blank(" \u{2003}\r\n"));
    try std.testing.expect(!is_blank(" .\n"));
}
