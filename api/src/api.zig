//! Publr's REST API as its clients read it: the one place the shape of `/api/<operation>`
//! is known outside Publr. `POST /api/<namespace>.<verb>` with the input as a JSON object
//! answers `{ "result": <the operation's answer>, "meta": { ... } }`: `meta.next` is the
//! page after this one for an operation answering a page at a time. A refusal answers a
//! status past 299 and `{ "error", "message", "problems" }`. Sending is the client's own
//! (each has its transport); what is sent and read is here, so a change to the shape is one
//! change to this file.
const std = @import("std");

/// The route of an operation: `/api/record.list`.
pub fn path(arena: std.mem.Allocator, operation: []const u8) error{ OutOfMemory, Invalid }![]u8 {
    const dot = std.mem.indexOfScalar(u8, operation, '.') orelse return error.Invalid;

    if (dot == 0 or dot + 1 == operation.len) {
        return error.Invalid;
    }

    return std.fmt.allocPrint(arena, "/api/{s}", .{operation});
}

/// What is about a call itself.
pub const Meta = struct {
    /// The page after this one, for `after`: empty after the last, or for an operation that
    /// answers in one piece.
    next: []const u8 = "",
};

/// A call's whole answer: the operation's own, and what is about the call.
pub fn Answered(comptime Out: type) type {
    return struct {
        result: Out,
        meta: Meta = .{},
    };
}

pub const Problem = struct {
    field: []const u8 = "",
    message: []const u8 = "",
};

/// A refused call: its code (`Invalid`, `Denied`, a plugin's own failure), what it says,
/// and what was wrong with each field.
pub const Refusal = struct {
    @"error": []const u8 = "",
    message: []const u8 = "",
    problems: []const Problem = &.{},
};

pub const ReadError = error{ OutOfMemory, Invalid };

/// An answer as the operation's `Out`, with `meta` beside it. Fields the client does not
/// name are let be: the answer may say more than a client knows.
pub fn read(
    comptime Out: type,
    arena: std.mem.Allocator,
    body: []const u8,
) ReadError!Answered(Out) {
    return std.json.parseFromSliceLeaky(Answered(Out), arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

/// Only the operation's answer.
pub fn result(comptime Out: type, arena: std.mem.Allocator, body: []const u8) ReadError!Out {
    return (try read(Out, arena, body)).result;
}

/// The operation's answer as its JSON, for a client that prints or passes it on.
pub fn result_json(arena: std.mem.Allocator, body: []const u8) ReadError![]const u8 {
    const value = try read(std.json.Value, arena, body);

    return std.json.Stringify.valueAlloc(arena, value.result, .{}) catch error.OutOfMemory;
}

/// What a refusal says; empty words when its body is not one.
pub fn refusal(arena: std.mem.Allocator, body: []const u8) Refusal {
    return std.json.parseFromSliceLeaky(Refusal, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{};
}

test "an answer is its result beside meta; a refusal its words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const Listed = struct {
        names: []const []const u8,
    };
    const answered = try read(Listed, arena, "{\"result\":{\"names\":[\"a\"],\"more\":1}," ++
        "\"meta\":{\"next\":\"a\"}}");

    try std.testing.expectEqualStrings("a", answered.result.names[0]);
    try std.testing.expectEqualStrings("a", answered.meta.next);
    try std.testing.expectEqualStrings("", (try read(Listed, arena, "{\"result\":{\"names\":[]}}"))
        .meta.next);
    try std.testing.expectError(error.Invalid, read(Listed, arena, "{\"names\":[]}"));
    try std.testing.expectEqualStrings("{\"id\":\"x\"}", try result_json(
        arena,
        "{\"result\":{\"id\":\"x\"},\"meta\":{}}",
    ));

    const refused = refusal(arena, "{\"error\":\"Invalid\",\"problems\":[{\"field\":\"name\"," ++
        "\"message\":\"Required\"}]}");

    try std.testing.expectEqualStrings("Invalid", refused.@"error");
    try std.testing.expectEqualStrings("name", refused.problems[0].field);
    try std.testing.expectEqualStrings("/api/record.list", try path(arena, "record.list"));
    try std.testing.expectError(error.Invalid, path(arena, "record"));
}
