//! Winsock implementation of the socket surface, for developing Publr on Windows. The
//! std library's ws2_32 bindings were reduced to constants in Zig 0.16, so the handful
//! of functions needed are declared here against the stable Winsock ABI.
//!
//! Scope is dev-grade on purpose: production deployments are POSIX. RLIMIT has no
//! equivalent (ensure_file_limit is a no-op; Winsock handles are not fd-limited the
//! same way), and there is no SIGPIPE to suppress.
const std = @import("std");
const builtin = @import("builtin");

pub const Fd = usize;

pub const invalid: Fd = ~@as(usize, 0);
const invalid_socket: Fd = invalid;
const socket_error: i32 = -1;

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

const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const IPPROTO_TCP: i32 = 6;
const SOL_SOCKET: i32 = 0xffff;
const SO_REUSEADDR: i32 = 0x0004;
const SO_ERROR: i32 = 0x1007;
const TCP_NODELAY: i32 = 1;
const FIONBIO: u32 = 0x8004667e;
const SD_SEND: i32 = 1;

const WSAEWOULDBLOCK: i32 = 10035;
const WSAEINPROGRESS: i32 = 10036;
const WSAEADDRINUSE: i32 = 10048;
const WSAECONNRESET: i32 = 10054;
const WSAECONNABORTED: i32 = 10053;
const WSAECONNREFUSED: i32 = 10061;
const WSAEMFILE: i32 = 10024;
const WSAEINTR: i32 = 10004;

const SockaddrIn = extern struct {
    family: i16,
    port: u16,
    addr: u32,
    zero: [8]u8 = @splat(0),
};

const WsaData = extern struct {
    version: u16,
    high_version: u16,
    description: [257]u8,
    system_status: [129]u8,
    max_sockets: u16,
    max_udp_datagram: u16,
    vendor_info: ?[*]u8,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) Fd;
extern "ws2_32" fn bind(s: Fd, addr: *const SockaddrIn, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(s: Fd, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(s: Fd, addr: ?*SockaddrIn, len: ?*i32) callconv(.winapi) Fd;
extern "ws2_32" fn connect(s: Fd, addr: *const SockaddrIn, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: Fd, buffer: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: Fd, buffer: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: Fd) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: Fd, command: u32, argument: *u32) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(s: Fd, addr: *SockaddrIn, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(
    s: Fd,
    level: i32,
    option: i32,
    value: [*]const u8,
    len: i32,
) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(
    s: Fd,
    level: i32,
    option: i32,
    value: [*]u8,
    len: *i32,
) callconv(.winapi) i32;

extern "kernel32" fn CreateFileW(
    path: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ReadFile(
    handle: *anyopaque,
    buffer: [*]u8,
    to_read: u32,
    read_len: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(handle: *anyopaque, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;

const file_attribute_reparse_point: u32 = 0x400;
const invalid_file_attributes: u32 = 0xFFFF_FFFF;

fn startup() void {
    var data: WsaData = undefined;
    _ = WSAStartup(0x0202, &data);
}

pub fn listen_tcp(address: [4]u8, port: u16, backlog: u31) Error!Fd {
    std.debug.assert(backlog > 0);

    startup();

    const fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

    if (fd == invalid_socket) {
        return error.SocketFailed;
    }

    errdefer close(fd);

    try set_nonblocking(fd);

    var sockaddr: SockaddrIn = .{
        .family = AF_INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };

    if (bind(fd, &sockaddr, @sizeOf(SockaddrIn)) == socket_error) {
        return if (WSAGetLastError() == WSAEADDRINUSE) error.AddressInUse else error.BindFailed;
    }

    if (listen(fd, backlog) == socket_error) {
        return error.ListenFailed;
    }

    return fd;
}

pub fn connect_tcp(address: [4]u8, port: u16) IoError!Fd {
    std.debug.assert(port > 0);

    startup();

    const fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

    if (fd == invalid_socket) {
        return error.SocketFailed;
    }

    errdefer close(fd);

    try set_nonblocking(fd);
    try set_no_delay(fd);

    var sockaddr: SockaddrIn = .{
        .family = AF_INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };

    if (connect(fd, &sockaddr, @sizeOf(SockaddrIn)) == socket_error) {
        switch (WSAGetLastError()) {
            WSAEWOULDBLOCK, WSAEINPROGRESS => {},
            WSAECONNRESET, WSAECONNREFUSED => return error.ConnectionReset,
            else => return error.Unexpected,
        }
    }

    return fd;
}

pub fn connect_result(fd: Fd) IoError!void {
    std.debug.assert(fd != invalid_socket);

    var so_error: i32 = 0;
    var len: i32 = @sizeOf(i32);

    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, @ptrCast(&so_error), &len) == socket_error) {
        return error.Unexpected;
    }

    if (so_error != 0) {
        return error.ConnectionReset;
    }
}

pub fn accept_connection(listener: Fd) IoError!?Fd {
    std.debug.assert(listener != invalid_socket);

    const fd = accept(listener, null, null);

    if (fd == invalid_socket) {
        return switch (WSAGetLastError()) {
            WSAEWOULDBLOCK, WSAECONNABORTED, WSAEINTR => null,
            WSAEMFILE => error.FileLimitReached,
            else => error.Unexpected,
        };
    }

    errdefer close(fd);
    try set_nonblocking(fd);
    try set_no_delay(fd);

    return fd;
}

pub fn recv_bytes(fd: Fd, buffer: []u8) IoError!u32 {
    std.debug.assert(fd != invalid_socket);
    std.debug.assert(buffer.len > 0);

    const len: i32 = @intCast(@min(buffer.len, std.math.maxInt(i32)));
    const result = recv(fd, buffer.ptr, len, 0);

    if (result == socket_error) {
        return switch (WSAGetLastError()) {
            WSAEWOULDBLOCK, WSAEINTR => error.WouldBlock,
            WSAECONNRESET => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    if (result == 0) {
        return error.ConnectionClosed;
    }

    return @intCast(result);
}

pub fn send_bytes(fd: Fd, bytes: []const u8) IoError!u32 {
    std.debug.assert(fd != invalid_socket);
    std.debug.assert(bytes.len > 0);

    const len: i32 = @intCast(@min(bytes.len, std.math.maxInt(i32)));
    const result = send(fd, bytes.ptr, len, 0);

    if (result == socket_error) {
        return switch (WSAGetLastError()) {
            WSAEWOULDBLOCK, WSAEINTR => error.WouldBlock,
            WSAECONNRESET => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    return @intCast(result);
}

pub fn close(fd: Fd) void {
    _ = closesocket(fd);
}

pub fn bound_port(fd: Fd) Error!u16 {
    std.debug.assert(fd != invalid_socket);

    var sockaddr: SockaddrIn = undefined;
    var len: i32 = @sizeOf(SockaddrIn);

    if (getsockname(fd, &sockaddr, &len) == socket_error) {
        return error.Unexpected;
    }

    return std.mem.bigToNative(u16, sockaddr.port);
}

pub fn ensure_file_limit(files_needed: u64) Error!void {
    std.debug.assert(files_needed > 0);
}

pub fn effective_backlog_cap() ?u32 {
    return null;
}

pub fn monotonic_ms() i64 {
    return @intCast(GetTickCount64());
}

pub fn read_small_file(path: []const u8, buffer: []u8) ?u32 {
    std.debug.assert(path.len > 0);
    std.debug.assert(buffer.len > 0);

    if (path.len >= 1024) {
        return null;
    }

    var path_w: [1024:0]u16 = undefined;
    const wide_len = std.unicode.wtf8ToWtf16Le(path_w[0..1024], path) catch return null;
    path_w[wide_len] = 0;

    const generic_read: u32 = 0x80000000;
    const share_read: u32 = 1;
    const open_existing: u32 = 3;
    const handle = CreateFileW(&path_w, generic_read, share_read, null, open_existing, 0, null);
    const invalid_handle: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

    if (handle == null or handle == invalid_handle) {
        return null;
    }

    defer _ = CloseHandle(handle.?);

    var total: u32 = 0;

    while (total < buffer.len) {
        var got: u32 = 0;
        const to_read: u32 = @intCast(buffer.len - total);

        if (ReadFile(handle.?, buffer[total..].ptr, to_read, &got, null) == 0) {
            return null;
        }

        if (got == 0) {
            return total;
        }

        total += got;
    }

    return null;
}

/// The outcome of `read_file`: how many bytes landed in the buffer, or why none did.
/// Directories and unreadable paths report `.not_found` (opening a directory without
/// backup semantics fails); a regular file larger than the buffer reports
/// `.too_large` so callers can distinguish "absent" from "present but over the cap".
pub const FileRead = union(enum) { len: u32, not_found, too_large };

pub fn read_file(fd: Fd, buffer: []u8) FileRead {
    std.debug.assert(fd != invalid);
    std.debug.assert(buffer.len > 0);

    const handle: *anyopaque = @ptrFromInt(fd);

    var size: i64 = 0;

    if (GetFileSizeEx(handle, &size) == 0) {
        return .not_found;
    }

    if (size < 0 or size > buffer.len) {
        return .too_large;
    }

    const wanted: u32 = @intCast(size);
    var total: u32 = 0;

    while (total < wanted) {
        var got: u32 = 0;

        if (ReadFile(handle, buffer[total..].ptr, wanted - total, &got, null) == 0) {
            return .not_found;
        }

        if (got == 0) {
            break;
        }

        total += got;
    }

    return .{ .len = total };
}

/// Opens the file named by the `/`-separated `rel` path under `root`, refusing to
/// traverse any reparse point (symlink/junction/mount) in any component below root.
/// `GetFileAttributesW` does not follow the final component of the path it is asked
/// about, so querying each component prefix detects a reparse point anywhere. The
/// final open still races a planted reparse point — Windows is a development target
/// here (see README), and the production platforms use an openat walk instead.
pub fn open_under(root: []const u8, rel: []const u8) ?Fd {
    std.debug.assert(root.len > 0);
    std.debug.assert(rel.len > 0);

    var prefix: [1024]u8 = undefined;
    if (root.len >= prefix.len) return null;
    @memcpy(prefix[0..root.len], root);
    var prefix_len: usize = root.len;

    var prefix_w: [1024:0]u16 = undefined;

    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return null;
        if (prefix_len + 1 + segment.len > prefix.len) return null;
        prefix[prefix_len] = '/';
        prefix_len += 1;
        @memcpy(prefix[prefix_len..][0..segment.len], segment);
        prefix_len += segment.len;

        const wide_len = std.unicode.wtf8ToWtf16Le(prefix_w[0..1024], prefix[0..prefix_len]) catch return null;
        prefix_w[wide_len] = 0;

        const attrs = GetFileAttributesW(&prefix_w);
        if (attrs == invalid_file_attributes) return null;
        if (attrs & file_attribute_reparse_point != 0) return null;
    }

    const generic_read: u32 = 0x80000000;
    const share_read: u32 = 1;
    const open_existing: u32 = 3;
    const handle = CreateFileW(&prefix_w, generic_read, share_read, null, open_existing, 0, null);
    const invalid_handle: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

    if (handle == null or handle == invalid_handle) return null;

    return @intFromPtr(handle.?);
}

fn set_nonblocking(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd != invalid_socket);

    var mode: u32 = 1;

    if (ioctlsocket(fd, FIONBIO, &mode) == socket_error) {
        return error.Unexpected;
    }
}

fn set_no_delay(fd: Fd) error{Unexpected}!void {
    std.debug.assert(fd != invalid_socket);

    const on: i32 = 1;
    const result = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, @ptrCast(&on), @sizeOf(i32));

    if (result == socket_error) {
        return error.Unexpected;
    }
}
