//! A parsed GROQ query: nodes in one array, children by index.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const Index = u32;

pub const Operator = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    in_,
    match,
    plus,
    minus,
    star,
    slash,
    percent,
    star_star,
    and_,
    or_,
};

pub const Element = struct { value: Index, spread: bool };

pub const Entry = struct { key: []const u8, value: Index };

pub const Attribute = union(enum) {
    /// `"key": value`
    keyed: Entry,
    /// `name`, `items[0]`: the key is the name it reads.
    derived: Entry,
    /// `...` (the this value) or `...value`.
    spread: ?Index,
    /// `condition => { ... }`: the object's attributes when the condition is true.
    conditional: struct { condition: Index, value: Index },
};

pub const Call = struct {
    namespace: []const u8,
    name: []const u8,
    arguments: []const Index,
};

/// One traversal step (GROQ-1.revision5, "Traversal operators"). Indexes and slice ends are
/// constants: square brackets are told apart when the query is read.
pub const Step = union(enum) {
    attribute: []const u8,
    element: i64,
    slice: struct { start: i64, end: i64, exclusive: bool },
    filter: Index,
    array_postfix,
    projection: []const Attribute,
    dereference: ?[]const u8,

    /// How a step treats arrays: what it works on and what it returns.
    pub const Shape = enum { plain, element, array, projection };

    pub fn shape(step: Step) Shape {
        std.debug.assert(step != .element or @abs(step.element) <= 9_000_000_000_000_000);

        return switch (step) {
            .attribute, .dereference => .plain,
            .element => .element,
            .slice, .filter, .array_postfix => .array,
            .projection => .projection,
        };
    }
};

pub const Node = union(enum) {
    literal: Value,
    array: []const Element,
    object: []const Attribute,
    this,
    this_attribute: []const u8,
    everything,
    parent: u32,
    param: []const u8,
    call: Call,
    pipe: struct { base: Index, call: Call },
    group: Index,
    traversal: struct { base: Index, steps: []const Step },
    binary: struct { operator: Operator, left: Index, right: Index },
    not_: Index,
    negate: Index,
    positive: Index,
    range: struct { start: Index, end: Index, exclusive: bool },
    pair: struct { first: Index, second: Index },
    asc: Index,
    desc: Index,
};

pub const Query = struct {
    nodes: []const Node,
    root: Index,

    pub fn node(query: *const Query, index: Index) Node {
        std.debug.assert(index < query.nodes.len);

        return query.nodes[index];
    }
};
