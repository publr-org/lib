//! Integration tests: a real module (`guest.zig`, built for wasm32-freestanding) run by the
//! vendored interpreter. What is ours: the hand-declared ABI (init arguments, instantiation
//! arguments, calls, memory access), the error mapping (a trap, an exhausted budget, a
//! missing export, bytes that are not a module), the user data handed to host functions,
//! nested calls, and the memory ceiling. WAMR's own semantics are not re-tested.
const std = @import("std");
const wasm = @import("publr_wasm");

const guest_bytes = @embedFile("guest.wasm");
const heap_bytes: u32 = 4 << 20;
/// Above the guest's initial memory (its 1 MiB stack and data), well below 4 GiB.
const pages_max: u32 = 64;

const Seen = struct {
    text: [64]u8 = undefined,
    len: u32 = 0,
};

fn host_echo(env: *wasm.Env, ptr: u32, len: u32) callconv(.c) i32 {
    const seen: *Seen = @ptrCast(@alignCast(env.user_data() orelse return -1));
    const bytes = env.bytes(ptr, len) orelse return -2;

    @memcpy(seen.text[0..bytes.len], bytes);
    seen.len = len;

    return @intCast(len);
}

fn host_nested(env: *wasm.Env) callconv(.c) i32 {
    var problem: wasm.Problem = .{};
    const sum = env.call("add", &.{ 20, 21 }, &problem) catch return -1;

    return @intCast(sum);
}

const imports = [_]wasm.Import{
    .{ .name = "host_echo", .signature = "(ii)i", .function = &host_echo },
    .{ .name = "host_nested", .signature = "()i", .function = &host_nested },
};

const Fixture = struct {
    heap: []u8,
    bytes: []u8,
    runtime: wasm.Runtime,
    module: wasm.Module,
    instance: wasm.Instance,
    problem: wasm.Problem,

    fn init(fixture: *Fixture, ceiling_pages: u32) !void {
        fixture.problem = .{};
        fixture.heap = try std.testing.allocator.alloc(u8, heap_bytes);
        errdefer std.testing.allocator.free(fixture.heap);
        fixture.bytes = try std.testing.allocator.dupe(u8, guest_bytes);
        errdefer std.testing.allocator.free(fixture.bytes);

        try fixture.runtime.init(.{ .heap = fixture.heap, .imports = &imports });
        errdefer fixture.runtime.deinit();
        fixture.module = try wasm.Module.load(&fixture.runtime, fixture.bytes, &fixture.problem);
        errdefer fixture.module.unload();
        fixture.instance = try wasm.Instance.init(&fixture.module, .{
            .memory_pages_max = ceiling_pages,
        }, &fixture.problem);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.instance.deinit();
        fixture.module.unload();
        fixture.runtime.deinit();
        std.testing.allocator.free(fixture.bytes);
        std.testing.allocator.free(fixture.heap);
    }

    fn call(fixture: *Fixture, name: [:0]const u8, params: []const u32) wasm.Error!u32 {
        return fixture.instance.call(name, params, .{
            .instructions_max = 1_000_000,
        }, &fixture.problem);
    }
};

test "an export is called with parameters and answers its result" {
    var fixture: Fixture = undefined;
    try fixture.init(pages_max);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(u32, 42), try fixture.call("add", &.{ 40, 2 }));
    try std.testing.expectError(error.NotFound, fixture.call("missing", &.{}));
    try std.testing.expectEqualStrings("missing", fixture.problem.text());
}

test "a host function reads the guest's memory and finds the call's user data" {
    var fixture: Fixture = undefined;
    try fixture.init(pages_max);
    defer fixture.deinit();

    var seen: Seen = .{};
    const len = try fixture.instance.call("echo", &.{}, .{
        .instructions_max = 1_000_000,
        .user_data = &seen,
    }, &fixture.problem);

    try std.testing.expectEqual(@as(u32, 20), len);
    try std.testing.expectEqualStrings("hello from the guest", seen.text[0..seen.len]);

    // Without user data the host function says so, and the call still completes.
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try fixture.call("echo", &.{}));
}

test "a host function calls back into the same instance" {
    var fixture: Fixture = undefined;
    try fixture.init(pages_max);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(u32, 42), try fixture.call("nested", &.{}));
}

test "a call over its instruction budget stops as exhausted and the instance answers again" {
    var fixture: Fixture = undefined;
    try fixture.init(pages_max);
    defer fixture.deinit();

    try std.testing.expectError(error.Exhausted, fixture.call("spin", &.{1_000_000_000}));
    try std.testing.expect(fixture.problem.len > 0);
    _ = try fixture.call("spin", &.{10});
    try std.testing.expectEqual(@as(u32, 3), try fixture.call("add", &.{ 1, 2 }));
}

test "a trap is an error with WAMR's reason, never a crash" {
    var fixture: Fixture = undefined;
    try fixture.init(pages_max);
    defer fixture.deinit();

    try std.testing.expectError(error.Trap, fixture.call("crash", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, fixture.problem.text(), "unreachable") != null);
}

test "memory grows up to the instance's ceiling and no further; bounds are checked" {
    var fixture: Fixture = undefined;
    try fixture.init(pages_max);
    defer fixture.deinit();

    const initial = try fixture.call("grow", &.{0});
    const grown = try fixture.call("grow", &.{pages_max - initial});
    const refused = try fixture.call("grow", &.{1});

    try std.testing.expectEqual(initial, grown);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), refused);
    try std.testing.expect(fixture.instance.bytes(pages_max * wasm.page_bytes - 1, 1) != null);
    try std.testing.expect(fixture.instance.bytes(pages_max * wasm.page_bytes, 1) == null);
    try std.testing.expect(fixture.instance.bytes(std.math.maxInt(u32), 2) == null);
}

test "a ceiling below the module's own initial memory refuses the instance" {
    var fixture: Fixture = undefined;
    try std.testing.expectError(error.Instantiate, fixture.init(1));
    try std.testing.expect(std.mem.indexOf(u8, fixture.problem.text(), "ceiling") != null);
}

test "bytes that are not a module are refused with a reason" {
    const heap = try std.testing.allocator.alloc(u8, heap_bytes);
    defer std.testing.allocator.free(heap);

    var runtime: wasm.Runtime = undefined;
    try runtime.init(.{ .heap = heap, .imports = &imports });
    defer runtime.deinit();

    var junk = "\x00asm\x01\x00\x00\x00\x01\xff".*;
    var problem: wasm.Problem = .{};

    try std.testing.expectError(error.Load, wasm.Module.load(&runtime, &junk, &problem));
    try std.testing.expect(problem.len > 0);
}
