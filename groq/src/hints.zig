//! What a filter on `*` says about the documents it can match, for a dataset to read fewer:
//! its top-level `&&` clauses `attribute == value` and `attribute in [values]` whose value
//! does not depend on the document (a literal, a `$param`, `^.field`). The filter is still
//! applied in full afterwards; hints only narrow.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const evaluate_module = @import("evaluate.zig");
const dataset_module = @import("dataset.zig");

const Index = tree.Index;
const Value = value_module.Value;
const Hint = dataset_module.Hint;
const Context = evaluate_module.Context;
const Scope = evaluate_module.Scope;

pub const hints_max: u32 = 16;

pub fn of(
    context: *Context,
    predicate: Index,
    scope: *const Scope,
    depth: u32,
) evaluate_module.Error![]const Hint {
    var found: std.ArrayList(Hint) = .empty;
    var pending: [64]Index = undefined;
    var count: u32 = 1;

    pending[0] = predicate;

    // A document's own scope: `^` inside the filter is the scope the filter runs in.
    const element: Scope = .{ .this = .null, .parent = scope };

    while (count > 0 and found.items.len < hints_max) {
        count -= 1;

        const node = context.query.node(pending[count]);

        switch (node) {
            .group => |inner| {
                pending[count] = inner;
                count += 1;
            },
            .binary => |binary| switch (binary.operator) {
                .and_ => if (count + 2 <= pending.len) {
                    pending[count] = binary.left;
                    pending[count + 1] = binary.right;
                    count += 2;
                },
                .equal, .in_ => if (try hint_of(context, binary, &element, depth)) |hint| {
                    try found.append(context.arena, hint);
                },
                else => {},
            },
            else => {},
        }
    }

    return found.items;
}

fn hint_of(
    context: *Context,
    binary: @FieldType(tree.Node, "binary"),
    element: *const Scope,
    depth: u32,
) evaluate_module.Error!?Hint {
    const left = context.query.node(binary.left);
    const right = context.query.node(binary.right);
    var attribute: []const u8 = undefined;
    var other: Index = undefined;

    const field_first = left == .this_attribute and outer(context, binary.right, 0);
    const field_second = binary.operator == .equal and right == .this_attribute and
        outer(context, binary.left, 0);

    if (field_first) {
        attribute = left.this_attribute;
        other = binary.right;
    } else if (field_second) {
        attribute = right.this_attribute;
        other = binary.left;
    } else {
        return null;
    }

    const held = try evaluate_module.evaluate(context, other, element, depth);

    if (binary.operator == .equal) {
        if (!scalar(held)) {
            return null;
        }

        const one = try context.arena.alloc(Value, 1);

        one[0] = held;

        return .{ .attribute = attribute, .values = one };
    }

    if (held != .array) {
        return null;
    }

    for (held.array) |item| {
        if (!scalar(item)) {
            return null;
        }
    }

    return .{ .attribute = attribute, .values = held.array };
}

fn scalar(value: Value) bool {
    return value == .string or value == .number or value == .boolean;
}

/// Whether a value is the same for every document: no `@`, no attribute of the document.
fn outer(context: *Context, index: Index, depth: u32) bool {
    std.debug.assert(context.query.root < context.query.nodes.len);

    if (depth > 16) {
        return false;
    }

    return switch (context.query.node(index)) {
        .literal, .param => true,
        .parent => true,
        .group => |inner| outer(context, inner, depth + 1),
        .negate, .positive => |inner| outer(context, inner, depth + 1),
        .array => |elements| all_outer(context, elements, depth),
        .traversal => |traversal| context.query.node(traversal.base) == .parent and
            only_attributes(traversal.steps),
        else => false,
    };
}

fn all_outer(context: *Context, elements: []const tree.Element, depth: u32) bool {
    std.debug.assert(depth <= 16);

    for (elements) |element| {
        if (!outer(context, element.value, depth + 1)) {
            return false;
        }
    }

    return true;
}

/// `^.author.name`: attribute steps only.
fn only_attributes(steps: []const tree.Step) bool {
    std.debug.assert(steps.len > 0);

    for (steps) |step| {
        if (step != .attribute) {
            return false;
        }
    }

    return true;
}
