//! Readiness backend: kqueue on Darwin/BSD, epoll on Linux. Level-triggered on both, so an
//! event that is not fully drained is simply re-reported on the next wait and a lost wakeup
//! cannot deadlock the server.
//!
//! Interest is registered once per connection (read enabled, write disabled) and toggled only
//! on the rare short-write path, so the request hot path costs zero interest syscalls. Tokens
//! are opaque u64 payload carried back by the kernel; the server packs a generation counter
//! into them to reject events for a slot that was closed and reused within one batch.
//!
//! A portable poll() fallback (the default on Windows, forceable with -Devent-backend)
//! provides the same surface at O(registrations) per wait. It cannot receive signals
//! through a kernel queue, so shutdown signals set an atomic flag from a handler instead —
//! the one deliberate piece of global state in the server.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const libc = std.c;
const linux = std.os.linux;
const socket = @import("socket.zig");

pub const backend: Backend = blk: {
    if (build_options.event_backend) |name| {
        break :blk std.meta.stringToEnum(Backend, name) orelse
            @compileError("unknown -Devent-backend, expected kqueue, epoll, or poll");
    }

    break :blk switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly => .kqueue,
        .linux => .epoll,
        else => .poll,
    };
};

pub const Backend = enum { kqueue, epoll, poll };

var poll_signal_flag = std.atomic.Value(bool).init(false);

const PollFd = if (builtin.os.tag == .windows) extern struct {
    fd: socket.Fd,
    events: i16,
    revents: i16,
} else libc.pollfd;

const poll_in: i16 = if (builtin.os.tag == .windows) 0x0300 else @intCast(libc.POLL.IN);
const poll_out: i16 = if (builtin.os.tag == .windows) 0x0010 else @intCast(libc.POLL.OUT);
const poll_err: i16 = if (builtin.os.tag == .windows) 0x0001 else @intCast(libc.POLL.ERR);
const poll_hup: i16 = if (builtin.os.tag == .windows) 0x0002 else @intCast(libc.POLL.HUP);
const poll_nval: i16 = if (builtin.os.tag == .windows) 0x0004 else @intCast(libc.POLL.NVAL);
const poll_eof_mask: i16 = poll_err | poll_hup | poll_nval;

const Registration = struct {
    fd: socket.Fd,
    token: u64,
    interest: Interest,
};

extern "ws2_32" fn WSAPoll(fds: [*]PollFd, count: u32, timeout_ms: i32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCtrlHandler(
    handler: *const fn (u32) callconv(.winapi) i32,
    add: i32,
) callconv(.winapi) i32;

fn console_control_handler(control_type: u32) callconv(.winapi) i32 {
    _ = control_type;
    poll_signal_flag.store(true, .release);
    return 1;
}

fn posix_signal_handler(sig: libc.SIG) callconv(.c) void {
    _ = sig;
    poll_signal_flag.store(true, .release);
}

fn linux_signal_handler(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    poll_signal_flag.store(true, .release);
}

pub const Error = error{ EventInitFailed, EventChangeFailed, EventWaitFailed, OutOfMemory };

pub const Interest = enum { read, write };

pub const token_listener: u64 = std.math.maxInt(u64);
pub const token_signal: u64 = std.math.maxInt(u64) - 1;
pub const token_reserved_first: u64 = token_signal;

pub const Event = struct {
    token: u64,
    readable: bool,
    writable: bool,
    eof: bool,
};

pub const Loop = struct {
    gpa: std.mem.Allocator,
    queue: QueueFd,
    signal_fd: QueueFd = invalid_queue_fd,
    events: []Event,
    kqueue_events: []KqueueEvent,
    epoll_events: []EpollEvent,
    registrations: []PollRegistration,
    registration_count: u32 = 0,
    poll_scan_offset: u32 = 0,
    poll_fds: []PollFd,
    signals_wanted: bool = false,

    const KqueueEvent = if (backend == .kqueue) libc.Kevent else void;
    const EpollEvent = if (backend == .epoll) linux.epoll_event else void;
    const PollRegistration = if (backend == .poll) Registration else void;
    const QueueFd = if (builtin.os.tag == .windows) socket.Fd else std.c.fd_t;
    const invalid_queue_fd: QueueFd = if (builtin.os.tag == .windows) ~@as(usize, 0) else -1;

    pub fn init(gpa: std.mem.Allocator, events_max: u32, registrations_max: u32) Error!Loop {
        std.debug.assert(events_max > 0);
        std.debug.assert(events_max <= 4096);
        std.debug.assert(registrations_max > 0);

        const queue: QueueFd = switch (backend) {
            .kqueue => libc.kqueue(),
            .epoll => epoll_create(),
            .poll => invalid_queue_fd,
        };

        if (backend != .poll and queue == invalid_queue_fd) {
            return error.EventInitFailed;
        }

        errdefer if (backend != .poll) close_queue_fd(queue);

        const events = gpa.alloc(Event, events_max) catch return error.OutOfMemory;
        errdefer gpa.free(events);

        const kqueue_count: u32 = if (backend == .kqueue) events_max else 0;
        const kqueue_events = gpa.alloc(KqueueEvent, kqueue_count) catch return error.OutOfMemory;
        errdefer gpa.free(kqueue_events);

        const epoll_count: u32 = if (backend == .epoll) events_max else 0;
        const epoll_events = gpa.alloc(EpollEvent, epoll_count) catch return error.OutOfMemory;
        errdefer gpa.free(epoll_events);

        const registration_count: u32 = if (backend == .poll) registrations_max else 0;
        const registrations = gpa.alloc(PollRegistration, registration_count) catch
            return error.OutOfMemory;
        errdefer gpa.free(registrations);

        const poll_fds = gpa.alloc(PollFd, registration_count) catch return error.OutOfMemory;

        return .{
            .gpa = gpa,
            .queue = queue,
            .events = events,
            .kqueue_events = kqueue_events,
            .epoll_events = epoll_events,
            .registrations = registrations,
            .poll_fds = poll_fds,
        };
    }

    pub fn deinit(loop: *Loop) void {
        if (loop.signal_fd != invalid_queue_fd) {
            close_queue_fd(loop.signal_fd);
        }

        if (backend != .poll) {
            close_queue_fd(loop.queue);
        }

        loop.gpa.free(loop.poll_fds);
        loop.gpa.free(loop.registrations);
        loop.gpa.free(loop.epoll_events);
        loop.gpa.free(loop.kqueue_events);
        loop.gpa.free(loop.events);
        loop.* = undefined;
    }

    fn close_queue_fd(fd: QueueFd) void {
        switch (builtin.os.tag) {
            .windows => socket.close(fd),
            .linux => _ = linux.close(fd),
            else => _ = libc.close(fd),
        }
    }

    pub fn add_listener(loop: *Loop, fd: socket.Fd) Error!void {
        std.debug.assert(fd != socket.invalid);

        switch (backend) {
            .poll => return loop.poll_register(fd, token_listener, .read),
            else => {},
        }

        switch (backend) {
            .kqueue => {
                var changes = [1]libc.Kevent{
                    kqueue_change(fd, libc.EVFILT.READ, libc.EV.ADD, token_listener),
                };
                try loop.kqueue_submit(&changes);
            },
            .epoll => try loop.epoll_control(
                linux.EPOLL.CTL_ADD,
                fd,
                linux.EPOLL.IN,
                token_listener,
            ),
            .poll => unreachable,
        }
    }

    pub fn add_connection(loop: *Loop, fd: socket.Fd, token: u64) Error!void {
        std.debug.assert(token < token_reserved_first);

        switch (backend) {
            .poll => return loop.poll_register(fd, token, .read),
            else => {},
        }

        switch (backend) {
            .kqueue => {
                var changes = [2]libc.Kevent{
                    kqueue_change(fd, libc.EVFILT.READ, libc.EV.ADD, token),
                    kqueue_change(fd, libc.EVFILT.WRITE, libc.EV.ADD | libc.EV.DISABLE, token),
                };
                try loop.kqueue_submit(&changes);
            },
            .epoll => try loop.epoll_control(linux.EPOLL.CTL_ADD, fd, linux.EPOLL.IN, token),
            .poll => unreachable,
        }
    }

    pub fn direct(loop: *Loop, fd: socket.Fd, token: u64, interest: Interest) Error!void {
        std.debug.assert(token < token_reserved_first);

        switch (backend) {
            .poll => {
                const registration = loop.poll_find(fd) orelse return error.EventChangeFailed;
                registration.interest = interest;
                return;
            },
            else => {},
        }

        switch (backend) {
            .kqueue => {
                const enable: u16 = libc.EV.ENABLE;
                const disable: u16 = libc.EV.DISABLE;
                const read_flags: u16 = if (interest == .read) enable else disable;
                const write_flags: u16 = if (interest == .write) enable else disable;
                var changes = [2]libc.Kevent{
                    kqueue_change(fd, libc.EVFILT.READ, read_flags, token),
                    kqueue_change(fd, libc.EVFILT.WRITE, write_flags, token),
                };
                try loop.kqueue_submit(&changes);
            },
            .epoll => {
                const mask: u32 = if (interest == .read) linux.EPOLL.IN else linux.EPOLL.OUT;
                try loop.epoll_control(linux.EPOLL.CTL_MOD, fd, mask, token);
            },
            .poll => unreachable,
        }
    }

    pub fn forget(loop: *Loop, fd: socket.Fd) void {
        if (backend != .poll) {
            return;
        }

        const registration = loop.poll_find(fd) orelse return;
        const last = loop.registration_count - 1;

        registration.* = loop.registrations[last];
        loop.registration_count = last;
    }

    fn poll_register(loop: *Loop, fd: socket.Fd, token: u64, interest: Interest) Error!void {
        if (backend != .poll) unreachable;

        std.debug.assert(loop.poll_find(fd) == null);

        if (loop.registration_count == loop.registrations.len) {
            return error.EventChangeFailed;
        }

        loop.registrations[loop.registration_count] = .{
            .fd = fd,
            .token = token,
            .interest = interest,
        };
        loop.registration_count += 1;
    }

    fn poll_find(loop: *Loop, fd: socket.Fd) ?*Registration {
        if (backend != .poll) unreachable;

        for (loop.registrations[0..loop.registration_count]) |*registration| {
            if (registration.fd == fd) {
                return registration;
            }
        }

        return null;
    }

    pub fn add_shutdown_signals(loop: *Loop) Error!void {
        switch (backend) {
            .poll => {
                loop.signals_wanted = true;

                switch (builtin.os.tag) {
                    .windows => _ = SetConsoleCtrlHandler(&console_control_handler, 1),
                    .linux => {
                        const action: linux.Sigaction = .{
                            .handler = .{ .handler = &linux_signal_handler },
                            .mask = std.mem.zeroes(linux.sigset_t),
                            .flags = 0,
                        };
                        _ = linux.sigaction(.INT, &action, null);
                        _ = linux.sigaction(.TERM, &action, null);
                    },
                    else => {
                        const action: libc.Sigaction = .{
                            .handler = .{ .handler = &posix_signal_handler },
                            .mask = std.mem.zeroes(libc.sigset_t),
                            .flags = 0,
                        };
                        _ = libc.sigaction(libc.SIG.INT, &action, null);
                        _ = libc.sigaction(libc.SIG.TERM, &action, null);
                    },
                }

                return;
            },
            else => {},
        }

        switch (backend) {
            .kqueue => {
                ignore_signal(libc.SIG.INT);
                ignore_signal(libc.SIG.TERM);

                const sigint = @intFromEnum(libc.SIG.INT);
                const sigterm = @intFromEnum(libc.SIG.TERM);
                var changes = [2]libc.Kevent{
                    kqueue_change(sigint, libc.EVFILT.SIGNAL, libc.EV.ADD, token_signal),
                    kqueue_change(sigterm, libc.EVFILT.SIGNAL, libc.EV.ADD, token_signal),
                };
                try loop.kqueue_submit(&changes);
            },
            .epoll => {
                var mask = std.mem.zeroes(linux.sigset_t);
                linux.sigaddset(&mask, .INT);
                linux.sigaddset(&mask, .TERM);
                _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);

                const rc = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);

                if (linux.errno(rc) != .SUCCESS) {
                    return error.EventInitFailed;
                }

                const fd: QueueFd = @intCast(rc);
                loop.signal_fd = fd;
                try loop.epoll_control(linux.EPOLL.CTL_ADD, fd, linux.EPOLL.IN, token_signal);
            },
            .poll => unreachable,
        }
    }

    pub fn wait(loop: *Loop, timeout_ms: i32) Error![]const Event {
        if (backend != .poll) std.debug.assert(loop.queue != invalid_queue_fd);
        std.debug.assert(timeout_ms >= 0);

        const count = switch (backend) {
            .kqueue => try loop.kqueue_wait(timeout_ms),
            .epoll => try loop.epoll_wait(timeout_ms),
            .poll => try loop.poll_wait(timeout_ms),
        };

        std.debug.assert(count <= loop.events.len);

        return loop.events[0..count];
    }

    fn poll_wait(loop: *Loop, timeout_ms: i32) Error!u32 {
        if (backend != .poll) unreachable;

        const active = loop.registration_count;

        for (loop.registrations[0..active], loop.poll_fds[0..active]) |registration, *entry| {
            entry.* = .{
                .fd = registration.fd,
                .events = if (registration.interest == .read) poll_in else poll_out,
                .revents = 0,
            };
        }

        const ready = poll_call(loop.poll_fds[0..active], timeout_ms) catch
            return error.EventWaitFailed;

        return loop.poll_collect(ready);
    }

    fn poll_collect(loop: *Loop, ready: u32) u32 {
        if (backend != .poll) unreachable;

        var count: u32 = 0;

        if (loop.signals_wanted and poll_signal_flag.swap(false, .acq_rel)) {
            loop.events[count] = .{
                .token = token_signal,
                .readable = false,
                .writable = false,
                .eof = false,
            };
            count += 1;
        }

        if (ready == 0) {
            return count;
        }

        const active = loop.registration_count;
        const start = if (active == 0) 0 else loop.poll_scan_offset % active;
        loop.poll_scan_offset +%= 1;

        var scanned: u32 = 0;

        while (scanned < active) : (scanned += 1) {
            const index = (start + scanned) % active;
            const entry = loop.poll_fds[index];
            const registration = loop.registrations[index];

            if (entry.revents == 0) {
                continue;
            }

            if (count == loop.events.len) {
                break;
            }

            loop.events[count] = .{
                .token = registration.token,
                .readable = entry.revents & poll_in != 0,
                .writable = entry.revents & poll_out != 0,
                .eof = entry.revents & poll_eof_mask != 0,
            };
            count += 1;
        }

        return count;
    }

    fn kqueue_wait(loop: *Loop, timeout_ms: i32) Error!u32 {
        const timeout: libc.timespec = .{
            .sec = @divTrunc(timeout_ms, 1000),
            .nsec = @as(isize, @mod(timeout_ms, 1000)) * std.time.ns_per_ms,
        };
        const no_changes = [0]libc.Kevent{};
        const result = libc.kevent(
            loop.queue,
            &no_changes,
            0,
            loop.kqueue_events.ptr,
            @intCast(loop.kqueue_events.len),
            &timeout,
        );

        if (result < 0) {
            return switch (libc.errno(result)) {
                .INTR => 0,
                else => error.EventWaitFailed,
            };
        }

        const count: u32 = @intCast(result);

        for (loop.kqueue_events[0..count], loop.events[0..count]) |kernel, *event| {
            const is_signal = kernel.filter == libc.EVFILT.SIGNAL;

            event.* = .{
                .token = if (is_signal) token_signal else kernel.udata,
                .readable = kernel.filter == libc.EVFILT.READ,
                .writable = kernel.filter == libc.EVFILT.WRITE,
                .eof = kernel.flags & libc.EV.EOF != 0,
            };
        }

        return count;
    }

    fn epoll_wait(loop: *Loop, timeout_ms: i32) Error!u32 {
        if (backend != .epoll) unreachable;

        const result = linux.epoll_wait(
            loop.queue,
            loop.epoll_events.ptr,
            @intCast(loop.epoll_events.len),
            timeout_ms,
        );

        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => return 0,
            else => return error.EventWaitFailed,
        }

        const count: u32 = @intCast(result);

        for (loop.epoll_events[0..count], loop.events[0..count]) |kernel, *event| {
            const hangup = linux.EPOLL.HUP | linux.EPOLL.RDHUP | linux.EPOLL.ERR;

            if (kernel.data.u64 == token_signal) {
                loop.drain_signal_fd();
            }

            event.* = .{
                .token = kernel.data.u64,
                .readable = kernel.events & linux.EPOLL.IN != 0,
                .writable = kernel.events & linux.EPOLL.OUT != 0,
                .eof = kernel.events & hangup != 0,
            };
        }

        return count;
    }

    fn drain_signal_fd(loop: *Loop) void {
        if (backend != .epoll) unreachable;

        std.debug.assert(loop.signal_fd >= 0);

        var sink: [512]u8 = undefined;
        var reads: u32 = 0;

        while (reads < 16) : (reads += 1) {
            const rc = linux.read(loop.signal_fd, &sink, sink.len);

            if (linux.errno(rc) != .SUCCESS or rc == 0) {
                return;
            }
        }
    }

    fn kqueue_submit(loop: *Loop, changes: []libc.Kevent) Error!void {
        std.debug.assert(changes.len > 0);
        std.debug.assert(changes.len <= 2);

        const result = libc.kevent(
            loop.queue,
            changes.ptr,
            @intCast(changes.len),
            loop.kqueue_events.ptr,
            0,
            null,
        );

        if (result < 0) {
            return error.EventChangeFailed;
        }
    }

    fn epoll_control(loop: *Loop, operation: u32, fd: socket.Fd, mask: u32, token: u64) Error!void {
        if (backend != .epoll) unreachable;

        var event: linux.epoll_event = .{
            .events = mask | linux.EPOLL.RDHUP,
            .data = .{ .u64 = token },
        };
        const result = linux.epoll_ctl(loop.queue, operation, fd, &event);

        if (linux.errno(result) != .SUCCESS) {
            return error.EventChangeFailed;
        }
    }
};

/// One poll() round: the ready count, with EINTR already folded into "0 ready".
fn poll_call(fds: []PollFd, timeout_ms: i32) error{PollFailed}!u32 {
    if (builtin.os.tag == .windows) {
        if (fds.len == 0) {
            var dummy = [1]PollFd{.{ .fd = ~@as(usize, 0), .events = 0, .revents = 0 }};
            const ready = WSAPoll(&dummy, 1, timeout_ms);
            return if (ready < 0) error.PollFailed else @intCast(ready);
        }

        const ready = WSAPoll(fds.ptr, @intCast(fds.len), timeout_ms);
        return if (ready < 0) error.PollFailed else @intCast(ready);
    }

    if (builtin.os.tag == .linux) {
        const rc = linux.poll(@ptrCast(fds.ptr), @intCast(fds.len), timeout_ms);

        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => 0,
            else => error.PollFailed,
        };
    }

    const ready = libc.poll(@ptrCast(fds.ptr), @intCast(fds.len), timeout_ms);

    if (ready < 0) {
        return if (libc.errno(ready) == .INTR) 0 else error.PollFailed;
    }

    return @intCast(ready);
}

/// The epoll instance fd, or the invalid fd on failure (checked by `init`).
fn epoll_create() i32 {
    const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);

    if (linux.errno(rc) != .SUCCESS) {
        return -1;
    }

    return @intCast(rc);
}

fn kqueue_change(ident: anytype, filter: i16, flags: u16, token: u64) libc.Kevent {
    return .{
        .ident = @intCast(ident),
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = token,
    };
}

fn ignore_signal(signal: libc.SIG) void {
    std.debug.assert(@intFromEnum(signal) > 0);

    const action: libc.Sigaction = .{
        .handler = .{ .handler = libc.SIG.IGN },
        .mask = std.mem.zeroes(libc.sigset_t),
        .flags = 0,
    };
    _ = libc.sigaction(signal, &action, null);
}

test "a listener becomes readable when a client connects" {
    const listener = try socket.listen_tcp(.{ 127, 0, 0, 1 }, 0, 4);
    defer socket.close(listener);

    var loop = try Loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();

    try loop.add_listener(listener);
    try std.testing.expectEqual(@as(usize, 0), (try loop.wait(0)).len);

    const port = try socket.bound_port(listener);
    const client = try socket.connect_tcp(.{ 127, 0, 0, 1 }, port);
    defer socket.close(client);

    const events = try loop.wait(1000);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(token_listener, events[0].token);
    try std.testing.expect(events[0].readable);
}

test "a peer close surfaces as an event and recv reports the closed connection" {
    const listener = try socket.listen_tcp(.{ 127, 0, 0, 1 }, 0, 4);
    defer socket.close(listener);

    var loop = try Loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();

    try loop.add_listener(listener);

    const port = try socket.bound_port(listener);
    const client = try socket.connect_tcp(.{ 127, 0, 0, 1 }, port);

    _ = try loop.wait(1000);

    const accepted = (try socket.accept(listener)).?;
    defer socket.close(accepted);

    try loop.add_connection(accepted, 5);
    socket.close(client);

    var found = false;
    var attempts: u32 = 0;

    while (!found and attempts < 10) : (attempts += 1) {
        for (try loop.wait(200)) |item| {
            if (item.token == 5 and (item.eof or item.readable)) {
                found = true;
            }
        }
    }

    try std.testing.expect(found);

    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, socket.recv(accepted, &buffer));
}

test "write interest stays silent until directed, then fires" {
    const listener = try socket.listen_tcp(.{ 127, 0, 0, 1 }, 0, 4);
    defer socket.close(listener);

    var loop = try Loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();

    const port = try socket.bound_port(listener);
    const client = try socket.connect_tcp(.{ 127, 0, 0, 1 }, port);
    defer socket.close(client);

    try loop.add_listener(listener);
    _ = try loop.wait(1000);

    const accepted = (try socket.accept(listener)).?;
    defer socket.close(accepted);

    try loop.add_connection(accepted, 7);

    try std.testing.expectEqual(@as(usize, 0), (try loop.wait(50)).len);

    try loop.direct(accepted, 7, .write);

    const events = try loop.wait(1000);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(u64, 7), events[0].token);
    try std.testing.expect(events[0].writable);

    try loop.direct(accepted, 7, .read);
    try std.testing.expectEqual(@as(usize, 0), (try loop.wait(50)).len);
}
