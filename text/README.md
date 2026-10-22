# publr_text

The text helpers plugins need every day, named as JS's `String` names them, for Zig: no
Unicode tables, so a plugin that uses them stays small. Pure Zig over `std`.

```zig
const text = @import("publr_text");

if (text.starts_with(name, "admin")) { … }
const email = try text.lower(allocator, text.trim(given)); // "ada@example.com"
const parts = try text.split(allocator, "a, b, c", ", "); // a, b, c
```

Text is UTF-8 bytes. Positions and lengths count characters (code points), never bytes. A
malformed byte reads as one U+FFFD. Where JS answers -1 or `NaN`, these answer null. What
makes new text takes an allocator first; the rest return slices of their input.

## JS to publr_text

| JS | here |
|---|---|
| `===`, `length`, `slice` | `equals`, `length`, `slice` |
| `includes`, `startsWith`, `endsWith` | `contains`, `starts_with`, `ends_with` |
| `indexOf`, `lastIndexOf` | `index_of`, `last_index_of` |
| `trim`, `trimStart`, `trimEnd` | `trim`, `trim_start`, `trim_end` |
| `toLowerCase`, `toUpperCase` | `lower`, `upper` (A to Z only) |
| `split`, `replace`, `replaceAll` | `split`, `replace`, `replace_all` (by text) |
| `parseInt`, `parseFloat` | `parse_int`, `parse_float` |
| `encodeURIComponent`, `decodeURIComponent` | `encode_uri_component`, `decode_uri_component` |

And `equals_ignore_case` (A to Z), `is_empty`, `is_blank`, `is_email`, `is_url`.

## Where it differs from JS

- `lower`, `upper` and `equals_ignore_case` change only the plain Latin letters A to Z:
  `"Łódź"` lowers to `"Łódź"`. Enough for emails, slugs and codes.
- `split`, `replace` and `replace_all` take text, not patterns; `replace` has no `$`
  patterns.
- `is_url` accepts only `http` and `https` addresses; `is_email` follows the HTML
  standard's `<input type=email>`.
- `parse_int` answers null past `i64` where JS answers an approximate float.

## Left out

Locale order (`localeCompare`), `normalize`, case for every alphabet and patterns
(`match`, `search`, regular expressions). Each needs tables, up to hundreds of KB of
data, in every plugin that uses it, and no plugin needs them yet. The full version, with
Unicode 17 and CLDR 48 tables and a linear-time pattern engine, was built on 2026-10-20 and
set aside; if a plugin needs one, it comes back as a call into Publr so no plugin carries
the tables.

```bash
zig build test   # the tests, on the source tree and on the amalgamation
```
