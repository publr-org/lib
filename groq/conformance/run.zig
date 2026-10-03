//! Runs the GROQ conformance suite (github.com/sanity-io/groq-test-suite, its compiled
//! `suite.ndjson`) against Publr's GROQ engine and reports what passes, by file. Tests of what
//! Publr does not support on purpose are skipped and counted: the extensions, custom
//! functions, delta mode and `diff::`, vendor functions, GROQ before 1.0, and the movies
//! dataset unless given. `zig build conformance -- <suite.ndjson> [--show N] [--movies <path>]`.

const std = @import("std");
const groq = @import("groq");

const Value = groq.Value;

const skipped_features = [_][]const u8{
    "geoFunctions", "portableText", "customFunctions", "contentReleases", "internalDocuments",
};
const skipped_files = [_][]const u8{
    "function/diff.yml", "function/identity.yml", "type/path.yml", "legacy/func_path.yml",
};

const Counts = struct { passed: u32 = 0, failed: u32 = 0 };

pub fn main(init: std.process.Init) !u8 {
    std.debug.assert(skipped_features.len > 0);

    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    if (arguments.len < 2) {
        std.debug.print("usage: groq-suite <suite.ndjson> [--show N] [--movies <path>]\n", .{});
        return 2;
    }

    var show: u32 = 20;
    var movies_path: ?[]const u8 = null;
    var flag: usize = 2;

    while (flag + 1 < arguments.len) : (flag += 2) {
        if (std.mem.eql(u8, arguments[flag], "--show")) {
            show = try std.fmt.parseInt(u32, arguments[flag + 1], 10);
        } else if (std.mem.eql(u8, arguments[flag], "--movies")) {
            movies_path = arguments[flag + 1];
        }
    }

    const limit: std.Io.Limit = .limited(512 << 20);
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], arena, limit);
    var lines: std.ArrayList(std.json.Value) = .empty;
    var datasets: std.StringHashMapUnmanaged([]const Value) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');

    while (split.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});

        if (std.mem.eql(u8, parsed.object.get("_type").?.string, "dataset")) {
            const name = if (parsed.object.get("name")) |given| given.string else "";

            if (std.mem.eql(u8, name, "movies")) {
                if (movies_path) |path| {
                    const documents = try load_ndjson(init.io, arena, path);

                    try datasets.put(arena, parsed.object.get("_id").?.string, documents);
                }

                continue;
            }

            const documents = parsed.object.get("documents") orelse continue;

            if (documents != .array) {
                continue;
            }

            const converted = try groq.values.from_json(arena, documents);
            const sorted = try arena.dupe(Value, converted.array);

            // `*` is the dataset in `_id` order, as the reference implementation reads it.
            std.mem.sort(Value, sorted, {}, by_id);
            try datasets.put(arena, parsed.object.get("_id").?.string, sorted);
        } else {
            try lines.append(arena, parsed);
        }
    }

    return run(init.io, arena, lines.items, &datasets, show);
}

fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    tests: []const std.json.Value,
    datasets: *std.StringHashMapUnmanaged([]const Value),
    show: u32,
) !u8 {
    _ = io;

    var by_file: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    var skipped: u32 = 0;
    var shown: u32 = 0;
    var total: Counts = .{};

    for (tests) |test_value| {
        const object = test_value.object;
        const file = if (object.get("filename")) |name| name.string else "?";

        if (skip(object, file, datasets)) {
            skipped += 1;
            continue;
        }

        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();

        const outcome = try check(scratch.allocator(), object, datasets);
        const entry = try by_file.getOrPut(arena, file);

        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }

        if (outcome.passed) {
            entry.value_ptr.passed += 1;
            total.passed += 1;
            continue;
        }

        entry.value_ptr.failed += 1;
        total.failed += 1;

        if (shown < show) {
            shown += 1;
            std.debug.print("FAIL {s} | {s}\n  query: {s}\n  {s}\n", .{
                file,
                if (object.get("name")) |name| name.string else "",
                object.get("query").?.string,
                outcome.detail,
            });
        }
    }

    var files = by_file.iterator();

    while (files.next()) |entry| {
        if (entry.value_ptr.failed > 0) {
            std.debug.print("{d:>5} / {d:<5} {s}\n", .{
                entry.value_ptr.passed,
                entry.value_ptr.passed + entry.value_ptr.failed,
                entry.key_ptr.*,
            });
        }
    }

    std.debug.print("groq suite: {d} passed, {d} failed, {d} skipped\n", .{
        total.passed,
        total.failed,
        skipped,
    });

    return if (total.failed == 0) 0 else 1;
}

/// A dataset of one document per line, in `_id` order.
fn load_ndjson(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const Value {
    std.debug.assert(path.len <= 1 << 30);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30));
    var documents: std.ArrayList(Value) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});

        try documents.append(arena, try groq.values.from_json(arena, parsed));
    }

    std.mem.sort(Value, documents.items, {}, by_id);

    return documents.items;
}

fn by_id(_: void, left: Value, right: Value) bool {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    const left_id = groq.evaluation.attribute_of(left, "_id");
    const right_id = groq.evaluation.attribute_of(right, "_id");

    if (left_id != .string or right_id != .string) {
        return left_id == .string;
    }

    return std.mem.order(u8, left_id.string, right_id.string) == .lt;
}

/// The vendor functions (`path()`, `identity()`) and the Portable Text extension (`pt::`)
/// are not supported, on purpose.
fn uses_vendor_function(query: []const u8) bool {
    return std.mem.indexOf(u8, query, "path(") != null or
        std.mem.indexOf(u8, query, "identity(") != null or
        std.mem.indexOf(u8, query, "pt::") != null;
}

fn skip(
    object: std.json.ObjectMap,
    file: []const u8,
    datasets: *std.StringHashMapUnmanaged([]const Value),
) bool {
    if (object.get("features")) |features| {
        if (features == .array) {
            for (features.array.items) |feature| {
                for (skipped_features) |name| {
                    if (std.mem.eql(u8, feature.string, name)) {
                        return true;
                    }
                }
            }
        }
    }

    if (uses_vendor_function(object.get("query").?.string)) {
        return true;
    }

    for (skipped_files) |name| {
        if (std.mem.eql(u8, file, name)) {
            return true;
        }
    }

    if (object.get("version")) |version| {
        if (version == .string and std.mem.startsWith(u8, version.string, "0.")) {
            return true;
        }
    }

    const reference = (object.get("dataset") orelse return false).object.get("_ref").?.string;

    return !datasets.contains(reference);
}

const Outcome = struct { passed: bool, detail: []const u8 = "" };

fn check(
    arena: std.mem.Allocator,
    object: std.json.ObjectMap,
    datasets: *std.StringHashMapUnmanaged([]const Value),
) !Outcome {
    const query = object.get("query").?.string;
    const valid = if (object.get("valid")) |given| given.bool else true;
    const reference = object.get("dataset").?.object.get("_ref").?.string;
    var memory: groq.Memory = .{ .documents = datasets.get(reference).? };
    var params: Value = .{ .object = .{} };

    if (object.get("params")) |given| {
        if (given == .object) {
            params = try groq.values.from_json(arena, given);
        }
    }

    var problem: groq.Problem = .{};
    const result = groq.execute(arena, query, memory.dataset(), .{
        .params = params.object,
        .now = .{ .seconds = 1_700_000_000 },
    }, &problem);

    if (!valid) {
        if (result) |got| {
            const shown = try groq.values.to_json(arena, got.value);
            const detail = try std.fmt.allocPrint(arena, "expected invalid, got {s}", .{shown});

            return .{ .passed = false, .detail = detail };
        } else |err| {
            return .{ .passed = err == error.Invalid };
        }
    }

    const answered = result catch |err| {
        const detail = try std.fmt.allocPrint(arena, "error {t}: {s} at {d}", .{
            err,
            problem.message,
            problem.at,
        });

        return .{ .passed = false, .detail = detail };
    };
    // Through JSON, as a client sees it: a datetime, pair or range becomes its text.
    const written = try groq.values.to_json(arena, answered.value);
    const round_trip = try std.json.parseFromSliceLeaky(std.json.Value, arena, written, .{});
    const got = try groq.values.from_json(arena, round_trip);
    const expected = try groq.values.from_json(arena, object.get("result") orelse .null);
    const normalized = try normalize_scores(arena, got, expected);

    if (same(normalized, expected)) {
        return .{ .passed = true };
    }

    const detail = try std.fmt.allocPrint(arena, "expected {s}\n  got      {s}", .{
        try groq.values.to_json(arena, expected),
        try groq.values.to_json(arena, normalized),
    });

    return .{ .passed = false, .detail = detail };
}

/// The suite writes scores as `_pos`, each element's rank by score, 1 the highest, equal
/// scores the same rank: the same is made of `_score` here.
fn normalize_scores(arena: std.mem.Allocator, got: Value, expected: Value) !Value {
    std.debug.assert(got != .number or std.math.isFinite(got.number));

    if (got != .array or expected != .array or expected.array.len == 0) {
        return got;
    }

    const first = expected.array[0];

    if (first != .object or first.object.get("_pos") == null) {
        return got;
    }

    var scores: std.ArrayList(f64) = .empty;

    for (got.array) |item| {
        if (item == .object) {
            if (item.object.get("_score")) |held| {
                if (held == .number) {
                    try scores.append(arena, held.number);
                }
            }
        }
    }

    std.mem.sort(f64, scores.items, {}, std.sort.desc(f64));

    const items = try arena.alloc(Value, got.array.len);

    for (got.array, items) |item, *out| {
        out.* = item;

        if (item != .object) {
            continue;
        }

        var builder: groq.values.ObjectBuilder = .{};

        for (item.object.keys, item.object.values) |key, held| {
            if (std.mem.eql(u8, key, "_score") and held == .number) {
                try builder.put(arena, "_pos", .{ .number = rank(scores.items, held.number) });
            } else {
                try builder.put(arena, key, held);
            }
        }

        out.* = .{ .object = builder.object() };
    }

    return .{ .array = items };
}

fn rank(sorted: []const f64, score: f64) f64 {
    std.debug.assert(sorted.len <= 1 << 30);

    var distinct: f64 = 0;
    var previous: ?f64 = null;

    for (sorted) |each| {
        if (previous == null or previous.? != each) {
            distinct += 1;
            previous = each;
        }

        if (each == score) {
            return distinct;
        }
    }

    return distinct + 1;
}

fn same(left: Value, right: Value) bool {
    std.debug.assert(left != .number or std.math.isFinite(left.number));

    if (std.meta.activeTag(left) != std.meta.activeTag(right)) {
        return false;
    }

    return switch (left) {
        .null => true,
        .boolean => |truth| truth == right.boolean,
        .number => |number| number == right.number or
            @abs(number - right.number) <= 1e-9 * @max(@abs(number), @abs(right.number)),
        .string => |text| std.mem.eql(u8, text, right.string),
        .array => |items| same_arrays(items, right.array),
        .object => |object| same_objects(object, right.object),
        else => false,
    };
}

fn same_arrays(left: []const Value, right: []const Value) bool {
    std.debug.assert(left.len <= 1 << 30);

    if (left.len != right.len) {
        return false;
    }

    for (left, right) |left_item, right_item| {
        if (!same(left_item, right_item)) {
            return false;
        }
    }

    return true;
}

/// The same keys with the same values, in any order.
fn same_objects(left: groq.values.Object, right: groq.values.Object) bool {
    std.debug.assert(left.keys.len == left.values.len);

    if (left.keys.len != right.keys.len) {
        return false;
    }

    for (left.keys, left.values) |key, held| {
        const other = right.get(key) orelse return false;

        if (!same(held, other)) {
            return false;
        }
    }

    return true;
}
