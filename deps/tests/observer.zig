//! TESTS.md §8 — the observer: a tap that sees what changed, the resolved
//! graph, the deduped plan, and the execution — and can change nothing.
const std = @import("std");
const deps = @import("publr_deps");
const helper = @import("helper.zig");

/// Records every event as one formatted line, so a test asserts the whole
/// story at once.
const Recorder = struct {
    lines: std.ArrayList([]const u8) = .empty,
    arena: std.mem.Allocator,

    fn add(recorder: *Recorder, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(recorder.arena, fmt, args) catch return;
        recorder.lines.append(recorder.arena, line) catch {};
    }
    fn self(context: ?*anyopaque) *Recorder {
        return @ptrCast(@alignCast(context.?));
    }
    fn invalidated(context: ?*anyopaque, key: []const u8, first_time: bool) void {
        self(context).add("invalidated {s} first={}", .{ key, first_time });
    }
    fn sealed(context: ?*anyopaque, batch: u64, keys: []const []const u8) void {
        self(context).add("sealed #{d} n={d}", .{ batch, keys.len });
    }
    fn planned(context: ?*anyopaque, batch: u64, key: []const u8, artifacts: []const []const u8) void {
        var recorder = self(context);
        var list: std.ArrayList(u8) = .empty;
        for (artifacts) |artifact| {
            list.print(recorder.arena, " {s}", .{artifact}) catch {};
        }
        recorder.add("planned #{d} {s} →{s}", .{ batch, key, list.items });
    }
    fn plan(context: ?*anyopaque, batch: u64, artifacts: []const []const u8) void {
        self(context).add("plan #{d} n={d}", .{ batch, artifacts.len });
    }
    fn executed(context: ?*anyopaque, batch: u64, artifact: []const u8, outcome: deps.Outcome, detail: []const u8) void {
        self(context).add("executed #{d} {s} {s}{s}{s}", .{ batch, artifact, @tagName(outcome), if (detail.len > 0) " " else "", detail });
    }
    fn refused(context: ?*anyopaque, batch: u64, count: u64, limit: u64) void {
        self(context).add("refused #{d} {d}>{d}", .{ batch, count, limit });
    }

    fn observer(recorder: *Recorder) deps.Observer {
        return .{
            .context = recorder,
            .invalidated = invalidated,
            .sealed = sealed,
            .planned = planned,
            .plan = plan,
            .executed = executed,
            .refused = refused,
        };
    }
};

fn watched(world: *helper.World, options: deps.Options, recorder: *Recorder) !void {
    try world.open(options);
    recorder.arena = world.arena_state.allocator();
    world.index.options.observer = recorder.observer();
}

fn expect_lines(recorder: *const Recorder, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, recorder.lines.items.len);
    for (expected, recorder.lines.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "8.1 silence is free" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);
    _ = try world.flush(1000); // no observer: nothing to assert is the assertion
}

test "8.2 what changed, coalescing visible" {
    var recorder: Recorder = .{ .arena = undefined };
    var world: helper.World = undefined;
    try watched(&world, .{ .quiet_ms = 1000 }, &recorder);
    defer world.close();
    for (0..3) |_| try world.index.invalidate(&.{"entry:1"}, 0);
    try expect_lines(&recorder, &.{
        "invalidated entry:1 first=true",
        "invalidated entry:1 first=false",
        "invalidated entry:1 first=false",
    });
}

test "8.3 + 8.4 the resolved graph, the plan, the execution" {
    var recorder: Recorder = .{ .arena = undefined };
    var world: helper.World = undefined;
    try watched(&world, .{ .quiet_ms = 1000 }, &recorder);
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/b", &.{ "entry:1", "entry:2" });
    try world.index.invalidate(&.{ "entry:1", "entry:2" }, 0);

    const batch = (try world.index.take(world.arena(), 1000)).?;
    const artifacts = try world.index.plan(world.arena(), batch);
    world.index.executed(batch.no, artifacts[0], .written, "");
    world.index.executed(batch.no, artifacts[1], .identical, "");
    try world.index.done(batch);

    try expect_lines(&recorder, &.{
        "invalidated entry:1 first=true",
        "invalidated entry:2 first=true",
        "sealed #1 n=2",
        "planned #1 entry:1 → /a /b",
        "planned #1 entry:2 → /b",
        "plan #1 n=2",
        "executed #1 /a written",
        "executed #1 /b identical",
    });
}

test "8.5 a refusal is an event, and no execution follows" {
    var recorder: Recorder = .{ .arena = undefined };
    var world: helper.World = undefined;
    try watched(&world, .{ .quiet_ms = 1000, .fanout_max = 1 }, &recorder);
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/b", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);

    const batch = (try world.index.take(world.arena(), 1000)).?;
    try std.testing.expectError(error.FanOutExceeded, world.index.plan(world.arena(), batch));
    try expect_lines(&recorder, &.{
        "invalidated entry:1 first=true",
        "sealed #1 n=1",
        "refused #1 2>1",
    });
}

test "8.6 batches are distinguishable and never interleave" {
    var recorder: Recorder = .{ .arena = undefined };
    var world: helper.World = undefined;
    try watched(&world, .{ .quiet_ms = 60_000, .queue_cap = 2 }, &recorder);
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/c", &.{"entry:3"});
    try world.index.invalidate(&.{ "entry:1", "entry:2" }, 0);
    try world.index.invalidate(&.{ "entry:3", "entry:4" }, 1);

    _ = try world.flush(2);
    _ = try world.flush(3);

    try expect_lines(&recorder, &.{
        "invalidated entry:1 first=true",
        "invalidated entry:2 first=true",
        "sealed #1 n=2",
        "invalidated entry:3 first=true",
        "invalidated entry:4 first=true",
        "sealed #2 n=2",
        "planned #1 entry:1 → /a",
        "planned #1 entry:2 →",
        "plan #1 n=1",
        "planned #2 entry:3 → /c",
        "planned #2 entry:4 →",
        "plan #2 n=1",
    });
}

test "8.7 the observer sees what the API would say" {
    var recorder: Recorder = .{ .arena = undefined };
    var world: helper.World = undefined;
    try watched(&world, .{ .quiet_ms = 1000 }, &recorder);
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);

    const batch = (try world.index.take(world.arena(), 1000)).?;
    const direct = try world.index.affected(world.arena(), &.{"entry:1"});
    _ = try world.index.plan(world.arena(), batch);
    try world.index.done(batch);

    var found = false;
    for (recorder.lines.items) |line| {
        if (std.mem.startsWith(u8, line, "planned #1 entry:1 →")) {
            found = true;
            try std.testing.expectEqualStrings("planned #1 entry:1 → /a", line);
            try std.testing.expectEqual(@as(usize, 1), direct.len);
            try std.testing.expectEqualStrings(direct[0], "/a");
        }
    }
    try std.testing.expect(found);
}
