//! Evaluates a GROQ query (GROQ-1.revision5, "Execution") over a dataset of JSON values:
//! every expression and operator, traversals combined by join, map, flat map and inner map
//! (section 3.11), pipe functions. Recursion is bounded by `depth_max`.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const operators = @import("operators.zig");
const functions = @import("functions.zig");
const pipes = @import("pipes.zig");
const text_match = @import("text_match.zig");
const dataset_module = @import("dataset.zig");
const traversal = @import("traversal.zig");

const Index = tree.Index;
const Value = value_module.Value;
const Datetime = value_module.Datetime;

pub const depth_max: u32 = 256;

pub const Error = error{ OutOfMemory, TooDeep, TooMuchWork, DatasetFailed, OutOfReach };

pub const Dataset = dataset_module.Dataset;

/// A reference the caller may not follow, made `null`: which record, and why.
pub const Problem = struct { id: []const u8, reason: []const u8 };

pub const Context = struct {
    arena: std.mem.Allocator,
    query: *const tree.Query,
    dataset: Dataset,
    params: value_module.Object,
    now: Datetime,
    /// Publr's references are record ids: `->` follows a string as it follows `{_ref}`.
    strings_are_references: bool = false,
    /// Evaluation steps left; each node evaluated takes one.
    work_left: u64 = std.math.maxInt(u64),
    problems: std.ArrayList(Problem) = .empty,
};

pub const Scope = struct {
    this: Value,
    parent: ?*const Scope,
};

pub fn run(context: *Context) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    const root: Scope = .{ .this = .null, .parent = null };

    return evaluate(context, context.query.root, &root, 0);
}

pub fn evaluate(context: *Context, index: Index, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    if (depth >= depth_max) {
        return error.TooDeep;
    }

    if (context.work_left == 0) {
        return error.TooMuchWork;
    }

    context.work_left -= 1;

    const inner = depth + 1;

    return switch (context.query.node(index)) {
        .literal => |literal| literal,
        .this => scope.this,
        .this_attribute => |name| attribute_of(scope.this, name),
        .everything => .{ .array = try context.dataset.everything(context.arena) },
        .parent => |levels| parent_of(scope, levels),
        .param => |name| context.params.get(name) orelse .null,
        .group => |held| evaluate(context, held, scope, inner),
        .array => |elements| array_of(context, elements, scope, inner),
        .object => |attributes| object_of(context, attributes, scope, inner),
        .call => |call| functions.call(context, call, scope, inner),
        .pipe => |pipe| pipe_of(context, pipe.base, pipe.call, scope, inner),
        .traversal => |held| traversal.traversal_of(context, held.base, held.steps, scope, inner),
        .binary => |pair| binary_of(context, pair.operator, pair.left, pair.right, scope, inner),
        .not_ => |held| not_of(try evaluate(context, held, scope, inner)),
        .negate => |held| operators.negate(try evaluate(context, held, scope, inner)),
        .positive => |held| operators.positive(try evaluate(context, held, scope, inner)),
        .range => |range| range_of(context, range.start, range.end, range.exclusive, scope, inner),
        .pair => |pair| pair_of(context, pair.first, pair.second, scope, inner),
        .asc, .desc => .null,
    };
}

pub fn attribute_of(base: Value, name: []const u8) Value {
    std.debug.assert(base != .number or std.math.isFinite(base.number));

    if (base != .object) {
        return .null;
    }

    return base.object.get(name) orelse .null;
}

fn parent_of(scope: *const Scope, levels: u32) Value {
    std.debug.assert(levels > 0);

    var current: *const Scope = scope;

    for (0..levels) |_| {
        current = current.parent orelse return .null;
    }

    return current.this;
}

fn not_of(value: Value) Value {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    if (value != .boolean) {
        return .null;
    }

    return .{ .boolean = !value.boolean };
}

fn array_of(
    context: *Context,
    elements: []const tree.Element,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    var items: std.ArrayList(Value) = .empty;

    for (elements) |element| {
        const item = try evaluate(context, element.value, scope, depth);

        if (!element.spread) {
            try items.append(context.arena, item);
        } else if (item == .array) {
            try items.appendSlice(context.arena, item.array);
        }
    }

    return .{ .array = items.items };
}

pub fn object_of(
    context: *Context,
    attributes: []const tree.Attribute,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    var builder: value_module.ObjectBuilder = .{};

    for (attributes) |attribute| {
        switch (attribute) {
            .keyed, .derived => |entry| {
                const held = try evaluate(context, entry.value, scope, depth);

                try builder.put(context.arena, entry.key, held);
            },
            .spread => |spread| {
                const base = if (spread) |expression|
                    try evaluate(context, expression, scope, depth)
                else
                    scope.this;

                try spread_into(context, &builder, base);
            },
            .conditional => |conditional| {
                const condition = try evaluate(context, conditional.condition, scope, depth);

                if (condition.is_true()) {
                    const held = try evaluate(context, conditional.value, scope, depth);

                    try spread_into(context, &builder, held);
                }
            },
        }
    }

    return .{ .object = builder.object() };
}

fn spread_into(context: *Context, builder: *value_module.ObjectBuilder, base: Value) Error!void {
    std.debug.assert(context.query.root < context.query.nodes.len);

    if (base != .object) {
        return;
    }

    for (base.object.keys, base.object.values) |key, item| {
        try builder.put(context.arena, key, item);
    }
}

fn range_of(
    context: *Context,
    start_index: Index,
    end_index: Index,
    exclusive: bool,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const start = try evaluate(context, start_index, scope, depth);
    const end = try evaluate(context, end_index, scope, depth);

    if (value_module.partial_compare(start, end) == null) {
        return .null;
    }

    const range = try context.arena.create(value_module.Range);

    range.* = .{ .start = start, .end = end, .exclusive = exclusive };

    return .{ .range = range };
}

fn pair_of(
    context: *Context,
    first: Index,
    second: Index,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const pair = try context.arena.create(value_module.Pair);

    pair.* = .{
        .first = try evaluate(context, first, scope, depth),
        .second = try evaluate(context, second, scope, depth),
    };

    return .{ .pair = pair };
}

fn binary_of(
    context: *Context,
    operator: tree.Operator,
    left_index: Index,
    right_index: Index,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    if (operator == .in_) {
        if (range_node(context, right_index)) |range_index| {
            return in_range(context, left_index, range_index, scope, depth);
        }
    }

    const left = try evaluate(context, left_index, scope, depth);
    const right = try evaluate(context, right_index, scope, depth);

    return switch (operator) {
        .and_ => and_of(left, right),
        .or_ => or_of(left, right),
        .equal => .{ .boolean = value_module.equal(left, right) },
        .not_equal => .{ .boolean = !value_module.equal(left, right) },
        .less, .less_equal, .greater, .greater_equal => compared(operator, left, right),
        .in_ => in_array(left, right),
        .match => .{ .boolean = try text_match.matches(context.arena, left, right) },
        .plus => operators.plus(context.arena, left, right),
        .minus => operators.minus(left, right),
        .star => operators.star(left, right),
        .slash => operators.slash(left, right),
        .percent => operators.percent(left, right),
        .star_star => operators.star_star(left, right),
    };
}

/// The range node under any parentheses, when the node is one.
fn range_node(context: *Context, index: Index) ?Index {
    std.debug.assert(context.query.root < context.query.nodes.len);

    var at = index;

    for (0..depth_max) |_| {
        switch (context.query.node(at)) {
            .range => return at,
            .group => |inner| at = inner,
            else => return null,
        }
    }

    return null;
}

fn and_of(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    const left_false = left == .boolean and !left.boolean;
    const right_false = right == .boolean and !right.boolean;

    if (left_false or right_false) {
        return Value.false_value;
    }

    if (left != .boolean or right != .boolean) {
        return .null;
    }

    return Value.true_value;
}

fn or_of(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (left.is_true() or right.is_true()) {
        return Value.true_value;
    }

    if (left != .boolean or right != .boolean) {
        return .null;
    }

    return Value.false_value;
}

fn compared(operator: tree.Operator, left: Value, right: Value) Value {
    const order = value_module.partial_compare(left, right) orelse return .null;

    return .{ .boolean = switch (operator) {
        .less => order == .less,
        .less_equal => order != .greater,
        .greater => order == .greater,
        .greater_equal => order != .less,
        else => unreachable,
    } };
}

fn in_array(left: Value, right: Value) Value {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (right != .array) {
        return .null;
    }

    for (right.array) |item| {
        if (value_module.equal(left, item)) {
            return Value.true_value;
        }
    }

    return Value.false_value;
}

fn in_range(
    context: *Context,
    left_index: Index,
    range_index: Index,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const range = context.query.node(range_index).range;
    const left = try evaluate(context, left_index, scope, depth);
    const lower = try evaluate(context, range.start, scope, depth);
    const upper = try evaluate(context, range.end, scope, depth);
    const left_order = value_module.partial_compare(left, lower) orelse return .null;
    const right_order = value_module.partial_compare(left, upper) orelse return .null;

    if (left_order == .less or right_order == .greater) {
        return Value.false_value;
    }

    if (range.exclusive and right_order == .equal) {
        return Value.false_value;
    }

    return Value.true_value;
}

fn pipe_of(
    context: *Context,
    base_index: Index,
    call: tree.Call,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    const base = try evaluate(context, base_index, scope, depth);

    if (base != .array) {
        return .null;
    }

    return pipes.pipe(context, base.array, call, scope, depth);
}
