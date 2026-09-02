//! Per-connection state machine: everything that happens to one slot between accept and
//! close. The engine (engine.zig) owns the loop, the slot pool, accepts, timers, and
//! shutdown; this file owns reading, framing, and flushing, handing each complete
//! request to the app layer through `server.on_request` (which routes, serializes, and
//! calls back into `start_writing`). Functions take the server explicitly because the
//! machine mutates shared state (stats, free stack, pending counter, event interest)
//! that the server owns.
const std = @import("std");
const socket = @import("platform/socket.zig");
const request_module = @import("http/request.zig");
const response_module = @import("http/response.zig");
const engine_module = @import("engine.zig");
const status_module = @import("http/status.zig");
const Status = status_module.Status;

const Response = response_module.Response;
const Engine = engine_module.Engine;
const Slot = engine_module.Slot;

pub fn service_reading(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .reading);
    std.debug.assert(slot.read_len <= slot.read_buffer.len);

    while (slot.read_len < slot.read_buffer.len) {
        const free_space = slot.read_buffer[slot.read_len..];
        const received = socket.recv(slot.fd, free_space) catch |err| switch (err) {
            error.WouldBlock => break,
            error.ConnectionClosed => {
                slot.peer_closed = true;
                break;
            },
            else => return close_slot(server, slot),
        };

        if (slot.read_len == 0) {
            slot.deadline_ms = engine_module.now_ms() + server.options.request_timeout_ms;
        }

        slot.read_len += received;
        server.counters.bytes_read_total += received;
    }

    process_requests(server, slot);
}

pub fn process_requests(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .reading);
    std.debug.assert(server.pending_total <= server.slots.len);

    clear_pending(server, slot);

    var handled: u32 = 0;

    while (handled < engine_module.pipeline_batch) : (handled += 1) {
        switch (next_request(server, slot)) {
            .wait => return,
            .closed => return,
            .ready => |request| {
                std.debug.assert(slot.state == .reading);

                slot.served += 1;
                server.counters.requests_total += 1;
                server.on_request(server, slot, &request);

                if (slot.state != .reading) {
                    return;
                }
            },
        }
    }

    if (slot.read_len > 0) {
        mark_pending(server, slot);
    }
}

fn mark_pending(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state == .reading);
    std.debug.assert(server.pending_total < server.slots.len);

    if (!slot.pending) {
        slot.pending = true;
        server.pending_total += 1;
    }
}

fn clear_pending(server: *Engine, slot: *Slot) void {
    std.debug.assert(server.pending_total <= server.slots.len);

    if (slot.pending) {
        std.debug.assert(server.pending_total > 0);
        slot.pending = false;
        server.pending_total -= 1;
    }
}

const NextRequest = union(enum) { wait, closed, ready: request_module.Request };

fn next_request(server: *Engine, slot: *Slot) NextRequest {
    std.debug.assert(slot.state == .reading);
    std.debug.assert(slot.read_len <= slot.read_buffer.len);

    const parsed = request_module.parse(slot.read_buffer[0..slot.read_len]) catch |err| {
        respond_error(server, slot, request_module.status_for(err));
        return .closed;
    };

    const request = switch (parsed) {
        .incomplete => {
            if (slot.read_len == slot.read_buffer.len) {
                respond_error(server, slot, .header_fields_too_large);
                return .closed;
            }
            if (slot.peer_closed) {
                close_slot(server, slot);
                return .closed;
            }

            return .wait;
        },
        .complete => |request| request,
    };

    const total: u64 = @as(u64, request.head_len) + request.content_length;

    if (total > slot.read_buffer.len) {
        respond_error(server, slot, .payload_too_large);
        return .closed;
    }

    if (slot.read_len < total) {
        if (slot.peer_closed) {
            close_slot(server, slot);
            return .closed;
        }

        return .wait;
    }

    return .{ .ready = request };
}

pub fn respond_error(server: *Engine, slot: *Slot, status: Status) void {
    std.debug.assert(status_module.is_error(status));
    std.debug.assert(slot.state == .reading);

    var arena_state = std.heap.FixedBufferAllocator.init(server.arena_buffer);
    var response = response_module.init(arena_state.allocator());

    response.keep_alive = false;
    response.text(status, status_module.reason(status)) catch return close_slot(server, slot);

    var writer: std.Io.Writer = .fixed(slot.write_buffer);
    response_module.write_to(&response, &writer, false) catch return close_slot(server, slot);

    start_writing(server, slot, @intCast(writer.buffered().len), false, slot.read_len);
}

pub fn start_writing(server: *Engine, slot: *Slot, len: u32, keep_alive: bool, consumed: u32) void {
    std.debug.assert(len <= slot.write_buffer.len);
    std.debug.assert(consumed <= slot.read_len);

    const remaining = slot.read_len - consumed;
    const tail = slot.read_buffer[consumed..slot.read_len];
    std.mem.copyForwards(u8, slot.read_buffer[0..remaining], tail);

    slot.read_len = remaining;
    slot.write_len = len;
    slot.write_pos = 0;
    slot.keep_alive = keep_alive;
    slot.state = .writing;
    slot.deadline_ms = engine_module.now_ms() + server.options.request_timeout_ms;

    flush(server, slot, .inline_first);
}

const FlushKind = enum { inline_first, from_event };

fn flush(server: *Engine, slot: *Slot, kind: FlushKind) void {
    std.debug.assert(slot.state == .writing);
    std.debug.assert(slot.write_pos <= slot.write_len);

    while (slot.write_pos < slot.write_len) {
        const chunk = slot.write_buffer[slot.write_pos..slot.write_len];
        const sent = socket.send(slot.fd, chunk) catch |err| switch (err) {
            error.WouldBlock => {
                if (kind == .inline_first) {
                    const index = server.slot_index(slot);
                    const write_token = engine_module.token(index, slot.generation);
                    server.loop.direct(slot.fd, write_token, .write) catch {
                        server.counters.event_errors_total += 1;
                        return close_slot(server, slot);
                    };
                }

                return;
            },
            else => return close_slot(server, slot),
        };

        slot.write_pos += sent;
        server.counters.bytes_written_total += sent;
    }

    if (kind == .from_event) {
        const index = server.slot_index(slot);
        server.loop.direct(slot.fd, engine_module.token(index, slot.generation), .read) catch {
            server.counters.event_errors_total += 1;
            return close_slot(server, slot);
        };
    }

    if (slot.upgrading) {
        std.debug.assert(slot.owner < server.registered_len);

        const extension = server.registered[slot.owner].extension;
        slot.upgrading = false;
        slot.state = .upgraded;
        slot.deadline_ms = engine_module.now_ms() + server.options.idle_timeout_ms;

        if (extension.on_upgraded) |on_upgraded| {
            on_upgraded(server, slot);
        }

        return;
    }

    if (!slot.keep_alive or server.phase != .running) {
        return close_slot(server, slot);
    }

    slot.state = .reading;

    const grace_ms = if (slot.read_len > 0)
        server.options.request_timeout_ms
    else
        server.options.idle_timeout_ms;
    slot.deadline_ms = engine_module.now_ms() + grace_ms;

    if (slot.read_len > 0 and kind == .from_event) {
        mark_pending(server, slot);
    }
}

pub fn service_writing(server: *Engine, slot: *Slot) void {
    flush(server, slot, .from_event);
}

pub fn close_slot(server: *Engine, slot: *Slot) void {
    std.debug.assert(slot.state != .free);
    std.debug.assert(server.active() > 0);
    std.debug.assert(server.free_count < server.slots.len);

    clear_pending(server, slot);
    server.loop.forget(slot.fd);
    socket.close(slot.fd);
    slot.state = .free;
    slot.fd = socket.invalid;
    slot.generation +%= 1;
    slot.read_len = 0;
    slot.write_len = 0;
    slot.write_pos = 0;
    slot.served = 0;
    slot.peer_closed = false;
    slot.upgrading = false;
    server.free_stack[server.free_count] = server.slot_index(slot);
    server.free_count += 1;

    server.counters.active = server.active();
}
