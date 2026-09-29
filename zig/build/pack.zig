//! `pack <out.tar.gz> <entry>...`: files and folders as one gzipped tar, its entries sorted
//! and undated so the same inputs always give the same bytes. An entry is
//! `<name>=<file>`, `+<name>=<file>` (executable), or `<name>/=<folder>[:<suffix>]`: every
//! file under the folder, or only those ending in `<suffix>`, as `<name>/<path>`.
const std = @import("std");
const Io = std.Io;

const file_bytes_max = 64 << 20;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    std.debug.assert(args.len >= 3);

    const cwd = Io.Dir.cwd();
    var out_file = try cwd.createFile(io, args[1], .{});
    defer out_file.close(io);

    var out_buffer: [64 << 10]u8 = undefined;
    var out = out_file.writer(io, &out_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.init(&out.interface, &window, .gzip, .best);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };

    for (args[2..]) |entry| {
        try add(io, arena, &tar, entry);
    }

    try tar.finishPedantically();
    try gzip.finish();
    try out.interface.flush();
}

fn add(io: Io, arena: std.mem.Allocator, tar: *std.tar.Writer, entry: []const u8) !void {
    const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadEntry;
    const executable = entry[0] == '+';
    const name = entry[@intFromBool(executable)..equals];
    const source = entry[equals + 1 ..];
    const cwd = Io.Dir.cwd();

    if (!std.mem.endsWith(u8, name, "/")) {
        const mode: u32 = if (executable) 0o755 else 0o644;

        return tar.writeFileBytes(name, try read(io, arena, cwd, source), .{ .mode = mode });
    }

    const colon = std.mem.lastIndexOfScalar(u8, source, ':');
    const folder = if (colon) |at| source[0..at] else source;
    const suffix = if (colon) |at| source[at + 1 ..] else "";
    var dir = try cwd.openDir(io, folder, .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |found| {
        if (found.kind == .file and std.mem.endsWith(u8, found.path, suffix)) {
            try paths.append(arena, try arena.dupe(u8, found.path));
        }
    }

    std.mem.sort([]const u8, paths.items, {}, less_than);

    for (paths.items) |path| {
        const packed_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, path });

        try tar.writeFileBytes(packed_name, try read(io, arena, dir, path), .{ .mode = 0o644 });
    }
}

fn read(io: Io, arena: std.mem.Allocator, dir: Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, arena, .limited(file_bytes_max));
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
