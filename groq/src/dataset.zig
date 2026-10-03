//! Where a query's `*` reads from and `->` looks up in. In memory for the conformance suite
//! and tests; Publr's own reads its records as the caller may read them. A dataset may
//! answer `candidates` with more than match: the evaluator applies the whole filter after.

const std = @import("std");
const value_module = @import("value.zig");

const Value = value_module.Value;

/// An attribute that must hold one of these values for a document to match, taken from a
/// filter's top-level `&&`: `_type == "post"`, `slug == $slug`, `product == ^._id`.
pub const Hint = struct { attribute: []const u8, values: []const Value };

pub const Found = union(enum) {
    document: Value,
    /// There, but not for this caller: why, for the answer's problems.
    unreadable: []const u8,
    missing,
};

/// `OutOfReach`: the query names what the caller may not read at all.
pub const Error = error{ OutOfMemory, DatasetFailed, TooMuchWork, OutOfReach };

pub const Dataset = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        everything: *const fn (context: *anyopaque, arena: std.mem.Allocator) Error![]const Value,
        candidates: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            hints: []const Hint,
        ) Error![]const Value,
        find: *const fn (context: *anyopaque, arena: std.mem.Allocator, id: []const u8) Error!Found,
    };

    pub fn everything(dataset: Dataset, arena: std.mem.Allocator) Error![]const Value {
        return dataset.vtable.everything(dataset.context, arena);
    }

    pub fn candidates(
        dataset: Dataset,
        arena: std.mem.Allocator,
        hints: []const Hint,
    ) Error![]const Value {
        return dataset.vtable.candidates(dataset.context, arena, hints);
    }

    pub fn find(dataset: Dataset, arena: std.mem.Allocator, id: []const u8) Error!Found {
        std.debug.assert(id.len > 0 or id.len == 0);

        return dataset.vtable.find(dataset.context, arena, id);
    }
};

/// Documents held in memory, `*` in the order given. Hinted attributes are indexed on first
/// use (value to documents, in order), so a join reads one bucket, not every document.
pub const Memory = struct {
    documents: []const Value,
    index: ?std.StringHashMapUnmanaged(Value) = null,
    attributes: std.StringHashMapUnmanaged(Buckets) = .empty,

    /// For one attribute: the positions of the documents holding each value, in order.
    const Buckets = std.StringHashMapUnmanaged([]const u32);

    const vtable: Dataset.VTable = .{
        .everything = &everything,
        .candidates = &candidates,
        .find = &find,
    };

    pub fn dataset(memory: *Memory) Dataset {
        return .{ .context = memory, .vtable = &vtable };
    }

    fn of(context: *anyopaque) *Memory {
        return @ptrCast(@alignCast(context));
    }

    fn everything(context: *anyopaque, arena: std.mem.Allocator) Error![]const Value {
        _ = arena;

        return of(context).documents;
    }

    /// The documents of the smallest hinted bucket, in the dataset's order.
    fn candidates(
        context: *anyopaque,
        arena: std.mem.Allocator,
        hints: []const Hint,
    ) Error![]const Value {
        const memory = of(context);
        var best: ?[]const u32 = null;

        for (hints) |hint| {
            const buckets = try memory.buckets_of(arena, hint.attribute);
            var positions: std.ArrayList(u32) = .empty;
            var keyed = true;

            for (hint.values) |wanted| {
                var key_buffer: [64]u8 = undefined;
                const key = key_of(&key_buffer, wanted) orelse {
                    keyed = false;
                    break;
                };

                if (buckets.get(key)) |found| {
                    try positions.appendSlice(arena, found);
                }
            }

            // A value too long to key cannot narrow: the hint is left out.
            if (!keyed) {
                continue;
            }

            if (best == null or positions.items.len < best.?.len) {
                std.mem.sort(u32, positions.items, {}, std.sort.asc(u32));
                best = positions.items;
            }
        }

        const chosen = best orelse return memory.documents;
        const documents = try arena.alloc(Value, chosen.len);
        var count: u32 = 0;
        var previous: ?u32 = null;

        for (chosen) |position| {
            if (previous != null and previous.? == position) {
                continue;
            }

            documents[count] = memory.documents[position];
            count += 1;
            previous = position;
        }

        return documents[0..count];
    }

    fn buckets_of(memory: *Memory, arena: std.mem.Allocator, attribute: []const u8) Error!Buckets {
        std.debug.assert(memory.documents.len <= std.math.maxInt(u32));

        if (memory.attributes.get(attribute)) |built| {
            return built;
        }

        var lists: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;

        for (memory.documents, 0..) |document, position| {
            if (document != .object) {
                continue;
            }

            const held = document.object.get(attribute) orelse continue;
            var key_buffer: [64]u8 = undefined;
            const key = key_of(&key_buffer, held) orelse continue;
            const entry = try lists.getOrPut(arena, key);

            if (!entry.found_existing) {
                entry.key_ptr.* = try arena.dupe(u8, key);
                entry.value_ptr.* = .empty;
            }

            try entry.value_ptr.append(arena, @intCast(position));
        }

        var built: Buckets = .empty;
        var entries = lists.iterator();

        while (entries.next()) |entry| {
            try built.put(arena, entry.key_ptr.*, entry.value_ptr.items);
        }

        try memory.attributes.put(arena, attribute, built);

        return built;
    }

    fn find(context: *anyopaque, arena: std.mem.Allocator, id: []const u8) Error!Found {
        std.debug.assert(of(context).documents.len <= std.math.maxInt(u32));

        const memory = of(context);

        if (memory.index == null) {
            var built: std.StringHashMapUnmanaged(Value) = .empty;

            for (memory.documents) |document| {
                if (document != .object) {
                    continue;
                }

                const own = document.object.get("_id") orelse continue;

                if (own == .string and !built.contains(own.string)) {
                    try built.put(arena, own.string, document);
                }
            }

            memory.index = built;
        }

        const found = memory.index.?.get(id) orelse return .missing;

        return .{ .document = found };
    }
};

/// A scalar as a bucket key, its type first so `1` and `"1"` differ; null for other values
/// and for text too long to key (such documents are found by a full read instead).
fn key_of(buffer: *[64]u8, value: Value) ?[]const u8 {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    return switch (value) {
        .string => |text| std.fmt.bufPrint(buffer, "s{s}", .{text}) catch null,
        .number => |number| std.fmt.bufPrint(buffer, "n{d}", .{number}) catch null,
        .boolean => |truth| if (truth) "btrue" else "bfalse",
        else => null,
    };
}
