const std = @import("std");
const providers = @This();
const message = @import("message.zig");

/// What a provider's call can come to besides an answer.
pub const Error = error{
    /// The provider could not be reached, or answered with a failure of its own.
    Unavailable,
    /// No key is set for the provider.
    KeyMissing,
    /// The provider refused the key.
    KeyRejected,
    /// The provider limited the call: too many, too often, or out of credit.
    Limited,
    /// The provider's answer was not one this contract can read.
    InvalidResponse,
    OutOfMemory,
};

/// A model provider, as the loop calls it: one request in, one response out.
pub const Provider = struct {
    context: *anyopaque,
    complete_fn: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: message.Request,
    ) providers.Error!message.Response,

    pub fn complete(provider: providers.Provider, arena: std.mem.Allocator, request: message.Request) providers.Error!message.Response {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(request.output_tokens_max > 0);

        return provider.complete_fn(provider.context, arena, request);
    }
};

pub const Model = struct {
    id: []const u8,
    label: []const u8,
};

/// How a person gets a key and how one looks, so a paste can be checked as it is typed.
pub const Key = struct {
    /// The name the key is kept under, as an environment variable would be:
    /// `EXAMPLE_API_KEY`.
    secret: []const u8,
    /// The page where a key is made.
    create_url: []const u8,
    /// What to do there, one short line each.
    steps: []const []const u8 = &.{},
    /// What every key starts with; empty when keys have no fixed start.
    prefix: []const u8 = "",
    length_min: u32 = 20,
    length_max: u32 = 512,

    /// Whether `value` could be a key: the right start, a plausible length, nothing but
    /// printable characters without spaces.
    pub fn looks_right(key: providers.Key, value: []const u8) bool {
        std.debug.assert(key.length_min <= key.length_max);
        std.debug.assert(key.create_url.len > 0);

        if (value.len < key.length_min or value.len > key.length_max) {
            return false;
        }

        if (!std.mem.startsWith(u8, value, key.prefix)) {
            return false;
        }

        for (value) |byte| {
            if (byte <= ' ' or byte >= 0x7f) {
                return false;
            }
        }

        return true;
    }
};

/// What a provider registers as: its id and name, the models it offers, and its key.
pub const Description = struct {
    /// Lowercase letters, digits and underscores: `example_ai`.
    id: []const u8,
    label: []const u8,
    models: []const providers.Model,
    /// One of `models`, used when none is chosen.
    default_model: []const u8,
    /// Absent for a provider that needs no key (a model on this machine).
    key: ?providers.Key = null,
    /// Whether its models look at pictures. One that does not, a provider written before
    /// pictures were, is sent a line in each one's place.
    pictures: bool = false,
    /// Whether it turns speech into text, through `<plugin>.transcribe`.
    speech: bool = false,

    pub fn valid(description: providers.Description) bool {
        std.debug.assert(description.id.len <= 64);
        std.debug.assert(description.models.len <= 256);

        if (description.id.len == 0 or description.label.len == 0) {
            return false;
        }

        for (description.id) |byte| {
            const allowed = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_';

            if (!allowed) {
                return false;
            }
        }

        for (description.models) |model| {
            if (std.mem.eql(u8, model.id, description.default_model)) {
                return true;
            }
        }

        return false;
    }
};

test "a key is checked by its start, length and characters" {
    const key: providers.Key = .{
        .secret = "EXAMPLE_API_KEY",
        .create_url = "https://example.com/keys",
        .prefix = "ex-",
        .length_min = 8,
    };

    try std.testing.expect(key.looks_right("ex-12345678"));
    try std.testing.expect(!key.looks_right("ex-123"));
    try std.testing.expect(!key.looks_right("zz-12345678"));
    try std.testing.expect(!key.looks_right("ex-1234 5678"));
}

test "a description names its default among its models" {
    const models = [_]providers.Model{.{
        .id = "small",
        .label = "Small",
    }};

    try std.testing.expect((providers.Description{
        .id = "example_ai",
        .label = "Example",
        .models = &models,
        .default_model = "small",
    }).valid());
    try std.testing.expect(!(providers.Description{
        .id = "Example",
        .label = "Example",
        .models = &models,
        .default_model = "small",
    }).valid());
    try std.testing.expect(!(providers.Description{
        .id = "example_ai",
        .label = "Example",
        .models = &models,
        .default_model = "large",
    }).valid());
}
