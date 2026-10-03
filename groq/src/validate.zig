//! Query validation (GROQ-1.revision5, section 3.6): functions known with the right number
//! of arguments, pipe functions only after `|`, `boost()` only inside `score()`, `asc` and
//! `desc` only inside `order()`, `select()`'s default last, every `$param` given.

const std = @import("std");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const functions = @import("functions.zig");
const syntax = @import("syntax.zig");

const Index = tree.Index;

pub const Error = error{Invalid};

/// Where a node stands, for the nodes only some places allow: `asc`/`desc` (in `order()`),
/// `boost()` (in `score()`), a range (right of `in`), a pair (an argument of `select()`).
const Place = enum { anywhere, order_argument, score_argument, in_right, select_argument };

const Pending = struct { index: Index, place: Place };

pub fn validate(
    arena: std.mem.Allocator,
    query: *const tree.Query,
    params: value_module.Object,
    problem: *syntax.Problem,
) (Error || error{OutOfMemory})!void {
    var pending: std.ArrayList(Pending) = .empty;

    try pending.append(arena, .{ .index = query.root, .place = .anywhere });

    while (pending.pop()) |item| {
        if (try check(arena, query, params, item, &pending)) |message| {
            problem.* = .{ .message = message };
            return error.Invalid;
        }
    }
}

/// The node's own rule, its children pushed; the problem when it breaks one.
fn check(
    arena: std.mem.Allocator,
    query: *const tree.Query,
    params: value_module.Object,
    item: Pending,
    pending: *std.ArrayList(Pending),
) error{OutOfMemory}!?[]const u8 {
    const node = query.node(item.index);
    const push = Pusher{ .arena = arena, .pending = pending };

    switch (node) {
        .param => |name| if (params.get(name) == null) {
            return "a `$param` the query names was not given";
        },
        .asc, .desc => |held| {
            if (item.place != .order_argument) {
                return "`asc` and `desc` belong inside `order()`";
            }

            try push.add(held, .anywhere);
        },
        .call => |called| return try call(push, query, called, item.place, false),
        .pipe => |piped| {
            try push.add(piped.base, .anywhere);

            const scoring = std.mem.eql(u8, piped.call.name, "score");

            if (scoring and !documents_of(query, piped.base)) {
                return "`score()` scores documents: `*`, `*[...]` or a slice of them";
            }

            return try call(push, query, piped.call, item.place, true);
        },
        .array => |elements| for (elements) |element| try push.add(element.value, .anywhere),
        .object => |attributes| try push.attributes(attributes),
        .group => |held| try push.add(held, item.place),
        .traversal => |traversal| {
            try push.add(traversal.base, .anywhere);

            for (traversal.steps) |step| {
                switch (step) {
                    .filter => |predicate| try push.add(predicate, .anywhere),
                    .projection => |attributes| try push.attributes(attributes),
                    else => {},
                }
            }
        },
        .binary => |binary| {
            const inside = if (item.place == .score_argument and logical(binary.operator))
                Place.score_argument
            else
                Place.anywhere;

            try push.add(binary.left, inside);
            try push.add(binary.right, if (binary.operator == .in_) .in_right else inside);
        },
        .not_, .negate, .positive => |held| try push.add(held, .anywhere),
        .range => |range| {
            if (item.place != .in_right) {
                return "a range stands right of `in`, or inside `[...]`";
            }

            try push.add(range.start, .anywhere);
            try push.add(range.end, .anywhere);
        },
        .pair => |pair| {
            if (item.place != .select_argument) {
                return "`=>` belongs in `select()` or as a condition in an object";
            }

            try push.add(pair.first, .anywhere);
            try push.add(pair.second, .anywhere);
        },
        .literal, .this, .this_attribute, .everything, .parent => {},
    }

    return null;
}

/// Whether a value is a list of documents: `*`, its filters and slices, earlier pipes.
fn documents_of(query: *const tree.Query, index: Index) bool {
    std.debug.assert(query.root < query.nodes.len);

    return switch (query.node(index)) {
        .everything, .pipe => true,
        .group => |inner| documents_of(query, inner),
        .traversal => |traversal| blk: {
            for (traversal.steps) |step| {
                const kept = step == .filter or step == .slice or step == .array_postfix;

                if (!kept) {
                    break :blk false;
                }
            }

            break :blk documents_of(query, traversal.base);
        },
        else => false,
    };
}

fn logical(operator: tree.Operator) bool {
    return operator == .and_ or operator == .or_;
}

const Pusher = struct {
    arena: std.mem.Allocator,
    pending: *std.ArrayList(Pending),

    fn add(pusher: Pusher, index: Index, place: Place) error{OutOfMemory}!void {
        try pusher.pending.append(pusher.arena, .{ .index = index, .place = place });
    }

    fn attributes(pusher: Pusher, list: []const tree.Attribute) error{OutOfMemory}!void {
        std.debug.assert(list.len <= 1 << 30);

        for (list) |attribute| {
            switch (attribute) {
                .keyed, .derived => |entry| try pusher.add(entry.value, .anywhere),
                .spread => |spread| if (spread) |held| try pusher.add(held, .anywhere),
                .conditional => |conditional| {
                    try pusher.add(conditional.condition, .anywhere);
                    try pusher.add(conditional.value, .anywhere);
                },
            }
        }
    }
};

fn call(
    push: Pusher,
    query: *const tree.Query,
    called: tree.Call,
    place: Place,
    piped: bool,
) error{OutOfMemory}!?[]const u8 {
    var known_namespace = false;

    for (functions.namespaces) |namespace| {
        known_namespace = known_namespace or std.mem.eql(u8, namespace, called.namespace);
    }

    if (!known_namespace) {
        return "a function namespace GROQ does not have, or Publr does not support";
    }

    const list: []const functions.Signature = if (piped)
        &functions.pipe_signatures
    else
        &functions.signatures;
    const signature = functions.find(list, called.namespace, called.name) orelse {
        return if (piped)
            "the only pipe functions are `order()` and `score()`"
        else
            "a function GROQ does not have, or one that only works after `|`";
    };
    const count = called.arguments.len;

    if (count < signature.arguments_min or count > signature.arguments_max) {
        return "the function takes another number of arguments";
    }

    const is_order = piped and std.mem.eql(u8, called.name, "order");
    const is_score = piped and std.mem.eql(u8, called.name, "score");
    const is_boost = std.mem.eql(u8, called.name, "boost");

    if (is_boost and place != .score_argument) {
        return "`boost()` belongs inside `score()`";
    }

    if (std.mem.eql(u8, called.name, "select")) {
        if (select_default_misplaced(query, called)) {
            return "`select()` takes its default last";
        }
    }

    const is_select = !piped and std.mem.eql(u8, called.name, "select");

    for (called.arguments) |each| {
        const inside: Place = if (is_order)
            .order_argument
        else if (is_score)
            .score_argument
        else if (is_select)
            .select_argument
        else
            .anywhere;

        try push.add(each, if (is_boost) .anywhere else inside);
    }

    return null;
}

/// A non-pair argument is `select()`'s default; anything after it is a mistake.
fn select_default_misplaced(query: *const tree.Query, called: tree.Call) bool {
    std.debug.assert(called.name.len > 0);

    var seen_default = false;

    for (called.arguments) |each| {
        if (seen_default) {
            return true;
        }

        seen_default = query.node(each) != .pair;
    }

    return false;
}
