//! GROQ's functions and pipe functions (GROQ-1.revision5, sections 11 and 13): the global
//! namespace, `dateTime::`, `array::`, `string::`, `math::`, `order()` and `score()`.
//! Arguments arrive unevaluated; each function evaluates them in the scope it needs.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const evaluate_module = @import("evaluate.zig");
const datetime = @import("datetime.zig");
const namespace_functions = @import("namespaces.zig");

const Index = tree.Index;
const Value = value_module.Value;
const Context = evaluate_module.Context;
const Scope = evaluate_module.Scope;
const Error = evaluate_module.Error;

/// A function's namespace and name, with how many arguments it takes.
pub const Signature = struct {
    namespace: []const u8,
    name: []const u8,
    arguments_min: u32,
    arguments_max: u32,
};

pub const signatures = [_]Signature{
    .{ .namespace = "global", .name = "coalesce", .arguments_min = 0, .arguments_max = 1024 },
    .{ .namespace = "global", .name = "count", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "global", .name = "dateTime", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "global", .name = "defined", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "global", .name = "length", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "global", .name = "now", .arguments_min = 0, .arguments_max = 0 },
    .{ .namespace = "global", .name = "references", .arguments_min = 1, .arguments_max = 1024 },
    .{ .namespace = "global", .name = "round", .arguments_min = 1, .arguments_max = 2 },
    .{ .namespace = "global", .name = "select", .arguments_min = 0, .arguments_max = 1024 },
    .{ .namespace = "global", .name = "string", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "global", .name = "boost", .arguments_min = 2, .arguments_max = 2 },
    .{ .namespace = "global", .name = "lower", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "global", .name = "upper", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "dateTime", .name = "now", .arguments_min = 0, .arguments_max = 0 },
    .{ .namespace = "array", .name = "join", .arguments_min = 2, .arguments_max = 2 },
    .{ .namespace = "array", .name = "compact", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "array", .name = "unique", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "array", .name = "intersects", .arguments_min = 2, .arguments_max = 2 },
    .{ .namespace = "string", .name = "split", .arguments_min = 2, .arguments_max = 2 },
    .{ .namespace = "string", .name = "startsWith", .arguments_min = 2, .arguments_max = 2 },
    .{ .namespace = "string", .name = "lower", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "string", .name = "upper", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "math", .name = "sum", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "math", .name = "avg", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "math", .name = "min", .arguments_min = 1, .arguments_max = 1 },
    .{ .namespace = "math", .name = "max", .arguments_min = 1, .arguments_max = 1 },
};

pub const pipe_signatures = [_]Signature{
    .{ .namespace = "global", .name = "order", .arguments_min = 1, .arguments_max = 1024 },
    .{ .namespace = "global", .name = "score", .arguments_min = 1, .arguments_max = 1024 },
};

pub const namespaces = [_][]const u8{ "global", "dateTime", "array", "string", "math" };

pub fn find(list: []const Signature, namespace: []const u8, name: []const u8) ?Signature {
    std.debug.assert(namespace.len <= 1 << 30);

    for (list) |signature| {
        const same = std.mem.eql(u8, signature.namespace, namespace) and
            std.mem.eql(u8, signature.name, name);

        if (same) {
            return signature;
        }
    }

    return null;
}

pub fn is(called: tree.Call, namespace: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, called.namespace, namespace) and std.mem.eql(u8, called.name, name);
}

pub fn argument(
    context: *Context,
    called: tree.Call,
    position: u32,
    scope: *const Scope,
    depth: u32,
) Error!Value {
    std.debug.assert(position < called.arguments.len);

    return evaluate_module.evaluate(context, called.arguments[position], scope, depth);
}

pub fn call(context: *Context, called: tree.Call, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    if (std.mem.eql(u8, called.namespace, "global")) {
        return global(context, called, scope, depth);
    }

    if (is(called, "dateTime", "now")) {
        return .{ .datetime = context.now };
    }

    if (std.mem.eql(u8, called.namespace, "array")) {
        return namespace_functions.array_namespace(context, called, scope, depth);
    }

    if (std.mem.eql(u8, called.namespace, "string")) {
        return namespace_functions.string_namespace(context, called, scope, depth);
    }

    if (std.mem.eql(u8, called.namespace, "math")) {
        return namespace_functions.math_namespace(context, called, scope, depth);
    }

    return .null;
}

fn global(context: *Context, called: tree.Call, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    const name = called.name;

    if (std.mem.eql(u8, name, "coalesce")) {
        for (called.arguments, 0..) |_, position| {
            const held = try argument(context, called, @intCast(position), scope, depth);

            if (held != .null) {
                return held;
            }
        }

        return .null;
    }

    if (std.mem.eql(u8, name, "select")) {
        return select(context, called, scope, depth);
    }

    if (std.mem.eql(u8, name, "references")) {
        return references(context, called, scope, depth);
    }

    if (std.mem.eql(u8, name, "now")) {
        var buffer: [40]u8 = undefined;

        return .{ .string = try context.arena.dupe(u8, datetime.format(&buffer, context.now)) };
    }

    if (std.mem.eql(u8, name, "round")) {
        return round(context, called, scope, depth);
    }

    if (std.mem.eql(u8, name, "boost")) {
        const result = try argument(context, called, 0, scope, depth);
        const amount = try argument(context, called, 1, scope, depth);

        return if (amount != .number or amount.number < 0) .null else result;
    }

    const first = try argument(context, called, 0, scope, depth);

    return single(context.arena, name, first);
}

/// The global functions of one argument.
pub fn single(arena: std.mem.Allocator, name: []const u8, first: Value) Error!Value {
    std.debug.assert(first != .number or std.math.isFinite(first.number));

    if (std.mem.eql(u8, name, "count")) {
        return if (first == .array) Value.of_number(@floatFromInt(first.array.len)) else .null;
    }

    if (std.mem.eql(u8, name, "defined")) {
        return .{ .boolean = first != .null };
    }

    if (std.mem.eql(u8, name, "length")) {
        return switch (first) {
            .string => |text| Value.of_number(@floatFromInt(code_points(text))),
            .array => |items| Value.of_number(@floatFromInt(items.len)),
            else => .null,
        };
    }

    if (std.mem.eql(u8, name, "dateTime")) {
        return switch (first) {
            .string => |text| if (datetime.parse(text)) |time| .{ .datetime = time } else .null,
            .datetime => first,
            else => .null,
        };
    }

    if (std.mem.eql(u8, name, "string")) {
        return string_of(arena, first);
    }

    if (std.mem.eql(u8, name, "lower") or std.mem.eql(u8, name, "upper")) {
        if (first != .string) {
            return .null;
        }

        const changed = try arena.alloc(u8, first.string.len);

        if (name[0] == 'l') {
            _ = std.ascii.lowerString(changed, first.string);
        } else {
            _ = std.ascii.upperString(changed, first.string);
        }

        return .{ .string = changed };
    }

    return .null;
}

fn code_points(text: []const u8) u64 {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn string_of(arena: std.mem.Allocator, value: Value) Error!Value {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    return switch (value) {
        .boolean => |truth| .{ .string = if (truth) "true" else "false" },
        .string => value,
        .number => |number| {
            var out: std.Io.Writer.Allocating = .init(arena);

            value_module.write_number(&out.writer, number) catch return error.OutOfMemory;

            return .{ .string = out.written() };
        },
        .datetime => |time| {
            var buffer: [40]u8 = undefined;

            return .{ .string = try arena.dupe(u8, datetime.format(&buffer, time)) };
        },
        else => .null,
    };
}

fn select(context: *Context, called: tree.Call, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    for (called.arguments) |each| {
        const node = context.query.node(each);

        if (node != .pair) {
            return evaluate_module.evaluate(context, each, scope, depth);
        }

        const condition = try evaluate_module.evaluate(context, node.pair.first, scope, depth);

        if (condition.is_true()) {
            return evaluate_module.evaluate(context, node.pair.second, scope, depth);
        }
    }

    return .null;
}

fn round(context: *Context, called: tree.Call, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    const number = try argument(context, called, 0, scope, depth);

    if (number != .number) {
        return .null;
    }

    var precision: f64 = 0;

    if (called.arguments.len == 2) {
        const given = try argument(context, called, 1, scope, depth);

        const whole = given == .number and @floor(given.number) == given.number;

        if (!whole or given.number < 0) {
            return .null;
        }

        precision = given.number;
    }

    const scale = std.math.pow(f64, 10, precision);
    const scaled = number.number * scale;
    // Halves round away from zero.
    const rounded = if (scaled < 0) -@floor(-scaled + 0.5) else @floor(scaled + 0.5);

    return Value.of_number(rounded / scale);
}

fn references(context: *Context, called: tree.Call, scope: *const Scope, depth: u32) Error!Value {
    std.debug.assert(context.query.root < context.query.nodes.len);

    var ids: std.ArrayList([]const u8) = .empty;

    for (called.arguments, 0..) |_, position| {
        const held = try argument(context, called, @intCast(position), scope, depth);

        switch (held) {
            .string => |text| try ids.append(context.arena, text),
            .array => |items| for (items) |item| {
                if (item == .string) {
                    try ids.append(context.arena, item.string);
                }
            },
            else => {},
        }
    }

    if (ids.items.len == 0) {
        return Value.false_value;
    }

    return .{ .boolean = try has_reference(context, scope.this, ids.items) };
}

/// Whether a value holds a `{_ref}` (or, in Publr, a reference id) to one of `ids`, at any
/// depth; walked with an explicit stack.
fn has_reference(context: *Context, start: Value, ids: []const []const u8) Error!bool {
    std.debug.assert(context.query.root < context.query.nodes.len);

    var pending: std.ArrayList(Value) = .empty;

    try pending.append(context.arena, start);

    while (pending.pop()) |value| {
        switch (value) {
            .array => |items| try pending.appendSlice(context.arena, items),
            .object => |object| {
                if (object.get("_ref")) |reference| {
                    if (reference == .string and listed(ids, reference.string)) {
                        return true;
                    }

                    continue;
                }

                try pending.appendSlice(context.arena, object.values);
            },
            else => {},
        }
    }

    return false;
}

fn listed(ids: []const []const u8, id: []const u8) bool {
    std.debug.assert(id.len <= 1 << 30);

    for (ids) |each| {
        if (std.mem.eql(u8, each, id)) {
            return true;
        }
    }

    return false;
}
