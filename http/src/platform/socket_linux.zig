//! Linux implementation of the socket surface via raw syscalls (std.os.linux), no
//! libc involved — the same move socket_windows.zig makes with direct DLL externs.
//! Linux has the one stable syscall ABI, and staying on it keeps release binaries
//! fully static and libc-free. Nonblocking and close-on-exec are set atomically at
//! creation (SOCK_NONBLOCK/SOCK_CLOEXEC), and sends use MSG_NOSIGNAL, so the fcntl
//! and SIGPIPE dances of the POSIX impl disappear entirely.
const std = @import("std");
const linux = std.os.linux;

pub const Fd = i32;

pub const invalid: Fd = -1;

/// Setup failures: what binding a listener can report. This is the platform half of
/// the engine's `Error`, so the engine spells the members out rather than merging.
pub const Error = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    AddressInUse,
    FileLimitReached,
    FileLimitTooLow,
    Unexpected,
};

/// Per-connection I/O failures. Every caller handles these on the spot (a dead peer
/// closes the slot, a full kernel buffer waits for writability), so none of them
/// ever surface through the engine.
pub const IoError = error{
    WouldBlock,
    ConnectionClosed,
    ConnectionReset,
    FileLimitReached,
    SocketFailed,
    Unexpected,
};

pub fn listen_tcp(address: [4]u8, port: u16, backlog: u31) Error!Fd {
    std.debug.assert(backlog > 0);

    const fd = try open_socket();
    errdefer close(fd);

    try set_reuse_address(fd);

    var sockaddr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };

    switch (linux.errno(linux.bind(fd, @ptrCast(&sockaddr), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.BindFailed,
    }

    if (linux.errno(linux.listen(fd, backlog)) != .SUCCESS) {
        return error.ListenFailed;
    }

    std.debug.assert(fd >= 0);

    return fd;
}

pub fn connect_tcp(address: [4]u8, port: u16) IoError!Fd {
    std.debug.assert(port > 0);

    const fd = try open_socket();
    errdefer close(fd);

    try set_no_delay(fd);

    var sockaddr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };

    switch (linux.errno(linux.connect(fd, @ptrCast(&sockaddr), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS, .INPROGRESS => {},
        .CONNRESET, .CONNREFUSED => return error.ConnectionReset,
        else => return error.Unexpected,
    }

    std.debug.assert(fd >= 0);

    return fd;
}

pub fn connect_result(fd: Fd) IoError!void {
    std.debug.assert(fd >= 0);

    var so_error: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    const result = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &len);

    if (linux.errno(result) != .SUCCESS) {
        return error.Unexpected;
    }

    if (so_error != 0) {
        return error.ConnectionReset;
    }
}

pub fn accept(listener: Fd) IoError!?Fd {
    std.debug.assert(listener >= 0);

    const rc = linux.accept4(listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .CONNABORTED, .INTR => return null,
        .MFILE, .NFILE => return error.FileLimitReached,
        else => return error.Unexpected,
    }

    const fd: Fd = @intCast(rc);
    errdefer close(fd);

    try set_no_delay(fd);

    std.debug.assert(fd != listener);

    return fd;
}

pub fn recv(fd: Fd, buffer: []u8) IoError!u32 {
    std.debug.assert(fd >= 0);
    std.debug.assert(buffer.len > 0);

    const rc = linux.recvfrom(fd, buffer.ptr, buffer.len, 0, null, null);

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .INTR => return error.WouldBlock,
        .CONNRESET => return error.ConnectionReset,
        else => return error.Unexpected,
    }

    if (rc == 0) {
        return error.ConnectionClosed;
    }

    return @intCast(rc);
}

pub fn send(fd: Fd, bytes: []const u8) IoError!u32 {
    std.debug.assert(fd >= 0);
    std.debug.assert(bytes.len > 0);

    const rc = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .INTR => return error.WouldBlock,
        .PIPE, .CONNRESET => return error.ConnectionReset,
        else => return error.Unexpected,
    }

    return @intCast(rc);
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn bound_port(fd: Fd) Error!u16 {
    std.debug.assert(fd >= 0);

    var storage: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const result = linux.getsockname(fd, @ptrCast(&storage), &len);

    if (linux.errno(result) != .SUCCESS) {
        return error.Unexpected;
    }

    const port = std.mem.bigToNative(u16, storage.port);
    std.debug.assert(port > 0);

    return port;
}

pub fn ensure_file_limit(files_needed: u64) Error!void {
    std.debug.assert(files_needed > 0);
    std.debug.assert(files_needed < 1 << 24);

    var limit: linux.rlimit = undefined;

    if (linux.errno(linux.getrlimit(.NOFILE, &limit)) != .SUCCESS) {
        return error.Unexpected;
    }

    if (limit.cur >= files_needed) {
        return;
    }

    limit.cur = @min(files_needed, limit.max);

    if (linux.errno(linux.setrlimit(.NOFILE, &limit)) != .SUCCESS) {
        return error.FileLimitTooLow;
    }

    if (limit.cur < files_needed) {
        return error.FileLimitTooLow;
    }
}

pub fn read_small_file(path: []const u8, buffer: []u8) ?u32 {
    std.debug.assert(path.len > 0);
    std.debug.assert(buffer.len > 0);

    const fd = open_read(path) orelse return null;
    defer close(fd);

    var total: u32 = 0;

    while (total < buffer.len) {
        const rc = linux.read(fd, buffer[total..].ptr, buffer.len - total);

        if (linux.errno(rc) != .SUCCESS) {
            return null;
        }

        if (rc == 0) {
            return total;
        }

        total += @intCast(rc);
    }

    return null;
}

/// The outcome of `read_file`: how many bytes landed in the buffer, or why none did.
/// Directories and unreadable paths report `.not_found`; a regular file larger than
/// the buffer reports `.too_large` so callers can distinguish "absent" from "present
/// but over the response cap".
pub const FileRead = union(enum) { len: u32, not_found, too_large };

pub fn read_file(fd: Fd, buffer: []u8) FileRead {
    std.debug.assert(fd >= 0);
    std.debug.assert(buffer.len > 0);

    var stat: linux.Statx = undefined;

    const statx_result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
        .TYPE = true,
        .SIZE = true,
    }, &stat);

    if (linux.errno(statx_result) != .SUCCESS) {
        return .not_found;
    }

    // Regular files only. A directory, FIFO, socket, or device node under root
    // is not served — a FIFO especially would block the single-threaded loop
    // in read() forever.
    if (!linux.S.ISREG(stat.mode)) {
        return .not_found;
    }

    if (stat.size > buffer.len) {
        return .too_large;
    }

    const size: u32 = @intCast(stat.size);
    var total: u32 = 0;

    while (total < size) {
        const rc = linux.read(fd, buffer[total..].ptr, size - total);

        if (linux.errno(rc) != .SUCCESS) {
            return .not_found;
        }

        if (rc == 0) {
            break;
        }

        total += @intCast(rc);
    }

    return .{ .len = total };
}

/// Opens the file named by the `/`-separated `rel` path under `root`, refusing to
/// follow any symlink in any component — intermediate or final. The root directory is
/// opened once; every directory component is then opened with `openat` +
/// `O_DIRECTORY` + `O_NOFOLLOW`, and the final component with `openat` + `O_NOFOLLOW`.
/// The walk is one syscall per component, so no component can be swapped for a
/// symlink between check and use. Returns the open file descriptor, or null when the
/// path is absent, over-long, or any component is a symlink.
pub fn open_under(root: []const u8, rel: []const u8) ?Fd {
    std.debug.assert(root.len > 0);
    std.debug.assert(rel.len > 0);

    var root_z: [1024:0]u8 = undefined;
    if (root.len >= 1024) return null;
    @memcpy(root_z[0..root.len], root);
    root_z[root.len] = 0;

    const root_flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const root_rc = linux.open(&root_z, root_flags, 0);
    if (linux.errno(root_rc) != .SUCCESS) return null;
    const root_fd: Fd = @intCast(root_rc);
    defer close(root_fd);

    var segment_z: [1024:0]u8 = undefined;
    var segments = std.mem.splitScalar(u8, rel, '/');
    var current: Fd = root_fd;

    while (segments.next()) |segment| {
        if (segment.len == 0) return null;
        if (segment.len >= 1024) return null;
        @memcpy(segment_z[0..segment.len], segment);
        segment_z[segment.len] = 0;

        const is_last = segments.peek() == null;
        const flags: linux.O = if (is_last)
            .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }
        else
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

        const rc = linux.openat(current, &segment_z, flags, 0);
        if (linux.errno(rc) != .SUCCESS) {
            if (current != root_fd) close(current);
            return null;
        }

        const next: Fd = @intCast(rc);
        if (current != root_fd) close(current);
        current = next;
    }

    return current;
}

pub fn monotonic_ms() i64 {
    var spec: linux.timespec = undefined;
    const result = linux.clock_gettime(.MONOTONIC, &spec);

    std.debug.assert(linux.errno(result) == .SUCCESS);

    return @as(i64, spec.sec) * 1000 + @divTrunc(spec.nsec, std.time.ns_per_ms);
}

pub fn effective_backlog_cap() ?u32 {
    const fd = open_read("/proc/sys/net/core/somaxconn") orelse return null;
    defer close(fd);

    var buffer: [32]u8 = undefined;
    const rc = linux.read(fd, &buffer, buffer.len);

    if (linux.errno(rc) != .SUCCESS or rc == 0) {
        return null;
    }

    const text = std.mem.trim(u8, buffer[0..@intCast(rc)], " \n");

    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn open_socket() error{ SocketFailed, FileLimitReached }!Fd {
    const socket_type = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const rc = linux.socket(linux.AF.INET, socket_type, linux.IPPROTO.TCP);

    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE, .NFILE => return error.FileLimitReached,
        else => return error.SocketFailed,
    }
}

fn open_read(path: []const u8) ?Fd {
    if (path.len >= 1024) {
        return null;
    }

    var path_z: [1024:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    // Used only for operator-supplied single paths (config file, /proc). NOFOLLOW
    // refuses a final-component symlink; a full no-symlink walk is `open_under`'s job.
    const rc = linux.open(&path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);

    if (linux.errno(rc) != .SUCCESS) {
        return null;
    }

    return @intCast(rc);
}

fn set_reuse_address(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);

    const on: i32 = 1;
    const result = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        @ptrCast(&on),
        @sizeOf(i32),
    );

    if (linux.errno(result) != .SUCCESS) {
        return error.Unexpected;
    }
}

fn set_no_delay(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);

    const on: i32 = 1;
    const result = linux.setsockopt(
        fd,
        linux.IPPROTO.TCP,
        linux.TCP.NODELAY,
        @ptrCast(&on),
        @sizeOf(i32),
    );

    if (linux.errno(result) != .SUCCESS) {
        return error.Unexpected;
    }
}

test "listen_tcp binds an ephemeral port a client can connect to" {
    const listener = try listen_tcp(.{ 127, 0, 0, 1 }, 0, 4);
    defer close(listener);

    const port = try bound_port(listener);
    const fd = try connect_tcp(.{ 127, 0, 0, 1 }, port);
    defer close(fd);

    try std.testing.expect(fd >= 0);
}

test "ensure_file_limit is satisfied for a trivial count" {
    try ensure_file_limit(64);
}
