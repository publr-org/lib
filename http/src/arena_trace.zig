//! A request's arena, watched: when a request asks for more than its fixed buffer holds,
//! the log says which request, how full the buffer was, and, in Debug builds, which call
//! sites took the bytes, the largest first, with their stacks. Elsewhere it is the plain
//! fixed buffer with the one summary line.
const std = @import("std");
const builtin = @import("builtin");

/// Call sites are traced only where stacks are cheap to take and print.
pub const traced = builtin.mode == .Debug and std.options.allow_stack_tracing;

const frames_max = 12;
/// A page render alone has well over a thousand distinct call sites.
const sites_max = 8192;
/// Open addressing over the sites, twice their number so probes stay short.
const slots_len = sites_max * 2;
const shown_max = 10;

const Site = struct {
    addresses: [frames_max]usize = undefined,
    depth: u8 = 0,
    bytes: u64 = 0,
    count: u32 = 0,
};

pub const Table = struct {
    sites: [sites_max]Site = undefined,
    /// Each slot one past a site's index; 0 is empty.
    slots: [slots_len]u16 = @splat(0),
    used: u32 = 0,
    /// Bytes from sites past the table's room, counted but not placed.
    unplaced_bytes: u64 = 0,
};

/// The engine's table, made at startup beside its arena buffer; nothing outside Debug.
pub const Sites = struct {
    table: if (traced) *Table else void,

    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Sites {
        if (!traced) {
            return .{
                .table = {},
            };
        }

        const table = try gpa.create(Table);

        table.* = .{};

        return .{
            .table = table,
        };
    }

    pub fn deinit(sites: Sites, gpa: std.mem.Allocator) void {
        if (traced) {
            gpa.destroy(sites.table);
        }
    }
};

pub const Arena = struct {
    fixed: std.heap.FixedBufferAllocator,
    sites: Sites,
    method: []const u8,
    path: []const u8,
    reported: bool = false,

    /// The arena over `buffer` for the request `method path`, which the report names.
    pub fn init(buffer: []u8, sites: Sites, method: []const u8, path: []const u8) Arena {
        std.debug.assert(buffer.len > 0);

        if (traced) {
            sites.table.used = 0;
            sites.table.unplaced_bytes = 0;
            sites.table.slots = @splat(0);
        }

        return .{
            .fixed = .init(buffer),
            .sites = sites,
            .method = method,
            .path = path,
        };
    }

    pub fn allocator(arena: *Arena) std.mem.Allocator {
        return .{
            .ptr = arena,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn inner(arena: *Arena) std.mem.Allocator {
        return arena.fixed.allocator();
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const arena: *Arena = @ptrCast(@alignCast(context));
        const memory = arena.inner().rawAlloc(len, alignment, ret_addr);

        if (memory == null) {
            arena.report(len, ret_addr);
        } else {
            arena.note(len, ret_addr);
        }

        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const arena: *Arena = @ptrCast(@alignCast(context));
        const resized = arena.inner().rawResize(memory, alignment, new_len, ret_addr);

        if (resized and new_len > memory.len) {
            arena.note(new_len - memory.len, ret_addr);
        }

        return resized;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const arena: *Arena = @ptrCast(@alignCast(context));
        const remapped = arena.inner().rawRemap(memory, alignment, new_len, ret_addr);

        if (remapped != null and new_len > memory.len) {
            arena.note(new_len - memory.len, ret_addr);
        }

        return remapped;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const arena: *Arena = @ptrCast(@alignCast(context));

        arena.inner().rawFree(memory, alignment, ret_addr);
    }

    /// `len` bytes taken at the call site above `ret_addr`.
    fn note(arena: *Arena, len: usize, ret_addr: usize) void {
        if (!traced or arena.reported) {
            return;
        }

        var addresses: [frames_max]usize = undefined;
        const stack = std.debug.captureCurrentStackTrace(.{
            .first_address = ret_addr,
        }, &addresses);
        const table = arena.sites.table;
        const site = place(table, stack.return_addresses) orelse {
            table.unplaced_bytes += len;
            return;
        };

        site.bytes += len;
        site.count += 1;
    }

    /// The site with these addresses, made when new; null when the table is full.
    fn place(table: *Table, addresses: []const usize) ?*Site {
        std.debug.assert(addresses.len <= frames_max);

        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(addresses));
        var slot: usize = @intCast(hash % slots_len);
        var probes: u32 = 0;

        while (table.slots[slot] != 0) : (probes += 1) {
            std.debug.assert(probes < slots_len);

            const site = &table.sites[table.slots[slot] - 1];

            if (std.mem.eql(usize, site.addresses[0..site.depth], addresses)) {
                return site;
            }

            slot = (slot + 1) % slots_len;
        }

        if (table.used == sites_max) {
            return null;
        }

        const site = &table.sites[table.used];

        table.used += 1;
        table.slots[slot] = @intCast(table.used);
        site.* = .{
            .depth = @intCast(addresses.len),
        };
        @memcpy(site.addresses[0..addresses.len], addresses);

        return site;
    }

    /// The request's first allocation that did not fit, written to the log once.
    fn report(arena: *Arena, len: usize, ret_addr: usize) void {
        if (arena.reported) {
            return;
        }

        arena.reported = true;

        const used = arena.fixed.end_index;
        const capacity = arena.fixed.buffer.len;

        std.log.scoped(.publr_http).warn(
            "request arena full: {s} {s} used {Bi:.1} of {Bi:.1}, then asked for {Bi:.1}",
            .{ arena.method, arena.path, used, capacity, len },
        );

        if (!traced) {
            return;
        }

        var addresses: [frames_max]usize = undefined;
        const failed = std.debug.captureCurrentStackTrace(.{
            .first_address = ret_addr,
        }, &addresses);

        std.debug.print("The allocation that did not fit:\n", .{});
        std.debug.dumpStackTrace(&failed);

        const table = arena.sites.table;
        const sites = table.sites[0..table.used];

        std.mem.sort(Site, sites, {}, larger);

        const shown = @min(sites.len, shown_max);

        for (sites[0..shown], 1..) |*site, rank| {
            std.debug.print("\n#{d}: {Bi:.1} in {d} allocations ({d}% of the arena)\n", .{
                rank,
                site.bytes,
                site.count,
                site.bytes * 100 / capacity,
            });

            const stack: std.debug.StackTrace = .{
                .return_addresses = site.addresses[0..site.depth],
                .skipped = .unknown,
            };

            std.debug.dumpStackTrace(&stack);
        }

        if (table.unplaced_bytes > 0) {
            std.debug.print("\n{Bi:.1} more from sites past the first {d}\n", .{
                table.unplaced_bytes,
                sites_max,
            });
        }
    }

    fn larger(_: void, a: Site, b: Site) bool {
        return a.bytes > b.bytes;
    }
};
