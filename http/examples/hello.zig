//! Hello world: the smallest complete consumer of the http-server library, and what
//! `zig build run` runs. Compose the app type from the comptime extension set, mount
//! the CLI from main, register routes in setup. The liveness (`/health`) and
//! observability (`/stats`, from the always-on engine counters plus `http.process`)
//! endpoints live here so the other examples can stay focused on their own subject.
//!
//!   zig build run -- --port 8090
//!   curl http://127.0.0.1:8090/
//!   curl http://127.0.0.1:8090/health
//!   curl http://127.0.0.1:8090/stats
const std = @import("std");
const http = @import("publr_http");

const App = http.Server(.{});

pub fn main(init: std.process.Init) u8 {
    return http.cli.serve(App, init, .{ .setup = &setup });
}

fn setup(app: *App) !void {
    var router = app.router();
    router.get("/", &hello);
    router.get("/health", &health);
    router.get("/stats", &stats);
}

fn hello(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = req;
    _ = ctx;
    try res.text(.ok, "hello, world\n");
}

fn health(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = req;
    _ = ctx;
    try res.text(.ok, "ok");
}

fn stats(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = req;
    try res.json(.ok, .{
        .server = ctx.counters.*,
        .cpu_micros_total = http.process.cpu_micros(),
        .pid = http.process.id(),
    });
}
