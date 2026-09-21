//! The response statuses this server can produce. A deliberate subset of the registry:
//! add a status here when a handler needs it, not speculatively.
const std = @import("std");

/// The statuses a response can carry, as an enum so a handler writes `.not_found`
/// and a typo is a compile error. The ones the engine itself sends — without any
/// handler involved — are marked; the rest exist for handlers to use.
pub const Status = enum(u16) {
    /// The default of a fresh `Response`.
    ok = 200,
    /// A POST made something; conventionally with a `Location` header.
    created = 201,
    /// Done, nothing to say — a DELETE, or a PUT that changed nothing visible.
    no_content = 204,
    /// A bounded byte range of a static media file.
    partial_content = 206,
    /// Permanent redirect; clients may cache it. Use with `redirect`.
    moved_permanently = 301,
    /// Temporary redirect, same method. Use with `redirect`.
    found = 302,
    /// Redirect after a POST so the browser GETs the result. Use with `redirect`.
    see_other = 303,
    /// The client's cached copy is current; send no body.
    not_modified = 304,
    /// Engine: a malformed request (see `request.Error.BadRequest`).
    bad_request = 400,
    /// No or bad credentials.
    unauthorized = 401,
    /// Credentials are fine; this action is not allowed for them.
    forbidden = 403,
    /// Engine: the router's default for an unmatched path.
    not_found = 404,
    /// The path exists but not for this method. The router does not send this
    /// itself — an unmatched method is a 404 — so it is the handler's to use.
    method_not_allowed = 405,
    /// The request collides with current state — a duplicate slug, a stale
    /// version. The usual mapping for a database constraint violation.
    conflict = 409,
    /// The request needs a `Content-Length` it did not send.
    length_required = 411,
    /// Engine: a declared body larger than `Options.request_bytes_max`.
    payload_too_large = 413,
    /// Engine: a request line over `request.request_line_bytes_max`.
    uri_too_long = 414,
    /// The body's `Content-Type` is not one the handler accepts.
    unsupported_media_type = 415,
    /// No requested byte range overlaps the resource.
    range_not_satisfiable = 416,
    /// The body parsed but fails validation.
    unprocessable_content = 422,
    /// The conventional answer when a WebSocket route gets a plain request.
    upgrade_required = 426,
    /// The client is over its rate limit; conventionally with `Retry-After`.
    too_many_requests = 429,
    /// Engine: a head over `request.head_bytes_max`, or one with too many or
    /// too-long headers.
    header_fields_too_large = 431,
    /// Engine: a handler returned an error, or its response did not fit the
    /// write buffer. Always with a generic body; the cause stays in the log.
    internal_server_error = 500,
    /// Engine: an unknown method, or `Transfer-Encoding`.
    not_implemented = 501,
    /// Engine: every connection slot is busy. Sent with `Retry-After: 1` and
    /// the connection closed.
    service_unavailable = 503,
    /// Engine: a version other than HTTP/1.0 or 1.1.
    http_version_not_supported = 505,

    /// The numeric code, for logging and comparisons.
    pub fn code(status: Status) u16 {
        return @intFromEnum(status);
    }
};

/// The reason phrase that follows the code on the status line; the response
/// writer's, not a consumer's.
pub fn reason(status: Status) []const u8 {
    std.debug.assert(status.code() >= 200);
    std.debug.assert(status.code() < 600);

    return switch (status) {
        .ok => "OK",
        .created => "Created",
        .no_content => "No Content",
        .partial_content => "Partial Content",
        .moved_permanently => "Moved Permanently",
        .found => "Found",
        .see_other => "See Other",
        .not_modified => "Not Modified",
        .bad_request => "Bad Request",
        .unauthorized => "Unauthorized",
        .forbidden => "Forbidden",
        .not_found => "Not Found",
        .method_not_allowed => "Method Not Allowed",
        .conflict => "Conflict",
        .length_required => "Length Required",
        .payload_too_large => "Payload Too Large",
        .uri_too_long => "URI Too Long",
        .unsupported_media_type => "Unsupported Media Type",
        .range_not_satisfiable => "Range Not Satisfiable",
        .unprocessable_content => "Unprocessable Content",
        .upgrade_required => "Upgrade Required",
        .too_many_requests => "Too Many Requests",
        .header_fields_too_large => "Request Header Fields Too Large",
        .internal_server_error => "Internal Server Error",
        .not_implemented => "Not Implemented",
        .service_unavailable => "Service Unavailable",
        .http_version_not_supported => "HTTP Version Not Supported",
    };
}

/// True for 4xx and 5xx — what the engine asserts before closing a connection
/// on a refused request.
pub fn is_error(status: Status) bool {
    return status.code() >= 400;
}

test "codes and reasons" {
    try std.testing.expectEqual(@as(u16, 404), Status.not_found.code());
    try std.testing.expectEqualStrings("Not Found", reason(.not_found));
    try std.testing.expect(is_error(.internal_server_error));
    try std.testing.expect(!is_error(.ok));
}
