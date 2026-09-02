//! Rewrites the `sources.tar` that `zig build docs` emits: keeps only one module's
//! files, and puts its root first.
//!
//! The compiler tars up every module reachable from the docs object, so all ~525
//! files of `std` ride along with the module's own. The viewer registers one
//! module per top-level directory in the tar (`lib/docs/wasm/main.zig`,
//! `unpackInner`), so std lands in the module list and in every search result —
//! and it is 99.8% of the 16 MB payload.
//!
//! The viewer also takes a module's *first* file as its root, overriding that only
//! for the names `root.zig` and `<module>.zig`. Writing the named root first fixes
//! it without dictating what the file is called.
//!
//! Which of the module's own declarations are public is not this tool's concern:
//! the docs are built from the amalgamation (see amalgamate.zig), in which `pub`
//! already means exactly that.
//!
//! Usage: trim_sources <in.tar> <out.tar> <module-name> <root-file>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.log.err("usage: {s} <in.tar> <out.tar> <module-name> <root-file>", .{args[0]});
        return error.InvalidUsage;
    }
    const input_path = args[1];
    const output_path = args[2];
    const module_name = args[3];
    const root_file = args[4];

    // The prefix every kept entry carries. `unpackInner` splits each name on the
    // first '/' to decide which module a file belongs to, so this is exactly the
    // set of files the viewer would register under `module_name`.
    const prefix = try std.mem.concat(arena, u8, &.{ module_name, "/" });
    const root_entry = try std.mem.concat(arena, u8, &.{ prefix, root_file });

    const cwd = std.Io.Dir.cwd();
    const tar_bytes = try cwd.readFileAlloc(io, input_path, arena, .limited(1 << 30));

    var input_reader: std.Io.Reader = .fixed(tar_bytes);
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&input_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    const Entry = struct { name: []const u8, body: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var root_seen = false;

    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        // `entry.name` points into `file_name_buffer`, which the iterator reuses
        // on the next call, so copy it before streaming the body out.
        const name = try arena.dupe(u8, entry.name);
        var body: std.Io.Writer.Allocating = .init(arena);
        try it.streamRemaining(entry, &body.writer);

        if (std.mem.eql(u8, name, root_entry)) {
            root_seen = true;
            try entries.insert(arena, 0, .{ .name = name, .body = body.written() });
        } else {
            try entries.append(arena, .{ .name = name, .body = body.written() });
        }
    }

    // Both of these mean the docs would silently come out wrong — an empty
    // reference, or one rooted at an arbitrary file — so fail the build.
    if (entries.items.len == 0) {
        std.log.err("no files under '{s}' — is the module name right?", .{prefix});
        return error.ModuleNotFound;
    }
    if (!root_seen) {
        std.log.err("'{s}' is not in the docs sources — is the root file right?", .{root_entry});
        return error.RootFileNotFound;
    }

    const output_file = try cwd.createFile(io, output_path, .{});
    defer output_file.close(io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var output_writer = output_file.writer(io, &output_buffer);
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &output_writer.interface };

    for (entries.items) |entry| {
        try tar_writer.writeFileBytes(entry.name, entry.body, .{});
    }
    try output_writer.interface.flush();
}
