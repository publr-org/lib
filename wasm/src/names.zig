//! The names a module imports and exports, read from its bytes without loading it: what it
//! asks of its host, and what it marks for whoever builds it.
const std = @import("std");
const section = @import("section.zig");

const import_id: u8 = 2;
const export_id: u8 = 7;
/// How many imports or exports one module may list.
pub const names_max: u32 = 1 << 14;

pub const Error = section.ParseError || error{OutOfMemory};

const Kind = enum(u8) { function, table, memory, global, tag };

/// The functions the module imports from `module_name` (`env`), by name, in its order.
pub fn imported_functions(
    arena: std.mem.Allocator,
    bytes: []const u8,
    module_name: []const u8,
) Error![]const []const u8 {
    std.debug.assert(module_name.len > 0);

    const body = try section.body_of(bytes, import_id) orelse return &.{};
    var offset: u32 = 0;
    const count = try counted(body, &offset);
    var found: std.ArrayList([]const u8) = .empty;
    var index: u32 = 0;

    while (index < count) : (index += 1) {
        const module = try name_at(body, &offset);
        const name = try name_at(body, &offset);
        const kind = try kind_at(body, &offset);

        try skip_import(body, &offset, kind);

        if (kind == .function and std.mem.eql(u8, module, module_name)) {
            try found.append(arena, name);
        }
    }

    std.debug.assert(found.items.len <= count);

    return found.items;
}

/// The names of the module's exports that start with `prefix`, the prefix taken off.
pub fn exported_with(
    arena: std.mem.Allocator,
    bytes: []const u8,
    prefix: []const u8,
) Error![]const []const u8 {
    std.debug.assert(prefix.len > 0);

    const body = try section.body_of(bytes, export_id) orelse return &.{};
    var offset: u32 = 0;
    const count = try counted(body, &offset);
    var found: std.ArrayList([]const u8) = .empty;
    var index: u32 = 0;

    while (index < count) : (index += 1) {
        const name = try name_at(body, &offset);

        _ = try kind_at(body, &offset);
        _ = try section.read_number(body, &offset);

        if (name.len > prefix.len and std.mem.startsWith(u8, name, prefix)) {
            try found.append(arena, name[prefix.len..]);
        }
    }

    std.debug.assert(found.items.len <= count);

    return found.items;
}

fn counted(body: []const u8, offset: *u32) section.ParseError!u32 {
    std.debug.assert(offset.* == 0);

    const count = try section.read_number(body, offset);

    if (count > names_max) {
        return error.Malformed;
    }

    return count;
}

fn name_at(body: []const u8, offset: *u32) section.ParseError![]const u8 {
    std.debug.assert(offset.* <= body.len);

    const len = try section.read_number(body, offset);

    if (len > body.len - offset.*) {
        return error.Malformed;
    }

    const name = body[offset.* .. offset.* + len];
    offset.* += len;

    return name;
}

fn kind_at(body: []const u8, offset: *u32) section.ParseError!Kind {
    std.debug.assert(offset.* <= body.len);

    if (offset.* == body.len) {
        return error.Malformed;
    }

    const byte = body[offset.*];
    offset.* += 1;

    return std.enums.fromInt(Kind, byte) orelse error.Malformed;
}

/// Past an import's description: a function's type, a table's or a memory's limits, a
/// global's type, a tag's.
fn skip_import(body: []const u8, offset: *u32, kind: Kind) section.ParseError!void {
    std.debug.assert(offset.* <= body.len);

    switch (kind) {
        .function => {
            _ = try section.read_number(body, offset);
        },
        .table => {
            try skip_bytes(body, offset, 1);
            try skip_limits(body, offset);
        },
        .memory => try skip_limits(body, offset),
        .global => try skip_bytes(body, offset, 2),
        .tag => {
            try skip_bytes(body, offset, 1);
            _ = try section.read_number(body, offset);
        },
    }
}

fn skip_limits(body: []const u8, offset: *u32) section.ParseError!void {
    std.debug.assert(offset.* <= body.len);

    if (offset.* == body.len) {
        return error.Malformed;
    }

    const flags = body[offset.*];
    offset.* += 1;

    _ = try section.read_number(body, offset);

    if (flags & 1 == 1) {
        _ = try section.read_number(body, offset);
    }
}

fn skip_bytes(body: []const u8, offset: *u32, count: u32) section.ParseError!void {
    std.debug.assert(count > 0);

    if (count > body.len - offset.*) {
        return error.Malformed;
    }

    offset.* += count;
}

const header = "\x00asm\x01\x00\x00\x00";

test "a module's imported functions are listed by module, other kinds skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // (import "env" "publr_call" (func 0)) (import "env" "memory" (memory 1 2))
    // (import "other" "x" (func 0)) (import "env" "publr_emit" (func 0))
    const imports = "\x02\x3c\x04" ++
        "\x03env\x0apublr_call\x00\x00" ++
        "\x03env\x06memory\x02\x01\x01\x02" ++
        "\x05other\x01x\x00\x00" ++
        "\x03env\x0apublr_emit\x00\x00";
    const module = header ++ "\x01\x04\x01\x60\x00\x00" ++ imports;
    const found = try imported_functions(arena_state.allocator(), module, "env");

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("publr_call", found[0]);
    try std.testing.expectEqualStrings("publr_emit", found[1]);
    try std.testing.expectEqual(@as(usize, 0), (try imported_functions(
        arena_state.allocator(),
        header,
        "env",
    )).len);
}

test "exports with a prefix are listed without it; a cut section is malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // (export "run" (func 0)) (export "publr_uses:money.texts" (global 0))
    const exports = "\x07\x20\x02" ++
        "\x03run\x00\x00" ++
        "\x16publr_uses:money.texts\x03\x00";
    const module = header ++ exports;
    const found = try exported_with(arena_state.allocator(), module, "publr_uses:");

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("money.texts", found[0]);
    try std.testing.expectError(error.Malformed, exported_with(
        arena_state.allocator(),
        module[0 .. module.len - 3],
        "publr_uses:",
    ));
}
