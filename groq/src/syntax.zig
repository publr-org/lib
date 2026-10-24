//! Reads a GROQ query (GROQ-1.revision5) into a tree: operators by the precedence of section
//! 10, traversal steps collected after the expression they start from, square brackets told
//! apart by constant evaluation (section 8.8). The descent is bounded by `depth_max`.

const std = @import("std");
const tokens_module = @import("tokens.zig");
const tree = @import("tree.zig");
const value_module = @import("value.zig");
const values = @import("syntax_values.zig");

const Token = tokens_module.Token;
const Kind = tokens_module.Kind;
const Node = tree.Node;
const Index = tree.Index;
const Step = tree.Step;
const Value = value_module.Value;

pub const depth_max: u32 = 48;
pub const nodes_max: u32 = 8192;

pub const Error = error{ Invalid, OutOfMemory };

/// Why a query was refused: where, and what was expected.
pub const Problem = struct {
    at: u32 = 0,
    message: []const u8 = "",
};

pub fn parse(
    arena: std.mem.Allocator,
    text: []const u8,
    problem: *Problem,
) Error!tree.Query {
    std.debug.assert(depth_max > 0);

    const tokens = tokens_module.tokenize(arena, text) catch |err| {
        problem.* = .{
            .message = "a character GROQ does not have, a bad escape or a number",
        };
        return err;
    };
    var parser: Parser = .{
        .arena = arena,
        .tokens = tokens,
        .problem = problem,
    };
    const root = try parser.expression(0, 0);

    if (parser.peek().kind != .end) {
        return parser.fail("more after the end of the query");
    }

    return .{
        .nodes = parser.nodes.items,
        .root = root,
        .deferred = parser.deferred,
    };
}

/// The query with its parameters bound: square brackets that read a `$param` told apart by
/// their values (`[$index]` an element, `[$from...$to]` a slice). A parsed query is kept
/// and bound again for each run; one with no such brackets is returned as it is.
pub fn bind(
    arena: std.mem.Allocator,
    query: *const tree.Query,
    params: value_module.Object,
    problem: *Problem,
) Error!tree.Query {
    std.debug.assert(query.root < query.nodes.len);

    if (!query.deferred) {
        return query.*;
    }

    const nodes = try arena.dupe(Node, query.nodes);
    const constants: values.Constants = .{
        .arena = arena,
        .nodes = query.nodes,
        .params = params,
    };

    for (nodes) |*node| {
        if (node.* != .traversal) {
            continue;
        }

        var steps: ?[]Step = null;

        for (node.traversal.steps, 0..) |step, index| {
            if (step != .bracket) {
                continue;
            }

            const bound = steps orelse try arena.dupe(Step, node.traversal.steps);
            var message: []const u8 = "";

            bound[index] = values.step_of(constants, step.bracket, &message) catch |err| {
                switch (err) {
                    error.Param => unreachable,
                    error.Invalid => {
                        problem.* = .{
                            .message = message,
                        };
                        return error.Invalid;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                }
            };
            steps = bound;
        }

        if (steps) |bound| {
            node.traversal.steps = bound;
        }
    }

    // A bracket bound to a name (`items[$key]`) reads an attribute: the value it stands in
    // derives no key, as when the name is written in the query.
    for (nodes) |node| {
        const keyed = switch (node) {
            .object => |attributes| named(nodes, attributes),
            .traversal => |traversal| for (traversal.steps) |step| {
                if (step == .projection and !named(nodes, step.projection)) {
                    break false;
                }
            } else true,
            else => true,
        };

        if (!keyed) {
            problem.* = .{
                .message = values.needs_key,
            };
            return error.Invalid;
        }
    }

    return .{
        .nodes = nodes,
        .root = query.root,
    };
}

/// Whether each derived key still reads a name once the brackets are bound.
fn named(nodes: []const Node, attributes: []const tree.Attribute) bool {
    for (attributes) |attribute| {
        if (attribute == .derived and values.name_of(nodes, attribute.derived.value) == null) {
            return false;
        }
    }

    return true;
}

/// Levels of section 10, lowest first; an infix operator binds at its level.
pub const Level = struct {
    const pair: u8 = 1;
    const or_: u8 = 2;
    const and_: u8 = 3;
    const comparison: u8 = 4;
    const range: u8 = 5;
    const additive: u8 = 6;
    const multiplicative: u8 = 7;
    const negate: u8 = 8;
    const power: u8 = 9;
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    problem: *Problem,
    at: u32 = 0,
    /// A square bracket waits for the parameters.
    deferred: bool = false,
    nodes: std.ArrayList(Node) = .empty,

    pub fn peek(parser: *const Parser) Token {
        std.debug.assert(parser.at < parser.tokens.len);

        return parser.tokens[parser.at];
    }

    pub fn peek_at(parser: *const Parser, ahead: u32) Token {
        const index = @min(parser.at + ahead, parser.tokens.len - 1);

        return parser.tokens[index];
    }

    pub fn take(parser: *Parser) Token {
        std.debug.assert(parser.at < parser.tokens.len);

        const token = parser.peek();

        if (token.kind != .end) {
            parser.at += 1;
        }

        return token;
    }

    pub fn accept(parser: *Parser, kind: Kind) bool {
        std.debug.assert(parser.at < parser.tokens.len);

        if (parser.peek().kind == kind) {
            parser.at += 1;
            return true;
        }

        return false;
    }

    pub fn expect(parser: *Parser, kind: Kind, message: []const u8) Error!Token {
        std.debug.assert(message.len > 0);

        if (parser.peek().kind != kind) {
            return parser.fail(message);
        }

        return parser.take();
    }

    pub fn fail(parser: *Parser, message: []const u8) error{Invalid} {
        std.debug.assert(message.len > 0);

        parser.problem.* = .{
            .at = parser.peek().at,
            .message = message,
        };

        return error.Invalid;
    }

    pub fn add(parser: *Parser, node: Node) Error!Index {
        std.debug.assert(parser.at < parser.tokens.len);

        if (parser.nodes.items.len == nodes_max) {
            return parser.fail("the query is too long");
        }

        try parser.nodes.append(parser.arena, node);

        return @intCast(parser.nodes.items.len - 1);
    }

    pub fn deeper(parser: *Parser, depth: u32) Error!u32 {
        std.debug.assert(parser.at < parser.tokens.len);

        if (depth >= depth_max) {
            return parser.fail("the query nests too deep");
        }

        return depth + 1;
    }

    pub fn is_word(parser: *const Parser, expected: []const u8) bool {
        const token = parser.peek();

        return token.kind == .identifier and std.mem.eql(u8, token.text, expected);
    }

    /// An expression whose operators all bind at `minimum` or tighter.
    pub fn expression(parser: *Parser, minimum: u8, depth: u32) Error!Index {
        std.debug.assert(parser.at < parser.tokens.len);

        const inner = try parser.deeper(depth);
        var left = try parser.prefix(inner);

        while (true) {
            const before = left;

            left = try parser.infix(left, minimum, inner);

            if (left == before) {
                return left;
            }
        }
    }

    /// One infix (or postfix `asc`/`desc`) operator on `left`, when one binding at
    /// `minimum` or tighter follows; `left` itself otherwise.
    fn infix(parser: *Parser, left: Index, minimum: u8, depth: u32) Error!Index {
        std.debug.assert(parser.at < parser.tokens.len);

        const token = parser.peek();

        if (token.kind == .pair_arrow and minimum <= Level.pair) {
            _ = parser.take();
            const second = try parser.expression(Level.pair + 1, depth);

            return parser.add(.{
                .pair = .{
                    .first = left,
                    .second = second,
                },
            });
        }

        if (token.kind == .or_ and minimum <= Level.or_) {
            return parser.binary(.or_, left, Level.or_ + 1, depth);
        }

        if (token.kind == .and_ and minimum <= Level.and_) {
            return parser.binary(.and_, left, Level.and_ + 1, depth);
        }

        if (minimum <= Level.comparison) {
            if (comparison_of(parser)) |operator| {
                const node = try parser.binary(operator, left, Level.comparison + 1, depth);

                if (comparison_of(parser) != null) {
                    return parser.fail("comparisons do not chain: add parentheses");
                }

                return node;
            }

            if (parser.is_word("asc") or parser.is_word("desc")) {
                const descending = parser.is_word("desc");

                _ = parser.take();

                return parser.add(if (descending) .{
                    .desc = left,
                } else .{
                    .asc = left,
                });
            }
        }

        const ranged = token.kind == .dot_dot or token.kind == .dot_dot_dot;

        if (ranged and minimum <= Level.range) {
            _ = parser.take();
            const end = try parser.expression(Level.range + 1, depth);

            return parser.add(.{
                .range = .{
                    .start = left,
                    .end = end,
                    .exclusive = token.kind == .dot_dot_dot,
                },
            });
        }

        return parser.arithmetic(left, minimum, depth);
    }

    fn arithmetic(parser: *Parser, left: Index, minimum: u8, depth: u32) Error!Index {
        std.debug.assert(parser.at < parser.tokens.len);

        const token = parser.peek();

        if ((token.kind == .plus or token.kind == .minus) and minimum <= Level.additive) {
            const operator: tree.Operator = if (token.kind == .plus) .plus else .minus;

            return parser.binary(operator, left, Level.additive + 1, depth);
        }

        const multiplicative: ?tree.Operator = switch (token.kind) {
            .star => .star,
            .slash => .slash,
            .percent => .percent,
            else => null,
        };

        if (multiplicative != null and minimum <= Level.multiplicative) {
            return parser.binary(multiplicative.?, left, Level.multiplicative + 1, depth);
        }

        if (token.kind == .star_star and minimum <= Level.power) {
            return parser.binary(.star_star, left, Level.power, depth);
        }

        return left;
    }

    fn binary(
        parser: *Parser,
        operator: tree.Operator,
        left: Index,
        right_minimum: u8,
        depth: u32,
    ) Error!Index {
        _ = parser.take();

        const right = try parser.expression(right_minimum, depth);

        return parser.add(.{
            .binary = .{
                .operator = operator,
                .left = left,
                .right = right,
            },
        });
    }

    fn prefix(parser: *Parser, depth: u32) Error!Index {
        std.debug.assert(parser.at < parser.tokens.len);

        const token = parser.peek();

        switch (token.kind) {
            .minus => {
                _ = parser.take();
                return parser.add(.{
                    .negate = try parser.expression(Level.negate + 1, depth),
                });
            },
            .plus => {
                _ = parser.take();
                return parser.add(.{
                    .positive = try parser.unary_operand(depth),
                });
            },
            .not_ => {
                _ = parser.take();
                return parser.add(.{
                    .not_ = try parser.unary_operand(depth),
                });
            },
            else => return values.postfix(parser, try values.primary(parser, depth), depth),
        }
    }

    /// What `+` and `!` (level 10) apply to: another prefix operator or a compound.
    fn unary_operand(parser: *Parser, depth: u32) Error!Index {
        const inner = try parser.deeper(depth);

        return parser.prefix(inner);
    }
};

pub fn comparison_of(parser: *const Parser) ?tree.Operator {
    std.debug.assert(parser.at < parser.tokens.len);

    return switch (parser.peek().kind) {
        .equal => .equal,
        .not_equal => .not_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .identifier => if (parser.is_word("in"))
            .in_
        else if (parser.is_word("match"))
            .match
        else
            null,
        else => null,
    };
}

test "syntax: precedence, traversals, brackets told apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = .{};

    const power = try parse(arena, "-2 ** 2", &problem);

    try std.testing.expect(power.node(power.root) == .negate);

    const chain = try parse(arena, "*[_type == \"a\"][0..-1].items[]->title", &problem);
    const steps = chain.node(chain.root).traversal.steps;

    try std.testing.expectEqual(@as(usize, 5), steps.len);
    try std.testing.expect(steps[0] == .filter);
    try std.testing.expectEqual(@as(i64, -1), steps[1].slice.end);
    try std.testing.expect(steps[3] == .array_postfix);
    try std.testing.expectEqualStrings("title", steps[4].dereference.?);

    const keyed = try parse(arena, "x[\"name\"][1 + 1]", &problem);

    try std.testing.expectEqualStrings("name", keyed.node(keyed.root).traversal.steps[0].attribute);
    try std.testing.expectEqual(@as(i64, 2), keyed.node(keyed.root).traversal.steps[1].element);
    try std.testing.expectError(error.Invalid, parse(arena, "a == b == c", &problem));
    try std.testing.expectError(error.Invalid, parse(arena, "x[1.5]", &problem));
    try std.testing.expectError(error.Invalid, parse(arena, "{a.b}", &problem));

    const piped = try parse(arena, "*[a > 1] | order(a desc) | {a}", &problem);

    try std.testing.expect(piped.node(piped.root) == .traversal);
}

test "syntax: brackets that read a parameter, told apart when it is bound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = .{};

    const kept = try parse(arena, "*[_type == $type][$from...$to].tags[$at]", &problem);
    const waiting = kept.node(kept.root).traversal.steps;

    try std.testing.expect(kept.deferred);
    try std.testing.expect(waiting[0] == .filter and waiting[1] == .bracket);

    var params: value_module.ObjectBuilder = .{};

    try params.put(arena, "type", .{ .string = "post" });
    try params.put(arena, "from", .{ .number = 2 });
    try params.put(arena, "to", .{ .number = 4 });
    try params.put(arena, "at", .{ .number = 1 });

    const bound = try bind(arena, &kept, params.object(), &problem);
    const steps = bound.node(bound.root).traversal.steps;

    try std.testing.expect(steps[0] == .filter);
    try std.testing.expectEqual(@as(i64, 2), steps[1].slice.start);
    try std.testing.expectEqual(@as(i64, 4), steps[1].slice.end);
    try std.testing.expectEqual(@as(i64, 1), steps[3].element);
    try std.testing.expect(waiting[1] == .bracket);

    try params.put(arena, "from", .{ .number = 1.5 });
    try std.testing.expectError(error.Invalid, bind(arena, &kept, params.object(), &problem));

    // A name bound into a derived key's value leaves it without a key, as written: the
    // answer the query had when brackets were told apart while it was read.
    const derived = try parse(arena, "{ items[$at] }", &problem);

    try std.testing.expectEqualStrings("items", derived.node(derived.root).object[0].derived.key);
    _ = try bind(arena, &derived, params.object(), &problem);
    try params.put(arena, "at", .{ .string = "name" });
    try std.testing.expectError(error.Invalid, bind(arena, &derived, params.object(), &problem));
    try std.testing.expectEqualStrings(values.needs_key, problem.message);
    try std.testing.expectError(error.Invalid, parse(arena, "{ items[\"name\"] }", &problem));
    try std.testing.expectEqualStrings(values.needs_key, problem.message);

    const plain = try parse(arena, "*[_type == \"post\"][0...2]", &problem);

    try std.testing.expect(!plain.deferred);
}
