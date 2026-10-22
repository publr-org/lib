//! Upper and lower case for the plain Latin letters A to Z, which is what emails, slugs
//! and codes need. Every other character is kept as it is: `"Łódź"` lowers to `"Łódź"`.

const std = @import("std");

/// `text` with A to Z lowered. JS's `toLowerCase` on plain Latin text.
pub fn lower(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const out = try allocator.alloc(u8, text.len);

    std.debug.assert(out.len == text.len);

    return std.ascii.lowerString(out, text);
}

/// `text` with a to z raised. JS's `toUpperCase` on plain Latin text.
pub fn upper(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const out = try allocator.alloc(u8, text.len);

    std.debug.assert(out.len == text.len);

    return std.ascii.upperString(out, text);
}

test "only A to Z change case" {
    const allocator = std.testing.allocator;
    const lowered = try lower(allocator, "Ada@Example.COM Łódź");
    defer allocator.free(lowered);
    const raised = try upper(allocator, "sku-12b ż");
    defer allocator.free(raised);

    try std.testing.expectEqualStrings("ada@example.com Łódź", lowered);
    try std.testing.expectEqualStrings("SKU-12B ż", raised);
}
