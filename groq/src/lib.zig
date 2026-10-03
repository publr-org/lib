//! GROQ (GROQ-1.revision5, spec.groq.dev): a query from text to value, parsed, validated
//! and evaluated over a dataset. All of the language but its extensions (Portable Text,
//! geo, documents), custom functions, delta mode and `diff::`/`delta::`, and the vendor
//! functions. The conformance suite runs with `zig build conformance -- <suite.ndjson>`.
//!
//! ```zig
//! const groq = @import("publr_groq");
//!
//! var memory: groq.Memory = .{ .documents = documents };
//! var problem: groq.Problem = .{};
//! const query = "*[_type == \"post\"]{ title }";
//! const answer = try groq.execute(arena, query, memory.dataset(), .{}, &problem);
//! const json = try groq.values.to_json(arena, answer.value);
//! ```

const std = @import("std");
const syntax = @import("syntax.zig");
const validate_module = @import("validate.zig");
const evaluate_module = @import("evaluate.zig");
const value_module = @import("value.zig");
const dataset_module = @import("dataset.zig");

pub const Value = value_module.Value;
pub const values = value_module;
pub const evaluation = evaluate_module;
pub const datetimes = @import("datetime.zig");
pub const DatasetError = dataset_module.Error;
pub const Dataset = dataset_module.Dataset;
pub const Memory = dataset_module.Memory;
pub const Hint = dataset_module.Hint;
pub const Found = dataset_module.Found;
pub const Problem = syntax.Problem;
pub const tree = @import("tree.zig");
pub const parse = syntax.parse;

pub const Error = error{ Invalid, OutOfMemory, TooDeep, TooMuchWork, DatasetFailed, OutOfReach };

pub const Options = struct {
    params: value_module.Object = .{},
    now: value_module.Datetime = .{ .seconds = 0 },
    strings_are_references: bool = false,
    work_steps: u64 = std.math.maxInt(u64),
};

pub const Answer = struct { value: Value, problems: []const evaluate_module.Problem };

pub fn execute(
    arena: std.mem.Allocator,
    text: []const u8,
    dataset: Dataset,
    options: Options,
    problem: *Problem,
) Error!Answer {
    std.debug.assert(options.work_steps > 0);

    const query = try syntax.parse_with(arena, text, options.params, problem);

    try validate_module.validate(arena, &query, options.params, problem);

    var context: evaluate_module.Context = .{
        .arena = arena,
        .query = &query,
        .dataset = dataset,
        .params = options.params,
        .now = options.now,
        .strings_are_references = options.strings_are_references,
        .work_left = options.work_steps,
    };

    const result = try evaluate_module.run(&context);

    return .{ .value = result, .problems = context.problems.items };
}

test {
    _ = @import("tokens.zig");
    _ = @import("value.zig");
    _ = @import("datetime.zig");
    _ = @import("operators.zig");
    _ = @import("syntax.zig");
    _ = @import("text_match.zig");
}
