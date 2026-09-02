//! POSIX libc implementation of the socket surface, for Darwin and the BSDs — the
//! platforms where libc is the stable kernel ABI and comes linked implicitly. Linux
//! uses socket_linux.zig (raw syscalls) and Windows socket_windows.zig (Winsock).
const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

pub const Fd = std.c.fd_t;

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

    const fd = libc.socket(libc.AF.INET, libc.SOCK.STREAM, libc.IPPROTO.TCP);

    if (fd < 0) {
        return error.SocketFailed;
    }

    errdefer close(fd);

    try set_reuse_address(fd);
    try set_nonblocking(fd);
    try set_cloexec(fd);

    var sockaddr: libc.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    const sockaddr_ptr: *const libc.sockaddr = @ptrCast(&sockaddr);

    if (libc.bind(fd, sockaddr_ptr, @sizeOf(libc.sockaddr.in)) != 0) {
        return switch (libc.errno(@as(c_int, -1))) {
            .ADDRINUSE => error.AddressInUse,
            else => error.BindFailed,
        };
    }

    if (libc.listen(fd, backlog) != 0) {
        return error.ListenFailed;
    }

    std.debug.assert(fd >= 0);

    return fd;
}

pub fn connect_tcp(address: [4]u8, port: u16) IoError!Fd {
    std.debug.assert(port > 0);

    const fd = libc.socket(libc.AF.INET, libc.SOCK.STREAM, libc.IPPROTO.TCP);

    if (fd < 0) {
        return switch (libc.errno(fd)) {
            .MFILE, .NFILE => error.FileLimitReached,
            else => error.SocketFailed,
        };
    }

    errdefer close(fd);

    try set_nonblocking(fd);
    try set_no_delay(fd);
    try set_cloexec(fd);
    try set_no_sigpipe(fd);

    var sockaddr: libc.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    const sockaddr_ptr: *const libc.sockaddr = @ptrCast(&sockaddr);
    const result = libc.connect(fd, sockaddr_ptr, @sizeOf(libc.sockaddr.in));

    if (result != 0) {
        switch (libc.errno(result)) {
            .INPROGRESS => {},
            .CONNRESET, .CONNREFUSED => return error.ConnectionReset,
            else => return error.Unexpected,
        }
    }

    std.debug.assert(fd >= 0);

    return fd;
}

pub fn connect_result(fd: Fd) IoError!void {
    std.debug.assert(fd >= 0);

    var so_error: c_int = 0;
    var len: libc.socklen_t = @sizeOf(c_int);
    const result = libc.getsockopt(fd, libc.SOL.SOCKET, libc.SO.ERROR, &so_error, &len);

    if (result != 0) {
        return error.Unexpected;
    }

    if (so_error != 0) {
        return error.ConnectionReset;
    }
}

pub fn accept(listener: Fd) IoError!?Fd {
    std.debug.assert(listener >= 0);

    const fd = libc.accept(listener, null, null);

    if (fd < 0) {
        return switch (libc.errno(fd)) {
            .AGAIN => null,
            .CONNABORTED, .INTR => null,
            .MFILE, .NFILE => error.FileLimitReached,
            else => error.Unexpected,
        };
    }

    errdefer close(fd);
    try set_nonblocking(fd);
    try set_no_delay(fd);
    try set_cloexec(fd);
    try set_no_sigpipe(fd);

    std.debug.assert(fd != listener);

    return fd;
}

pub fn recv(fd: Fd, buffer: []u8) IoError!u32 {
    std.debug.assert(fd >= 0);
    std.debug.assert(buffer.len > 0);

    const result = libc.recv(fd, buffer.ptr, buffer.len, 0);

    if (result < 0) {
        return switch (libc.errno(result)) {
            .AGAIN, .INTR => error.WouldBlock,
            .CONNRESET => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    if (result == 0) {
        return error.ConnectionClosed;
    }

    return @intCast(result);
}

pub fn send(fd: Fd, bytes: []const u8) IoError!u32 {
    std.debug.assert(fd >= 0);
    std.debug.assert(bytes.len > 0);

    const result = libc.send(fd, bytes.ptr, bytes.len, 0);

    if (result < 0) {
        return switch (libc.errno(result)) {
            .AGAIN, .INTR => error.WouldBlock,
            .PIPE, .CONNRESET => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    return @intCast(result);
}

pub fn close(fd: Fd) void {
    _ = libc.close(fd);
}

pub fn bound_port(fd: Fd) Error!u16 {
    std.debug.assert(fd >= 0);

    var storage: libc.sockaddr.in = undefined;
    var len: libc.socklen_t = @sizeOf(libc.sockaddr.in);
    const result = libc.getsockname(fd, @ptrCast(&storage), &len);

    if (result != 0) {
        return error.Unexpected;
    }

    const port = std.mem.bigToNative(u16, storage.port);
    std.debug.assert(port > 0);

    return port;
}

pub fn ensure_file_limit(files_needed: u64) Error!void {
    std.debug.assert(files_needed > 0);
    std.debug.assert(files_needed < 1 << 24);

    var limit: libc.rlimit = undefined;

    if (libc.getrlimit(libc.rlimit_resource.NOFILE, &limit) != 0) {
        return error.Unexpected;
    }

    if (limit.cur >= files_needed) {
        return;
    }

    limit.cur = @min(files_needed, limit.max);

    if (libc.setrlimit(libc.rlimit_resource.NOFILE, &limit) != 0) {
        return error.FileLimitTooLow;
    }

    if (limit.cur < files_needed) {
        return error.FileLimitTooLow;
    }
}

pub fn read_small_file(path: []const u8, buffer: []u8) ?u32 {
    std.debug.assert(path.len > 0);
    std.debug.assert(buffer.len > 0);

    if (path.len >= 1024) {
        return null;
    }

    var path_z: [1024:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = std.c.open(&path_z, .{ .ACCMODE = .RDONLY });

    if (fd < 0) {
        return null;
    }

    defer _ = std.c.close(fd);

    var total: u32 = 0;

    while (total < buffer.len) {
        const got = std.c.read(fd, buffer[total..].ptr, buffer.len - total);

        if (got < 0) {
            return null;
        }

        if (got == 0) {
            return total;
        }

        total += @intCast(got);
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

    var stat: std.c.Stat = undefined;

    if (std.c.fstat(fd, &stat) != 0) {
        return .not_found;
    }

    // Regular files only. A directory, FIFO, socket, or device node under root
    // is not served — a FIFO especially would block the single-threaded loop
    // in read() forever.
    if (!std.c.S.ISREG(stat.mode)) {
        return .not_found;
    }

    if (stat.size < 0 or stat.size > buffer.len) {
        return .too_large;
    }

    const size: u32 = @intCast(stat.size);
    var total: u32 = 0;

    while (total < size) {
        const got = std.c.read(fd, buffer[total..].ptr, size - total);

        if (got < 0) {
            return .not_found;
        }

        if (got == 0) {
            break;
        }

        total += @intCast(got);
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

    const root_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const root_fd: Fd = std.c.open(&root_z, root_flags);
    if (root_fd < 0) return null;
    defer _ = std.c.close(root_fd);

    var segment_z: [1024:0]u8 = undefined;
    var segments = std.mem.splitScalar(u8, rel, '/');
    var current: Fd = root_fd;

    while (segments.next()) |segment| {
        if (segment.len == 0) return null;
        if (segment.len >= 1024) return null;
        @memcpy(segment_z[0..segment.len], segment);
        segment_z[segment.len] = 0;

        const is_last = segments.peek() == null;
        const flags: std.c.O = if (is_last)
            .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }
        else
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

        const next: Fd = std.c.openat(current, &segment_z, flags);
        if (next < 0) {
            if (current != root_fd) _ = std.c.close(current);
            return null;
        }
        if (current != root_fd) _ = std.c.close(current);
        current = next;
    }

    return current;
}

pub fn monotonic_ms() i64 {
    var spec: std.c.timespec = undefined;
    const result = std.c.clock_gettime(.MONOTONIC, &spec);

    std.debug.assert(result == 0);

    return @as(i64, spec.sec) * 1000 + @divTrunc(spec.nsec, std.time.ns_per_ms);
}

fn set_nonblocking(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);

    const flags = libc.fcntl(fd, libc.F.GETFL, @as(c_int, 0));

    if (flags < 0) {
        return error.Unexpected;
    }

    const nonblock: c_int = @bitCast(@as(u32, @bitCast(libc.O{ .NONBLOCK = true })));
    std.debug.assert(nonblock != 0);

    if (libc.fcntl(fd, libc.F.SETFL, flags | nonblock) < 0) {
        return error.Unexpected;
    }
}

fn set_reuse_address(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);
    std.debug.assert(@sizeOf(c_int) == 4);

    const on: c_int = 1;
    const result = libc.setsockopt(fd, libc.SOL.SOCKET, libc.SO.REUSEADDR, &on, @sizeOf(c_int));

    if (result != 0) {
        return error.Unexpected;
    }
}

pub fn effective_backlog_cap() ?u32 {
    switch (builtin.os.tag) {
        .macos => {
            var value: c_int = 0;
            var len: usize = @sizeOf(c_int);
            const name = "kern.ipc.somaxconn";

            if (libc.sysctlbyname(name, &value, &len, null, 0) != 0) {
                return null;
            }

            if (value <= 0) {
                return null;
            }

            return @intCast(value);
        },
        else => return null,
    }
}

fn set_cloexec(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);

    if (libc.fcntl(fd, libc.F.SETFD, @as(c_int, libc.FD_CLOEXEC)) < 0) {
        return error.Unexpected;
    }
}

fn set_no_sigpipe(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);

    if (builtin.os.tag != .macos) {
        return;
    }

    const on: c_int = 1;
    const result = libc.setsockopt(fd, libc.SOL.SOCKET, libc.SO.NOSIGPIPE, &on, @sizeOf(c_int));

    if (result != 0) {
        return error.Unexpected;
    }
}

fn set_no_delay(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd >= 0);
    std.debug.assert(@sizeOf(c_int) == 4);

    const on: c_int = 1;
    const result = libc.setsockopt(fd, libc.IPPROTO.TCP, libc.TCP.NODELAY, &on, @sizeOf(c_int));

    if (result != 0) {
        return error.Unexpected;
    }
}

test "listen on an ephemeral port, accept returns null when nothing is pending" {
    const listener = try listen_tcp(.{ 127, 0, 0, 1 }, 0, 4);
    defer close(listener);

    try std.testing.expectEqual(@as(?Fd, null), try accept(listener));
    try std.testing.expect(try bound_port(listener) > 0);
}

test "non-blocking connect to our own listener completes" {
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

test "open_under reads a regular file and refuses symlinks, escapes, and directories" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "hello" });
    try tmp.dir.symLink(io, "real.txt", "link.txt", .{});
    // An intermediate-directory symlink pointing outside the root: a request that
    // walks through it must not resolve (open_under refuses it before the file).
    try tmp.dir.symLink(io, "/etc", "escape", .{});

    // tmpDir is cwd-relative: .zig-cache/tmp/<sub_path> (std.testing.tmpDir).
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var read_buffer: [64]u8 = undefined;

    const real_fd = open_under(root, "real.txt").?;
    defer close(real_fd);
    try std.testing.expectEqual(@as(u32, 5), read_file(real_fd, &read_buffer).len);

    // Final-component symlink: refused.
    try std.testing.expectEqual(@as(?Fd, null), open_under(root, "link.txt"));

    // Intermediate-directory symlink escaping the root: refused.
    try std.testing.expectEqual(@as(?Fd, null), open_under(root, "escape/passwd"));

    // The root itself as the final component is a directory, not a regular file:
    // opened, but read_file reports not_found.
    const dir_fd = open_under(root, ".").?;
    defer close(dir_fd);
    try std.testing.expectEqual(FileRead.not_found, read_file(dir_fd, &read_buffer));
}
