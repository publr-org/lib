//! The engine: a fixed-capacity, single-threaded HTTP/1.1 event loop over kqueue/epoll
//! readiness. Non-generic and routing-agnostic — parsing, framing, slots, timeouts,
//! shutdown, and extension plumbing live here, while routing and handler invocation
//! live in the comptime layer (server.zig), which reaches back in through the single
//! `on_request` hook.
//!
//! A handler never touches the engine: `ctx.counters` and `ctx.options` point into
//! it, and that is all a handler needs. An extension taking over a connection
//! (extensions/websocket.zig) works with `Slot`, `Extension`, `slot_index`, and
//! `extension_index`. Nothing here is called directly by an app — `http.Server(...)`
//! wraps it — and none of it is public outside this library.
//!
//! All memory is allocated once at init: one slot per connection with static read/write
//! buffers, one shared handler arena (dispatch is synchronous, so responses never outlive
//! the serialization that follows), an O(1) free-slot stack, a pending list for slots
//! whose pipelined requests exceeded their fairness budget, and the state of every
//! registered extension. The hot path (request in, response out) performs zero
//! event-interest syscalls: write interest is enabled only when a response hits a short
//! write, and disabled once it drains.
const std = @import("std");
const event = @import("platform/event.zig");
const socket = @import("platform/socket.zig");
const request_module = @import("http/request.zig");
const connection = @import("connection.zig");

const connections_limit: u32 = 1 << 18;
/// After this many requests on one keep-alive connection the engine answers the next
/// one with `Connection: close` — a cheap guard against a client holding a slot
/// forever, not a throughput limit.
pub const requests_per_connection_max: u32 = 100_000;

const accept_batch: u32 = 64;
/// Most pipelined requests served from one connection in one `tick`; anything past
/// it waits on the pending list until the next tick, so one eager client cannot
/// starve the rest.
pub const pipeline_batch: u32 = 16;
const events_max: u32 = 256;
const arena_bytes_min: u32 = 256 << 10;
const backlog_min: u31 = 128;
const backlog_max: u31 = 4096;
const scan_interval_ms: u32 = 500;
const fd_margin: u32 = 64;

/// Debug builds serve this machine only; release builds serve all interfaces.
const address_default: [4]u8 = if (@import("builtin").mode == .Debug)
    .{ 127, 0, 0, 1 }
else
    .{ 0, 0, 0, 0 };

const refused_response = "HTTP/1.1 503 Service Unavailable\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\nContent-Length: 19\r\n" ++
    "Retry-After: 1\r\nConnection: close\r\n\r\nservice unavailable";

/// The single configuration surface: the same struct whether filled from code, from a
/// .zon config file (which parses directly into it), or from CLI flags. Buffer sizes,
/// backlog, and event-loop internals are derived from these, never set directly.
pub const Options = struct {
    /// The default bind is decided at compile time by the build mode: a Debug build is
    /// a dev build and binds 127.0.0.1 (private to the machine, no firewall prompts);
    /// a release build is a deployment artifact and binds 0.0.0.0 (reachable out of
    /// the box, the nginx convention). `--address` overrides either way, and the
    /// startup banner always prints what was bound.
    address: [4]u8 = address_default,
    /// TCP port to listen on. `0` asks the kernel for an ephemeral port, which is
    /// how this library's own tests avoid colliding.
    port: u16 = 8080,
    /// Concurrent connection slots, allocated up front and never grown. A client
    /// arriving when every slot is busy gets a 503 with `Retry-After: 1` and its
    /// connection closed — load is shed, never queued. Also sizes the listen
    /// backlog and the open-file limit `init` asks the OS for.
    connections_max: u32 = 4096,
    /// Caps one request, head plus body; sized as each slot's read buffer. A
    /// request whose head alone exceeds it gets 431, one whose declared body
    /// would exceed it gets 413.
    request_bytes_max: u32 = 16 << 10,
    /// Caps one serialized response, headers plus body; sized as each slot's
    /// write buffer. A handler response that does not fit becomes a 500.
    response_bytes_max: u32 = 32 << 10,
    /// How long a keep-alive connection may sit with no request in progress
    /// before the engine closes it. Counted in `Counters.timed_out_total`.
    idle_timeout_ms: u32 = 15_000,
    /// Deadline for one request to arrive in full and its response to drain:
    /// armed when the first byte of a request lands, re-armed when the response
    /// starts writing. A slow-loris sender or a stalled reader is closed when it
    /// expires.
    request_timeout_ms: u32 = 30_000,
    /// After `stop` (or a shutdown signal), how long in-flight responses get to
    /// finish before the engine stops regardless.
    shutdown_timeout_ms: u32 = 5_000,
};

/// User-space memory `init` will allocate up front — every slot's buffers plus the
/// handler arena — for the CLI's startup banner.
pub fn memory_bytes(options: *const Options) u64 {
    const per_slot: u64 = @as(u64, options.request_bytes_max) + options.response_bytes_max +
        @sizeOf(Slot) + @sizeOf(u32);
    return per_slot * options.connections_max + arena_bytes(options);
}

/// Open-file descriptors the server needs: one per connection slot plus a
/// fixed margin for the listener, the event queue, and the application's own
/// files. `init` raises the process's soft limit to this; the CLI banner prints it.
pub fn files_needed(options: *const Options) u64 {
    return @as(u64, options.connections_max) + fd_margin;
}

/// Handler scratch arena: enough to build a response body before serialization, never
/// less than a fixed floor so small response caps do not starve handlers.
pub fn arena_bytes(options: *const Options) u32 {
    return @max(arena_bytes_min, std.math.mul(u32, options.response_bytes_max, 2) catch
        std.math.maxInt(u32));
}

/// Listen backlog follows capacity within kernel-realistic bounds.
pub fn backlog(options: *const Options) u31 {
    const clamped = std.math.clamp(options.connections_max, backlog_min, backlog_max);
    return @intCast(clamped);
}

/// Always-on tallies the engine records as it serves — pure integer increments on
/// paths that just did a syscall, so effectively free. Handlers read them as
/// `ctx.counters`, embedders as `app.engine.counters`; the CLI prints them as the
/// exit summary. They never touch the wire unless a handler serves them.
///
/// The `/stats` endpoint, in full:
///
/// ```zig
/// fn stats(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
///     _ = req;
///     try res.json(.ok, .{ .server = ctx.counters.*, .pid = http.process.id() });
/// }
/// ```
pub const Counters = struct {
    /// Connections accepted into a slot over the server's life.
    accepted_total: u64 = 0,
    /// Connections turned away with a 503 because every slot was busy.
    refused_total: u64 = 0,
    /// Connections closed by `idle_timeout_ms` or `request_timeout_ms` expiring.
    timed_out_total: u64 = 0,
    /// Complete requests handed to the router, pipelined ones included.
    requests_total: u64 = 0,
    /// Bytes received from clients, HTTP and WebSocket alike.
    bytes_read_total: u64 = 0,
    /// Bytes sent to clients, HTTP and WebSocket alike.
    bytes_written_total: u64 = 0,
    /// `accept()` calls that failed — typically the process at its open-file
    /// limit, which `connections_max` is meant to keep under the hard limit.
    accept_errors_total: u64 = 0,
    /// Event-interest registrations that failed; each one cost a connection.
    event_errors_total: u64 = 0,
    /// Connections open right now.
    active: u32 = 0,
    /// The highest `active` has been.
    active_peak: u32 = 0,
};

/// Everything `init`, `listen`, `tick`, `bound_port`, and `enable_shutdown_signals`
/// can fail with. Spelled out rather than merged from the platform layer so the set
/// is the contract, not an accident of whatever the OS binding happens to define:
/// every member below is one the engine genuinely returns.
///
/// Per-connection failures (a peer resetting, a full kernel buffer) are not here —
/// the engine absorbs those on the spot, closing the slot or waiting for
/// writability, and counts them in `Counters`.
pub const Error = error{
    /// `socket()` itself refused: the kernel would not hand out a TCP socket.
    SocketFailed,
    /// `bind()` failed for a reason other than the port being taken — an address
    /// this host does not own, or a privileged port without the rights for it.
    BindFailed,
    /// `listen()` failed after a successful bind.
    ListenFailed,
    /// Another process already holds the port. The CLI reports this one by name
    /// with the port number.
    AddressInUse,
    /// Opening a descriptor hit the process's open-file limit. `init` raises the
    /// soft limit toward what `Options.files_needed` asks for first, so this means
    /// the hard limit is lower than that.
    FileLimitReached,
    /// The open-file hard limit cannot cover `Options.files_needed`: lower
    /// `connections_max` or raise the limit (`ulimit -n`). The CLI reports this one
    /// by name with the number needed.
    FileLimitTooLow,
    /// The kernel refused to create the readiness queue (kqueue/epoll), or the
    /// shutdown-signal registration failed.
    EventInitFailed,
    /// Registering or changing interest on a descriptor failed. From `init`, the
    /// listener could not be registered.
    EventChangeFailed,
    /// The readiness wait itself failed, from `tick` (and so from `listen`). Not
    /// the same as an error on one connection, which is handled per slot.
    EventWaitFailed,
    /// `init` could not allocate the slot pool, buffers, or an extension's state.
    OutOfMemory,
    /// A syscall failed in a way the platform layer has no specific name for.
    Unexpected,
};

/// Where the engine is in its life. Read it as `app.engine.phase` when driving
/// `tick` by hand, to know when to stop.
pub const Phase = enum {
    /// Accepting and serving.
    running,
    /// `stop` (or a shutdown signal) has been seen: the listener is closed, idle
    /// connections are gone, in-flight responses finish, and the next `tick` after
    /// the last one drains — or after `shutdown_timeout_ms` — moves to `stopped`.
    draining,
    /// Done; `listen` has returned and `tick` must not be called again.
    stopped,
};

const State = enum { free, reading, writing, upgraded };

/// One connection's state from accept to close — the engine-side record an extension
/// works with after taking the connection over. Slots are preallocated, one per
/// `Options.connections_max`, and recycled through the free stack with a bumped
/// `generation` each time. Handlers see one as `ctx.slot` but have no reason to
/// touch it.
pub const Slot = struct {
    /// The connection's descriptor; `socket.invalid` while the slot is free.
    fd: socket.Fd = socket.invalid,
    /// Where the connection is in its life. `.upgraded` hands its events to the
    /// extension in `owner` instead of the HTTP pipeline.
    state: State = .free,
    /// Bumped on every close and packed into the event token, so a readiness
    /// event for a connection that was closed and the slot reused is ignored.
    generation: u32 = 0,
    /// This slot's fixed read buffer, `Options.request_bytes_max` long.
    read_buffer: []u8,
    /// Bytes of `read_buffer` holding input not yet consumed.
    read_len: u32 = 0,
    /// This slot's fixed write buffer, `Options.response_bytes_max` long.
    write_buffer: []u8,
    /// Bytes of `write_buffer` queued for sending.
    write_len: u32 = 0,
    /// Bytes of the queued `write_len` already on the wire; a write is in flight
    /// while this is less than `write_len`.
    write_pos: u32 = 0,
    /// Whether the connection stays open once the current response has drained.
    keep_alive: bool = true,
    /// The peer half-closed: whatever is buffered is all there will ever be.
    peer_closed: bool = false,
    /// On the pending list — pipelined requests are waiting past this tick's
    /// fairness budget (`pipeline_batch`).
    pending: bool = false,
    /// An extension has queued its switching response; once it drains, `state`
    /// becomes `.upgraded` and the owner's `on_upgraded` fires.
    upgrading: bool = false,
    /// Registration index of the extension that owns this connection while
    /// `upgrading` or `.upgraded`; obtained with `Engine.extension_index`.
    owner: u32 = 0,
    /// Monotonic time at which the active timeout expires. Once upgraded it is
    /// armed with `idle_timeout_ms` and the owning extension re-arms it as traffic
    /// arrives; on expiry the extension's `on_expired` decides (or, absent one,
    /// the slot is closed like any idle keep-alive connection).
    deadline_ms: i64 = 0,
    /// Requests served on this connection, against `requests_per_connection_max`.
    served: u32 = 0,
};

/// Most extensions one server can register.
const extensions_max: u32 = 8;

/// The engine-side contract an extension module implements (src/extensions/ holds the
/// implementations; server.zig collects these vtables from the comptime extension set).
/// The engine owns extension state: `init` is called once with the connection count,
/// `deinit` on engine deinit, and the app layer hands handlers a typed pointer to the
/// state via the context.
///
/// The optional hooks are for extensions that take over connections. A takeover starts
/// inside an ordinary route handler: the extension queues its switching response
/// directly on the slot with `slot.upgrading` and `slot.owner` set, and once that
/// response drains the slot moves to `.upgraded`, `on_upgraded` fires, and the slot's
/// events go to `on_readable`/`on_writable` instead of the HTTP pipeline. An
/// `.upgraded` slot is still covered by the timeout scan: its deadline starts at
/// `idle_timeout_ms` past the upgrade, the extension re-arms `slot.deadline_ms` as it
/// sees traffic, and when it expires `on_expired` fires — so a peer that goes silent
/// cannot hold a slot forever, whatever protocol it upgraded to.
pub const Extension = struct {
    /// Allocates the extension's per-server state, sized for `connections_max`
    /// connections. The returned pointer is what handlers see as
    /// `ctx.extensions.<name>`, cast back to the extension's `State`.
    init: *const fn (gpa: std.mem.Allocator, connections_max: u32) error{OutOfMemory}!*anyopaque,
    /// Frees what `init` allocated; called from `Engine.deinit`.
    deinit: *const fn (gpa: std.mem.Allocator, context: *anyopaque) void,
    /// Fires once the takeover's switching response has fully drained and the
    /// slot is `.upgraded`. Sending is safe from here on.
    on_upgraded: ?*const fn (server: *Engine, slot: *Slot) void = null,
    /// The connection is readable, or the peer closed. The extension drains the
    /// socket into `slot.read_buffer` itself.
    on_readable: ?*const fn (server: *Engine, slot: *Slot) void = null,
    /// The connection became writable after a short write; resume sending from
    /// `slot.write_pos`.
    on_writable: ?*const fn (server: *Engine, slot: *Slot) void = null,
    /// The upgraded slot's `deadline_ms` passed. The extension either re-arms the
    /// deadline (after probing the peer, say) or closes the slot; an extension
    /// without this hook has its silent connections closed by the engine,
    /// counted in `Counters.timed_out_total`.
    on_expired: ?*const fn (server: *Engine, slot: *Slot) void = null,
};

const Registered = struct {
    extension: *const Extension,
    context: *anyopaque,
};

/// The app layer's entry point for a complete, framed request: build the context,
/// route, serialize the response, and start writing (see server.zig's request shim).
const OnRequest = *const fn (server: *Engine, slot: *Slot, request: *const request_module.Request) void;

/// The running server: listener, event loop, slot pool, counters, and the registered
/// extensions. An `App` holds one; handlers get `ctx.counters` and `ctx.options`
/// pointing into it and nothing more. Every other field is loop state that the
/// connection machine and extensions mutate.
pub const Engine = struct {
    /// The allocator `init` took everything from and `deinit` returns it to.
    gpa: std.mem.Allocator,
    /// The configuration this engine was built with, unchanged since `init`.
    options: Options,
    /// The listening socket; closed at the start of draining.
    listener: socket.Fd,
    /// The readiness backend: kqueue, epoll, or poll.
    loop: event.Loop,
    /// One slot per `Options.connections_max`, indexed by the low half of an
    /// event token.
    slots: []Slot,
    /// Backing memory for every slot's `read_buffer`, carved up at init.
    read_buffers: []u8,
    /// Backing memory for every slot's `write_buffer`, carved up at init.
    write_buffers: []u8,
    /// The per-request scratch arena handed to handlers as `ctx.arena`, reset for
    /// every request. Dispatch is synchronous, so one buffer serves all slots.
    arena_buffer: []u8,
    /// Indices of free slots, used as a stack: `free_stack[0..free_count]`.
    free_stack: []u32,
    /// Live entries of `free_stack`; `slots.len - free_count` is `active`.
    free_count: u32,
    /// Slots with pipelined requests waiting past this tick's fairness budget.
    pending_total: u32 = 0,
    /// The always-on tallies; see `Counters`.
    counters: Counters = .{},
    /// Running, draining, or stopped; see `Phase`.
    phase: Phase = .running,
    /// When the timeout scan next runs over every slot.
    next_scan_ms: i64 = 0,
    /// When draining stops waiting for in-flight responses.
    shutdown_deadline_ms: i64 = 0,
    /// The app layer's request entry point — server.zig's shim.
    on_request: OnRequest,
    /// The extensions registered at init, in declaration order, with their state.
    registered: [extensions_max]Registered = undefined,
    /// How many of `registered` are live.
    registered_len: u32 = 0,

    /// Binds and listens on `options.address:port`, preallocates every slot and
    /// buffer, creates the event loop, and initializes each extension. The app
    /// layer calls this from `App.init`; `on_request` is its request shim.
    ///
    /// Fails with any member of `Error`. On failure everything allocated so far
    /// is released, so there is nothing to deinit. Asserts the options are sane:
    /// at least one slot, a read buffer that can hold a maximal head, timeouts
    /// longer than the scan interval.
    pub fn init(
        gpa: std.mem.Allocator,
        options: Options,
        vtables: []const *const Extension,
        on_request: OnRequest,
    ) Error!Engine {
        std.debug.assert(vtables.len <= extensions_max);
        std.debug.assert(options.connections_max > 0);
        std.debug.assert(options.connections_max <= connections_limit);
        std.debug.assert(options.request_bytes_max >= request_module.head_bytes_max);
        std.debug.assert(options.response_bytes_max >= 1 << 10);
        std.debug.assert(options.idle_timeout_ms >= 2 * scan_interval_ms);
        std.debug.assert(options.request_timeout_ms >= 2 * scan_interval_ms);

        try socket.ensure_file_limit(files_needed(&options));

        const listener = try socket.listen_tcp(options.address, options.port, backlog(&options));
        errdefer socket.close(listener);

        var loop = try event.Loop.init(gpa, events_max, options.connections_max + 4);
        errdefer loop.deinit();

        try loop.add_listener(listener);

        const count: u64 = options.connections_max;

        const slots = gpa.alloc(Slot, options.connections_max) catch return error.OutOfMemory;
        errdefer gpa.free(slots);

        const read_total = std.math.mul(u64, count, options.request_bytes_max) catch
            return error.OutOfMemory;
        const read_buffers = gpa.alloc(u8, @intCast(read_total)) catch return error.OutOfMemory;
        errdefer gpa.free(read_buffers);

        const write_total = std.math.mul(u64, count, options.response_bytes_max) catch
            return error.OutOfMemory;
        const write_buffers = gpa.alloc(u8, @intCast(write_total)) catch return error.OutOfMemory;
        errdefer gpa.free(write_buffers);

        const arena_buffer = gpa.alloc(u8, arena_bytes(&options)) catch return error.OutOfMemory;
        errdefer gpa.free(arena_buffer);

        const free_stack = gpa.alloc(u32, options.connections_max) catch return error.OutOfMemory;
        errdefer gpa.free(free_stack);

        for (slots, 0..) |*slot, index| {
            slot.* = .{
                .read_buffer = read_buffers[index * options.request_bytes_max ..][0..options
                    .request_bytes_max],
                .write_buffer = write_buffers[index * options.response_bytes_max ..][0..options
                    .response_bytes_max],
            };
            free_stack[index] = @intCast(options.connections_max - 1 - index);
        }

        std.debug.assert(slots.len == options.connections_max);

        var registered: [extensions_max]Registered = undefined;
        var registered_len: u32 = 0;
        errdefer for (registered[0..registered_len]) |entry| {
            entry.extension.deinit(gpa, entry.context);
        };

        for (vtables) |extension| {
            const context = try extension.init(gpa, options.connections_max);
            registered[registered_len] = .{ .extension = extension, .context = context };
            registered_len += 1;
        }

        return .{
            .gpa = gpa,
            .options = options,
            .listener = listener,
            .loop = loop,
            .slots = slots,
            .read_buffers = read_buffers,
            .write_buffers = write_buffers,
            .arena_buffer = arena_buffer,
            .free_stack = free_stack,
            .free_count = options.connections_max,
            .next_scan_ms = now_ms() + scan_interval_ms,
            .on_request = on_request,
            .registered = registered,
            .registered_len = registered_len,
        };
    }

    /// Closes every open connection and the listener, frees every extension's
    /// state, and poisons the value. Connections still open are dropped without a
    /// response; `stop` first and drain if that matters.
    pub fn deinit(server: *Engine) void {
        for (server.slots) |*slot| {
            if (slot.state != .free) {
                socket.close(slot.fd);
            }
        }

        if (server.phase == .running) {
            socket.close(server.listener);
        }

        for (server.registered[0..server.registered_len]) |entry| {
            entry.extension.deinit(server.gpa, entry.context);
        }

        server.loop.deinit();
        server.gpa.free(server.free_stack);
        server.gpa.free(server.arena_buffer);
        server.gpa.free(server.write_buffers);
        server.gpa.free(server.read_buffers);
        server.gpa.free(server.slots);
        server.* = undefined;
    }

    /// The port the listener is actually bound to — the ephemeral one when
    /// `Options.port` was 0. Fails with `error.Unexpected` if the kernel will not
    /// report it.
    pub fn bound_port(server: *const Engine) Error!u16 {
        return socket.bound_port(server.listener);
    }

    /// Routes SIGINT and SIGTERM (Ctrl-C on Windows) into `stop`. Not installed
    /// unless asked: a library must not take over a process's signals uninvited.
    /// A second signal during the drain stops immediately. Fails with
    /// `error.EventInitFailed` if the signal source cannot be registered.
    pub fn enable_shutdown_signals(server: *Engine) Error!void {
        try server.loop.add_shutdown_signals();
    }

    /// Serves until `phase` is `.stopped` — `tick` in a loop. Returns only after a
    /// `stop` (or signal) and the drain that follows it. Fails as `tick` does.
    pub fn listen(server: *Engine) Error!void {
        std.debug.assert(server.phase == .running);

        while (server.phase != .stopped) try server.tick(scan_interval_ms);
    }

    /// Begins graceful shutdown: the listener closes, idle connections close, and
    /// in-flight responses drain until done or `shutdown_timeout_ms`. Calling it
    /// again while draining stops immediately.
    pub fn stop(server: *Engine) void {
        server.shutdown_begin();
    }

    /// One event-loop iteration: wait for readiness (at most `timeout_cap_ms`),
    /// service every ready slot, accept new connections, run the timeout scan
    /// when due, and advance the drain. `listen` is this in a loop.
    ///
    /// Call it directly to interleave the server with other work, or to drive
    /// tests:
    ///
    /// ```zig
    /// while (app.engine.phase != .stopped) {
    ///     try app.tick(20);
    ///     do_other_work();
    /// }
    /// ```
    ///
    /// Fails with `error.EventWaitFailed` if the readiness wait itself fails. A
    /// failure on one connection never propagates; it closes that slot.
    pub fn tick(server: *Engine, timeout_cap_ms: i32) Error!void {
        std.debug.assert(server.phase != .stopped);
        std.debug.assert(server.free_count <= server.slots.len);
        std.debug.assert(timeout_cap_ms >= 0);

        const timeout = @min(server.wait_timeout_ms(), timeout_cap_ms);
        const events = try server.loop.wait(timeout);
        var listener_ready = false;

        for (events) |item| {
            if (item.token == event.token_signal) {
                server.shutdown_begin();
            } else if (item.token == event.token_listener) {
                listener_ready = true;
            } else {
                server.dispatch(item);
            }
        }

        server.service_pending();

        if (listener_ready and server.phase == .running) {
            try server.accept_pending();
        }

        const now = now_ms();

        if (now >= server.next_scan_ms) {
            server.expire_slots(now);
            server.next_scan_ms = now + scan_interval_ms;
        }

        if (server.phase == .draining) {
            const drained = server.active() == 0;

            if (drained or now >= server.shutdown_deadline_ms) {
                server.phase = .stopped;
            }
        }
    }

    /// Live connections: every non-free slot is exactly one accepted connection.
    pub fn active(server: *const Engine) u32 {
        std.debug.assert(server.free_count <= server.slots.len);

        return @intCast(server.slots.len - server.free_count);
    }

    fn wait_timeout_ms(server: *const Engine) i32 {
        std.debug.assert(server.next_scan_ms > 0);

        if (server.pending_total > 0) {
            return 0;
        }

        const now = now_ms();
        var until = server.next_scan_ms - now;

        if (server.phase == .draining) {
            until = @min(until, server.shutdown_deadline_ms - now);
        }

        return @intCast(std.math.clamp(until, 0, scan_interval_ms));
    }

    fn dispatch(server: *Engine, item: event.Event) void {
        const index: u32 = @truncate(item.token);
        const generation: u32 = @intCast(item.token >> 32);

        std.debug.assert(item.token < event.token_reserved_first);

        if (index >= server.slots.len) {
            return;
        }

        const slot = &server.slots[index];

        if (slot.state == .free or slot.generation != generation) {
            return;
        }

        switch (slot.state) {
            .reading => if (item.readable or item.eof) {
                connection.service_reading(server, slot);
            },
            .writing => if (item.writable) {
                connection.service_writing(server, slot);
            } else if (item.eof) {
                connection.close_slot(server, slot);
            },
            .upgraded => {
                std.debug.assert(slot.owner < server.registered_len);

                const extension = server.registered[slot.owner].extension;

                if (item.readable or item.eof) {
                    if (extension.on_readable) |on_readable| {
                        on_readable(server, slot);
                    }
                }
                if (slot.state == .upgraded and item.writable) {
                    if (extension.on_writable) |on_writable| {
                        on_writable(server, slot);
                    }
                }
            },
            .free => unreachable,
        }
    }

    fn service_pending(server: *Engine) void {
        std.debug.assert(server.pending_total <= server.slots.len);

        if (server.pending_total == 0) {
            return;
        }

        for (server.slots) |*slot| {
            if (slot.pending and slot.state == .reading) {
                connection.process_requests(server, slot);
            }
        }
    }

    fn accept_pending(server: *Engine) Error!void {
        std.debug.assert(server.phase == .running);
        std.debug.assert(server.listener >= 0);

        var accepted: u32 = 0;

        while (accepted < accept_batch) : (accepted += 1) {
            const fd = socket.accept(server.listener) catch {
                server.counters.accept_errors_total += 1;
                return;
            } orelse return;

            if (server.free_count == 0) {
                server.refuse(fd);
                continue;
            }

            server.free_count -= 1;

            const index = server.free_stack[server.free_count];
            const slot = &server.slots[index];

            std.debug.assert(slot.state == .free);

            slot.* = .{
                .fd = fd,
                .state = .reading,
                .generation = slot.generation,
                .read_buffer = slot.read_buffer,
                .write_buffer = slot.write_buffer,
                .deadline_ms = now_ms() + server.options.idle_timeout_ms,
            };

            server.loop.add_connection(fd, token(index, slot.generation)) catch {
                server.counters.event_errors_total += 1;
                socket.close(fd);
                slot.state = .free;
                server.free_stack[server.free_count] = index;
                server.free_count += 1;
                continue;
            };

            const counters = &server.counters;
            counters.accepted_total += 1;
            counters.active = server.active();
            counters.active_peak = @max(counters.active_peak, counters.active);
        }
    }

    fn refuse(server: *Engine, fd: socket.Fd) void {
        std.debug.assert(server.free_count == 0);
        std.debug.assert(fd != socket.invalid);

        var sink: [1024]u8 = undefined;
        var drains: u32 = 0;

        while (drains < 16) : (drains += 1) {
            _ = socket.recv(fd, &sink) catch break;
        }

        _ = socket.send(fd, refused_response) catch 0;
        socket.close(fd);

        server.counters.refused_total += 1;
    }

    fn shutdown_begin(server: *Engine) void {
        std.debug.assert(server.phase != .stopped);

        if (server.phase == .draining) {
            server.phase = .stopped;
            return;
        }

        server.phase = .draining;
        server.shutdown_deadline_ms = now_ms() + server.options.shutdown_timeout_ms;
        server.loop.forget(server.listener);
        socket.close(server.listener);

        for (server.slots) |*slot| {
            const idle = slot.state == .reading and slot.read_len == 0;

            if (slot.state != .free and idle) {
                connection.close_slot(server, slot);
            }
        }
    }

    fn expire_slots(server: *Engine, now: i64) void {
        std.debug.assert(now > 0);

        for (server.slots) |*slot| {
            if (slot.state == .free) {
                continue;
            }

            if (now < slot.deadline_ms) {
                continue;
            }

            if (slot.state == .upgraded) {
                std.debug.assert(slot.owner < server.registered_len);

                if (server.registered[slot.owner].extension.on_expired) |on_expired| {
                    on_expired(server, slot);
                    continue;
                }
            }

            server.counters.timed_out_total += 1;
            connection.close_slot(server, slot);
        }
    }

    /// Finds the registration index of the extension state at `context` — the value
    /// an extension stores in `slot.owner` when taking over a connection. Asserts the
    /// state belongs to a registered extension.
    pub fn extension_index(server: *const Engine, context: *const anyopaque) u32 {
        for (server.registered[0..server.registered_len], 0..) |entry, index| {
            if (entry.context == context) {
                return @intCast(index);
            }
        }

        unreachable;
    }

    /// Position of `slot` in `slots` — the index half of its event token, and the
    /// index into an extension's per-connection state.
    pub fn slot_index(server: *const Engine, slot: *const Slot) u32 {
        const base = @intFromPtr(server.slots.ptr);
        const index: u32 = @intCast((@intFromPtr(slot) - base) / @sizeOf(Slot));

        std.debug.assert(index < server.slots.len);

        return index;
    }
};

/// Packs a slot index and generation into the u64 the event loop carries back with
/// each readiness event, so a stale event can be told from a live one.
pub fn token(index: u32, generation: u32) u64 {
    return (@as(u64, generation) << 32) | index;
}

/// The monotonic clock every deadline in the engine is measured against.
pub fn now_ms() i64 {
    return socket.monotonic_ms();
}
