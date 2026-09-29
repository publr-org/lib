//! Zig's compiler, carried inside the binary that imports this module, for building
//! WebAssembly modules on a machine that has no Zig installed. The compiler, its standard
//! library and a prebuilt compiler_rt travel as one archive; `unpack` writes them to a
//! folder once, and the binary runs the compiler from there.
const std = @import("std");
const Io = std.Io;

/// The Zig the compiler is: the one this module vendors, which is the one it is built with.
pub const version = "0.16.0";

/// What `wasm32` modules are built with: the compiler's own backend and linker (it carries
/// no LLVM), compiler_rt from the toolchain (the wasm backend cannot compile it yet), no
/// sanitizer runtime, and no entry point run while the module is instantiated. Pass
/// `Toolchain.compiler_rt` as an input beside them.
pub const wasm_flags = [_][]const u8{
    "-fno-llvm",
    "-fno-lld",
    "-fno-ubsan-rt",
    "-fno-compiler-rt",
    "-fno-entry",
};

const archive = @embedFile("toolchain_archive");

/// An unpacked toolchain: `<root>/zig`, `<root>/lib/std`, `<root>/lib/libcompiler_rt.a`.
/// The compiler finds its standard library beside itself.
pub const Toolchain = struct {
    root: []const u8,
    compiler: []const u8,
    compiler_rt: []const u8,
};

/// The toolchain under `parent`, written out there first unless it already is. Paths are
/// answered as `parent` is given, relative or absolute, allocated with `gpa`.
pub fn unpack(io: Io, gpa: std.mem.Allocator, parent: []const u8) !Toolchain {
    std.debug.assert(parent.len > 0);
    std.debug.assert(archive.len > 0);

    const root = try write_out(io, gpa, parent, "zig-" ++ version, archive);
    errdefer gpa.free(root);
    const compiler = try std.fs.path.join(gpa, &.{ root, "zig" });
    errdefer gpa.free(compiler);
    const compiler_rt = try std.fs.path.join(gpa, &.{ root, "lib", "libcompiler_rt.a" });

    return .{ .root = root, .compiler = compiler, .compiler_rt = compiler_rt };
}

/// A gzipped tar written out under `parent` as `<label>-<hash of its bytes>`, unless a folder
/// of that name is there already, and that folder's path. The name follows the bytes, so a
/// binary carrying other files never uses these. It is unpacked into a folder of its own and
/// renamed into place, so a process stopped halfway leaves nothing that looks finished, and
/// two processes doing it at once both end with the same folder.
pub fn write_out(
    io: Io,
    gpa: std.mem.Allocator,
    parent: []const u8,
    comptime label: []const u8,
    bytes: []const u8,
) ![]const u8 {
    std.debug.assert(parent.len > 0);
    std.debug.assert(bytes.len > 0);

    const name = (label ++ "-")[0..].* ++ std.fmt.hex(std.hash.Wyhash.hash(0, bytes));
    const root = try std.fs.path.join(gpa, &.{ parent, &name });
    errdefer gpa.free(root);
    const cwd = Io.Dir.cwd();

    if (cwd.access(io, root, .{})) |_| {
        return root;
    } else |_| {}

    try cwd.createDirPath(io, parent);

    var parent_dir = try cwd.openDir(io, parent, .{});
    defer parent_dir.close(io);

    var suffix: [8]u8 = undefined;
    io.random(&suffix);

    const scratch_name = name ++ "-partial-".* ++ std.fmt.bytesToHex(suffix, .lower);
    var scratch_dir = try parent_dir.createDirPathOpen(io, &scratch_name, .{});
    defer scratch_dir.close(io);
    errdefer parent_dir.deleteTree(io, &scratch_name) catch {};

    var input: Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);

    try std.tar.extract(io, scratch_dir, &gzip.reader, .{});

    Io.Dir.rename(parent_dir, &scratch_name, parent_dir, &name, io) catch |err| switch (err) {
        // Another process wrote it out first: its copy is the same bytes.
        error.DirNotEmpty => {
            parent_dir.deleteTree(io, &scratch_name) catch {};
        },
        else => return err,
    };

    return root;
}
