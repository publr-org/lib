//! The standalone file server: serve a folder over HTTP without writing a program.
//! The app is still composed at comptime like any consumer — one wildcard route, no
//! extensions — and the only runtime input beyond the shared server flags is which
//! folder to serve.
//!
//! ```zig
//! publr-http --root ./public
//! ```
//!
//! Files must fit --response-bytes-max (raise it for large assets); directory paths
//! serve their index.html; dotfiles and traversal never resolve (see static.zig).
const std = @import("std");
const http = @import("publr_http");

const App = http.Server(.{});

var root: []const u8 = ".";

pub fn main(init: std.process.Init) u8 {
    return http.cli.serve(App, init, .{
        .setup = &setup,
        .flags = &.{
            .{ .name = "--root", .value = .{ .text = &root } },
        },
        .flags_help = "  --root <dir>               folder to serve files from (current directory)\n",
    });
}

fn setup(app: *App) !void {
    app.router().get("/*", &serve_static);
}

fn serve_static(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    switch (try http.static.serve_file(
        root,
        req.path(),
        res,
        ctx.arena,
        ctx.options.response_bytes_max,
    )) {
        .served => {},
        .not_found => try res.text(.not_found, "Not Found"),
        .too_large => try res.text(.internal_server_error, "file exceeds --response-bytes-max"),
    }
}
