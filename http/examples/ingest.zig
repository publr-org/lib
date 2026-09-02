//! A lightweight event-ingestion service built on the http-server library, exactly the
//! way any consumer (Publr) embeds it: compose the app type, mount the CLI from main,
//! register routes in setup. Handlers follow the three-argument contract
//! `fn (req, res, ctx) !void`. See examples/hello.zig for the liveness and
//! observability endpoints.
//!
//!   zig build
//!   ./zig-out/bin/ingest --port 8090
//!   curl -X POST --data '{"kind":"page_view"}' http://127.0.0.1:8090/ingest
//!   curl http://127.0.0.1:8090/event/42
const std = @import("std");
const http = @import("publr_http");

const App = http.Server(.{});

const ingest_page =
    \\ingest: a demo consumer of the publr http-server library.
    \\POST /ingest records an event. GET /event/:id echoes an id back.
    \\
;

const Ingest = struct {
    events_total: u64 = 0,
    bytes_total: u64 = 0,
    rejected_total: u64 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    var state: Ingest = .{};

    return http.cli.serve(App, init, .{ .setup = &setup, .user_data = &state });
}

fn setup(app: *App) !void {
    var router = app.router();
    router.get("/", &info);
    router.get("/event/:id", &get_event);
    router.post("/ingest", &post_ingest);
}

fn ingest_of(ctx: *App.Context) *Ingest {
    return @ptrCast(@alignCast(ctx.user_data.?));
}

fn info(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = req;
    _ = ctx;
    try res.text(.ok, ingest_page);
}

fn post_ingest(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    const state = ingest_of(ctx);

    std.debug.assert(req.body.len <= ctx.options.request_bytes_max);

    if (req.body.len == 0) {
        state.rejected_total += 1;
        try res.text(.bad_request, "empty event");
        return;
    }

    state.events_total += 1;
    state.bytes_total += req.body.len;

    std.debug.assert(state.bytes_total >= req.body.len);

    try res.json(.created, .{ .accepted = true, .events_total = state.events_total });
}

fn get_event(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = ctx;
    const id = req.param("id").?;

    try res.json(.ok, .{ .id = id, .query = req.query() });
}
