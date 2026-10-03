//! The values a GROQ query is made of, for the parser (`syntax.zig`): primaries (literals,
//! `*`, `@`, `^`, `$param`, arrays, objects, calls), the traversal steps after them,
//! square brackets told apart by constant evaluation (section 8.8), and the names
//! projections derive their keys from.

const std = @import("std");
const tokens_module = @import("tokens.zig");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const operators = @import("operators.zig");
const syntax = @import("syntax.zig");

const Token = tokens_module.Token;
const Kind = tokens_module.Kind;
const Index = tree.Index;
const Step = tree.Step;
const Value = value_module.Value;
const Parser = syntax.Parser;
const Error = syntax.Error;
const depth_max = syntax.depth_max;

const ConstantError = error{ NotConstant, OutOfMemory };

/// Traversal steps and pipe calls after an expression (level 11).
pub fn postfix(parser: *Parser, start: Index, depth: u32) Error!Index {
    std.debug.assert(parser.at < parser.tokens.len);

    var base = start;
    var steps: std.ArrayList(Step) = .empty;

    while (true) {
        const next_step = try step(parser, depth) orelse {
            if (parser.peek().kind == .pipe and parser.peek_at(1).kind == .identifier) {
                base = try close(parser, base, &steps);
                _ = parser.take();
                const called = try call_of(parser, parser.take(), depth);

                base = try parser.add(.{ .pipe = .{ .base = base, .call = called } });
                continue;
            }

            return close(parser, base, &steps);
        };

        try steps.append(parser.arena, next_step);
    }
}

pub fn close(parser: *Parser, base: Index, steps: *std.ArrayList(Step)) Error!Index {
    std.debug.assert(parser.at < parser.tokens.len);

    if (steps.items.len == 0) {
        return base;
    }

    const taken = steps.items;

    steps.* = .empty;

    return parser.add(.{ .traversal = .{ .base = base, .steps = taken } });
}

/// One traversal step, or null when none follows.
pub fn step(parser: *Parser, depth: u32) Error!?Step {
    std.debug.assert(parser.at < parser.tokens.len);

    switch (parser.peek().kind) {
        .dot => {
            if (parser.peek_at(1).kind != .identifier) {
                return null;
            }

            _ = parser.take();

            return .{ .attribute = parser.take().text };
        },
        .arrow => {
            _ = parser.take();

            if (parser.peek().kind == .identifier) {
                return .{ .dereference = parser.take().text };
            }

            return .{ .dereference = null };
        },
        .left_bracket => {
            _ = parser.take();

            return try bracket(parser, depth);
        },
        .left_brace => {
            _ = parser.take();

            return .{ .projection = try attributes(parser, depth) };
        },
        .pipe => {
            if (parser.peek_at(1).kind != .left_brace) {
                return null;
            }

            parser.at += 2;

            return .{ .projection = try attributes(parser, depth) };
        },
        else => return null,
    }
}

/// After `[`: `[]`, a slice, or what constant evaluation says (section 8.8).
pub fn bracket(parser: *Parser, depth: u32) Error!Step {
    std.debug.assert(parser.at < parser.tokens.len);

    if (parser.accept(.right_bracket)) {
        return .array_postfix;
    }

    const inner = try parser.expression(0, depth);

    _ = try parser.expect(.right_bracket, "`]`");

    if (parser.nodes.items[inner] == .range) {
        const range = parser.nodes.items[inner].range;
        const start = try whole_constant(parser, range.start, "a slice runs between whole numbers");
        const end = try whole_constant(parser, range.end, "a slice runs between whole numbers");

        return .{ .slice = .{ .start = start, .end = end, .exclusive = range.exclusive } };
    }

    const constant = constant_value(parser, inner) catch |err| switch (err) {
        error.NotConstant => return .{ .filter = inner },
        error.OutOfMemory => return error.OutOfMemory,
    };

    return switch (constant) {
        .string => |name| .{ .attribute = name },
        .number => .{ .element = try whole_constant(parser, inner, "an index is a whole number") },
        else => .{ .filter = inner },
    };
}

pub fn whole_constant(parser: *Parser, index: Index, message: []const u8) Error!i64 {
    std.debug.assert(parser.at < parser.tokens.len);

    const constant = constant_value(parser, index) catch |err| switch (err) {
        error.NotConstant => return parser.fail(message),
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (constant != .number or @floor(constant.number) != constant.number) {
        return parser.fail(message);
    }

    if (@abs(constant.number) > 9.0e15) {
        return parser.fail(message);
    }

    return @intFromFloat(constant.number);
}

pub fn primary(parser: *Parser, depth: u32) Error!Index {
    std.debug.assert(parser.at < parser.tokens.len);

    const token = parser.take();

    return switch (token.kind) {
        .star => parser.add(.everything),
        .at => parser.add(.this),
        .caret => parent(
            parser,
        ),
        .string => parser.add(.{ .literal = .{ .string = token.text } }),
        .number => parser.add(.{ .literal = .{
            .number = std.fmt.parseFloat(f64, token.text) catch return parser.fail("a number"),
        } }),
        .param => parser.add(.{ .param = token.text }),
        .left_paren => group(parser, depth),
        .left_bracket => array(parser, depth),
        .left_brace => parser.add(.{ .object = try attributes(parser, depth) }),
        .identifier => word(parser, token, depth),
        else => parser.fail("a value: a literal, a field, `*`, `@`, `^`, `$param` or `(`"),
    };
}

pub fn parent(parser: *Parser) Error!Index {
    std.debug.assert(parser.at < parser.tokens.len);

    var levels: u32 = 1;

    while (parser.peek().kind == .dot and parser.peek_at(1).kind == .caret) {
        parser.at += 2;
        levels += 1;
    }

    return parser.add(.{ .parent = levels });
}

pub fn group(parser: *Parser, depth: u32) Error!Index {
    const inner = try parser.expression(0, depth);

    _ = try parser.expect(.right_paren, "`)`");

    return parser.add(.{ .group = inner });
}

pub fn array(parser: *Parser, depth: u32) Error!Index {
    std.debug.assert(parser.at < parser.tokens.len);

    var elements: std.ArrayList(tree.Element) = .empty;

    while (!parser.accept(.right_bracket)) {
        const spread = parser.accept(.dot_dot_dot);
        const element = try parser.expression(0, depth);

        try elements.append(parser.arena, .{ .value = element, .spread = spread });

        if (!parser.accept(.comma)) {
            _ = try parser.expect(.right_bracket, "`,` or `]` in the array");
            break;
        }
    }

    return parser.add(.{ .array = elements.items });
}

/// After `{`, up to and with `}`.
pub fn attributes(parser: *Parser, depth: u32) Error![]const tree.Attribute {
    std.debug.assert(parser.at < parser.tokens.len);

    var list: std.ArrayList(tree.Attribute) = .empty;

    while (!parser.accept(.right_brace)) {
        try list.append(parser.arena, try attribute(parser, depth));

        if (!parser.accept(.comma)) {
            _ = try parser.expect(.right_brace, "`,` or `}` in the object");
            break;
        }
    }

    return list.items;
}

pub fn attribute(parser: *Parser, depth: u32) Error!tree.Attribute {
    std.debug.assert(parser.at < parser.tokens.len);

    if (parser.accept(.dot_dot_dot)) {
        const bare = parser.peek().kind == .comma or parser.peek().kind == .right_brace;

        return .{ .spread = if (bare) null else try parser.expression(0, depth) };
    }

    if (parser.peek().kind == .string and parser.peek_at(1).kind == .colon) {
        const key = parser.take().text;

        _ = parser.take();

        return .{ .keyed = .{ .key = key, .value = try parser.expression(0, depth) } };
    }

    const held = try parser.expression(0, depth);

    if (parser.nodes.items[held] == .pair) {
        const pair = parser.nodes.items[held].pair;

        return .{ .conditional = .{ .condition = pair.first, .value = pair.second } };
    }

    const key = name_of(parser, held) orelse {
        return parser.fail("this value needs a key: `\"name\": value`");
    };

    return .{ .derived = .{ .key = key, .value = held } };
}

/// `true`, `false`, `null`, a function call (`count(items)`, `string::split(text, ",")`), or an
/// attribute of the this value.
pub fn word(parser: *Parser, token: Token, depth: u32) Error!Index {
    std.debug.assert(token.kind == .identifier);

    const text = token.text;

    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
        return parser.add(.{ .literal = .{ .boolean = text[0] == 't' } });
    }

    if (std.mem.eql(u8, text, "null")) {
        return parser.add(.{ .literal = .null });
    }

    const called = parser.peek().kind == .left_paren or parser.peek().kind == .colon_colon;

    if (called) {
        return parser.add(.{ .call = try call_of(parser, token, depth) });
    }

    return parser.add(.{ .this_attribute = text });
}

pub fn call_of(parser: *Parser, token: Token, depth: u32) Error!tree.Call {
    std.debug.assert(parser.at < parser.tokens.len);

    if (token.kind != .identifier) {
        return parser.fail("a function's name");
    }

    var namespace: []const u8 = "global";
    var name = token.text;

    if (parser.accept(.colon_colon)) {
        namespace = name;
        name = (try parser.expect(.identifier, "a function's name after `::`")).text;
    }

    _ = try parser.expect(.left_paren, "`(` after a function's name");

    var arguments: std.ArrayList(Index) = .empty;

    while (!parser.accept(.right_paren)) {
        try arguments.append(parser.arena, try parser.expression(0, depth));

        if (!parser.accept(.comma)) {
            _ = try parser.expect(.right_paren, "`,` or `)` in the call");
            break;
        }
    }

    return .{ .namespace = namespace, .name = name, .arguments = arguments.items };
}

/// DetermineName (section 4.6): the attribute a value reads, through the steps that keep
/// it (`items[0]`, `items[]`, `items{...}`, `author->`); null when it reads none.
fn name_of(parser: *const Parser, index: Index) ?[]const u8 {
    std.debug.assert(parser.at < parser.tokens.len);

    var at = index;

    for (0..depth_max) |_| {
        switch (parser.nodes.items[at]) {
            .this_attribute => |name| return name,
            .pipe => |piped| at = piped.base,
            .traversal => |traversal| {
                for (traversal.steps) |each| {
                    if (each == .attribute) {
                        return null;
                    }
                }

                at = traversal.base;
            },
            else => return null,
        }
    }

    return null;
}
/// ConstantEvaluate (section 3.8): literals, parentheses and the arithmetic operators.
pub fn constant_value(parser: *Parser, index: Index) ConstantError!Value {
    std.debug.assert(parser.at < parser.tokens.len);

    const node = parser.nodes.items[index];

    return switch (node) {
        .literal => |literal| literal,
        .param => |name| parser.params.get(name) orelse error.NotConstant,
        .group => |inner| constant_value(parser, inner),
        .negate => |inner| operators.negate(try constant_value(parser, inner)),
        .positive => |inner| operators.positive(try constant_value(parser, inner)),
        .binary => |pair| {
            const left = try constant_value(parser, pair.left);
            const right = try constant_value(parser, pair.right);

            return switch (pair.operator) {
                .plus => operators.plus(parser.arena, left, right),
                .minus => operators.minus(left, right),
                .star => operators.star(left, right),
                .slash => operators.slash(left, right),
                .percent => operators.percent(left, right),
                .star_star => operators.star_star(left, right),
                else => error.NotConstant,
            };
        },
        else => error.NotConstant,
    };
}
