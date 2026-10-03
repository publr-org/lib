//! The pipe functions (GROQ-1.revision5, section 13): `order()` by the total order, and
//! `score()` with the score evaluation of section 3.9.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const evaluate_module = @import("evaluate.zig");
const functions = @import("functions.zig");
const text_match = @import("text_match.zig");

const Index = tree.Index;
const Value = value_module.Value;
const Context = evaluate_module.Context;
const Scope = evaluate_module.Scope;
const Error = evaluate_module.Error;
const argument = functions.argument;
const is = functions.is;

pub fn pipe(
    context: *Context,
    base: []const Value,
    called: tree.Call,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    if (std.mem.eql(u8, called.name, "order")) {
        return order(context, base, called.arguments, scope, depth);
    }

    return score(context, base, called.arguments, scope, depth);
}

const Keyed = struct { item: Value, keys: []const Value, position: u32 };

/// Sorted by the arguments' values (`asc` by default, `desc` reversed), by TotalCompare;
/// equal items keep their order.
fn order(
    context: *Context,
    base: []const Value,
    arguments: []const Index,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const keyed = try context.arena.alloc(Keyed, base.len);
    const descending = try context.arena.alloc(bool, arguments.len);

    for (arguments, descending) |each, *reversed| {
        reversed.* = context.query.node(each) == .desc;
    }

    for (base, keyed, 0..) |item, *entry, position| {
        const inner: Scope = .{ .this = item, .parent = scope };
        const keys = try context.arena.alloc(Value, arguments.len);

        for (arguments, keys) |each, *key| {
            const node = context.query.node(each);
            const sorted_by = switch (node) {
                .asc, .desc => |held| held,
                else => each,
            };

            key.* = try evaluate_module.evaluate(context, sorted_by, &inner, depth);
        }

        entry.* = .{ .item = item, .keys = keys, .position = @intCast(position) };
    }

    std.mem.sort(Keyed, keyed, descending, before);

    const sorted = try context.arena.alloc(Value, base.len);

    for (keyed, sorted) |entry, *item| {
        item.* = entry.item;
    }

    return .{ .array = sorted };
}

fn before(descending: []const bool, left: Keyed, right: Keyed) bool {
    std.debug.assert(left.keys.len == right.keys.len);

    for (left.keys, right.keys, descending) |left_key, right_key, reversed| {
        const compared = value_module.total_compare(left_key, right_key);

        if (compared == .equal) {
            continue;
        }

        return if (reversed) compared == .greater else compared == .less;
    }

    return left.position < right.position;
}

/// Each object gets `_score`: its score so far (0 when it has none) plus each argument's
/// score; then all, highest score first.
fn score(
    context: *Context,
    base: []const Value,
    arguments: []const Index,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const scored = try context.arena.alloc(Keyed, base.len);

    for (base, scored, 0..) |item, *entry, position| {
        entry.* = .{ .item = item, .keys = &.{}, .position = @intCast(position) };

        if (item != .object) {
            continue;
        }

        const inner: Scope = .{ .this = item, .parent = scope };
        const existing = item.object.get("_score");
        var sum: f64 = if (existing != null and existing.? == .number) existing.?.number else 0;

        for (arguments) |each| {
            sum += try score_of(context, each, &inner, depth);
        }

        var builder: value_module.ObjectBuilder = .{};

        for (item.object.keys, item.object.values) |key, held| {
            try builder.put(context.arena, key, held);
        }

        try builder.put(context.arena, "_score", .{ .number = sum });

        const keys = try context.arena.alloc(Value, 1);

        keys[0] = .{ .number = sum };
        entry.* = .{
            .item = .{ .object = builder.object() },
            .keys = keys,
            .position = @intCast(position),
        };
    }

    std.mem.sort(Keyed, scored, {}, higher_score);

    const sorted = try context.arena.alloc(Value, base.len);

    for (scored, sorted) |entry, *item| {
        item.* = entry.item;
    }

    return .{ .array = sorted };
}

fn higher_score(_: void, left: Keyed, right: Keyed) bool {
    std.debug.assert(left.keys.len == right.keys.len);

    const left_score = if (left.keys.len > 0) left.keys[0].number else 0;
    const right_score = if (right.keys.len > 0) right.keys[0].number else 0;

    if (left_score != right_score) {
        return left_score > right_score;
    }

    return left.position < right.position;
}

/// EvaluateScore (section 3.9): a true predicate scores 1, `&&` and `||` the sum of their
/// true clauses, `boost(predicate, amount)` adds the amount when the predicate holds,
/// `match` its own score.
fn score_of(context: *Context, index: Index, scope: *const Scope, depth: u32) Error!f64 {
    std.debug.assert(context.query.root < context.query.nodes.len);

    const node = context.query.node(index);

    switch (node) {
        .group => |inner| return score_of(context, inner, scope, depth + 1),
        .binary => |binary| {
            if (binary.operator == .and_ or binary.operator == .or_) {
                const left = try score_of(context, binary.left, scope, depth + 1);
                const right = try score_of(context, binary.right, scope, depth + 1);
                const holds = try evaluate_module.evaluate(context, index, scope, depth);

                return if (holds.is_true()) left + right else 0;
            }

            if (binary.operator == .match) {
                const left = try evaluate_module.evaluate(context, binary.left, scope, depth);
                const right = try evaluate_module.evaluate(context, binary.right, scope, depth);

                return text_match.score(context.arena, left, right);
            }
        },
        .call => |called| {
            if (is(called, "global", "boost") and called.arguments.len == 2) {
                const base = try score_of(context, called.arguments[0], scope, depth + 1);
                const amount = try argument(context, called, 1, scope, depth);
                const boost = if (amount == .number) amount.number else 0;

                return if (base > 0) base + boost else 0;
            }
        },
        else => {},
    }

    const holds = try evaluate_module.evaluate(context, index, scope, depth);

    return if (holds.is_true()) 1 else 0;
}
