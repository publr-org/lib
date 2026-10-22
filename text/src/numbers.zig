//! Numbers from text the way JS reads them: `parseInt` and `parseFloat`. Where JS answers
//! `NaN`, these answer null.

const std = @import("std");
const whitespace = @import("whitespace.zig");

/// The whole number `text` starts with, after white space and a sign. `radix` 2 to 36, or 0
/// for JS's default: 16 after `0x`, else 10. Null when no digit is read, or the number
/// does not fit an `i64` (JS would answer an approximate float). JS's `parseInt`.
pub fn parse_int(text: []const u8, radix: u8) ?i64 {
    if (radix == 1 or radix > 36) {
        return null;
    }

    var rest = whitespace.trim_start(text);
    const negative = rest.len > 0 and rest[0] == '-';

    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
        rest = rest[1..];
    }

    var base: u8 = if (radix == 0) 10 else radix;
    const hex_prefix = rest.len >= 2 and rest[0] == '0' and (rest[1] | 0x20) == 'x';

    if (hex_prefix and (radix == 0 or radix == 16)) {
        rest = rest[2..];
        base = 16;
    }

    var value: i64 = 0;
    var digits: u32 = 0;

    for (rest) |byte| {
        const digit = std.fmt.charToDigit(byte, base) catch break;
        const scaled = std.math.mul(i64, value, base) catch return null;

        const added = if (negative)
            std.math.sub(i64, scaled, digit)
        else
            std.math.add(i64, scaled, digit);

        value = added catch return null;
        digits += 1;
    }

    std.debug.assert(base >= 2 and base <= 36);

    return if (digits == 0) null else value;
}

/// The decimal number `text` starts with, after white space: `"3.5kg"` is 3.5, `"Infinity"`
/// is infinity. JS's `parseFloat`.
pub fn parse_float(text: []const u8) ?f64 {
    const rest = whitespace.trim_start(text);
    const len = decimal_prefix(rest);

    if (len == 0) {
        return null;
    }

    std.debug.assert(len <= rest.len);

    return read_decimal(rest[0..len]);
}

/// How many bytes at the start of `text` are a StrDecimalLiteral: a sign, then `Infinity`
/// or digits with an optional fraction and exponent.
fn decimal_prefix(text: []const u8) u32 {
    var cursor: u32 = 0;

    if (cursor < text.len and (text[cursor] == '+' or text[cursor] == '-')) {
        cursor += 1;
    }

    if (std.mem.startsWith(u8, text[cursor..], "Infinity")) {
        return cursor + 8;
    }

    const whole = digits_at(text, cursor);
    var end = cursor + whole;
    var fraction: u32 = 0;

    if (end < text.len and text[end] == '.') {
        fraction = digits_at(text, end + 1);

        if (whole > 0 or fraction > 0) {
            end += 1 + fraction;
        }
    }

    if (whole == 0 and fraction == 0) {
        return 0;
    }

    if (end < text.len and (text[end] | 0x20) == 'e') {
        var exponent_at = end + 1;

        if (exponent_at < text.len and (text[exponent_at] == '+' or text[exponent_at] == '-')) {
            exponent_at += 1;
        }

        const exponent = digits_at(text, exponent_at);

        if (exponent > 0) {
            end = exponent_at + exponent;
        }
    }

    std.debug.assert(end <= text.len);

    return end;
}

fn digits_at(text: []const u8, start: u32) u32 {
    var cursor = start;

    while (cursor < text.len and std.ascii.isDigit(text[cursor])) {
        cursor += 1;
    }

    return cursor - start;
}

fn read_decimal(literal: []const u8) f64 {
    std.debug.assert(literal.len > 0);

    const negative = literal[0] == '-';
    const unsigned = if (literal[0] == '-' or literal[0] == '+') literal[1..] else literal;

    if (std.mem.eql(u8, unsigned, "Infinity")) {
        return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    }

    const value = std.fmt.parseFloat(f64, literal) catch unreachable;

    return value;
}

test "parse_int reads like JS" {
    try std.testing.expectEqual(@as(?i64, 42), parse_int("  42px", 0));
    try std.testing.expectEqual(@as(?i64, -255), parse_int("-0xFF", 0));
    try std.testing.expectEqual(@as(?i64, 255), parse_int("ff", 16));
    try std.testing.expectEqual(@as(?i64, 0), parse_int("0x", 10));
    try std.testing.expectEqual(@as(?i64, 5), parse_int("101", 2));
    try std.testing.expectEqual(@as(?i64, null), parse_int("px", 0));
    try std.testing.expectEqual(@as(?i64, null), parse_int("1", 37));
    try std.testing.expectEqual(@as(?i64, null), parse_int("99999999999999999999", 10));
    const smallest = parse_int("-9223372036854775808", 10);

    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), smallest);
}

test "parse_float" {
    try std.testing.expectEqual(@as(?f64, 3.5), parse_float(" 3.5kg"));
    try std.testing.expectEqual(@as(?f64, 0.5), parse_float(".5"));
    try std.testing.expectEqual(@as(?f64, 1e3), parse_float("1e3e"));
    try std.testing.expectEqual(@as(?f64, 1), parse_float("1e"));
    try std.testing.expectEqual(@as(?f64, -std.math.inf(f64)), parse_float("-Infinityx"));
    try std.testing.expectEqual(@as(?f64, null), parse_float("."));
    try std.testing.expectEqual(@as(?f64, null), parse_float("inf"));
}
