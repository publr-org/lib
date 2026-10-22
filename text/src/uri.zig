//! Percent-encoding the way JS's `encodeURIComponent` and `decodeURIComponent` do it.

const std = @import("std");
const utf8 = @import("utf8.zig");

pub const Error = error{ OutOfMemory, Malformed };

const unreserved_marks = "-_.!~*'()";
const reserved = ";/?:@&=+$,#";

fn keeps(byte: u8, whole_uri: bool) bool {
    const mark = std.mem.indexOfScalar(u8, unreserved_marks, byte) != null;

    if (std.ascii.isAlphanumeric(byte) or mark) {
        return true;
    }

    return whole_uri and std.mem.indexOfScalar(u8, reserved, byte) != null;
}

/// Every byte but letters, digits and `-_.!~*'()` as `%XX`. Malformed UTF-8 is refused, as
/// JS refuses a lone surrogate. JS's `encodeURIComponent`.
pub fn encode_uri_component(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    return encode(allocator, text, false);
}

fn encode(allocator: std.mem.Allocator, text: []const u8, whole_uri: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, text.len);

    var iterator = utf8.iterate(text);

    while (iterator.next()) |item| {
        if (item.code_point == utf8.replacement and item.len == 1) {
            return error.Malformed;
        }

        for (text[item.offset..][0..item.len]) |byte| {
            if (keeps(byte, whole_uri)) {
                try out.append(allocator, byte);
            } else {
                try out.print(allocator, "%{X:0>2}", .{byte});
            }
        }
    }

    std.debug.assert(out.items.len >= text.len);

    return out.toOwnedSlice(allocator);
}

/// Every `%XX` back to its byte; refused when an escape is cut short or the bytes are not
/// UTF-8. JS's `decodeURIComponent`.
pub fn decode_uri_component(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    return decode(allocator, text, false);
}

fn decode(allocator: std.mem.Allocator, text: []const u8, whole_uri: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, text.len);

    var cursor: u32 = 0;

    while (cursor < text.len) {
        if (text[cursor] != '%') {
            try out.append(allocator, text[cursor]);
            cursor += 1;
            continue;
        }

        if (cursor + 3 > text.len) {
            return error.Malformed;
        }

        const hex = text[cursor + 1 ..][0..2];
        const byte = std.fmt.parseInt(u8, hex, 16) catch return error.Malformed;
        const kept = whole_uri and std.mem.indexOfScalar(u8, reserved, byte) != null;

        try out.appendSlice(allocator, if (kept) text[cursor..][0..3] else &.{byte});
        cursor += 3;
    }

    if (!std.unicode.utf8ValidateSlice(out.items)) {
        return error.Malformed;
    }

    std.debug.assert(out.items.len <= text.len);

    return out.toOwnedSlice(allocator);
}

fn expect_coded(want: []const u8, got: Error![]u8) !void {
    const owned = try got;
    defer std.testing.allocator.free(owned);

    try std.testing.expectEqualStrings(want, owned);
}

test "encode like JS" {
    const allocator = std.testing.allocator;

    try expect_coded("a%20b%26c%2Fd", encode_uri_component(allocator, "a b&c/d"));
    try expect_coded("%C5%82%C3%B3d%C5%BA", encode_uri_component(allocator, "łódź"));
    try expect_coded("-_.!~*'()", encode_uri_component(allocator, "-_.!~*'()"));
    try std.testing.expectError(error.Malformed, encode_uri_component(allocator, "\xFF"));
}

test "decode like JS" {
    const allocator = std.testing.allocator;

    try expect_coded("łódź a/b", decode_uri_component(allocator, "%C5%82%C3%B3d%C5%BA%20a%2Fb"));
    try expect_coded("", decode_uri_component(allocator, ""));
    try std.testing.expectError(error.Malformed, decode_uri_component(allocator, "%E"));
    try std.testing.expectError(error.Malformed, decode_uri_component(allocator, "%ZZ"));
    try std.testing.expectError(error.Malformed, decode_uri_component(allocator, "%FF"));
    try std.testing.expectError(error.Malformed, decode_uri_component(allocator, "%C5"));
}
