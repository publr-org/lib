//! The text helpers plugins need every day, as JS's `String` names them, without Unicode
//! tables: comparing, finding, trimming, slicing, splitting and replacing by plain text,
//! case for A to Z, numbers from text, URL encoding, and email and URL checks.
//!
//! Text is UTF-8 bytes. Positions and lengths count characters (code points), never bytes,
//! so no answer cuts a character in half. Where JS answers -1 or `NaN`, these answer null.
//! Functions that make new text take an allocator first and return memory the caller
//! frees; the rest return slices of their input.
//!
//! ```zig
//! const text = @import("publr_text");
//!
//! if (text.starts_with(name, "admin")) { … }
//! const email = try text.lower(allocator, text.trim(given)); // "ada@example.com"
//! ```
//!
//! JS names are spelled snake_case; `includes` is `contains`. Locale order, normalization,
//! case for every alphabet and patterns are left out: each needs megabytes of tables in
//! every plugin that uses it.

const std = @import("std");
const positions = @import("positions.zig");
const search = @import("search.zig");
const whitespace = @import("whitespace.zig");
const case = @import("case.zig");
const replacing = @import("replace.zig");
const numbers = @import("numbers.zig");
const uri = @import("uri.zig");
const addresses = @import("addresses.zig");

pub const length = positions.length;
pub const slice = positions.slice;

pub const equals = search.equals;
pub const equals_ignore_case = search.equals_ignore_case;
pub const contains = search.contains;
pub const starts_with = search.starts_with;
pub const ends_with = search.ends_with;
pub const index_of = search.index_of;
pub const last_index_of = search.last_index_of;
pub const is_empty = search.is_empty;

pub const trim = whitespace.trim;
pub const trim_start = whitespace.trim_start;
pub const trim_end = whitespace.trim_end;
pub const is_blank = whitespace.is_blank;

pub const lower = case.lower;
pub const upper = case.upper;

pub const split = replacing.split;
pub const replace = replacing.replace;
pub const replace_all = replacing.replace_all;

pub const parse_int = numbers.parse_int;
pub const parse_float = numbers.parse_float;

pub const encode_uri_component = uri.encode_uri_component;
pub const decode_uri_component = uri.decode_uri_component;

pub const is_email = addresses.is_email;
pub const is_url = addresses.is_url;

test "the root reads like JS" {
    const allocator = std.testing.allocator;
    const email = try lower(allocator, trim("  Ada@Example.com "));
    defer allocator.free(email);

    try std.testing.expectEqualStrings("ada@example.com", email);
    try std.testing.expect(is_email(email));
    try std.testing.expect(contains(trim("  gęś "), "ęś"));
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("utf8.zig");
    _ = positions;
    _ = search;
    _ = whitespace;
    _ = case;
    _ = replacing;
    _ = numbers;
    _ = uri;
    _ = addresses;
}
