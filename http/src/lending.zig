//! What a connection borrows from the engine's pools, and when it gives it back: a head
//! buffer while a request is read, a body buffer for a body larger than that, a response
//! buffer while a response is built and sent, and a head buffer each way once upgraded. A
//! connection with nothing left to read or send holds nothing but its slot.
//!
//! A connection whose buffer cannot be lent waits: it is not read (its interest is `none`)
//! until one comes back (`resume_waiting`), first come first served. Nothing is refused for
//! lack of a buffer. A connection waiting for a body buffer gives back its response buffer
//! first, so the two pools can never hold each other up.
const std = @import("std");
const engine_module = @import("engine.zig");
const connection = @import("connection.zig");

const Engine = engine_module.Engine;
const Slot = engine_module.Slot;

/// Which pool a slot's buffer came from, so it goes back to the right one.
pub const Held = enum { none, head, body, response, error_text };

/// The kind of buffer a waiting slot waits for.
pub const Waiting = enum { none, body, response };

/// Room in every slot for an error response, so an error never waits for a buffer.
pub const error_text_bytes: u32 = 512;

/// Slots waiting for one kind of buffer, first come first served, held by event token so a
/// slot that closed and was reused is never served by mistake.
pub const Waiters = struct {
    tokens: []u64,
    start: u32 = 0,
    len: u32 = 0,

    pub fn push(waiters: *Waiters, token: u64) void {
        std.debug.assert(waiters.len < waiters.tokens.len);
        std.debug.assert(waiters.start < waiters.tokens.len);

        const at = (waiters.start + waiters.len) % waiters.tokens.len;

        waiters.tokens[at] = token;
        waiters.len += 1;
    }

    pub fn pop(waiters: *Waiters) ?u64 {
        std.debug.assert(waiters.len <= waiters.tokens.len);

        if (waiters.len == 0) {
            return null;
        }

        const token = waiters.tokens[waiters.start];

        waiters.start = @intCast((waiters.start + 1) % waiters.tokens.len);
        waiters.len -= 1;

        return token;
    }

    /// Takes `token` out, wherever it is: its slot is closing.
    pub fn remove(waiters: *Waiters, token: u64) void {
        std.debug.assert(waiters.len <= waiters.tokens.len);

        var kept: u32 = 0;
        var read: u32 = 0;
        const count = waiters.tokens.len;

        while (read < waiters.len) : (read += 1) {
            const entry = waiters.tokens[(waiters.start + read) % count];

            if (entry != token) {
                waiters.tokens[(waiters.start + kept) % count] = entry;
                kept += 1;
            }
        }

        std.debug.assert(kept + 1 >= waiters.len);

        waiters.len = kept;
    }
};

/// A head buffer to read into, when the slot has nothing to read into. The pool holds two
/// for every slot, so this never waits.
pub fn ensure_head(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state != .free);

    if (slot.read_held != .none) {
        return;
    }

    const buffer = server.heads.take() orelse unreachable;

    slot.read_buffer = buffer;
    slot.read_held = .head;
}

/// Gives back what the slot reads into once nothing is left in it, unless it streams a
/// body or was upgraded: those read for as long as they last.
pub fn settle_read(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.read_len <= slot.read_buffer.len);

    const reads_on = slot.state == .streaming or slot.state == .upgraded or slot.upgrading;

    if (slot.state == .free or reads_on or slot.read_len > 0) {
        return;
    }

    give_read(server, slot);
}

/// What was read so far, moved into a body buffer so the whole body fits; false when none
/// is free, and the slot waits for one.
pub fn grow_to_body(server: *Engine, slot: *Slot) bool {
    std.debug.assert(slot.read_held == .head);
    std.debug.assert(slot.state == .reading);

    give_write(server, slot);

    const body = server.bodies.take() orelse {
        wait(server, slot, .body);
        return false;
    };

    @memcpy(body[0..slot.read_len], slot.read_buffer[0..slot.read_len]);
    server.heads.give(slot.read_buffer);
    slot.read_buffer = body;
    slot.read_held = .body;

    return true;
}

/// A response buffer for the request about to be answered; false when none is free, and the
/// slot waits for one.
pub fn ensure_response(server: *Engine, slot: *Slot) bool {
    std.debug.assert(slot.state == .reading);

    if (slot.write_held == .response) {
        return true;
    }

    std.debug.assert(slot.write_held == .none);

    const buffer = server.responses.take() orelse {
        wait(server, slot, .response);
        return false;
    };

    slot.write_buffer = buffer;
    slot.write_held = .response;

    return true;
}

/// Gives back what the slot writes from: its response is sent, or abandoned.
pub fn give_write(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.write_pos <= slot.write_len);

    switch (slot.write_held) {
        .none, .error_text => {},
        .head => server.heads.give(slot.write_buffer),
        .response => server.responses.give(slot.write_buffer),
        .body => unreachable,
    }

    slot.write_buffer = &.{};
    slot.write_held = .none;
}

/// The slot's own room for an error response, after anything it wrote from is given back.
pub fn use_error_text(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state != .free);

    give_write(server, slot);
    slot.write_buffer = &slot.error_text;
    slot.write_held = .error_text;
}

/// An upgraded connection reads and writes frames: a head buffer each way for as long as it
/// lasts, its response buffer back.
pub fn upgrade(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.upgrading);
    std.debug.assert(slot.write_pos == slot.write_len);

    give_write(server, slot);
    ensure_head(server, slot);
    slot.write_buffer = server.heads.take() orelse unreachable;
    slot.write_held = .head;
    slot.write_len = 0;
    slot.write_pos = 0;
}

/// Everything back, as the slot closes; out of the waiters it was among.
pub fn give_all(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state != .free);

    const token = engine_module.token(server.slot_index(slot), slot.generation);

    switch (slot.waiting) {
        .none => {},
        .body => server.waiting_bodies.remove(token),
        .response => server.waiting_responses.remove(token),
    }

    slot.waiting = .none;
    give_read(server, slot);
    give_write(server, slot);
}

fn give_read(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.read_len <= slot.read_buffer.len);

    switch (slot.read_held) {
        .none => {},
        .head => server.heads.give(slot.read_buffer),
        .body => server.bodies.give(slot.read_buffer),
        .response, .error_text => unreachable,
    }

    slot.read_buffer = &.{};
    slot.read_held = .none;
}

/// The slot stops being read and joins the waiters for `kind`.
fn wait(server: *Engine, slot: *Slot, kind: Waiting) void {
    std.debug.assert(kind != .none);
    std.debug.assert(slot.waiting == .none);

    const index = server.slot_index(slot);
    const token = engine_module.token(index, slot.generation);

    server.loop.direct(slot.fd, token, .none) catch {
        server.counters.event_errors_total += 1;
        return connection.close_slot(server, slot);
    };

    slot.waiting = kind;
    server.counters.waited_total += 1;

    switch (kind) {
        .body => server.waiting_bodies.push(token),
        .response => server.waiting_responses.push(token),
        .none => unreachable,
    }
}

/// The slots waiting for buffers that have come back go on, as many as there are buffers.
pub fn resume_waiting(server: *Engine) void {
    std.debug.assert(server.waiting_responses.len <= server.slots.len);
    std.debug.assert(server.waiting_bodies.len <= server.slots.len);

    while (server.responses.available() > 0) {
        const slot = next_waiter(server, &server.waiting_responses) orelse break;

        if (slot.state == .reading) {
            connection.process_requests(server, slot);
        }
    }

    while (server.bodies.available() > 0) {
        const slot = next_waiter(server, &server.waiting_bodies) orelse break;

        if (slot.state == .reading) {
            connection.service_reading(server, slot);
        }
    }
}

/// The first waiter, read again; null when none waits. It is closed (`.free`) when it could
/// not be read again.
fn next_waiter(server: *Engine, waiters: *Waiters) ?*Slot {
    std.debug.assert(waiters.len <= server.slots.len);

    const token = waiters.pop() orelse return null;
    const slot = &server.slots[@as(u32, @truncate(token))];

    std.debug.assert(slot.state == .reading);
    std.debug.assert(slot.waiting != .none);

    slot.waiting = .none;
    server.loop.direct(slot.fd, token, .read) catch {
        server.counters.event_errors_total += 1;
        connection.close_slot(server, slot);
    };

    return slot;
}

test "waiters come out in the order they went in, and one that closes leaves the line" {
    var tokens: [4]u64 = undefined;
    var waiters: Waiters = .{
        .tokens = &tokens,
    };

    waiters.push(1);
    waiters.push(2);
    waiters.push(3);
    waiters.remove(2);

    try std.testing.expectEqual(@as(?u64, 1), waiters.pop());
    waiters.push(4);
    waiters.push(5);
    try std.testing.expectEqual(@as(?u64, 3), waiters.pop());
    try std.testing.expectEqual(@as(?u64, 4), waiters.pop());
    try std.testing.expectEqual(@as(?u64, 5), waiters.pop());
    try std.testing.expectEqual(@as(?u64, null), waiters.pop());
}
