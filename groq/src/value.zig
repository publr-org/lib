//! GROQ's values (GROQ-1.revision5, "Data types") and how they compare ("Equality and
//! comparison"): equality, partial comparison and the total order `order()` sorts by; and
//! their JSON, both ways.

const std = @import("std");
const datetime = @import("datetime.zig");

pub const Datetime = datetime.Datetime;

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: Object,
    datetime: Datetime,
    pair: *const Pair,
    range: *const Range,

    pub const true_value: Value = .{ .boolean = true };
    pub const false_value: Value = .{ .boolean = false };

    pub fn of_bool(truth: bool) Value {
        return .{ .boolean = truth };
    }

    /// A number, `null` when it is not finite (GROQ has no Infinity or NaN).
    pub fn of_number(number: f64) Value {
        return if (std.math.isFinite(number)) .{ .number = number } else .null;
    }

    pub fn is_true(value: Value) bool {
        return value == .boolean and value.boolean;
    }
};

/// An object's attributes, in the order they were set; a key set again keeps its place.
pub const Object = struct {
    keys: []const []const u8 = &.{},
    values: []const Value = &.{},

    pub fn get(object: Object, key: []const u8) ?Value {
        std.debug.assert(object.keys.len == object.values.len);

        for (object.keys, object.values) |each, value| {
            if (std.mem.eql(u8, each, key)) {
                return value;
            }
        }

        return null;
    }
};

pub const Pair = struct { first: Value, second: Value };
pub const Range = struct { start: Value, end: Value, exclusive: bool };

/// An object built attribute by attribute: a key set twice keeps its first place and its
/// last value.
pub const ObjectBuilder = struct {
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,

    pub fn put(
        builder: *ObjectBuilder,
        arena: std.mem.Allocator,
        key: []const u8,
        value: Value,
    ) !void {
        std.debug.assert(builder.keys.items.len == builder.values.items.len);

        for (builder.keys.items, 0..) |each, index| {
            if (std.mem.eql(u8, each, key)) {
                builder.values.items[index] = value;
                return;
            }
        }

        try builder.keys.append(arena, key);
        try builder.values.append(arena, value);
    }

    pub fn object(builder: *const ObjectBuilder) Object {
        std.debug.assert(builder.keys.items.len == builder.values.items.len);

        return .{ .keys = builder.keys.items, .values = builder.values.items };
    }
};

pub const Order = enum { less, equal, greater };

/// `null` when the two cannot be compared: different types, or types without an order.
pub fn partial_compare(left: Value, right: Value) ?Order {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (std.meta.activeTag(left) != std.meta.activeTag(right)) {
        return null;
    }

    return switch (left) {
        .datetime => |time| order_of(datetime.compare(time, right.datetime)),
        .number => |number| order_of(std.math.order(number, right.number)),
        .string => |text| order_of(compare_code_points(text, right.string)),
        .boolean => |truth| order_of(std.math.order(
            @intFromBool(truth),
            @intFromBool(right.boolean),
        )),
        else => null,
    };
}

fn order_of(order: std.math.Order) Order {
    std.debug.assert(@intFromEnum(order) <= 2);

    return switch (order) {
        .lt => .less,
        .eq => .equal,
        .gt => .greater,
    };
}

/// UTF-8 compares byte by byte in code point order.
fn compare_code_points(left: []const u8, right: []const u8) std.math.Order {
    std.debug.assert(left.len <= std.math.maxInt(u32));

    return std.mem.order(u8, left, right);
}

pub fn equal(left: Value, right: Value) bool {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left == .null and right == .null) {
        return true;
    }

    const order = partial_compare(left, right) orelse return false;

    return order == .equal;
}

fn type_order(value: Value) u8 {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    return switch (value) {
        .datetime => 1,
        .number => 2,
        .string => 3,
        .boolean => 4,
        else => 5,
    };
}

pub fn total_compare(left: Value, right: Value) Order {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    const left_order = type_order(left);
    const right_order = type_order(right);

    if (left_order != right_order) {
        return order_of(std.math.order(left_order, right_order));
    }

    return partial_compare(left, right) orelse .equal;
}

/// A JSON value as a GROQ value; objects keep their key order.
pub fn from_json(arena: std.mem.Allocator, json: std.json.Value) error{OutOfMemory}!Value {
    std.debug.assert(json != .number_string or json.number_string.len > 0);

    return switch (json) {
        .null => .null,
        .bool => |truth| .{ .boolean = truth },
        .integer => |number| .{ .number = @floatFromInt(number) },
        .float => |number| Value.of_number(number),
        .number_string => |text| Value.of_number(std.fmt.parseFloat(f64, text) catch return .null),
        .string => |text| .{ .string = text },
        .array => |array| {
            const items = try arena.alloc(Value, array.items.len);

            for (array.items, items) |item, *value| {
                value.* = try from_json(arena, item);
            }

            return .{ .array = items };
        },
        .object => |object| {
            const keys = try arena.alloc([]const u8, object.count());
            const held = try arena.alloc(Value, object.count());
            var entries = object.iterator();
            var index: u32 = 0;

            while (entries.next()) |entry| : (index += 1) {
                keys[index] = entry.key_ptr.*;
                held[index] = try from_json(arena, entry.value_ptr.*);
            }

            return .{ .object = .{ .keys = keys, .values = held } };
        },
    };
}

/// The value as JSON: a datetime as RFC 3339 text, a pair as `first => second`, a range as
/// `start..end` (or `start...end`).
pub fn write_json(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: Value,
) error{ WriteFailed, OutOfMemory }!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .boolean => |truth| try writer.writeAll(if (truth) "true" else "false"),
        .number => |number| try write_number(writer, number),
        .string => |text| try std.json.Stringify.encodeJsonString(text, .{}, writer),
        .datetime => |time| {
            var buffer: [40]u8 = undefined;

            try std.json.Stringify.encodeJsonString(datetime.format(&buffer, time), .{}, writer);
        },
        .array => |items| {
            try writer.writeByte('[');

            for (items, 0..) |item, index| {
                if (index > 0) {
                    try writer.writeByte(',');
                }

                try write_json(arena, writer, item);
            }

            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');

            for (object.keys, object.values, 0..) |key, item, index| {
                if (index > 0) {
                    try writer.writeByte(',');
                }

                try std.json.Stringify.encodeJsonString(key, .{}, writer);
                try writer.writeByte(':');
                try write_json(arena, writer, item);
            }

            try writer.writeByte('}');
        },
        .pair, .range => {
            var buffer: std.Io.Writer.Allocating = .init(arena);

            try write_compound(arena, &buffer.writer, value);
            try std.json.Stringify.encodeJsonString(buffer.written(), .{}, writer);
        },
    }
}

fn write_compound(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: Value,
) error{ WriteFailed, OutOfMemory }!void {
    switch (value) {
        .pair => |pair| {
            try write_json(arena, writer, pair.first);
            try writer.writeAll(" => ");
            try write_json(arena, writer, pair.second);
        },
        .range => |range| {
            try write_json(arena, writer, range.start);
            try writer.writeAll(if (range.exclusive) "..." else "..");
            try write_json(arena, writer, range.end);
        },
        else => unreachable,
    }
}

/// A whole number without a fraction (`3`, not `3e0`); any other in its shortest form.
pub fn write_number(writer: *std.Io.Writer, number: f64) error{WriteFailed}!void {
    std.debug.assert(std.math.isFinite(number));

    const whole = @floor(number) == number and @abs(number) < 9.007199254740992e15;

    if (whole) {
        return writer.print("{d}", .{@as(i64, @intFromFloat(number))});
    }

    try writer.print("{d}", .{number});
}

pub fn to_json(arena: std.mem.Allocator, value: Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);

    try write_json(arena, &out.writer, value);

    return out.written();
}

test "equality and order follow the spec: null equals null, other types do not mix" {
    try std.testing.expect(equal(.null, .null));
    try std.testing.expect(!equal(.{ .number = 1 }, .null));
    try std.testing.expect(equal(.{ .number = 1 }, .{ .number = 1.0 }));
    try std.testing.expect(!equal(.{ .array = &.{} }, .{ .array = &.{} }));
    try std.testing.expect(partial_compare(.{ .number = 2 }, .{ .string = "1" }) == null);
    try std.testing.expectEqual(Order.less, total_compare(.{ .number = 9 }, .{ .string = "a" }));
    try std.testing.expectEqual(Order.equal, total_compare(.null, .{ .array = &.{} }));
}
