//! Process introspection for /stats-style endpoints: pid and cumulative CPU time.
//! Plain utilities, not an extension — the server counters are an always-on engine
//! feature (`engine.counters`); this module covers what only the OS knows about the
//! process. Nothing here runs unless a handler calls it.
const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetProcessTimes(
    handle: *anyopaque,
    creation: *u64,
    exit: *u64,
    kernel: *u64,
    user: *u64,
) callconv(.winapi) i32;

/// This process's id, for labeling stats when running several instances side by side.
pub fn id() u32 {
    return switch (builtin.os.tag) {
        .windows => GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// Cumulative user+system CPU time of this process in microseconds. Sampled twice
/// over a wall-clock interval, the delta over the interval is cores-in-use — the
/// direct answer to "is the server saturated".
pub fn cpu_micros() u64 {
    if (builtin.os.tag == .windows) {
        var creation: u64 = 0;
        var exit_time: u64 = 0;
        var kernel: u64 = 0;
        var user: u64 = 0;
        const result = GetProcessTimes(GetCurrentProcess(), &creation, &exit_time, &kernel, &user);

        std.debug.assert(result != 0);

        return (kernel + user) / 10;
    }

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rusage_self: i32 = 0;
        var usage: linux.rusage = undefined;
        const result = linux.getrusage(rusage_self, &usage);

        std.debug.assert(linux.errno(result) == .SUCCESS);

        const user: u64 = @as(u64, @intCast(usage.utime.sec)) * std.time.us_per_s +
            @as(u64, @intCast(usage.utime.usec));
        const system: u64 = @as(u64, @intCast(usage.stime.sec)) * std.time.us_per_s +
            @as(u64, @intCast(usage.stime.usec));

        return user + system;
    }

    var usage: std.c.rusage = undefined;
    const result = std.c.getrusage(std.c.rusage.SELF, &usage);

    std.debug.assert(result == 0);

    const user: u64 = @as(u64, @intCast(usage.utime.sec)) * std.time.us_per_s +
        @as(u64, @intCast(usage.utime.usec));
    const system: u64 = @as(u64, @intCast(usage.stime.sec)) * std.time.us_per_s +
        @as(u64, @intCast(usage.stime.usec));

    return user + system;
}

test "cpu_micros is monotonic" {
    const first = cpu_micros();
    var spin: u64 = 0;

    for (0..100_000) |index| {
        spin +%= index;
    }

    std.mem.doNotOptimizeAway(spin);
    try std.testing.expect(cpu_micros() >= first);
}

test "the pid is stable and nonzero" {
    try std.testing.expect(id() > 0);
    try std.testing.expectEqual(id(), id());
}
