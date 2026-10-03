//! The `array::`, `string::` and `math::` functions (GROQ-1.revision5, section 11), and
//! `string::lower()`/`upper()` beside the global ones, as the conformance suite has them.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const evaluate_module = @import("evaluate.zig");
const functions = @import("functions.zig");

const Value = value_module.Value;
const Context = evaluate_module.Context;
const Scope = evaluate_module.Scope;
const Error = evaluate_module.Error;
const argument = functions.argument;
const string_of = functions.string_of;
const single = functions.single;

pub fn array_namespace(
    context: *Context,
    called: tree.Call,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const first = try argument(context, called, 0, scope, depth);

    if (first != .array) {
        return .null;
    }

    const items = first.array;

    if (std.mem.eql(u8, called.name, "compact")) {
        var kept: std.ArrayList(Value) = .empty;

        for (items) |item| {
            if (item != .null) {
                try kept.append(context.arena, item);
            }
        }

        return .{ .array = kept.items };
    }

    if (std.mem.eql(u8, called.name, "unique")) {
        return unique(context.arena, items);
    }

    const second = try argument(context, called, 1, scope, depth);

    if (std.mem.eql(u8, called.name, "join")) {
        return join(context.arena, items, second);
    }

    if (second != .array) {
        return .null;
    }

    for (items) |left| {
        for (second.array) |right| {
            if (comparable(left) and value_module.equal(left, right)) {
                return Value.true_value;
            }
        }
    }

    return Value.false_value;
}

/// Values equality can compare: the rest are each unique.
fn comparable(value: Value) bool {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    return switch (value) {
        .null, .boolean, .number, .string, .datetime => true,
        else => false,
    };
}

fn unique(arena: std.mem.Allocator, items: []const Value) Error!Value {
    std.debug.assert(items.len <= 1 << 30);

    var kept: std.ArrayList(Value) = .empty;

    for (items) |item| {
        const seen = comparable(item) and for (kept.items) |other| {
            if (value_module.equal(item, other)) break true;
        } else false;

        if (!seen) {
            try kept.append(arena, item);
        }
    }

    return .{ .array = kept.items };
}

fn join(arena: std.mem.Allocator, items: []const Value, separator: Value) Error!Value {
    std.debug.assert(items.len <= 1 << 30);

    if (separator != .string) {
        return .null;
    }

    var out: std.ArrayList(u8) = .empty;

    for (items, 0..) |item, position| {
        if (position > 0) {
            try out.appendSlice(arena, separator.string);
        }

        const text = try string_of(arena, item);

        if (text != .string) {
            return .null;
        }

        try out.appendSlice(arena, text.string);
    }

    return .{ .string = out.items };
}

pub fn string_namespace(
    context: *Context,
    called: tree.Call,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const first = try argument(context, called, 0, scope, depth);

    if (std.mem.eql(u8, called.name, "lower") or std.mem.eql(u8, called.name, "upper")) {
        return single(context.arena, called.name, first);
    }

    if (first != .string) {
        return .null;
    }

    const second = try argument(context, called, 1, scope, depth);

    if (second != .string) {
        return .null;
    }

    if (std.mem.eql(u8, called.name, "startsWith")) {
        return .{ .boolean = std.mem.startsWith(u8, first.string, second.string) };
    }

    return split(context.arena, first.string, second.string);
}

fn split(arena: std.mem.Allocator, text: []const u8, separator: []const u8) Error!Value {
    std.debug.assert(text.len <= 1 << 30);

    var parts: std.ArrayList(Value) = .empty;

    if (text.len == 0) {
        return .{ .array = &.{} };
    }

    if (separator.len == 0) {
        var view = std.unicode.Utf8View.init(text) catch return .null;
        var points = view.iterator();

        while (points.nextCodepointSlice()) |point| {
            try parts.append(arena, .{ .string = point });
        }

        return .{ .array = parts.items };
    }

    var pieces = std.mem.splitSequence(u8, text, separator);

    while (pieces.next()) |piece| {
        try parts.append(arena, .{ .string = piece });
    }

    return .{ .array = parts.items };
}

pub fn math_namespace(
    context: *Context,
    called: tree.Call,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const first = try argument(context, called, 0, scope, depth);

    if (first != .array) {
        return .null;
    }

    var total: f64 = 0;
    var count: u64 = 0;
    var lowest: ?f64 = null;
    var highest: ?f64 = null;

    for (first.array) |item| {
        if (item == .null) {
            continue;
        }

        if (item != .number) {
            return .null;
        }

        total += item.number;
        count += 1;
        lowest = if (lowest) |seen| @min(seen, item.number) else item.number;
        highest = if (highest) |seen| @max(seen, item.number) else item.number;
    }

    const name = called.name;

    if (std.mem.eql(u8, name, "sum")) {
        return Value.of_number(total);
    }

    if (count == 0) {
        return .null;
    }

    if (std.mem.eql(u8, name, "avg")) {
        return Value.of_number(total / @as(f64, @floatFromInt(count)));
    }

    return .{ .number = if (std.mem.eql(u8, name, "min")) lowest.? else highest.? };
}
