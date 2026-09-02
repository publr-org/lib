//! A minimal collaboration demo built on the http-server library's WebSocket extension
//! (src/extensions/websocket.zig): one broadcast room at /ws/chat. The extension is
//! declared in the app's comptime set, the endpoint is an ordinary route whose handler
//! calls `ctx.extensions.websocket.upgrade`, and the room is a consumer-owned
//! `ws.Group`. See examples/hello.zig for the liveness and observability endpoints.
//!
//!   zig build
//!   ./zig-out/bin/chat --port 8090
//!
//! Then, from two terminals (websocat: https://github.com/vi/websocat):
//!   websocat ws://127.0.0.1:8090/ws/chat
//!
//! Or from a browser console:
//!   const ws = new WebSocket("ws://127.0.0.1:8090/ws/chat");
//!   ws.onmessage = (e) => console.log(e.data);
//!   ws.send("hello");
const std = @import("std");
const http = @import("publr_http");
const ws = http.extensions.websocket;

const App = http.Server(.{
    .websocket = ws,
});

const chat_page =
    \\chat: a demo consumer of the publr http-server library's WebSocket support.
    \\Connect to /ws/chat; every text message you send is broadcast to every other
    \\connected peer.
    \\
;

const room_capacity = 64;

const Chat = struct {
    peers: ws.Group(room_capacity) = .{},
    messages_total: u64 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    var chat: Chat = .{};

    return http.cli.serve(App, init, .{ .setup = &setup, .user_data = &chat });
}

fn setup(app: *App) !void {
    var router = app.router();
    router.get("/", &info);
    router.get("/ws/chat", &join_chat);
}

fn chat_of(ctx: ?*anyopaque) *Chat {
    return @ptrCast(@alignCast(ctx.?));
}

fn info(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    _ = req;
    _ = ctx;
    try res.text(.ok, chat_page);
}

fn join_chat(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    if (!ctx.extensions.websocket.upgrade(ctx, req, .{
        .on_message = &on_message,
        .on_open = &on_open,
        .on_close = &on_close,
        .ctx = ctx.user_data,
    })) {
        try res.text(.upgrade_required, "websocket expected");
    }
}

fn on_open(conn: ws.Connection, ctx: ?*anyopaque) void {
    const chat = chat_of(ctx);

    if (!chat.peers.add(conn)) {
        conn.close();
        return;
    }

    chat.peers.broadcast_text("a peer joined", conn);
}

fn on_message(conn: ws.Connection, message: ws.Message, ctx: ?*anyopaque) void {
    const chat = chat_of(ctx);
    chat.messages_total += 1;
    chat.peers.broadcast_text(message.data, conn);
}

fn on_close(conn: ws.Connection, ctx: ?*anyopaque) void {
    const chat = chat_of(ctx);
    chat.peers.remove(conn);
    chat.peers.broadcast_text("a peer left", null);
}
