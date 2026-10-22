//! UTF-8 as this library reads it. Text is bytes and may be malformed: each byte that does
//! not start a well-formed sequence reads as one U+FFFD of one byte, so every position and
//! count is defined for any input. Surrogates encoded in UTF-8 are malformed.

const std = @import("std");

pub const replacement: u21 = 0xFFFD;
pub const code_point_max: u21 = 0x10FFFF;

pub const Decoded = struct {
    code_point: u21,
    /// Bytes read: 1 to 4.
    len: u3,
};

/// The code point at the start of `bytes`, which is not empty.
pub fn decode(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len > 0);

    const lead = bytes[0];
    const malformed: Decoded = .{
        .code_point = replacement,
        .len = 1,
    };

    if (lead < 0x80) {
        return .{
            .code_point = lead,
            .len = 1,
        };
    }

    const len: u3 = switch (lead) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return malformed,
    };

    if (bytes.len < len) {
        return malformed;
    }

    var code_point: u21 = lead & (@as(u8, 0x7F) >> len);

    for (bytes[1..len]) |byte| {
        if (byte & 0xC0 != 0x80) {
            return malformed;
        }

        code_point = (code_point << 6) | (byte & 0x3F);
    }

    const shortest = switch (len) {
        2 => code_point >= 0x80,
        3 => code_point >= 0x800 and (code_point < 0xD800 or code_point > 0xDFFF),
        else => code_point >= 0x10000 and code_point <= code_point_max,
    };

    if (!shortest) {
        return malformed;
    }

    return .{
        .code_point = code_point,
        .len = len,
    };
}

/// Code points one after another, each with the byte offset it starts at.
pub const Iterator = struct {
    bytes: []const u8,
    offset: u32 = 0,

    pub const Item = struct {
        code_point: u21,
        offset: u32,
        len: u3,
    };

    pub fn next(self: *Iterator) ?Item {
        std.debug.assert(self.offset <= self.bytes.len);

        if (self.offset == self.bytes.len) {
            return null;
        }

        const decoded = decode(self.bytes[self.offset..]);
        const item: Item = .{
            .code_point = decoded.code_point,
            .offset = self.offset,
            .len = decoded.len,
        };

        self.offset += decoded.len;

        return item;
    }

    /// The code point before `offset`, stepping back over it.
    pub fn previous(self: *Iterator) ?Item {
        std.debug.assert(self.offset <= self.bytes.len);

        if (self.offset == 0) {
            return null;
        }

        const start = start_before(self.bytes, self.offset);
        const decoded = decode(self.bytes[start..]);

        self.offset = start;

        return .{
            .code_point = decoded.code_point,
            .offset = start,
            .len = decoded.len,
        };
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{
        .bytes = bytes,
    };
}

/// Where the code point ending at `end` starts.
pub fn start_before(bytes: []const u8, end: u32) u32 {
    std.debug.assert(end > 0 and end <= bytes.len);

    var start = end - 1;
    var back: u32 = 0;

    while (back < 3 and start > 0 and bytes[start] & 0xC0 == 0x80) : (back += 1) {
        start -= 1;
    }

    if (start + decode(bytes[start..]).len == end) {
        return start;
    }

    return end - 1;
}

/// How many code points `bytes` holds.
pub fn count(bytes: []const u8) u32 {
    var iterator = iterate(bytes);
    var total: u32 = 0;

    while (iterator.next()) |_| {
        total += 1;
    }

    std.debug.assert(total <= bytes.len);

    return total;
}

/// The byte offset of the `index`th code point; `count(bytes)` answers `bytes.len`, past
/// it answers null.
pub fn offset_of(bytes: []const u8, index: u32) ?u32 {
    var iterator = iterate(bytes);
    var seen: u32 = 0;

    while (seen < index) : (seen += 1) {
        _ = iterator.next() orelse return null;
    }

    std.debug.assert(iterator.offset <= bytes.len);

    return iterator.offset;
}

test "decode reads every length and refuses what is malformed" {
    try std.testing.expectEqual(Decoded{ .code_point = 'a', .len = 1 }, decode("a"));
    try std.testing.expectEqual(Decoded{ .code_point = 0x142, .len = 2 }, decode("ł"));
    try std.testing.expectEqual(Decoded{ .code_point = 0x20AC, .len = 3 }, decode("€"));
    try std.testing.expectEqual(Decoded{ .code_point = 0x1F600, .len = 4 }, decode("😀"));
    try std.testing.expectEqual(replacement, decode("\xC0\x80").code_point);
    try std.testing.expectEqual(replacement, decode("\xED\xA0\x80").code_point);
    try std.testing.expectEqual(replacement, decode("\xE2\x82").code_point);
    try std.testing.expectEqual(replacement, decode("\xF4\x90\x80\x80").code_point);
    try std.testing.expectEqual(@as(u3, 1), decode("\xFF").len);
}

test "counting and offsets step over malformed bytes one at a time" {
    const text = "ał\xFF😀";

    try std.testing.expectEqual(@as(u32, 4), count(text));
    try std.testing.expectEqual(@as(?u32, 3), offset_of(text, 2));
    try std.testing.expectEqual(@as(?u32, 8), offset_of(text, 4));
    try std.testing.expectEqual(@as(?u32, null), offset_of(text, 5));

    var iterator: Iterator = .{
        .bytes = text,
        .offset = text.len,
    };

    try std.testing.expectEqual(@as(u21, 0x1F600), iterator.previous().?.code_point);
    try std.testing.expectEqual(replacement, iterator.previous().?.code_point);
    try std.testing.expectEqual(@as(u21, 0x142), iterator.previous().?.code_point);
}
