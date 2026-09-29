//! Custom sections of a WebAssembly binary, read and appended without loading the module:
//! what a host inspects before it decides to run anything.
const std = @import("std");

const magic = "\x00asm";
const version = "\x01\x00\x00\x00";
const custom_id: u8 = 0;
const sections_max: u32 = 1 << 16;
const leb_bytes_max: u32 = 5;

pub const name_len_max: u32 = 256;

pub const ParseError = error{Malformed};

/// The payload of the first custom section called `name`, or null when there is none.
/// `bytes` must be a whole module: a truncated or foreign file is `error.Malformed`.
pub fn find(bytes: []const u8, name: []const u8) ParseError!?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= name_len_max);

    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], magic)) {
        return error.Malformed;
    }

    if (!std.mem.eql(u8, bytes[4..8], version)) {
        return error.Malformed;
    }

    var offset: u32 = 8;
    var count: u32 = 0;

    while (offset < bytes.len) : (count += 1) {
        if (count == sections_max) {
            return error.Malformed;
        }

        const id = bytes[offset];
        offset += 1;

        const size = try read_leb(bytes, &offset);

        if (size > bytes.len - offset) {
            return error.Malformed;
        }

        const body = bytes[offset .. offset + size];
        offset += size;

        if (id == custom_id) {
            if (try custom_payload(body, name)) |payload| {
                return payload;
            }
        }
    }

    std.debug.assert(offset == bytes.len);

    return null;
}

fn custom_payload(body: []const u8, name: []const u8) ParseError!?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(body.len <= std.math.maxInt(u32));

    var offset: u32 = 0;
    const name_len = try read_leb(body, &offset);

    if (name_len > body.len - offset) {
        return error.Malformed;
    }

    const found = body[offset .. offset + name_len];

    if (!std.mem.eql(u8, found, name)) {
        return null;
    }

    return body[offset + name_len ..];
}

/// Writes a custom section called `name` holding `payload`; appended to a module, the
/// module stays valid (custom sections may come anywhere).
pub fn write(writer: *std.Io.Writer, name: []const u8, payload: []const u8) !void {
    std.debug.assert(name.len > 0 and name.len <= name_len_max);
    std.debug.assert(payload.len < std.math.maxInt(u32) - name_len_max);

    const name_leb_len = leb_len(@intCast(name.len));
    const size: u32 = @intCast(name_leb_len + name.len + payload.len);

    try writer.writeByte(custom_id);
    try write_leb(writer, size);
    try write_leb(writer, @intCast(name.len));
    try writer.writeAll(name);
    try writer.writeAll(payload);
}

fn read_leb(bytes: []const u8, offset: *u32) ParseError!u32 {
    std.debug.assert(offset.* <= bytes.len);
    std.debug.assert(leb_bytes_max == 5);

    var value: u32 = 0;
    var index: u32 = 0;

    while (index < leb_bytes_max) : (index += 1) {
        if (offset.* >= bytes.len) {
            return error.Malformed;
        }

        const byte = bytes[offset.*];
        offset.* += 1;

        const shift: u5 = @intCast(index * 7);
        const bits: u32 = byte & 0x7f;

        if (index == leb_bytes_max - 1 and bits > 0x0f) {
            return error.Malformed;
        }

        value |= bits << shift;

        if (byte & 0x80 == 0) {
            return value;
        }
    }

    return error.Malformed;
}

fn write_leb(writer: *std.Io.Writer, value: u32) !void {
    std.debug.assert(leb_len(value) <= leb_bytes_max);
    std.debug.assert(leb_len(value) > 0);

    var rest = value;

    while (true) {
        const byte: u8 = @intCast(rest & 0x7f);
        rest >>= 7;

        if (rest == 0) {
            return writer.writeByte(byte);
        }

        try writer.writeByte(byte | 0x80);
    }
}

fn leb_len(value: u32) u32 {
    var len: u32 = 1;
    var rest = value >> 7;

    while (rest != 0) : (rest >>= 7) {
        len += 1;
    }

    std.debug.assert(len >= 1);
    std.debug.assert(len <= leb_bytes_max);

    return len;
}

test "a custom section written after a module is found again, others are skipped" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll(magic ++ version);
    // A type section with one `() -> ()` function type, so a known section is skipped.
    try writer.writeAll(&.{ 1, 4, 1, 0x60, 0, 0 });
    try write(&writer, "other", "ignored");
    try write(&writer, "publr", "{\"name\":\"hello\"}" ** 10);

    const module = writer.buffered();
    const payload = (try find(module, "publr")).?;

    try std.testing.expectEqualStrings("{\"name\":\"hello\"}" ** 10, payload);
    try std.testing.expectEqualStrings("ignored", (try find(module, "other")).?);
    try std.testing.expect(try find(module, "missing") == null);
}

test "truncated, foreign and oversized input is malformed, never read past the end" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll(magic ++ version);
    try write(&writer, "publr", "abc");

    const module = writer.buffered();

    try std.testing.expectError(error.Malformed, find(module[0 .. module.len - 1], "publr"));
    try std.testing.expectError(error.Malformed, find("not wasm at all", "publr"));
    try std.testing.expectError(error.Malformed, find(magic ++ version ++ "\x00\xff\xff\xff\xff\x7f", "x"));
    try std.testing.expect(try find(magic ++ version, "publr") == null);
}

test "leb128 lengths: one byte up to 127, two from 128" {
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_leb(&writer, 300);

    var offset: u32 = 0;

    try std.testing.expectEqual(@as(u32, 2), leb_len(300));
    try std.testing.expectEqual(@as(u32, 1), leb_len(127));
    try std.testing.expectEqual(@as(u32, 300), try read_leb(writer.buffered(), &offset));
    try std.testing.expectEqual(@as(u32, 2), offset);
}
