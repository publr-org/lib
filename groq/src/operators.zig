//! GROQ's arithmetic, concatenation and the datetime operators (GROQ-1.revision5,
//! "Operators"), on values: shared by evaluation and by constant evaluation.

const std = @import("std");
const value_module = @import("value.zig");
const datetime = @import("datetime.zig");

const Value = value_module.Value;

pub fn plus(arena: std.mem.Allocator, left: Value, right: Value) !Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left == .string and right == .string) {
        return .{ .string = try std.mem.concat(arena, u8, &.{ left.string, right.string }) };
    }

    if (left == .number and right == .number) {
        return Value.of_number(left.number + right.number);
    }

    if (left == .array and right == .array) {
        return .{ .array = try std.mem.concat(arena, Value, &.{ left.array, right.array }) };
    }

    if (left == .object and right == .object) {
        var merged: value_module.ObjectBuilder = .{};

        for (left.object.keys, left.object.values) |key, item| {
            try merged.put(arena, key, item);
        }

        for (right.object.keys, right.object.values) |key, item| {
            try merged.put(arena, key, item);
        }

        return .{ .object = merged.object() };
    }

    if (left == .datetime and right == .number) {
        return moved(left.datetime, right.number);
    }

    if (left == .number and right == .datetime) {
        return moved(right.datetime, left.number);
    }

    return .null;
}

fn moved(time: datetime.Datetime, seconds: f64) Value {
    const result = datetime.add_seconds(time, seconds) orelse return .null;

    return .{ .datetime = result };
}

pub fn minus(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left == .number and right == .number) {
        return Value.of_number(left.number - right.number);
    }

    if (left == .datetime and right == .datetime) {
        return Value.of_number(datetime.difference(left.datetime, right.datetime));
    }

    if (left == .datetime and right == .number) {
        return moved(left.datetime, -right.number);
    }

    return .null;
}

pub fn star(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left != .number or right != .number) {
        return .null;
    }

    return Value.of_number(left.number * right.number);
}

pub fn slash(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left != .number or right != .number) {
        return .null;
    }

    return Value.of_number(left.number / right.number);
}

/// The remainder takes the sign of the dividend, as in JavaScript.
pub fn percent(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left != .number or right != .number) {
        return .null;
    }

    if (right.number == 0) {
        return .null;
    }

    return Value.of_number(@rem(left.number, right.number));
}

pub fn star_star(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left != .number or right != .number) {
        return .null;
    }

    return Value.of_number(std.math.pow(f64, left.number, right.number));
}

pub fn negate(value: Value) Value {
    return if (value == .number) .{ .number = -value.number } else .null;
}

pub fn positive(value: Value) Value {
    return if (value == .number) value else .null;
}

test "operators: types that do not fit give null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sum = try plus(arena, .{ .number = 1 }, .{ .number = 2 });
    const joined = try plus(arena, .{ .string = "a" }, .{ .string = "b" });

    try std.testing.expectEqual(@as(f64, 3), sum.number);
    try std.testing.expectEqualStrings("ab", joined.string);
    try std.testing.expect(try plus(arena, .{ .number = 1 }, .null) == .null);
    try std.testing.expect(slash(.{ .number = 1 }, .{ .number = 0 }) == .null);
    try std.testing.expectEqual(@as(f64, -1), percent(.{ .number = -7 }, .{ .number = 3 }).number);
}
