const std = @import("std");

/// The vendored SQLite amalgamation compiled into the module itself, so any
/// consumer importing `publr_sqlite` gets a fully self-contained binary — no
/// system libsqlite3, nothing to install on the target machine.
pub fn build(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const library = b.addModule("publr_sqlite", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The flags are part of the library's contract: THREADSAFE=0 matches the
    // one-connection-one-thread model (no mutexes compiled in at all),
    // OMIT_LOAD_EXTENSION keeps the binary self-contained (no dlopen),
    // OMIT_AUTOINIT + ENABLE_MEMSYS5 are what make `Runtime` real (explicit
    // initialize, and a fixed heap the engine can be confined to), and
    // ENABLE_FTS5 is the full-text index consumers build on.
    library.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_AUTOINIT",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_ENABLE_MEMSYS5",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_TEMP_STORE=2",
        },
    });

    return library;
}
