//! GROQ datetimes (GROQ-1.revision5, "Datetime"): a point in time in UTC, read from RFC 3339
//! text, written back without fractional digits when it has none and with three otherwise,
//! moved by a number of seconds, subtracted to a number of seconds.

const std = @import("std");

pub const Datetime = struct {
    /// Seconds since 1970-01-01T00:00:00Z.
    seconds: i64,
    nanoseconds: u32 = 0,
};

/// `2006-01-02T15:04:05Z`, `2006-01-02t15:04:05.123+02:00`; null when it is not one, or
/// names a date or time that does not exist.
pub fn parse(text: []const u8) ?Datetime {
    std.debug.assert(text.len <= 1 << 30);

    if (text.len < 20) {
        return null;
    }

    const year = digits_of(text[0..4]) orelse return null;
    const month = digits_of(text[5..7]) orelse return null;
    const day = digits_of(text[8..10]) orelse return null;
    const hour = digits_of(text[11..13]) orelse return null;
    const minute = digits_of(text[14..16]) orelse return null;
    const second = digits_of(text[17..19]) orelse return null;
    const separators = text[4] == '-' and text[7] == '-' and text[13] == ':' and text[16] == ':';
    const t_letter = text[10] == 'T' or text[10] == 't';

    if (!separators or !t_letter) {
        return null;
    }

    if (month < 1 or month > 12 or day < 1 or day > days_in(year, month)) {
        return null;
    }

    if (hour > 23 or minute > 59 or second > 60) {
        return null;
    }

    var at: u32 = 19;
    var nanoseconds: u32 = 0;

    if (text[at] == '.') {
        at += 1;

        var places: u32 = 0;

        while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {
            if (places < 9) {
                nanoseconds = nanoseconds * 10 + (text[at] - '0');
                places += 1;
            }
        }

        if (places == 0) {
            return null;
        }

        while (places < 9) : (places += 1) {
            nanoseconds *= 10;
        }
    }

    const offset = offset_of(text[at..]) orelse return null;
    const days = days_from_civil(year, month, day);
    const clock: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @min(second, 59);

    return .{ .seconds = days * 86400 + clock - offset, .nanoseconds = nanoseconds };
}

/// `Z` (or `z`) is 0; `+02:00` is 7200 seconds ahead of UTC.
fn offset_of(rest: []const u8) ?i64 {
    std.debug.assert(rest.len <= 64);

    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {
        return 0;
    }

    if (rest.len != 6 or rest[3] != ':' or (rest[0] != '+' and rest[0] != '-')) {
        return null;
    }

    const hours = digits_of(rest[1..3]) orelse return null;
    const minutes = digits_of(rest[4..6]) orelse return null;

    if (hours > 23 or minutes > 59) {
        return null;
    }

    const seconds: i64 = @as(i64, hours) * 3600 + @as(i64, minutes) * 60;

    return if (rest[0] == '-') -seconds else seconds;
}

fn digits_of(text: []const u8) ?u32 {
    std.debug.assert(text.len <= 1 << 30);

    var number: u32 = 0;

    for (text) |char| {
        if (!std.ascii.isDigit(char)) {
            return null;
        }

        number = number * 10 + (char - '0');
    }

    return number;
}

fn leap(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn days_in(year: u32, month: u32) u32 {
    std.debug.assert(month >= 1 and month <= 12);

    const lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    return if (month == 2 and leap(year)) 29 else lengths[month - 1];
}

/// Days since 1970-01-01 of a date in the proleptic Gregorian calendar.
fn days_from_civil(year_in: u32, month: u32, day: u32) i64 {
    std.debug.assert(month >= 1 and month <= 12);

    const year: i64 = @as(i64, year_in) - @as(i64, @intFromBool(month <= 2));
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) +
        day_of_year;

    return era * 146097 + day_of_era - 719468;
}

const Civil = struct { year: i64, month: u32, day: u32 };

fn civil_from_days(days_since: i64) Civil {
    std.debug.assert(@abs(days_since) < 4_000_000);

    const days = days_since + 719468;
    const era = @divFloor(days, 146097);
    const day_of_era = days - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) +
        @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100));
    const shifted = @divFloor(5 * day_of_year + 2, 153);
    const day: u32 = @intCast(day_of_year - @divFloor(153 * shifted + 2, 5) + 1);
    const month: u32 = @intCast(if (shifted < 10) shifted + 3 else shifted - 9);
    const year = year_of_era + era * 400 + @as(i64, @intFromBool(month <= 2));

    return .{ .year = year, .month = month, .day = day };
}

/// RFC 3339 in UTC: no fraction when there is none, three digits when it is whole
/// milliseconds, nine otherwise.
pub fn format(buffer: *[40]u8, time: Datetime) []const u8 {
    const days = @divFloor(time.seconds, 86400);
    const clock: u32 = @intCast(time.seconds - days * 86400);
    const date = civil_from_days(days);
    const base = std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@max(date.year, 0))),
        date.month,
        date.day,
        clock / 3600,
        clock / 60 % 60,
        clock % 60,
    }) catch unreachable;
    var length: u32 = @intCast(base.len);

    if (time.nanoseconds != 0) {
        const millisecond_only = time.nanoseconds % 1_000_000 == 0;
        const fraction = if (millisecond_only)
            std.fmt.bufPrint(buffer[length..], ".{d:0>3}", .{time.nanoseconds / 1_000_000})
        else
            std.fmt.bufPrint(buffer[length..], ".{d:0>9}", .{time.nanoseconds});

        length += @intCast((fraction catch unreachable).len);
    }

    buffer[length] = 'Z';

    return buffer[0 .. length + 1];
}

pub fn compare(left: Datetime, right: Datetime) std.math.Order {
    std.debug.assert(left.nanoseconds < 1_000_000_000);

    const by_seconds = std.math.order(left.seconds, right.seconds);

    if (by_seconds != .eq) {
        return by_seconds;
    }

    return std.math.order(left.nanoseconds, right.nanoseconds);
}

/// The time moved by `seconds`, which may be fractional or negative.
pub fn add_seconds(time: Datetime, seconds: f64) ?Datetime {
    std.debug.assert(time.nanoseconds < 1_000_000_000);

    const total = @as(f64, @floatFromInt(time.seconds)) + seconds;

    if (!std.math.isFinite(total) or @abs(total) > 2.5e11) {
        return null;
    }

    const whole: i64 = @intFromFloat(@floor(seconds));
    const fraction_ns: i64 = @intFromFloat(@round((seconds - @floor(seconds)) * 1e9));
    var nanoseconds = @as(i64, time.nanoseconds) + fraction_ns;
    var moved = time.seconds + whole;

    if (nanoseconds >= 1_000_000_000) {
        nanoseconds -= 1_000_000_000;
        moved += 1;
    }

    return .{ .seconds = moved, .nanoseconds = @intCast(nanoseconds) };
}

/// `left - right` in seconds.
pub fn difference(left: Datetime, right: Datetime) f64 {
    std.debug.assert(left.nanoseconds < 1_000_000_000);

    const seconds: f64 = @floatFromInt(left.seconds - right.seconds);
    const nanoseconds: f64 = @as(f64, @floatFromInt(left.nanoseconds)) -
        @as(f64, @floatFromInt(right.nanoseconds));

    return seconds + nanoseconds / 1e9;
}

test "datetimes: offsets, fractions, invalid dates, arithmetic" {
    var buffer: [40]u8 = undefined;
    const plain = parse("2002-10-02T12:34:56Z").?;

    try std.testing.expectEqualStrings("2002-10-02T12:34:56Z", format(&buffer, plain));

    const offset = parse("2002-10-02T14:34:56.5+02:00").?;

    try std.testing.expectEqualStrings("2002-10-02T12:34:56.500Z", format(&buffer, offset));
    try std.testing.expect(parse("2002-02-30T00:00:00Z") == null);
    try std.testing.expect(parse("2002-10-02") == null);
    try std.testing.expectEqual(@as(f64, 0.5), difference(offset, plain));

    const later = add_seconds(plain, 86400 + 0.25).?;

    try std.testing.expectEqualStrings("2002-10-03T12:34:56.250Z", format(&buffer, later));
}
