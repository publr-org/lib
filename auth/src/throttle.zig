//! Sign-in throttling: a fixed table of subjects (an email, an address) and how
//! often each has failed, with growing delays after the free attempts. No clock of
//! its own — the caller passes `now_ms` — and no allocation: the table is an array
//! in the struct, and a full table evicts the least recently touched subject.
const std = @import("std");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

const delays_ms = [_]i64{ 60_000, 300_000, 900_000, 3_600_000 };

/// The table. Embed one per process (`State` does) and zero-initialize it.
///
/// The sign-in shape, in full:
///
/// ```zig
/// const key = state.throttle.key_for(email);
///
/// if (state.throttle.wait_ms(key, now_ms) > 0) {
///     return error.Throttled;
/// }
///
/// if (!state.verify_password(stored_hash, plain, io)) {
///     _ = state.throttle.record_failure(key, now_ms);
///     return error.BadCredentials;
/// }
///
/// state.throttle.record_success(key);
/// ```
pub const Throttle = struct {
    /// Subjects the table tracks at once. One more and the least recently
    /// touched subject that is not currently blocked is forgotten — a reset,
    /// never a lockout. A blocked subject is never evicted, so flooding the
    /// table with junk subjects cannot lift a delay; when every slot is
    /// blocked, a new subject is refused until the soonest delay ends.
    pub const slots_max: u32 = 1024;
    /// Failures a subject gets before the first delay.
    pub const failures_free: u8 = 4;
    /// The failure count saturates here; the delay is already at its longest.
    pub const failures_max: u8 = 255;
    /// Length of `secret`, the key `key_for` hashes subjects under.
    pub const secret_len: u32 = 32;

    /// The key `key_for` hashes subjects under, so two subjects collide only by
    /// chance, never by an attacker's choice. `State` shares its CSRF secret here.
    secret: [secret_len]u8 = undefined,

    slots: [slots_max]Slot = @splat(.{}),

    /// One tracked subject.
    pub const Slot = struct {
        /// The subject's key, from `key_for`; 0 marks a free slot.
        key: u64 = 0,
        /// Consecutive failures since the last success.
        failures: u8 = 0,
        /// Until when attempts are refused; 0 when they are not.
        blocked_until_ms: i64 = 0,
        /// When the slot was last used, for eviction.
        touched_ms: i64 = 0,
    };

    /// A table key for a subject: the subject HMAC'd under this table's `secret`,
    /// so two subjects collide only by chance, never by an attacker's design. The
    /// result is never 0.
    ///
    /// ```zig
    /// const key = state.throttle.key_for(email);
    /// ```
    pub fn key_for(throttle: *const Throttle, subject: []const u8) u64 {
        std.debug.assert(subject.len > 0);

        var mac: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&mac, subject, &throttle.secret);
        const hashed = std.mem.readInt(u64, mac[0..8], .big);

        return if (hashed == 0) 1 else hashed;
    }

    /// How long the subject must still wait before an attempt is allowed: 0 when
    /// it may try now. Check it before verifying a password, so a blocked
    /// subject costs no hashing.
    pub fn wait_ms(throttle: *const Throttle, key: u64, now_ms: i64) i64 {
        std.debug.assert(key != 0);
        std.debug.assert(now_ms >= 0);

        const slot = throttle.find(key) orelse return 0;

        if (slot.blocked_until_ms <= now_ms) {
            return 0;
        }

        return slot.blocked_until_ms - now_ms;
    }

    /// Counts one failed attempt and returns the delay it earned: 0 while the
    /// subject is within `failures_free`, then a minute, five, fifteen, an hour.
    pub fn record_failure(throttle: *Throttle, key: u64, now_ms: i64) i64 {
        std.debug.assert(key != 0);
        std.debug.assert(now_ms >= 0);

        const slot = throttle.claim(key, now_ms) orelse return throttle.soonest_release_ms(now_ms);

        if (slot.failures < failures_max) {
            slot.failures += 1;
        }

        slot.touched_ms = now_ms;

        if (slot.failures <= failures_free) {
            return 0;
        }

        const step: u32 = @min(slot.failures - failures_free - 1, delays_ms.len - 1);
        slot.blocked_until_ms = now_ms + delays_ms[step];

        std.debug.assert(slot.blocked_until_ms > now_ms);

        return delays_ms[step];
    }

    /// Forgets the subject: a successful sign-in clears its failures and any delay.
    pub fn record_success(throttle: *Throttle, key: u64) void {
        std.debug.assert(key != 0);
        std.debug.assert(throttle.slots.len == slots_max);

        if (throttle.find_mut(key)) |slot| {
            slot.* = .{};
        }
    }

    fn find(throttle: *const Throttle, key: u64) ?*const Slot {
        std.debug.assert(key != 0);
        std.debug.assert(throttle.slots.len == slots_max);

        for (&throttle.slots) |*slot| {
            if (slot.key == key) {
                return slot;
            }
        }

        return null;
    }

    fn find_mut(throttle: *Throttle, key: u64) ?*Slot {
        std.debug.assert(key != 0);
        std.debug.assert(throttle.slots.len == slots_max);

        for (&throttle.slots) |*slot| {
            if (slot.key == key) {
                return slot;
            }
        }

        return null;
    }

    /// The subject's slot, claiming one when it has none: a free slot, else
    /// the least recently touched slot that is not blocked. Null when every
    /// slot is blocked — the table is full of subjects still serving a delay,
    /// and none of them may be forgotten to make room.
    fn claim(throttle: *Throttle, key: u64, now_ms: i64) ?*Slot {
        std.debug.assert(key != 0);

        if (throttle.find_mut(key)) |slot| {
            return slot;
        }

        var victim: ?*Slot = null;

        for (&throttle.slots) |*slot| {
            if (slot.key == 0) {
                victim = slot;
                break;
            }
            if (slot.blocked_until_ms > now_ms) {
                continue;
            }
            if (victim == null or slot.touched_ms < victim.?.touched_ms) {
                victim = slot;
            }
        }

        const slot = victim orelse return null;

        std.debug.assert(slot.key == 0 or slot.touched_ms <= now_ms);

        slot.* = .{ .key = key, .touched_ms = now_ms };

        return slot;
    }

    /// How long until the first blocked slot frees — the delay a subject gets
    /// when the table has no room for it. Only called when every slot is
    /// blocked, so the result is always positive.
    fn soonest_release_ms(throttle: *const Throttle, now_ms: i64) i64 {
        var soonest: i64 = std.math.maxInt(i64);

        for (&throttle.slots) |*slot| {
            std.debug.assert(slot.blocked_until_ms > now_ms);
            soonest = @min(soonest, slot.blocked_until_ms);
        }

        std.debug.assert(soonest > now_ms);

        return soonest - now_ms;
    }
};

test "a blocked subject survives a flood of new subjects; a full table refuses" {
    var throttle: Throttle = .{};
    throttle.secret = @splat(9);
    const victim = throttle.key_for("victim@example.com");

    var index: u32 = 0;
    var delay: i64 = 0;
    while (index <= Throttle.failures_free) : (index += 1) {
        delay = throttle.record_failure(victim, 1000);
    }
    try std.testing.expect(delay > 0);

    // More junk subjects than the table holds, all touched later than the victim.
    var junk: u32 = 0;
    while (junk < Throttle.slots_max * 2) : (junk += 1) {
        var name: [24]u8 = undefined;
        const subject = std.fmt.bufPrint(&name, "junk{d}", .{junk}) catch unreachable;
        _ = throttle.record_failure(throttle.key_for(subject), 2000);
    }

    try std.testing.expectEqual(delay - 1000, throttle.wait_ms(victim, 2000));

    // Block every slot, then a new subject is refused for as long as the soonest block.
    for (&throttle.slots) |*slot| {
        slot.* = .{ .key = 1, .failures = Throttle.failures_free + 1, .blocked_until_ms = 5000, .touched_ms = 3000 };
    }
    try std.testing.expectEqual(@as(i64, 2000), throttle.record_failure(throttle.key_for("late"), 3000));
    try std.testing.expectEqual(@as(i64, 0), throttle.wait_ms(throttle.key_for("late"), 3000));
}

test "first four failures are free, then delays grow and a success clears" {
    var throttle: Throttle = .{};
    throttle.secret = @splat(7);
    const key = throttle.key_for("a@example.com");

    var index: u32 = 0;

    while (index < Throttle.failures_free) : (index += 1) {
        try std.testing.expectEqual(@as(i64, 0), throttle.record_failure(key, 1000));
        try std.testing.expectEqual(@as(i64, 0), throttle.wait_ms(key, 1000));
    }

    try std.testing.expectEqual(@as(i64, 60_000), throttle.record_failure(key, 1000));
    try std.testing.expectEqual(@as(i64, 60_000), throttle.wait_ms(key, 1000));
    try std.testing.expectEqual(@as(i64, 0), throttle.wait_ms(key, 61_000));
    try std.testing.expectEqual(@as(i64, 300_000), throttle.record_failure(key, 61_000));
    try std.testing.expectEqual(@as(i64, 900_000), throttle.record_failure(key, 61_000));
    try std.testing.expectEqual(@as(i64, 3_600_000), throttle.record_failure(key, 61_000));
    try std.testing.expectEqual(@as(i64, 3_600_000), throttle.record_failure(key, 61_000));

    throttle.record_success(key);
    try std.testing.expectEqual(@as(i64, 0), throttle.wait_ms(key, 61_000));
    try std.testing.expectEqual(@as(i64, 0), throttle.record_failure(key, 61_000));
}

test "key_for is keyed: deterministic per secret, different across secrets" {
    var a: Throttle = .{};
    var b: Throttle = .{};
    a.secret = @splat(7);
    b.secret = @splat(8);

    const subject = "a@example.com";
    try std.testing.expectEqual(a.key_for(subject), a.key_for(subject));
    try std.testing.expect(a.key_for(subject) != b.key_for(subject));
    try std.testing.expect(a.key_for(subject) != 0);
}

test "table is bounded: the least recently touched slot is evicted" {
    var throttle: Throttle = .{};

    var index: u64 = 1;

    while (index <= Throttle.slots_max) : (index += 1) {
        _ = throttle.record_failure(index, @intCast(index));
    }

    _ = throttle.record_failure(Throttle.slots_max + 1, Throttle.slots_max + 1);

    try std.testing.expect(throttle.find(1) == null);
    try std.testing.expect(throttle.find(2) != null);
    try std.testing.expect(throttle.find(Throttle.slots_max + 1) != null);
}
