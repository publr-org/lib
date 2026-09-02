//! WebSocket support (RFC 6455) as an extension: declared in the app's comptime
//! extension set, upgraded from an ordinary route handler. A WebSocket endpoint is a
//! normal route whose handler calls
//! `ctx.extensions.websocket.upgrade(ctx, req, .{ .on_message = ... })` — false means
//! "not a WebSocket handshake" and the handler serves its plain-HTTP fallback; true
//! means the 101 is queued and the callbacks own the connection from here on. See
//! examples/chat.zig.
//!
//! v1 scope, deliberately: a `Connection` and `Group` reach every connection in the
//! server (one process, one loop — nothing is sharded), no
//! message fragmentation (a continuation frame is a protocol error), no extensions
//! (a nonzero RSV bit is a protocol error). A message is capped by the connection's
//! read/write buffer, the same cap an HTTP request/response uses. Broadcast is
//! consumer-side: hold connections in a `Group` (or your own list) and send to each.
//!
//! Liveness is server-driven and needs nothing from the consumer: a connection that
//! has sent no frame for `Options.idle_timeout_ms` is pinged, and one that stays
//! silent for another `idle_timeout_ms` after that is closed (1001, counted in
//! `Counters.timed_out_total`). Any frame from the peer — pong, message, anything —
//! re-arms the clock, and browsers answer pings on their own, so an idle browser tab
//! stays connected while a vanished peer can hold a slot for at most two intervals.
const std = @import("std");
const socket = @import("../platform/socket.zig");
const engine_module = @import("../engine.zig");
const router_module = @import("../http/router.zig");
const connection = @import("../connection.zig");

const Engine = engine_module.Engine;
const Slot = engine_module.Slot;

const handshake_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// The RFC 6455 frame opcodes. Non-exhaustive: reserved values (0x3-0x7, 0xB-0xF)
/// parse but are rejected as a protocol error rather than trapping.
const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// One complete message delivered to `OnMessage`. `data` is borrowed from the
/// connection's read buffer and is only valid for the duration of the callback.
pub const Message = struct {
    /// True for a binary frame, false for text. Text has already been checked
    /// as valid UTF-8; invalid text closes the connection with 1007 before
    /// delivery.
    binary: bool,
    /// The unmasked payload, borrowed from the slot's read buffer — copy it to
    /// keep it past the callback.
    data: []const u8,
};

/// A live WebSocket connection: a slot index plus the generation that guards against
/// sending into a since-recycled slot. Cheap to copy and hold onto (e.g. in a `Group`)
/// across calls.
pub const Connection = struct {
    /// The engine the connection lives in.
    server: *Engine,
    /// The slot index.
    index: u32,
    /// The slot generation at upgrade time; a mismatch means the slot has since
    /// been recycled, and every operation becomes a no-op or `NotConnected`.
    generation: u32,

    /// Sends one text frame. The whole message is written in one go — there is
    /// no queue — so it fails rather than buffers when the connection cannot
    /// take it.
    ///
    /// Every failure is one the caller decides about:
    ///
    /// ```zig
    /// conn.send_text("hello") catch |err| switch (err) {
    ///     error.SlowConsumer => {}, // drop it; the peer is behind
    ///     error.NotConnected => {}, // gone; on_close has run or will
    ///     error.MessageTooLarge => unreachable, // a payload we control
    /// };
    /// ```
    pub fn send_text(conn: Connection, text: []const u8) SendError!void {
        try send(conn.server, conn.index, conn.generation, .text, text);
    }

    /// Sends one binary frame; otherwise exactly `send_text`.
    pub fn send_binary(conn: Connection, data: []const u8) SendError!void {
        try send(conn.server, conn.index, conn.generation, .binary, data);
    }

    /// Closes the connection immediately: no close-frame handshake. Safe to call from
    /// inside `OnOpen`/`OnMessage` for this same connection.
    pub fn close(conn: Connection) void {
        const slot = live_slot(conn.server, conn.index, conn.generation) orelse return;
        close_connection(conn.server, slot);
    }

    /// Identity within one server: slot index plus generation.
    pub fn eql(conn: Connection, other: Connection) bool {
        return conn.index == other.index and conn.generation == other.generation;
    }
};

/// Why a send did not happen. Nothing is partially written on any of these.
pub const SendError = error{
    /// The connection is closed, or the slot has been recycled since this
    /// `Connection` was made. Harmless to hit: drop the stale handle.
    NotConnected,
    /// The previous frame has not finished draining — the peer is not reading
    /// fast enough. There is no queue by design; the caller decides whether to
    /// drop, retry later, or close.
    SlowConsumer,
    /// Header plus payload exceeds the slot's write buffer
    /// (`Options.response_bytes_max`), the same cap an HTTP response has.
    MessageTooLarge,
};

/// Fires once the 101 response has actually been flushed, so it is safe to send from
/// here immediately.
pub const OnOpen = *const fn (conn: Connection, ctx: ?*anyopaque) void;
/// Fires once per complete text or binary message.
pub const OnMessage = *const fn (conn: Connection, message: Message, ctx: ?*anyopaque) void;
/// Fires once, right before the connection's slot is recycled, for any reason (peer
/// close, protocol error, `Connection.close`). Not called for connections still open
/// when the server itself shuts down.
pub const OnClose = *const fn (conn: Connection, ctx: ?*anyopaque) void;

/// The callbacks (and their context pointer) one `upgrade` call installs for the
/// lifetime of that connection.
pub const Handlers = struct {
    /// Every complete message; the one callback that is required.
    on_message: OnMessage,
    /// The connection is open and writable; the place to `Group.add`.
    on_open: ?OnOpen = null,
    /// The connection is going away; the place to `Group.remove`.
    on_close: ?OnClose = null,
    /// Passed back to every callback untouched — typically the app state, the
    /// same pointer as `ctx.user_data`.
    ctx: ?*anyopaque = null,
    /// Cross-Site-WebSocket-Hijacking defense. Browsers attach cookies to an
    /// upgrade request no matter which site's script opened the socket; only the
    /// Origin header says who asked. When set, the handshake is refused (the
    /// route's plain-HTTP fallback runs) unless the request carries an Origin
    /// exactly matching one of these entries, compared case-insensitively, e.g.
    /// "https://app.example.com". Note this also refuses clients that send no
    /// Origin at all (curl, native apps) — have them send one, or leave this
    /// null. null accepts any origin: only safe when the socket grants nothing
    /// based on cookies or an ambient session.
    origins: ?[]const []const u8 = null,
};

const Entry = struct {
    generation: u32 = 0,
    handlers: ?Handlers = null,
    /// A liveness ping went out and nothing has come back since; the next expiry
    /// closes the connection instead of pinging again.
    ping_pending: bool = false,
};

/// Per-connection WebSocket state, index-aligned with the engine's slots. Created and
/// owned by the server (declare the extension in the app's comptime set); handlers see
/// it as `ctx.extensions.<name>`.
pub const State = struct {
    /// One entry per engine slot: the handlers installed at upgrade and the
    /// generation they belong to.
    entries: []Entry,

    /// Attempts the WebSocket handshake for the current request, from inside an
    /// ordinary route handler. Returns false when the request is not a well-formed
    /// handshake (or its Origin is not in `handlers.origins`), and true when the
    /// 101 is queued and `handlers` own the connection from here on.
    ///
    /// The endpoint shape — the route stays a normal route:
    ///
    /// ```zig
    /// fn join(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
    ///     if (!ctx.extensions.websocket.upgrade(ctx, req, .{
    ///         .on_message = &on_message,
    ///         .on_open = &on_open,
    ///         .on_close = &on_close,
    ///         .ctx = ctx.user_data,
    ///     })) {
    ///         try res.text(.upgrade_required, "websocket expected");
    ///     }
    /// }
    /// ```
    ///
    /// After a true return the handler must not touch `res`: the switching
    /// response is already on the slot, and the HTTP response object is abandoned.
    pub fn upgrade(
        state: *State,
        ctx: anytype,
        req: *router_module.Request,
        handlers: Handlers,
    ) bool {
        const engine: *Engine = ctx.engine;
        const slot: *Slot = ctx.slot;
        const request = req.inner;

        std.debug.assert(slot.state == .reading);

        if (request.method != .get) {
            return false;
        }
        if (!header_has_token(request.header("upgrade"), "websocket")) {
            return false;
        }

        const key = request.header("sec-websocket-key") orelse return false;

        if (!header_has_token(request.header("connection"), "upgrade")) {
            return false;
        }
        if (!std.mem.eql(u8, request.header("sec-websocket-version") orelse "", "13")) {
            return false;
        }

        if (handlers.origins) |allowed| {
            const origin = request.header("origin") orelse return false;

            if (!origin_allowed(allowed, origin)) {
                return false;
            }
        }

        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(key);
        hasher.update(handshake_magic);
        hasher.final(&digest);

        var accept_buf: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
        const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

        var writer: std.Io.Writer = .fixed(slot.write_buffer);
        writer.print("HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{
            accept,
        }) catch return false;

        const index = engine.slot_index(slot);
        state.entries[index] = .{ .generation = slot.generation, .handlers = handlers };
        slot.owner = engine.extension_index(state);
        slot.upgrading = true;

        const consumed: u32 = request.head_len + @as(u32, @intCast(request.content_length));
        connection.start_writing(engine, slot, @intCast(writer.buffered().len), true, consumed);

        return true;
    }
};

/// The engine vtable; collected by server.zig from the comptime extension set.
pub const extension: engine_module.Extension = .{
    .init = &ext_init,
    .deinit = &ext_deinit,
    .on_upgraded = &on_upgraded,
    .on_readable = &service_readable,
    .on_writable = &service_writable,
    .on_expired = &service_expired,
};

/// A fixed-capacity membership list of connections — a room. Consumer-owned: `add` in
/// `on_open`, `remove` in `on_close`, broadcast from any callback. A member that died
/// without being removed is skipped by the generation check inside send, so a stale
/// entry is harmless until `remove` reclaims it.
pub fn Group(comptime capacity: u32) type {
    return struct {
        const Self = @This();

        /// The members, `members[0..len]`, in no particular order — `remove`
        /// swaps the last one in.
        members: [capacity]Connection = undefined,
        /// How many of `members` are live.
        len: u32 = 0,

        /// False when the group is full; the caller decides what that means
        /// (e.g. `conn.close()`).
        pub fn add(group: *Self, conn: Connection) bool {
            if (group.len == capacity) {
                return false;
            }

            group.members[group.len] = conn;
            group.len += 1;

            return true;
        }

        /// Drops `conn` from the group; a no-op when it is not a member, so
        /// calling it from `on_close` is always safe.
        pub fn remove(group: *Self, conn: Connection) void {
            for (group.members[0..group.len], 0..) |member, index| {
                if (member.eql(conn)) {
                    group.len -= 1;
                    group.members[index] = group.members[group.len];
                    return;
                }
            }
        }

        /// Best-effort text broadcast to every member except `exclude` (pass null to
        /// include everyone): a slow or dead member is skipped rather than queued, the
        /// same trade-off `send_text` makes.
        pub fn broadcast_text(group: *Self, text: []const u8, exclude: ?Connection) void {
            for (group.members[0..group.len]) |member| {
                if (exclude) |excluded| {
                    if (member.eql(excluded)) {
                        continue;
                    }
                }

                member.send_text(text) catch {};
            }
        }
    };
}

fn ext_init(gpa: std.mem.Allocator, connections_max: u32) error{OutOfMemory}!*anyopaque {
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);

    state.entries = try gpa.alloc(Entry, connections_max);
    @memset(state.entries, .{});

    return state;
}

fn ext_deinit(gpa: std.mem.Allocator, context: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(context));

    gpa.free(state.entries);
    gpa.destroy(state);
}

fn state_of(engine: *Engine, slot: *const Slot) *State {
    std.debug.assert(slot.owner < engine.registered_len);

    return @ptrCast(@alignCast(engine.registered[slot.owner].context));
}

fn header_has_token(value: ?[]const u8, wanted: []const u8) bool {
    const text = value orelse return false;
    var tokens = std.mem.splitScalar(u8, text, ',');

    while (tokens.next()) |raw| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t"), wanted)) {
            return true;
        }
    }

    return false;
}

// The on_upgraded hook: fires `OnOpen` once the 101 response has actually reached the
// wire.
fn on_upgraded(engine: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .upgraded);

    const index = engine.slot_index(slot);
    const handlers = state_of(engine, slot).entries[index].handlers orelse unreachable;

    if (handlers.on_open) |on_open| {
        on_open(.{ .server = engine, .index = index, .generation = slot.generation }, handlers.ctx);
    }
}

// The on_readable hook: drains the kernel receive buffer the same way
// `connection.service_reading` does, then decodes whatever complete frames arrived.
fn service_readable(engine: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .upgraded);

    while (slot.read_len < slot.read_buffer.len) {
        const free_space = slot.read_buffer[slot.read_len..];
        const received = socket.recv(slot.fd, free_space) catch |err| switch (err) {
            error.WouldBlock => break,
            error.ConnectionClosed => {
                slot.peer_closed = true;
                break;
            },
            else => return close_connection(engine, slot),
        };

        slot.read_len += received;
        engine.counters.bytes_read_total += received;
    }

    process_frames(engine, slot);
}

// The on_writable hook: resumes a frame send that hit a short write.
fn service_writable(engine: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .upgraded);

    flush_write(engine, slot, .resume_write);

    if (slot.state != .upgraded or slot.write_pos < slot.write_len) {
        return;
    }

    const index = engine.slot_index(slot);
    engine.loop.direct(slot.fd, engine_module.token(index, slot.generation), .read) catch {
        engine.counters.event_errors_total += 1;
        close_connection(engine, slot);
    };
}

// The on_expired hook: the peer has sent nothing for `idle_timeout_ms`. First expiry
// probes with a ping and re-arms; a second one with still nothing back closes the
// connection. A ping that cannot even be queued means the peer is not draining our
// writes either — the same verdict.
fn service_expired(engine: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .upgraded);

    const index = engine.slot_index(slot);
    const entry = &state_of(engine, slot).entries[index];

    if (entry.ping_pending) {
        engine.counters.timed_out_total += 1;
        return close_with_code(engine, slot, 1001);
    }

    send(engine, index, slot.generation, .ping, "") catch {
        engine.counters.timed_out_total += 1;
        return close_with_code(engine, slot, 1001);
    };

    if (slot.state != .upgraded) {
        return; // the send itself failed the connection
    }

    entry.ping_pending = true;
    arm_deadline(engine, slot);
}

fn arm_deadline(engine: *Engine, slot: *Slot) void {
    slot.deadline_ms = engine_module.now_ms() + engine.options.idle_timeout_ms;
}

const DecodedFrame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
    frame_len: u32,
};

const ParsedFrame = union(enum) {
    incomplete,
    frame: DecodedFrame,
};

const FrameError = error{ ProtocolError, MessageTooLarge };

fn process_frames(engine: *Engine, slot: *Slot) void {
    while (slot.state == .upgraded) {
        const parsed = parse_frame(slot.read_buffer[0..slot.read_len], slot.read_buffer.len) catch |err| {
            close_with_code(engine, slot, switch (err) {
                error.ProtocolError => 1002,
                error.MessageTooLarge => 1009,
            });
            return;
        };

        const frame = switch (parsed) {
            .incomplete => {
                if (slot.peer_closed) {
                    close_connection(engine, slot);
                }
                return;
            },
            .frame => |frame| frame,
        };

        // Any complete frame — pong included — is proof of life. A partial frame is
        // not: a peer dripping bytes without ever finishing one still times out.
        state_of(engine, slot).entries[engine.slot_index(slot)].ping_pending = false;
        arm_deadline(engine, slot);

        handle_frame(engine, slot, frame);

        if (slot.state != .upgraded) {
            return;
        }

        compact(slot, frame.frame_len);
    }
}

/// Parses one frame from the front of `buffer` (the slot's currently-filled read
/// bytes). `capacity` is the slot's full read-buffer size: a frame that could never
/// fit even once fully buffered is `error.MessageTooLarge` rather than `.incomplete`,
/// same trade `request.zig`'s parser makes against the read buffer cap.
fn parse_frame(buffer: []u8, capacity: usize) FrameError!ParsedFrame {
    if (buffer.len < 2) {
        return .incomplete;
    }

    const byte0 = buffer[0];
    const byte1 = buffer[1];

    if (byte0 & 0x70 != 0) {
        return error.ProtocolError;
    }
    if (byte1 & 0x80 == 0) {
        return error.ProtocolError; // client frames must be masked
    }

    const fin = byte0 & 0x80 != 0;
    const opcode: Opcode = @enumFromInt(byte0 & 0x0f);
    const len7: u8 = byte1 & 0x7f;

    if (is_control(opcode) and (len7 > 125 or !fin)) {
        return error.ProtocolError; // RFC 6455 §5.5: control frames are unfragmented, ≤ 125 bytes
    }

    var offset: usize = 2;
    var payload_len: u64 = undefined;

    if (len7 <= 125) {
        payload_len = len7;
    } else if (len7 == 126) {
        if (buffer.len < offset + 2) return .incomplete;
        payload_len = std.mem.readInt(u16, buffer[offset..][0..2], .big);
        offset += 2;
    } else {
        if (buffer.len < offset + 8) return .incomplete;
        payload_len = std.mem.readInt(u64, buffer[offset..][0..8], .big);
        if (payload_len & (1 << 63) != 0) return error.ProtocolError;
        offset += 8;
    }

    if (buffer.len < offset + 4) {
        return .incomplete;
    }

    const mask_key = buffer[offset..][0..4].*;
    offset += 4;

    const frame_len_full: u64 = @as(u64, offset) + payload_len;

    if (frame_len_full > capacity) {
        return error.MessageTooLarge;
    }

    const frame_len: u32 = @intCast(frame_len_full);

    if (buffer.len < frame_len) {
        return .incomplete;
    }

    const payload = buffer[offset..frame_len];

    for (payload, 0..) |*byte, i| {
        byte.* ^= mask_key[i % 4];
    }

    return .{ .frame = .{ .fin = fin, .opcode = opcode, .payload = payload, .frame_len = frame_len } };
}

fn is_control(opcode: Opcode) bool {
    return switch (opcode) {
        .close, .ping, .pong => true,
        else => false,
    };
}

fn origin_allowed(allowed: []const []const u8, origin: []const u8) bool {
    std.debug.assert(allowed.len > 0);

    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, origin)) {
            return true;
        }
    }

    return false;
}

fn handle_frame(engine: *Engine, slot: *Slot, frame: DecodedFrame) void {
    if (!frame.fin) {
        return close_with_code(engine, slot, 1003); // fragmentation unsupported (v1)
    }

    switch (frame.opcode) {
        .text => {
            if (!std.unicode.utf8ValidateSlice(frame.payload)) {
                return close_with_code(engine, slot, 1007); // RFC 6455 §8.1
            }

            deliver(engine, slot, false, frame.payload);
        },
        .binary => deliver(engine, slot, true, frame.payload),
        .ping => {
            const index = engine.slot_index(slot);
            send(engine, index, slot.generation, .pong, frame.payload) catch {};
        },
        .pong => {},
        .close => {
            send_close_frame(slot, 1000);
            close_connection(engine, slot);
        },
        else => close_with_code(engine, slot, 1002),
    }
}

fn deliver(engine: *Engine, slot: *Slot, binary: bool, payload: []const u8) void {
    const index = engine.slot_index(slot);
    const handlers = state_of(engine, slot).entries[index].handlers orelse unreachable;

    handlers.on_message(
        .{ .server = engine, .index = index, .generation = slot.generation },
        .{ .binary = binary, .data = payload },
        handlers.ctx,
    );
}

fn compact(slot: *Slot, consumed: u32) void {
    std.debug.assert(consumed <= slot.read_len);

    const remaining = slot.read_len - consumed;
    std.mem.copyForwards(u8, slot.read_buffer[0..remaining], slot.read_buffer[consumed..slot.read_len]);
    slot.read_len = remaining;
}

fn close_with_code(engine: *Engine, slot: *Slot, code: u16) void {
    send_close_frame(slot, code);
    close_connection(engine, slot);
}

fn send_close_frame(slot: *Slot, code: u16) void {
    var frame: [4]u8 = undefined;
    frame[0] = 0x80 | @as(u8, @intFromEnum(Opcode.close));
    frame[1] = 2;
    std.mem.writeInt(u16, frame[2..4], code, .big);

    _ = socket.send(slot.fd, &frame) catch {};
}

/// The one path every WebSocket teardown funnels through: fires `OnClose` (if the
/// connection made it past the handshake and still has live handlers), then hands off
/// to the shared slot-recycling path.
fn close_connection(engine: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .upgraded);

    const index = engine.slot_index(slot);
    const entry = &state_of(engine, slot).entries[index];

    if (entry.handlers) |handlers| {
        if (handlers.on_close) |on_close| {
            on_close(.{ .server = engine, .index = index, .generation = slot.generation }, handlers.ctx);
        }
    }

    entry.handlers = null;
    connection.close_slot(engine, slot);
}

fn live_slot(engine: *Engine, index: u32, generation: u32) ?*Slot {
    if (index >= engine.slots.len) {
        return null;
    }

    const slot = &engine.slots[index];

    if (slot.state != .upgraded or slot.generation != generation) {
        return null;
    }

    return slot;
}

fn send(engine: *Engine, index: u32, generation: u32, opcode: Opcode, payload: []const u8) SendError!void {
    const slot = live_slot(engine, index, generation) orelse return error.NotConnected;

    if (slot.write_pos < slot.write_len) {
        return error.SlowConsumer;
    }

    var header_buf: [10]u8 = undefined;
    const header_len = encode_header(&header_buf, opcode, payload.len);

    if (header_len + payload.len > slot.write_buffer.len) {
        return error.MessageTooLarge;
    }

    @memcpy(slot.write_buffer[0..header_len], header_buf[0..header_len]);
    @memcpy(slot.write_buffer[header_len..][0..payload.len], payload);

    slot.write_len = @intCast(header_len + payload.len);
    slot.write_pos = 0;

    flush_write(engine, slot, .first_write);
}

fn encode_header(buf: *[10]u8, opcode: Opcode, payload_len: usize) usize {
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN=1, RSV=0, no fragmentation ever sent
    if (payload_len <= 125) {
        buf[1] = @intCast(payload_len);
        return 2;
    }

    if (payload_len <= std.math.maxInt(u16)) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
        return 4;
    }

    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], @intCast(payload_len), .big);
    return 10;
}

const FlushKind = enum { first_write, resume_write };

/// Mirrors `connection.flush`'s short-write handling: opportunistic send, write
/// interest only on `WouldBlock`, flipped back to read interest once drained. A
/// second, WS-specific copy rather than a shared helper, so `connection.zig`'s
/// HTTP-only flush stays exactly as it was.
fn flush_write(engine: *Engine, slot: *Slot, kind: FlushKind) void {
    while (slot.write_pos < slot.write_len) {
        const chunk = slot.write_buffer[slot.write_pos..slot.write_len];
        const sent = socket.send(slot.fd, chunk) catch |err| switch (err) {
            error.WouldBlock => {
                if (kind == .first_write) {
                    const index = engine.slot_index(slot);
                    engine.loop.direct(slot.fd, engine_module.token(index, slot.generation), .write) catch {
                        engine.counters.event_errors_total += 1;
                        close_connection(engine, slot);
                    };
                }
                return;
            },
            else => return close_connection(engine, slot),
        };

        slot.write_pos += sent;
        engine.counters.bytes_written_total += sent;
    }

    if (kind == .resume_write) {
        const index = engine.slot_index(slot);
        engine.loop.direct(slot.fd, engine_module.token(index, slot.generation), .read) catch {
            engine.counters.event_errors_total += 1;
            close_connection(engine, slot);
        };
    }
}

test "parse_frame decodes a masked text frame and unmasks in place" {
    var buffer = [_]u8{ 0x81, 0x85, 1, 2, 3, 4, 'h' ^ 1, 'e' ^ 2, 'l' ^ 3, 'l' ^ 4, 'o' ^ 1 };

    const parsed = try parse_frame(&buffer, buffer.len);
    const frame = parsed.frame;

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualStrings("hello", frame.payload);
    try std.testing.expectEqual(@as(u32, buffer.len), frame.frame_len);
}

test "parse_frame reports incomplete until the whole frame is buffered" {
    var buffer = [_]u8{ 0x81, 0x85, 1, 2, 3, 4, 'h' ^ 1, 'e' ^ 2 };

    try std.testing.expectEqual(ParsedFrame.incomplete, try parse_frame(&buffer, 64));
}

test "parse_frame rejects an unmasked frame and a nonzero RSV bit" {
    var unmasked = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.ProtocolError, parse_frame(&unmasked, 64));

    var rsv = [_]u8{ 0xC1, 0x80, 1, 2, 3, 4 };
    try std.testing.expectError(error.ProtocolError, parse_frame(&rsv, 64));
}

test "parse_frame reports a declared length that can never fit as too large" {
    var buffer = [_]u8{ 0x81, 0xfe, 0xff, 0xff, 1, 2, 3, 4 };

    try std.testing.expectError(error.MessageTooLarge, parse_frame(&buffer, 64));
}

test "parse_frame rejects oversized and fragmented control frames" {
    var oversized_ping = [_]u8{ 0x89, 0xfe }; // FIN+ping, masked, len7 = 126
    try std.testing.expectError(error.ProtocolError, parse_frame(&oversized_ping, 16384));

    var fragmented_ping = [_]u8{ 0x09, 0x81 }; // no FIN, ping, masked, len 1
    try std.testing.expectError(error.ProtocolError, parse_frame(&fragmented_ping, 16384));

    var oversized_close = [_]u8{ 0x88, 0xff }; // FIN+close, masked, len7 = 127
    try std.testing.expectError(error.ProtocolError, parse_frame(&oversized_close, 16384));
}

test "encode_header picks the shortest length encoding" {
    var buf: [10]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 2), encode_header(&buf, .text, 10));
    try std.testing.expectEqual(@as(usize, 4), encode_header(&buf, .text, 200));
    try std.testing.expectEqual(@as(u8, 126), buf[1]);
    try std.testing.expectEqual(@as(usize, 10), encode_header(&buf, .text, 100_000));
    try std.testing.expectEqual(@as(u8, 127), buf[1]);
}

test "Group add/remove bookkeeping and capacity" {
    var group: Group(2) = .{};
    const first: Connection = .{ .server = undefined, .index = 0, .generation = 1 };
    const second: Connection = .{ .server = undefined, .index = 1, .generation = 1 };
    const third: Connection = .{ .server = undefined, .index = 2, .generation = 1 };

    try std.testing.expect(group.add(first));
    try std.testing.expect(group.add(second));
    try std.testing.expect(!group.add(third));

    group.remove(first);
    try std.testing.expectEqual(@as(u32, 1), group.len);
    try std.testing.expect(group.add(third));

    group.remove(.{ .server = undefined, .index = 9, .generation = 9 });
    try std.testing.expectEqual(@as(u32, 2), group.len);
}

const server_app = @import("../server.zig");
const TestApp = server_app.Server(.{ .websocket = @This() });
const Response = router_module.Response;

const TestClient = struct {
    stream: std.Io.net.Stream = undefined,
    write_buffer: [1024]u8 = undefined,
    read_buffer: [4096]u8 = undefined,
    // Kept as the wrapper, not just its `.interface`: the wrapper's address must stay
    // stable for the interface's vtable dispatch, so `client` (holding these fields)
    // must never move after `connect` — never return a `TestClient` by value.
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,

    fn connect(client: *TestClient, port: u16) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        client.stream = try address.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp });
        client.reader = client.stream.reader(std.testing.io, &client.read_buffer);
        client.writer = client.stream.writer(std.testing.io, &client.write_buffer);
    }

    fn close(client: *TestClient) void {
        client.stream.close(std.testing.io);
    }

    fn handshake(client: *TestClient, path: []const u8, key: []const u8) !void {
        try client.writer.interface.print("GET {s} HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{
            path, key,
        });
        try client.writer.interface.flush();
    }

    fn read_response_head(client: *TestClient, out: []u8) ![]const u8 {
        var len: usize = 0;

        while (len < out.len) {
            out[len] = try client.reader.interface.takeByte();
            len += 1;

            if (len >= 4 and std.mem.eql(u8, out[len - 4 .. len], "\r\n\r\n")) {
                return out[0..len];
            }
        }

        return error.HeadTooLarge;
    }

    fn send_masked(client: *TestClient, opcode: Opcode, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));

        var header_len: usize = undefined;

        if (payload.len <= 125) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
            header_len = 2;
        } else {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        }

        const mask_key = [4]u8{ 9, 8, 7, 6 };
        @memcpy(header[header_len..][0..4], &mask_key);
        header_len += 4;

        try client.writer.interface.writeAll(header[0..header_len]);

        for (payload, 0..) |byte, i| {
            try client.writer.interface.writeByte(byte ^ mask_key[i % 4]);
        }

        try client.writer.interface.flush();
    }

    /// Reads one server frame (unmasked, per spec) and returns its opcode and payload.
    fn read_frame(client: *TestClient, out: []u8) !struct { opcode: Opcode, payload: []const u8 } {
        const byte0 = try client.reader.interface.takeByte();
        const byte1 = try client.reader.interface.takeByte();
        const opcode: Opcode = @enumFromInt(byte0 & 0x0f);
        const len7 = byte1 & 0x7f;

        var payload_len: usize = len7;

        if (len7 == 126) {
            var buf: [2]u8 = undefined;
            try client.reader.interface.readSliceAll(&buf);
            payload_len = std.mem.readInt(u16, &buf, .big);
        }

        try client.reader.interface.readSliceAll(out[0..payload_len]);

        return .{ .opcode = opcode, .payload = out[0..payload_len] };
    }
};

const harness = @import("../testing.zig");

const EchoCtx = struct { opened: u32 = 0, closed: u32 = 0 };

fn echo_route(req: *router_module.Request, res: *Response, ctx: *TestApp.Context) anyerror!void {
    if (!ctx.extensions.websocket.upgrade(ctx, req, .{
        .on_message = &echo_on_message,
        .on_open = &echo_on_open,
        .on_close = &echo_on_close,
        .ctx = ctx.user_data,
    })) {
        try res.text(.upgrade_required, "websocket expected");
    }
}

fn echo_on_open(conn: Connection, ctx: ?*anyopaque) void {
    const state: *EchoCtx = @ptrCast(@alignCast(ctx.?));
    state.opened += 1;
    conn.send_text("welcome") catch {};
}

fn echo_on_message(conn: Connection, message: Message, ctx: ?*anyopaque) void {
    _ = ctx;
    conn.send_text(message.data) catch {};
}

fn echo_on_close(conn: Connection, ctx: ?*anyopaque) void {
    _ = conn;
    const state: *EchoCtx = @ptrCast(@alignCast(ctx.?));
    state.closed += 1;
}

test "handshake computes the RFC 6455 example accept key and upgrades the slot" {
    var app = try TestApp.init(std.testing.allocator, harness.options(4));
    defer app.deinit();

    var echo_state: EchoCtx = .{};
    app.user_data = &echo_state;
    app.router().get("/ws", &echo_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 50 });

    var client: TestClient = .{};
    try client.connect(port);
    defer client.close();

    try client.handshake("/ws", "dGhlIHNhbXBsZSBub25jZQ==");

    var head_buf: [256]u8 = undefined;
    const head = try client.read_response_head(&head_buf);

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);

    var payload_buf: [256]u8 = undefined;
    const welcome = try client.read_frame(&payload_buf);
    try std.testing.expectEqual(Opcode.text, welcome.opcode);
    try std.testing.expectEqualStrings("welcome", welcome.payload);

    try client.send_masked(.text, "hello");
    const echoed = try client.read_frame(&payload_buf);
    try std.testing.expectEqualStrings("hello", echoed.payload);

    try client.send_masked(.close, "");

    thread.join();

    try std.testing.expectEqual(@as(u32, 1), echo_state.opened);
    try std.testing.expectEqual(@as(u32, 1), echo_state.closed);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "a handshake missing Sec-WebSocket-Key falls back to the handler's response" {
    var app = try TestApp.init(std.testing.allocator, harness.options(2));
    defer app.deinit();

    var echo_state: EchoCtx = .{};
    app.user_data = &echo_state;
    app.router().get("/ws", &echo_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 30 });

    var client: TestClient = .{};
    try client.connect(port);
    defer client.close();

    try client.writer.interface.writeAll("GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n");
    try client.writer.interface.flush();

    var head_buf: [256]u8 = undefined;
    const head = try client.read_response_head(&head_buf);

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 426 Upgrade Required\r\n"));
    try std.testing.expectEqual(@as(u32, 0), echo_state.opened);

    thread.join();
}

fn origin_guarded_route(req: *router_module.Request, res: *Response, ctx: *TestApp.Context) anyerror!void {
    if (!ctx.extensions.websocket.upgrade(ctx, req, .{
        .on_message = &echo_on_message,
        .origins = &.{"https://app.example"},
    })) {
        try res.text(.upgrade_required, "websocket expected");
    }
}

test "an origin allowlist refuses foreign and absent origins, accepts the listed one" {
    var app = try TestApp.init(std.testing.allocator, harness.options(4));
    defer app.deinit();

    app.router().get("/ws", &origin_guarded_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 60 });

    const handshake_prefix = "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";

    {
        var client: TestClient = .{};
        try client.connect(port);
        defer client.close();
        try client.writer.interface.writeAll(handshake_prefix ++
            "Origin: https://evil.example\r\nConnection: close\r\n\r\n");
        try client.writer.interface.flush();

        var head_buf: [256]u8 = undefined;
        const head = try client.read_response_head(&head_buf);
        try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 426 Upgrade Required\r\n"));
    }

    {
        var client: TestClient = .{};
        try client.connect(port);
        defer client.close();
        try client.writer.interface.writeAll(handshake_prefix ++ "Connection: close\r\n\r\n");
        try client.writer.interface.flush();

        var head_buf: [256]u8 = undefined;
        const head = try client.read_response_head(&head_buf);
        try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 426 Upgrade Required\r\n"));
    }

    {
        var client: TestClient = .{};
        try client.connect(port);
        defer client.close();
        try client.writer.interface.writeAll(handshake_prefix ++
            "Origin: HTTPS://APP.EXAMPLE\r\n\r\n");
        try client.writer.interface.flush();

        var head_buf: [256]u8 = undefined;
        const head = try client.read_response_head(&head_buf);
        try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 101 Switching Protocols\r\n"));

        try client.send_masked(.close, "");
    }

    thread.join();
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "invalid UTF-8 in a text frame closes with 1007" {
    var app = try TestApp.init(std.testing.allocator, harness.options(2));
    defer app.deinit();

    var echo_state: EchoCtx = .{};
    app.user_data = &echo_state;
    app.router().get("/ws", &echo_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 50 });

    var client: TestClient = .{};
    try client.connect(port);
    defer client.close();

    try client.handshake("/ws", "dGhlIHNhbXBsZSBub25jZQ==");

    var head_buf: [256]u8 = undefined;
    _ = try client.read_response_head(&head_buf);

    var payload_buf: [256]u8 = undefined;
    const welcome = try client.read_frame(&payload_buf);
    try std.testing.expectEqualStrings("welcome", welcome.payload);

    try client.send_masked(.text, "\xff\xfe not utf-8");

    const closed = try client.read_frame(&payload_buf);
    try std.testing.expectEqual(Opcode.close, closed.opcode);
    try std.testing.expectEqual(@as(u16, 1007), std.mem.readInt(u16, closed.payload[0..2], .big));

    thread.join();
    try std.testing.expectEqual(@as(u32, 1), echo_state.closed);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

/// Harness options with the shortest liveness interval the engine accepts (two
/// timeout scans); one interval resolves within ~1.5 s of wall clock, so the tests
/// below budget 250 ticks (~5 s) for two intervals plus slack.
fn liveness_options() engine_module.Options {
    var options = harness.options(2);
    options.idle_timeout_ms = 1000;
    return options;
}

test "a silent peer is pinged after idle_timeout_ms and closed after a second one" {
    var app = try TestApp.init(std.testing.allocator, liveness_options());
    defer app.deinit();

    var echo_state: EchoCtx = .{};
    app.user_data = &echo_state;
    app.router().get("/ws", &echo_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 250 });

    var client: TestClient = .{};
    try client.connect(port);
    defer client.close();

    try client.handshake("/ws", "dGhlIHNhbXBsZSBub25jZQ==");

    var head_buf: [256]u8 = undefined;
    _ = try client.read_response_head(&head_buf);

    var payload_buf: [256]u8 = undefined;
    const welcome = try client.read_frame(&payload_buf);
    try std.testing.expectEqualStrings("welcome", welcome.payload);

    const ping = try client.read_frame(&payload_buf);
    try std.testing.expectEqual(Opcode.ping, ping.opcode);

    // Do not answer: the next expiry must close us with 1001.
    const closed = try client.read_frame(&payload_buf);
    try std.testing.expectEqual(Opcode.close, closed.opcode);
    try std.testing.expectEqual(@as(u16, 1001), std.mem.readInt(u16, closed.payload[0..2], .big));

    thread.join();
    try std.testing.expectEqual(@as(u32, 1), echo_state.closed);
    try std.testing.expectEqual(@as(u64, 1), app.engine.counters.timed_out_total);
    try std.testing.expectEqual(@as(u32, 0), app.engine.active());
}

test "a pong keeps a silent peer connected across liveness intervals" {
    var app = try TestApp.init(std.testing.allocator, liveness_options());
    defer app.deinit();

    var echo_state: EchoCtx = .{};
    app.user_data = &echo_state;
    app.router().get("/ws", &echo_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 250 });

    var client: TestClient = .{};
    try client.connect(port);
    defer client.close();

    try client.handshake("/ws", "dGhlIHNhbXBsZSBub25jZQ==");

    var head_buf: [256]u8 = undefined;
    _ = try client.read_response_head(&head_buf);

    var payload_buf: [256]u8 = undefined;
    _ = try client.read_frame(&payload_buf); // welcome

    // Two full ping/pong rounds: each pong must re-arm the clock, so the next
    // frame is another ping — never a close.
    for (0..2) |_| {
        const ping = try client.read_frame(&payload_buf);
        try std.testing.expectEqual(Opcode.ping, ping.opcode);
        try client.send_masked(.pong, "");
    }

    try std.testing.expectEqual(@as(u32, 0), echo_state.closed);
    try std.testing.expectEqual(@as(u64, 0), app.engine.counters.timed_out_total);

    try client.send_masked(.close, "");
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), echo_state.closed);
}

test "a plain GET to a websocket route reaches the handler's HTTP fallback" {
    var app = try TestApp.init(std.testing.allocator, harness.options(2));
    defer app.deinit();

    var echo_state: EchoCtx = .{};
    app.user_data = &echo_state;
    app.router().get("/ws", &echo_route);

    const port = try app.engine.bound_port();
    const thread = try std.Thread.spawn(.{}, harness.run_ticks, .{ &app, 30 });

    var client: TestClient = .{};
    try client.connect(port);
    defer client.close();

    try client.writer.interface.writeAll("GET /ws HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n");
    try client.writer.interface.flush();

    var head_buf: [256]u8 = undefined;
    const head = try client.read_response_head(&head_buf);

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 426 Upgrade Required\r\n"));

    thread.join();
}
