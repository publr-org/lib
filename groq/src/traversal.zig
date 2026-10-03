//! Traversals (GROQ-1.revision5, section 3.11): each step's shape (plain, element, array,
//! projection), how two steps combine (join, map, flat map, inner map), and each step
//! applied to a value. `*[filter]` asks the dataset for candidates, narrowed by the
//! filter's hints.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const evaluate_module = @import("evaluate.zig");
const hints = @import("hints.zig");

const Index = tree.Index;
const Step = tree.Step;
const Value = value_module.Value;
const Context = evaluate_module.Context;
const Scope = evaluate_module.Scope;
const Error = evaluate_module.Error;
const depth_max = evaluate_module.depth_max;

/// The traversal of `steps` from the value of `base_index`. `*`, an array literal or a pipe
/// call starts as if `[]` came first (section 7.2).
pub fn traversal_of(
    context: *Context,
    base_index: Index,
    steps: []const Step,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const from_everything = context.query.node(base_index) == .everything;
    const base: Value = if (from_everything and steps.len > 0 and steps[0] == .filter) blk: {
        const given = try hints.of(context, steps[0].filter, scope, depth);

        break :blk .{ .array = try context.dataset.candidates(context.arena, given) };
    } else try evaluate_module.evaluate(context, base_index, scope, depth);
    const implicit = switch (context.query.node(base_index)) {
        .everything, .array, .pipe => true,
        else => false,
    };

    if (implicit) {
        const all = try context.arena.alloc(Step, steps.len + 1);

        all[0] = .array_postfix;
        @memcpy(all[1..], steps);

        return traverse(context, all, base, scope, depth);
    }

    return traverse(context, steps, base, scope, depth);
}

/// What a run of steps works on and returns: arrays or plain values.
const Class = struct { takes_array: bool, gives_array: bool };

const Mode = enum { join, map, flat_map, inner_map };

fn class_of(steps: []const Step) Class {
    std.debug.assert(steps.len > 0);

    var class = own_class(steps[steps.len - 1]);
    var index = steps.len - 1;

    while (index > 0) {
        index -= 1;
        class = combined(steps[index], class).class;
    }

    return class;
}

fn own_class(step: Step) Class {
    std.debug.assert(step != .element or @abs(step.element) <= 9_000_000_000_000_000);

    return switch (step.shape()) {
        .plain, .projection => .{ .takes_array = false, .gives_array = false },
        .element => .{ .takes_array = true, .gives_array = false },
        .array => .{ .takes_array = true, .gives_array = true },
    };
}

/// How a step combines with the run after it (TraversalPlain, TraversalArray,
/// TraversalArraySource, TraversalArrayTarget), and what the two together are.
fn combined(first: Step, rest: Class) struct { mode: Mode, class: Class } {
    std.debug.assert(first != .element or @abs(first.element) <= 9_000_000_000_000_000);

    return switch (first.shape()) {
        .plain => .{ .mode = .join, .class = .{
            .takes_array = false,
            .gives_array = rest.gives_array,
        } },
        .element => .{ .mode = .join, .class = .{
            .takes_array = true,
            .gives_array = rest.gives_array,
        } },
        .array => if (rest.takes_array)
            .{ .mode = .join, .class = .{ .takes_array = true, .gives_array = rest.gives_array } }
        else
            .{
                .mode = if (rest.gives_array) .flat_map else .map,
                .class = .{ .takes_array = true, .gives_array = true },
            },
        .projection => if (rest.takes_array)
            .{
                .mode = .inner_map,
                .class = .{ .takes_array = true, .gives_array = rest.gives_array },
            }
        else
            .{ .mode = .join, .class = .{ .takes_array = false, .gives_array = rest.gives_array } },
    };
}

fn traverse(
    context: *Context,
    steps: []const Step,
    base: Value,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    if (depth >= depth_max) {
        return error.TooDeep;
    }

    if (steps.len == 0) {
        return base;
    }

    if (steps.len == 1) {
        return apply(context, steps[0], base, scope, depth);
    }

    const rest = steps[1..];
    const mode = combined(steps[0], class_of(rest)).mode;
    const inner = depth + 1;

    switch (mode) {
        .join => {
            const stepped = try apply(context, steps[0], base, scope, inner);

            return traverse(context, rest, stepped, scope, inner);
        },
        .map, .flat_map => {
            const stepped = try apply(context, steps[0], base, scope, inner);

            if (stepped != .array) {
                return .null;
            }

            var items: std.ArrayList(Value) = .empty;

            for (stepped.array) |item| {
                const each = try traverse(context, rest, item, scope, inner);

                // Flat-mapped results that are not arrays are kept as they are, as the
                // conformance suite has it (`integers[].attr[]` is `[null, null, null]`).
                if (mode == .flat_map and each == .array) {
                    try items.appendSlice(context.arena, each.array);
                } else {
                    try items.append(context.arena, each);
                }
            }

            return .{ .array = items.items };
        },
        .inner_map => {
            if (base != .array) {
                return .null;
            }

            const mapped = try context.arena.alloc(Value, base.array.len);

            for (base.array, mapped) |item, *each| {
                each.* = try apply(context, steps[0], item, scope, inner);
            }

            return traverse(context, rest, .{ .array = mapped }, scope, inner);
        },
    }
}

fn apply(context: *Context, step: Step, base: Value, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    return switch (step) {
        .attribute => |name| evaluate_module.attribute_of(base, name),
        .element => |index| element_of(base, index),
        .slice => |slice| slice_of(base, slice.start, slice.end, slice.exclusive),
        .filter => |predicate| filter_of(context, base, predicate, scope, depth),
        .array_postfix => if (base == .array) base else .null,
        .projection => |attributes| {
            if (base != .object) {
                return .null;
            }

            const inner: Scope = .{ .this = base, .parent = scope };

            return evaluate_module.object_of(context, attributes, &inner, depth);
        },
        .dereference => |name| dereference_of(context, base, name),
    };
}

fn element_of(base: Value, given: i64) Value {
    std.debug.assert(base != .number or std.math.isFinite(base.number));

    if (base != .array) {
        return .null;
    }

    const length: i64 = @intCast(base.array.len);
    const index = if (given < 0) given + length else given;

    if (index < 0 or index >= length) {
        return .null;
    }

    return base.array[@intCast(index)];
}

/// A negative end counts from the back; the inclusive end moves one on; both are then
/// held within the array, and nothing is taken when the start is not before the end.
fn slice_of(base: Value, start_given: i64, end_given: i64, exclusive: bool) Value {
    std.debug.assert(base != .number or std.math.isFinite(base.number));

    if (base != .array) {
        return .null;
    }

    const length: i64 = @intCast(base.array.len);
    var start = if (start_given < 0) start_given + length else start_given;
    var end = if (end_given < 0) end_given + length else end_given;

    if (!exclusive) {
        end += 1;
    }

    start = std.math.clamp(start, 0, length);
    end = std.math.clamp(end, 0, length);

    if (start >= end) {
        return .{ .array = &.{} };
    }

    return .{ .array = base.array[@intCast(start)..@intCast(end)] };
}

fn filter_of(
    context: *Context,
    base: Value,
    predicate: Index,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    if (base != .array) {
        return base;
    }

    var kept: std.ArrayList(Value) = .empty;

    for (base.array) |item| {
        const inner: Scope = .{ .this = item, .parent = scope };
        const matched = try evaluate_module.evaluate(context, predicate, &inner, depth);

        if (matched.is_true()) {
            try kept.append(context.arena, item);
        }
    }

    return .{ .array = kept.items };
}

fn dereference_of(context: *Context, base: Value, name: ?[]const u8) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    const id: []const u8 = switch (base) {
        .object => |object| blk: {
            const reference = object.get("_ref") orelse return .null;

            break :blk if (reference == .string) reference.string else return .null;
        },
        .string => |text| if (context.strings_are_references) text else return .null,
        else => return .null,
    };
    const found = switch (try context.dataset.find(context.arena, id)) {
        .document => |document| document,
        .missing => return .null,
        .unreadable => |reason| {
            try context.problems.append(context.arena, .{ .id = id, .reason = reason });
            return .null;
        },
    };

    if (name) |attribute| {
        return evaluate_module.attribute_of(found, attribute);
    }

    return found;
}
