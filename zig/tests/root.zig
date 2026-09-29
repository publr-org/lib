const std = @import("std");
const publr_zig = @import("publr_zig");

const io = std.testing.io;

test "the toolchain unpacks once and builds a module that needs compiler_rt" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(parent);

    const toolchain = try publr_zig.unpack(io, gpa, parent);
    defer free(gpa, toolchain);

    const again = try publr_zig.unpack(io, gpa, parent);
    defer free(gpa, again);

    try std.testing.expectEqualStrings(toolchain.root, again.root);

    try tmp.dir.writeFile(io, .{ .sub_path = "guest.zig", .data = @embedFile("guest.zig") });

    const source = try std.fs.path.join(gpa, &.{ parent, "guest.zig" });
    defer gpa.free(source);
    const output = try std.fs.path.join(gpa, &.{ parent, "guest.wasm" });
    defer gpa.free(output);
    const emit = try std.fmt.allocPrint(gpa, "-femit-bin={s}", .{output});
    defer gpa.free(emit);
    const cache = try std.fs.path.join(gpa, &.{ parent, "cache" });
    defer gpa.free(cache);

    const argv = [_][]const u8{
        toolchain.compiler,    "build-exe",      source,
        toolchain.compiler_rt, "-target",        "wasm32-freestanding",
        "-rdynamic",           "-OReleaseSmall", emit,
        "--cache-dir",         cache,            "--global-cache-dir",
        cache,
    } ++ publr_zig.wasm_flags;
    const result = try std.process.run(gpa, io, .{ .argv = &argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}\n", .{result.stderr});
        return error.CompileFailed;
    }

    const module = try tmp.dir.readFileAlloc(io, "guest.wasm", gpa, .limited(1 << 20));
    defer gpa.free(module);

    try std.testing.expect(std.mem.startsWith(u8, module, "\x00asm"));
    try std.testing.expect(std.mem.indexOf(u8, module, "multiply") != null);
}

fn free(gpa: std.mem.Allocator, toolchain: publr_zig.Toolchain) void {
    gpa.free(toolchain.root);
    gpa.free(toolchain.compiler);
    gpa.free(toolchain.compiler_rt);
}
