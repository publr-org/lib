//! Shared test scaffolding for the e2e tests in server.zig and the extensions: an
//! ephemeral-port options preset, a one-shot HTTP client, and tick-loop drivers
//! (generic over the app type). Test-only; never part of the library surface.
const std = @import("std");
const builtin = @import("builtin");
const engine_module = @import("engine.zig");
const request_module = @import("http/request.zig");

/// Blocking sleep for tests. The std library has no portable sleep since the Io
/// reorg, and Linux tests must not pull libc, so this dispatches per OS.
pub fn sleep_ms(ms: u32) void {
    std.debug.assert(ms > 0);
    std.debug.assert(ms <= 1000);

    if (builtin.os.tag == .linux) {
        var pause: std.os.linux.timespec = .{
            .sec = ms / 1000,
            .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms,
        };
        _ = std.os.linux.nanosleep(&pause, null);
        return;
    }

    var pause: std.c.timespec = .{
        .sec = ms / 1000,
        .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&pause, null);
}

pub fn options(connections_max: u32) engine_module.Options {
    return .{
        .port = 0,
        .connections_max = connections_max,
        .request_bytes_max = request_module.head_bytes_max,
        .response_bytes_max = 16 << 10,
    };
}

/// Drives the app until it stops or `ticks_max` short ticks elapse.
pub fn serve_until(app: anytype, ticks_max: u32) !void {
    std.debug.assert(ticks_max > 0);
    std.debug.assert(ticks_max <= 1000);

    var ticks: u32 = 0;

    while (ticks < ticks_max and app.engine.phase != .stopped) : (ticks += 1) {
        try app.engine.tick(20);
    }
}

/// Like `serve_until` but swallows errors — the signature `std.Thread.spawn` needs.
pub fn run_ticks(app: anytype, ticks_max: u32) void {
    serve_until(app, ticks_max) catch {};
}

/// A one-shot HTTP client: connects, writes `request` (optionally `request_second`
/// after a pause, for pipelining tests), then reads until the server closes.
pub const Client = struct {
    port: u16,
    request: []const u8,
    request_second: []const u8 = "",
    response: [32768]u8 = undefined,
    response_len: u32 = 0,
    failed: bool = false,

    pub fn run(client: *Client) void {
        client.exchange() catch {
            client.failed = true;
        };
    }

    fn exchange(client: *Client) !void {
        std.debug.assert(client.port > 0);
        std.debug.assert(client.request.len > 0);

        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", client.port);
        const stream = try address.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp });
        defer stream.close(std.testing.io);

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(std.testing.io, &write_buffer);
        try writer.interface.writeAll(client.request);
        try writer.interface.flush();

        if (client.request_second.len > 0) {
            sleep_ms(100);
            try writer.interface.writeAll(client.request_second);
            try writer.interface.flush();
        }

        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        client.response_len = @intCast(try reader.interface.readSliceShort(&client.response));
    }
};
