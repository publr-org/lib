//! The command-line face of the server: every example's main is nothing but a mount of
//! this module's `serve` (examples/hello.zig is the smallest — what `zig build run`
//! runs), and a program importing the library mounts the same entrypoint from its own
//! main or subcommand (e.g. a `zig build serve` step) by delegating argv to `serve`.
//! It owns everything that makes the server a command-line app: flags, --help, the
//! .zon config file, operator validation, shutdown signals, the banner, and the exit
//! counters.
//!
//! ```zig
//! const App = http.Server(.{});
//!
//! pub fn main(init: std.process.Init) !u8 {
//!     var state: MyApp = .{};
//!     return http.cli.serve(App, init, .{ .setup = &setup, .user_data = &state });
//! }
//!
//! fn setup(app: *App) !void {
//!     var router = app.router();
//!     router.get("/", &home);
//! }
//! ```
//!
//! Embedders that are not command-line apps skip this module entirely and drive
//! `App.init` / `listen` themselves.
const std = @import("std");
const event = @import("platform/event.zig");
const engine_module = @import("engine.zig");
const socket = @import("platform/socket.zig");

/// The outcome of `parse`: options ready to serve with, or an exit code to return
/// (help printed, or a usage error already reported).
const Parsed = union(enum) {
    options: engine_module.Options,
    exit: u8,
};

/// Per-app configuration for `serve`.
pub fn Config(comptime App: type) type {
    return struct {
        /// Called once, after the app is built and before it listens: register routes
        /// and finish wiring here.
        setup: *const fn (app: *App) anyerror!void,
        /// Application state passed to every handler as `ctx.user_data`.
        user_data: ?*anyopaque = null,
        /// Called after every dispatch with the request and its final response
        /// — the access log, in whatever shape the app wants it. See
        /// `App.on_response`.
        on_response: ?App.OnResponse = null,
        /// App-owned flags parsed alongside the built-in ones (the standalone file
        /// server's `--root`, say), at most eight. Targets are written during parse,
        /// before `setup` runs. The flag inventory stays comptime; only the values
        /// are runtime.
        flags: []const Flag = &.{},
        /// Help lines describing those flags, appended to the built-in `--help` text;
        /// match its format (two-space indent, name padded to column 29).
        flags_help: []const u8 = "",
        /// The app's own starting point for the built-in options, for an app whose
        /// nature differs from the library's guess — a local-only tool that wants
        /// `.address = .{ 127, 0, 0, 1 }` in every build mode, say. A `--config`
        /// file overlays these: a field the file omits keeps the app's default;
        /// flags override either.
        defaults: engine_module.Options = .{},
    };
}

/// The whole command-line lifecycle in one call: parse flags and config, build the
/// app, enable shutdown signals, run `setup`, print the banner, serve until stopped,
/// print the exit counters. Every failure is already reported to stderr by the time
/// it returns; the value is the process exit code, so `main` returns it as-is.
///
/// Exit codes: 0 after a clean shutdown or `--help`; 2 for a usage error (an unknown
/// flag, a bad value, an unreadable config, an out-of-range option); 1 when the app
/// could not start (`App.init` failed — the port is taken, the file limit is too
/// low — or `setup` returned an error) or the loop failed while serving.
pub fn serve(comptime App: type, init: std.process.Init, config: Config(App)) u8 {
    const options = switch (parse(init, config.defaults, config.flags, config.flags_help)) {
        .options => |options| options,
        .exit => |code| return code,
    };

    var app = App.init(init.gpa, options) catch |err| {
        return init_failure(err, &options);
    };
    defer app.deinit();

    app.user_data = config.user_data;
    app.on_response = config.on_response;

    app.enable_shutdown_signals() catch |err| {
        std.debug.print("http-server: cannot install shutdown signals: {s}\n", .{@errorName(err)});
        return 1;
    };

    config.setup(&app) catch |err| {
        std.debug.print("http-server: setup failed: {s}\n", .{@errorName(err)});
        return 1;
    };

    print_banner(&app.engine);

    app.listen() catch |err| {
        std.debug.print("http-server: fatal: {s}\n", .{@errorName(err)});
        return 1;
    };

    print_counters(&app.engine.counters);

    return 0;
}

/// The app's defaults, then the --config .zon file, then flags (built-in plus the
/// app's extra ones), then validation. On error or --help the message is already
/// printed; the caller just returns the exit code.
fn parse(
    init: std.process.Init,
    defaults: engine_module.Options,
    extra: []const Flag,
    extra_help: []const u8,
) Parsed {
    std.debug.assert(extra.len <= flags_extra_max);

    var args_storage: [args_max][]const u8 = undefined;
    const args = collect_args(init, &args_storage) catch {
        std.debug.print("http-server: too many arguments (max {d})\n", .{args_max});
        return .{ .exit = 2 };
    };

    std.debug.assert(args.len <= args_max);

    var options: engine_module.Options = load_config(init.gpa, args, defaults) catch {
        return .{ .exit = 2 };
    };
    var config_path: []const u8 = "";

    const builtin_flags = [_]Flag{
        .{ .name = "--config", .value = .{ .text = &config_path } },
        .{ .name = "--address", .value = .{ .address = &options.address } },
        .{ .name = "--port", .value = .{ .u16 = &options.port } },
        .{ .name = "--connections", .value = .{ .u32 = &options.connections_max } },
        .{ .name = "--request-bytes-max", .value = .{ .u32 = &options.request_bytes_max } },
        .{ .name = "--response-bytes-max", .value = .{ .u32 = &options.response_bytes_max } },
        .{ .name = "--idle-timeout-ms", .value = .{ .u32 = &options.idle_timeout_ms } },
        .{ .name = "--request-timeout-ms", .value = .{ .u32 = &options.request_timeout_ms } },
        .{ .name = "--shutdown-timeout-ms", .value = .{ .u32 = &options.shutdown_timeout_ms } },
    };

    var flags: [builtin_flags.len + flags_extra_max]Flag = undefined;
    @memcpy(flags[0..builtin_flags.len], &builtin_flags);
    @memcpy(flags[builtin_flags.len..][0..extra.len], extra);

    parse_flags(args, flags[0 .. builtin_flags.len + extra.len], extra_help) catch |err| {
        return .{ .exit = if (err == error.Help) 0 else 2 };
    };

    validate_serve_options(&options) catch return .{ .exit = 2 };

    return .{ .options = options };
}

/// Prints an actionable message for an App.init failure and returns the exit code.
fn init_failure(err: engine_module.Error, options: *const engine_module.Options) u8 {
    switch (err) {
        error.AddressInUse => std.debug.print(
            "http-server: port {d} is already in use\n",
            .{options.port},
        ),
        error.FileLimitTooLow => std.debug.print(
            "http-server: cannot raise the open-file limit to {d}; " ++
                "lower --connections or raise the hard limit (ulimit -n)\n",
            .{engine_module.files_needed(options)},
        ),
        else => std.debug.print("http-server: init failed: {s}\n", .{@errorName(err)}),
    }

    return 1;
}

/// Prints the startup banner: bind address, capacity, derived sizes, timeouts.
fn print_banner(server: *const engine_module.Engine) void {
    const options = &server.options;
    const port = server.bound_port() catch options.port;
    const memory_mib = engine_module.memory_bytes(options) / (1 << 20);
    const backlog_cap = socket.effective_backlog_cap();

    std.debug.print(
        "http-server ({t}) listening on http://{d}.{d}.{d}.{d}:{d}\n",
        .{
            event.backend,      options.address[0], options.address[1],
            options.address[2], options.address[3], port,
        },
    );
    std.debug.print(
        "  connections {d}, request cap {d} B, response cap {d} B, ~{d} MiB\n",
        .{
            options.connections_max, options.request_bytes_max, options.response_bytes_max,
            memory_mib,
        },
    );

    if (backlog_cap) |cap| {
        std.debug.print("  backlog {d} derived, kernel cap {d}; open files needed {d}\n", .{
            engine_module.backlog(options),
            cap,
            engine_module.files_needed(options),
        });
    } else {
        std.debug.print("  backlog {d} derived; open files needed {d}\n", .{
            engine_module.backlog(options),
            engine_module.files_needed(options),
        });
    }

    std.debug.print("  timeouts ms: idle {d}, request {d}, shutdown drain {d}\n", .{
        options.idle_timeout_ms,
        options.request_timeout_ms,
        options.shutdown_timeout_ms,
    });
}

/// Prints the end-of-run counters after `listen()` returns.
fn print_counters(stats: *const engine_module.Counters) void {
    std.debug.print(
        "http-server: stopped; accepted {d}, refused {d}, timed out {d}, requests {d}\n",
        .{
            stats.accepted_total,
            stats.refused_total,
            stats.timed_out_total,
            stats.requests_total,
        },
    );
    std.debug.print("  peak active {d}, read {d} B, wrote {d} B, errors accept {d} event {d}\n", .{
        stats.active_peak,
        stats.bytes_read_total,
        stats.bytes_written_total,
        stats.accept_errors_total,
        stats.event_errors_total,
    });
}

const args_max: u32 = 24;

const help_flags =
    \\Usage: <program> [flags]
    \\
    \\Flags override the config file, which overrides defaults (in parentheses):
    \\  --config <path>            .zon config file; fields mirror these flags
    \\  --address <a.b.c.d>        (debug builds: 127.0.0.1, this machine only;
    \\                             release builds: 0.0.0.0, all interfaces)
    \\  --port <n>                 (8080)
    \\  --connections <n>          concurrent connection slots (4096)
    \\  --request-bytes-max <n>    caps one request, head plus body (16384)
    \\  --response-bytes-max <n>   caps one response, headers plus body (32768)
    \\  --idle-timeout-ms <n>      close idle keep-alive connections after (15000)
    \\  --request-timeout-ms <n>   slow request/response deadline (30000)
    \\  --shutdown-timeout-ms <n>  drain budget after SIGINT/SIGTERM (5000)
    \\
;

const help_footer =
    \\
    \\Buffer layout, backlog, and event-loop tuning are derived from these; they are not
    \\configurable on purpose. Stress testing is external (artillery.io).
    \\
;

const config_bytes_max: u32 = 64 << 10;

/// A config file's shape: every field optional, so a field the file omits keeps
/// the app's `defaults` rather than silently reverting to the library's own.
const ConfigOptions = struct {
    address: ?[4]u8 = null,
    port: ?u16 = null,
    connections_max: ?u32 = null,
    request_bytes_max: ?u32 = null,
    response_bytes_max: ?u32 = null,
    idle_timeout_ms: ?u32 = null,
    request_timeout_ms: ?u32 = null,
    shutdown_timeout_ms: ?u32 = null,
};

fn load_config(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    defaults: engine_module.Options,
) error{Config}!engine_module.Options {
    std.debug.assert(args.len < args_max);

    var path: ?[]const u8 = null;
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--config")) {
            if (index + 1 == args.len) {
                std.debug.print("http-server: --config needs a path\n", .{});
                return error.Config;
            }
            path = args[index + 1];
        }
    }

    const config_path = path orelse return defaults;

    var buffer: [config_bytes_max:0]u8 = undefined;
    const len = socket.read_small_file(config_path, buffer[0..config_bytes_max]) orelse {
        std.debug.print("http-server: cannot read config file \"{s}\"\n", .{config_path});
        return error.Config;
    };
    buffer[len] = 0;

    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(gpa);

    const parsed = std.zon.parse.fromSlice(
        ConfigOptions,
        gpa,
        buffer[0..len :0],
        &diagnostics,
        .{},
    ) catch |err| {
        if (err == error.ParseZon) {
            std.debug.print("http-server: config \"{s}\": {f}\n", .{ config_path, diagnostics });
        } else {
            std.debug.print("http-server: config \"{s}\": {s}\n", .{
                config_path,
                @errorName(err),
            });
        }

        return error.Config;
    };

    return overlay(defaults, parsed);
}

/// The app's defaults, then the config file's explicitly-set fields, on top.
fn overlay(base: engine_module.Options, parsed: ConfigOptions) engine_module.Options {
    var options = base;

    inline for (std.meta.fields(ConfigOptions)) |field| {
        if (@field(parsed, field.name)) |value| {
            @field(options, field.name) = value;
        }
    }

    return options;
}

/// Most extra app-owned flags `parse` accepts alongside the built-in ones.
const flags_extra_max: u32 = 8;

/// One command-line flag: a name and a typed pointer the parsed value is written
/// through. Apps declare extras via `Config.flags`.
pub const Flag = struct {
    /// The flag as typed, dashes included: `"--root"`.
    name: []const u8,
    /// Where the parsed value goes, which also says how the argument is parsed.
    /// Every variant but `toggle` consumes the following argument.
    value: union(enum) {
        /// A decimal integer that fits u16 — ports.
        u16: *u16,
        /// A decimal integer that fits u31.
        u31: *u31,
        /// A decimal integer that fits u32.
        u32: *u32,
        /// A dotted quad, `a.b.c.d`.
        address: *[4]u8,
        /// The argument as-is, borrowed from argv for the life of the process.
        text: *[]const u8,
        /// Presence sets the target true; takes no argument.
        toggle: *bool,
    },
};

fn parse_flags(
    args: []const []const u8,
    flags: []Flag,
    extra_help: []const u8,
) error{ Usage, Help }!void {
    std.debug.assert(args.len < args_max);
    std.debug.assert(flags.len > 0);

    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const name = args[index];

        if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            std.debug.print("{s}{s}{s}", .{ help_flags, extra_help, help_footer });
            return error.Help;
        }

        const flag = flag_named(flags, name) orelse {
            std.debug.print("http-server: unknown flag \"{s}\"\n{s}{s}{s}", .{
                name,
                help_flags,
                extra_help,
                help_footer,
            });
            return error.Usage;
        };

        if (flag.value == .toggle) {
            flag.value.toggle.* = true;
            continue;
        }

        index += 1;

        if (index == args.len) {
            std.debug.print("http-server: {s} needs a value\n", .{name});
            return error.Usage;
        }

        apply_flag(flag, args[index]) catch {
            std.debug.print("http-server: invalid value for {s}: \"{s}\"\n", .{
                name,
                args[index],
            });
            return error.Usage;
        };
    }

    std.debug.assert(index == args.len);
}

fn flag_named(flags: []Flag, name: []const u8) ?*Flag {
    std.debug.assert(name.len > 0);
    std.debug.assert(flags.len > 0);

    for (flags) |*flag| {
        if (std.mem.eql(u8, flag.name, name)) {
            return flag;
        }
    }

    return null;
}

fn apply_flag(flag: *Flag, text: []const u8) !void {
    std.debug.assert(flag.name.len > 0);
    std.debug.assert(text.len > 0);

    switch (flag.value) {
        .u16 => |target| target.* = try std.fmt.parseInt(u16, text, 10),
        .u31 => |target| target.* = try std.fmt.parseInt(u31, text, 10),
        .u32 => |target| target.* = try std.fmt.parseInt(u32, text, 10),
        .address => |target| target.* = try parse_address(text),
        .text => |target| target.* = text,
        .toggle => unreachable,
    }
}

fn parse_address(text: []const u8) !([4]u8) {
    var result: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');

    for (&result) |*byte| {
        const part = parts.next() orelse return error.InvalidAddress;
        byte.* = try std.fmt.parseInt(u8, part, 10);
    }

    if (parts.next() != null) {
        return error.InvalidAddress;
    }

    return result;
}

fn validate_serve_options(options: *const engine_module.Options) error{Usage}!void {
    const checks = [_]struct { ok: bool, message: []const u8 }{
        .{
            .ok = options.connections_max > 0 and options.connections_max <= 65536,
            .message = "connections must be 1..65536",
        },
        .{
            .ok = options.request_bytes_max >= 16 << 10 and
                options.request_bytes_max <= 16 << 20,
            .message = "request-bytes-max must be 16384..16777216",
        },
        .{
            .ok = options.response_bytes_max >= 1 << 10 and
                options.response_bytes_max <= 64 << 20,
            .message = "response-bytes-max must be 1024..67108864",
        },
        .{
            .ok = options.idle_timeout_ms >= 1000 and options.idle_timeout_ms <= 600_000,
            .message = "idle-timeout-ms must be 1000..600000",
        },
        .{
            .ok = options.request_timeout_ms >= 1000 and options.request_timeout_ms <= 600_000,
            .message = "request-timeout-ms must be 1000..600000",
        },
        .{
            .ok = options.shutdown_timeout_ms >= 1000 and options.shutdown_timeout_ms <= 60_000,
            .message = "shutdown-timeout-ms must be 1000..60000",
        },
    };

    for (checks) |check| {
        if (!check.ok) {
            std.debug.print("http-server: {s}\n", .{check.message});
            return error.Usage;
        }
    }
}

fn collect_args(init: std.process.Init, storage: *[args_max][]const u8) ![]const []const u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());
    var count: u32 = 0;

    _ = iterator.next();

    while (iterator.next()) |arg| : (count += 1) {
        if (count == args_max) {
            return error.TooManyArguments;
        }
        storage[count] = arg;
    }

    std.debug.assert(count <= args_max);
    std.debug.assert(storage.len == args_max);

    return storage[0..count];
}

test "parse_address accepts dotted quads and rejects malformed input" {
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, try parse_address("127.0.0.1"));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try parse_address("0.0.0.0"));
    try std.testing.expectError(error.InvalidAddress, parse_address("1.2.3"));
    try std.testing.expectError(error.InvalidAddress, parse_address("1.2.3.4.5"));
    try std.testing.expectError(error.Overflow, parse_address("256.0.0.1"));
    try std.testing.expectError(error.InvalidCharacter, parse_address("a.b.c.d"));
}

test "parse_flags applies typed values and toggles in any order" {
    var port: u16 = 8080;
    var connections: u32 = 4096;
    var verbose = false;
    var flags = [_]Flag{
        .{ .name = "--port", .value = .{ .u16 = &port } },
        .{ .name = "--connections", .value = .{ .u32 = &connections } },
        .{ .name = "--verbose", .value = .{ .toggle = &verbose } },
    };
    const args = [_][]const u8{ "--verbose", "--port", "9000", "--connections", "64" };

    try parse_flags(&args, &flags, "");

    try std.testing.expectEqual(@as(u16, 9000), port);
    try std.testing.expectEqual(@as(u32, 64), connections);
    try std.testing.expect(verbose);
}

test "a config file overlays the app's defaults; omitted fields keep them" {
    const source: [:0]const u8 = ".{ .port = 9090, .connections_max = 128 }";
    const parsed = try std.zon.parse.fromSlice(
        ConfigOptions,
        std.testing.allocator,
        source,
        null,
        .{},
    );

    const options = overlay(.{ .address = .{ 127, 0, 0, 1 } }, parsed);

    try std.testing.expectEqual(@as(u16, 9090), options.port);
    try std.testing.expectEqual(@as(u32, 128), options.connections_max);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, options.address);
    try std.testing.expectEqual(@as(u32, 16 << 10), options.request_bytes_max);
    try std.testing.expectEqual(@as(u32, 15_000), options.idle_timeout_ms);
}

test "derived values follow the curated options" {
    const small: engine_module.Options = .{ .connections_max = 10 };
    try std.testing.expectEqual(@as(u31, 128), engine_module.backlog(&small));

    const big: engine_module.Options = .{ .connections_max = 65536 };
    try std.testing.expectEqual(@as(u31, 4096), engine_module.backlog(&big));

    const tiny_responses: engine_module.Options = .{ .response_bytes_max = 1 << 10 };
    try std.testing.expectEqual(@as(u32, 256 << 10), engine_module.arena_bytes(&tiny_responses));

    const huge_responses: engine_module.Options = .{ .response_bytes_max = 8 << 20 };
    try std.testing.expectEqual(@as(u32, 16 << 20), engine_module.arena_bytes(&huge_responses));
}
