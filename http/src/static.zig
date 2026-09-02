//! Static file serving: map a URL path onto a folder and serve the file, from any
//! handler. The route stays comptime like every other route — only the folder is
//! runtime data — so a file endpoint is one wildcard route calling `serve_file`.
//!
//! The whole of it:
//!
//! ```zig
//! router.get("/static/*", &assets);
//!
//! fn assets(req: *http.Request, res: *http.Response, ctx: *App.Context) !void {
//!     switch (try http.static.serve_file(
//!         "public",
//!         req.path()["/static".len..],
//!         res,
//!         ctx.arena,
//!         ctx.options.response_bytes_max,
//!     )) {
//!         .served => {},
//!         .not_found => try res.text(.not_found, "Not Found"),
//!         .too_large => try res.text(.internal_server_error, "file exceeds response cap"),
//!     }
//! }
//! ```
//!
//! Scope, deliberately: a file must fit the response cap (`--response-bytes-max`, the
//! same contract every response lives under — no streaming), URL paths are taken
//! literally (no percent-decoding), and dot-segments never resolve — `..`, `.`, and
//! dotfiles (`.git`, `.env`) all report `.not_found`. A path ending in `/` (and the
//! root itself) serves that directory's `index.html`. Only regular files are served
//! (a directory, FIFO, socket, or device under root is `.not_found`), served
//! responses carry `X-Content-Type-Options: nosniff`, and a symlink in any path
//! component — final or intermediate — is refused (`.not_found`), so nothing in the
//! served tree can point the response outside the root.
//!
//! SVG is scriptable in a document context, so it is served with
//! `Content-Disposition: attachment` — downloaded, never rendered inline — so a
//! stored `.svg` can never be a stored-XSS primitive even if the served tree ever
//! holds untrusted content.
const std = @import("std");
const socket = @import("platform/socket.zig");
const response_module = @import("http/response.zig");

const Response = response_module.Response;

/// Longest filesystem path `resolve` will produce (root plus URL path).
const path_len_max: u32 = 512;

/// Bytes reserved out of the response cap for the status line and headers, so a file
/// that fits the cap also fits the slot's write buffer once framed.
const headers_reserved: u32 = 512;

/// The outcome of `serve_file`. Only `.served` has filled the response; the caller
/// owns what a miss looks like (404 page, fallback route, SPA index).
pub const Serve = enum {
    /// The response holds the file: status 200, Content-Type by extension,
    /// `X-Content-Type-Options: nosniff`, and — for SVG, which scripts in a
    /// document context — `Content-Disposition: attachment`.
    served,
    /// No regular file there — also the answer for traversal, dotfiles, a
    /// directory without `index.html`, or a final-component symlink. The
    /// response is untouched.
    not_found,
    /// The file exists but would not fit under `bytes_max` once framed. The
    /// response is untouched.
    too_large,
};

/// Reads the file `url_path` names under `root` into the request arena and sets it as
/// the response body with a Content-Type derived from the extension. `bytes_max` is
/// the response cap (`ctx.options.response_bytes_max`); a file bigger than the
/// cap minus header room reports `.too_large` rather than a doomed oversized response.
///
/// Fails only as `Response.set_body`/`set_header` do, or with `error.OutOfMemory`
/// when the arena cannot hold a buffer of `bytes_max` — both 500s from a handler.
pub fn serve_file(
    root: []const u8,
    url_path: []const u8,
    res: *Response,
    arena: std.mem.Allocator,
    bytes_max: u32,
) Response.Error!Serve {
    std.debug.assert(root.len > 0);
    std.debug.assert(bytes_max > headers_reserved);

    var path_buffer: [path_len_max]u8 = undefined;
    const rel = resolve(url_path, &path_buffer) orelse return .not_found;

    const fd = socket.open_under(root, rel) orelse return .not_found;
    defer socket.close(fd);

    const cap = bytes_max - headers_reserved;
    const buffer = arena.alloc(u8, cap) catch return error.OutOfMemory;

    switch (socket.read_file(fd, buffer)) {
        .len => |len| {
            try res.set_body(.ok, content_type(rel), buffer[0..len]);
            // Pin the declared type: never let a browser sniff a served asset
            // into something executable (a .js-sniffed .txt, say).
            try res.set_header("X-Content-Type-Options", "nosniff");
            // SVG scripts in a document context; force a download so a stored
            // file can never be an XSS primitive.
            if (is_svg(rel)) {
                try res.set_header("Content-Disposition", "attachment");
            }
            return .served;
        },
        .not_found => return .not_found,
        .too_large => return .too_large,
    }
}

/// Maps `url_path` onto a `/`-separated, root-relative path, or null when the path is
/// unsafe or too long. Segments are taken literally (no percent-decoding); any segment
/// starting with '.' (traversal, hidden files) or containing '\' or NUL refuses to
/// resolve. A trailing '/' (including the bare root "/") resolves to `index.html`. The
/// result carries no leading '/'; the caller opens it under the root with
/// `socket.open_under`, which also refuses any symlink in any component.
fn resolve(url_path: []const u8, buffer: *[path_len_max]u8) ?[]const u8 {
    if (url_path.len == 0 or url_path[0] != '/') {
        return null;
    }

    var len: u32 = 0;
    var segments = std.mem.splitScalar(u8, url_path[1..], '/');

    while (segments.next()) |segment| {
        if (segment.len == 0) {
            continue;
        }

        if (segment[0] == '.') {
            return null;
        }

        if (std.mem.indexOfAny(u8, segment, "\\\x00") != null) {
            return null;
        }

        if (len + 1 + segment.len > buffer.len) {
            return null;
        }

        if (len > 0) {
            buffer[len] = '/';
            len += 1;
        }
        @memcpy(buffer[len..][0..segment.len], segment);
        len += @intCast(segment.len);
    }

    if (url_path[url_path.len - 1] == '/') {
        const index = "index.html";
        const separator: u32 = if (len > 0) 1 else 0;

        if (len + separator + index.len > buffer.len) {
            return null;
        }

        if (separator > 0) {
            buffer[len] = '/';
            len += 1;
        }
        @memcpy(buffer[len..][0..index.len], index);
        len += index.len;
    }

    return buffer[0..len];
}

/// The Content-Type for a file path, by extension; unknown extensions are served as
/// application/octet-stream so browsers download rather than guess. `serve_file`
/// uses it; a handler serving an `@embedFile`d asset with `Response.set_body` uses
/// it to name the type by the file's name.
pub fn content_type(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return fallback_type;
    const extension = path[dot + 1 ..];

    for (types) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.extension, extension)) {
            return entry.mime;
        }
    }

    return fallback_type;
}

/// Whether a path ends in an `.svg` extension, case-insensitively — the files
/// served as an attachment rather than inline.
fn is_svg(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;

    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], "svg");
}

const fallback_type = "application/octet-stream";

const types = [_]struct { extension: []const u8, mime: []const u8 }{
    .{ .extension = "html", .mime = "text/html; charset=utf-8" },
    .{ .extension = "htm", .mime = "text/html; charset=utf-8" },
    .{ .extension = "css", .mime = "text/css; charset=utf-8" },
    .{ .extension = "js", .mime = "text/javascript; charset=utf-8" },
    .{ .extension = "mjs", .mime = "text/javascript; charset=utf-8" },
    .{ .extension = "json", .mime = "application/json" },
    .{ .extension = "map", .mime = "application/json" },
    .{ .extension = "txt", .mime = "text/plain; charset=utf-8" },
    .{ .extension = "xml", .mime = "application/xml" },
    .{ .extension = "svg", .mime = "image/svg+xml" },
    .{ .extension = "png", .mime = "image/png" },
    .{ .extension = "jpg", .mime = "image/jpeg" },
    .{ .extension = "jpeg", .mime = "image/jpeg" },
    .{ .extension = "gif", .mime = "image/gif" },
    .{ .extension = "webp", .mime = "image/webp" },
    .{ .extension = "avif", .mime = "image/avif" },
    .{ .extension = "ico", .mime = "image/x-icon" },
    .{ .extension = "woff2", .mime = "font/woff2" },
    .{ .extension = "woff", .mime = "font/woff" },
    .{ .extension = "ttf", .mime = "font/ttf" },
    .{ .extension = "otf", .mime = "font/otf" },
    .{ .extension = "pdf", .mime = "application/pdf" },
    .{ .extension = "wasm", .mime = "application/wasm" },
    .{ .extension = "mp3", .mime = "audio/mpeg" },
    .{ .extension = "mp4", .mime = "video/mp4" },
    .{ .extension = "webm", .mime = "video/webm" },
};

test "resolve maps safe paths and refuses traversal, dotfiles, and separators" {
    var buffer: [path_len_max]u8 = undefined;

    try std.testing.expectEqualStrings("a.css", resolve("/a.css", &buffer).?);
    try std.testing.expectEqualStrings("sub/b.js", resolve("/sub/b.js", &buffer).?);
    try std.testing.expectEqualStrings("index.html", resolve("/", &buffer).?);
    try std.testing.expectEqualStrings("sub/index.html", resolve("/sub/", &buffer).?);
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("/../secret", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("/a/../b", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("/.git/config", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("/.env", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("/a\\b", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("no-slash", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve("", &buffer));
}

test "resolve collapses duplicate slashes instead of producing empty segments" {
    var buffer: [path_len_max]u8 = undefined;

    try std.testing.expectEqualStrings("a/b", resolve("//a//b", &buffer).?);
}

test "resolve refuses paths that overflow the buffer" {
    var buffer: [path_len_max]u8 = undefined;
    const long = "/x" ** (path_len_max / 2 + 2);

    try std.testing.expectEqual(@as(?[]const u8, null), resolve(long, &buffer));
}

test "content_type maps known extensions and falls back for the rest" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", content_type("a/index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", content_type("app.CSS"));
    try std.testing.expectEqualStrings("image/png", content_type("logo.png"));
    try std.testing.expectEqualStrings("application/wasm", content_type("mod.wasm"));
    try std.testing.expectEqualStrings(fallback_type, content_type("archive.tar.zst"));
    try std.testing.expectEqualStrings(fallback_type, content_type("no-extension"));
}

test "svg is detected by extension, case-insensitively, and not a false match" {
    try std.testing.expect(is_svg("assets/logo.svg"));
    try std.testing.expect(is_svg("drawing.SVG"));
    try std.testing.expect(!is_svg("assets/logo.png"));
    try std.testing.expect(!is_svg("assets/svg"));
}
