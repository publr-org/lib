//! Platform dispatcher, one surface with three implementations: raw syscalls on Linux
//! (no libc — keeps release binaries fully static), Winsock on Windows, and POSIX
//! libc on Darwin/BSD (where libc is the stable ABI and linked implicitly). Callers
//! never branch on OS.
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("socket_windows.zig"),
    .linux => @import("socket_linux.zig"),
    else => @import("socket_posix.zig"),
};

pub const Fd = impl.Fd;
pub const invalid = impl.invalid;
pub const Error = impl.Error;
pub const IoError = impl.IoError;

pub const listen_tcp = impl.listen_tcp;
pub const connect_tcp = impl.connect_tcp;
pub const connect_result = impl.connect_result;
pub const accept = if (builtin.os.tag == .windows) impl.accept_connection else impl.accept;
pub const recv = if (builtin.os.tag == .windows) impl.recv_bytes else impl.recv;
pub const send = if (builtin.os.tag == .windows) impl.send_bytes else impl.send;
pub const close = impl.close;
pub const bound_port = impl.bound_port;
pub const ensure_file_limit = impl.ensure_file_limit;
pub const effective_backlog_cap = impl.effective_backlog_cap;
pub const monotonic_ms = impl.monotonic_ms;
pub const read_small_file = impl.read_small_file;
pub const FileRead = impl.FileRead;
pub const read_file = impl.read_file;
pub const open_under = impl.open_under;

test {
    _ = impl;
}
