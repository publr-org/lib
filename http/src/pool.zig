//! Buffers of one size, reserved once at init and lent to connections while they need one:
//! a request head being read, a large body, a response being sent. The last buffer given
//! back is the next one lent, so only as many buffers as were ever in use at the same time
//! are ever written to, and the rest of the reservation never becomes resident.
const std = @import("std");

/// How a pool takes its memory and gives it back: the engine reserves it untouched.
pub const Memory = struct {
    reserve: *const fn (std.mem.Allocator, usize) error{OutOfMemory}![]u8,
    release: *const fn (std.mem.Allocator, []u8) void,
};

pub const Pool = struct {
    /// Every buffer, end to end: `count * buffer_bytes`.
    memory: []u8,
    buffer_bytes: u32,
    /// Indices of the buffers not lent, used as a stack: `free[0..free_count]`.
    free: []u32,
    free_count: u32,

    /// `count` buffers of `buffer_bytes`; `reserve` takes the memory untouched.
    pub fn init(
        gpa: std.mem.Allocator,
        count: u32,
        buffer_bytes: u32,
        memory_functions: Memory,
    ) error{OutOfMemory}!Pool {
        std.debug.assert(buffer_bytes > 0 or count == 0);

        const total = std.math.mul(u64, count, buffer_bytes) catch return error.OutOfMemory;
        const memory: []u8 = if (total == 0)
            &.{}
        else
            try memory_functions.reserve(gpa, @intCast(total));
        errdefer if (total > 0) memory_functions.release(gpa, memory);

        const free = gpa.alloc(u32, count) catch return error.OutOfMemory;

        for (free, 0..) |*entry, index| {
            entry.* = @intCast(count - 1 - index);
        }

        std.debug.assert(free.len == count);

        return .{
            .memory = memory,
            .buffer_bytes = buffer_bytes,
            .free = free,
            .free_count = count,
        };
    }

    pub fn deinit(pool: *Pool, gpa: std.mem.Allocator, memory_functions: Memory) void {
        std.debug.assert(pool.free_count <= pool.free.len);

        if (pool.memory.len > 0) {
            memory_functions.release(gpa, pool.memory);
        }

        gpa.free(pool.free);
        pool.* = undefined;
    }

    /// A buffer, or null when every one is lent.
    pub fn take(pool: *Pool) ?[]u8 {
        std.debug.assert(pool.free_count <= pool.free.len);

        if (pool.free_count == 0) {
            return null;
        }

        pool.free_count -= 1;

        const index = pool.free[pool.free_count];
        const buffer = pool.memory[@as(usize, index) * pool.buffer_bytes ..][0..pool.buffer_bytes];

        std.debug.assert(buffer.len == pool.buffer_bytes);

        return buffer;
    }

    /// `buffer`, lent by this pool, back.
    pub fn give(pool: *Pool, buffer: []u8) void {
        std.debug.assert(buffer.len == pool.buffer_bytes);
        std.debug.assert(pool.free_count < pool.free.len);

        const offset = @intFromPtr(buffer.ptr) - @intFromPtr(pool.memory.ptr);

        std.debug.assert(offset % pool.buffer_bytes == 0);
        std.debug.assert(offset < pool.memory.len);

        pool.free[pool.free_count] = @intCast(offset / pool.buffer_bytes);
        pool.free_count += 1;
    }

    pub fn available(pool: *const Pool) u32 {
        std.debug.assert(pool.free_count <= pool.free.len);

        return pool.free_count;
    }
};

fn test_reserve(gpa: std.mem.Allocator, len: usize) error{OutOfMemory}![]u8 {
    return gpa.alloc(u8, len);
}

fn test_release(gpa: std.mem.Allocator, memory: []u8) void {
    gpa.free(memory);
}

const test_memory: Memory = .{
    .reserve = &test_reserve,
    .release = &test_release,
};

test "a pool lends each buffer once, runs out, and lends the last one given back first" {
    var pool = try Pool.init(std.testing.allocator, 3, 16, test_memory);
    defer pool.deinit(std.testing.allocator, test_memory);

    const first = pool.take().?;
    const second = pool.take().?;
    const third = pool.take().?;

    try std.testing.expect(pool.take() == null);
    try std.testing.expect(first.ptr != second.ptr and second.ptr != third.ptr);
    try std.testing.expectEqual(@as(u32, 0), pool.available());

    pool.give(second);
    pool.give(first);

    try std.testing.expectEqual(first.ptr, pool.take().?.ptr);
    try std.testing.expectEqual(second.ptr, pool.take().?.ptr);
    try std.testing.expect(pool.take() == null);
}

test "a pool of none lends nothing" {
    var pool = try Pool.init(std.testing.allocator, 0, 0, test_memory);
    defer pool.deinit(std.testing.allocator, test_memory);

    try std.testing.expect(pool.take() == null);
    try std.testing.expectEqual(@as(u32, 0), pool.available());
}
