const std = @import("std");
const contract = @This();

/// Who said a message: the person or the program asking, the model, or a tool answering
/// the model's calls.
pub const Role = enum { user, assistant, tool };

pub const PartKind = enum { text, tool_call, tool_result, image };

/// A picture the model looks at: a screenshot, or one the person attached.
pub const Image = struct {
    /// `image/jpeg`, `image/png`, `image/webp` or `image/gif`.
    media_type: []const u8,
    /// The image's bytes, base64.
    data: []const u8,
};

/// One piece of a message. Flat, so its JSON is plain: `{"kind":"text","text":"Hi"}`,
/// `{"kind":"tool_call","id":"c1","name":"run","input":{...}}`,
/// `{"kind":"tool_result","id":"c1","output":"...","failed":false}`,
/// `{"kind":"image","media_type":"image/jpeg","data":"<base64>"}`. In a tool message, the
/// images follow the results and belong to the one before them.
pub const Part = struct {
    kind: contract.PartKind,
    /// `text`: the words.
    text: ?[]const u8 = null,
    /// `tool_call` and `tool_result`: the call's id, which the result answers.
    id: ?[]const u8 = null,
    /// `tool_call`: the tool's name.
    name: ?[]const u8 = null,
    /// `tool_call`: the arguments, as JSON the tool's schema describes.
    input: ?std.json.Value = null,
    /// `tool_result`: what the tool answered, as text.
    output: ?[]const u8 = null,
    /// `tool_result`: whether the call failed; the model sees the output either way.
    failed: bool = false,
    /// `image`: its type, as `Image.media_type`.
    media_type: ?[]const u8 = null,
    /// `image`: its bytes, base64.
    data: ?[]const u8 = null,

    pub fn of_text(text: []const u8) contract.Part {
        std.debug.assert(text.len <= contract.text_bytes_max);

        return .{
            .kind = .text,
            .text = text,
        };
    }

    pub fn of_image(image: contract.Image) contract.Part {
        std.debug.assert(std.mem.startsWith(u8, image.media_type, "image/"));
        std.debug.assert(image.data.len > 0 and image.data.len <= contract.text_bytes_max);

        return .{
            .kind = .image,
            .media_type = image.media_type,
            .data = image.data,
        };
    }

    pub fn of_result(id: []const u8, output: []const u8, failed: bool) contract.Part {
        std.debug.assert(id.len > 0);
        std.debug.assert(output.len <= contract.text_bytes_max);

        return .{
            .kind = .tool_result,
            .id = id,
            .output = output,
            .failed = failed,
        };
    }
};

pub const Message = struct {
    role: contract.Role,
    parts: []const contract.Part,
};

/// A tool the model may call: its name, what it does, and its input as a JSON Schema.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
};

/// One call to a model: everything it sees this time.
pub const Request = struct {
    /// The model's id as its provider names it; empty for the provider's default.
    model: []const u8 = "",
    /// Standing instructions, apart from the conversation.
    system: []const u8 = "",
    messages: []const contract.Message,
    tools: []const contract.Tool = &.{},
    output_tokens_max: u32 = 4096,
    /// How hard the model should think: `low`, `medium` or `high`; empty for its default.
    /// A provider without such a setting ignores it.
    effort: []const u8 = "",
};

/// Why the model stopped: it finished, it wants its tool calls answered, it ran out of
/// room, or it declined.
pub const Stop = enum { end, tool_calls, length, refused };

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    /// Of `input_tokens`, how many the provider read from its cache, at a fraction of the
    /// price; 0 when it does not say.
    cached_tokens: u64 = 0,
};

/// What a model answered: the assistant's parts, why it stopped, what it cost.
pub const Response = struct {
    parts: []const contract.Part,
    stop: contract.Stop,
    usage: contract.Usage = .{},
};

pub const text_bytes_max: u32 = 1 << 20;

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
    .max_value_len = contract.text_bytes_max,
};

const write_options: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
};

/// A request as JSON: what core hands a provider, across the sandbox when it is one.
pub fn request_json(arena: std.mem.Allocator, request: contract.Request) ![]const u8 {
    std.debug.assert(request.messages.len > 0);
    std.debug.assert(request.output_tokens_max > 0);

    return std.json.Stringify.valueAlloc(arena, request, write_options);
}

pub fn request_of(arena: std.mem.Allocator, json: []const u8) !contract.Request {
    std.debug.assert(json.len > 0);

    const request = try std.json.parseFromSliceLeaky(contract.Request, arena, json, parse_options);

    if (request.messages.len == 0 or request.output_tokens_max == 0) {
        return error.InvalidRequest;
    }

    return request;
}

/// A response as JSON: what a provider hands back.
pub fn response_json(arena: std.mem.Allocator, response: contract.Response) ![]const u8 {
    std.debug.assert(response.parts.len > 0 or response.stop != .tool_calls);

    return std.json.Stringify.valueAlloc(arena, response, write_options);
}

pub fn response_of(arena: std.mem.Allocator, json: []const u8) !contract.Response {
    std.debug.assert(json.len > 0);

    const response = try std.json.parseFromSliceLeaky(contract.Response, arena, json, parse_options);

    if (response.stop == .tool_calls and contract.calls_in(response.parts) == 0) {
        return error.InvalidResponse;
    }

    for (response.parts) |part| {
        const named = part.id != null and part.name != null and part.id.?.len > 0;

        if (part.kind == .tool_call and !named) {
            return error.InvalidResponse;
        }
    }

    return response;
}

/// `text` as valid UTF-8: as it is when it already is, else with each byte that cannot be
/// read replaced by U+FFFD. A page in another encoding, or one cut mid-character, must not
/// reach a request, which is written as JSON.
pub fn valid_text(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    if (std.unicode.utf8ValidateSlice(text)) {
        return text;
    }

    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;

    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        const whole = length > 0 and index + length <= text.len and
            std.unicode.utf8ValidateSlice(text[index .. index + length]);

        if (whole) {
            try out.appendSlice(arena, text[index .. index + length]);
            index += length;
        } else {
            try out.appendSlice(arena, "\u{FFFD}");
            index += 1;
        }
    }

    std.debug.assert(std.unicode.utf8ValidateSlice(out.items));

    return out.items;
}

/// How many tool calls the parts hold.
pub fn calls_in(parts: []const contract.Part) u32 {
    std.debug.assert(parts.len <= std.math.maxInt(u32));

    var count: u32 = 0;

    for (parts) |part| {
        if (part.kind == .tool_call) {
            count += 1;
        }
    }

    return count;
}

test "a request and a response go to JSON and back unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const asked = [_]contract.Message{.{
        .role = .user,
        .parts = &.{contract.Part.of_text("Add a recipes section")},
    }};
    const json = try contract.request_json(arena, .{
        .system = "Be brief.",
        .messages = &asked,
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\"") == null);

    const back = try contract.request_of(arena, json);
    try std.testing.expectEqualStrings("Be brief.", back.system);
    try std.testing.expectEqualStrings("Add a recipes section", back.messages[0].parts[0].text.?);

    const answer =
        \\{"parts":[{"kind":"tool_call","id":"c1","name":"run","input":{"args":["--help"]}}],
        \\ "stop":"tool_calls","usage":{"input_tokens":12,"output_tokens":3}}
    ;
    const response = try contract.response_of(arena, answer);
    try std.testing.expectEqual(contract.Stop.tool_calls, response.stop);
    try std.testing.expectEqual(@as(u32, 1), contract.calls_in(response.parts));
    try std.testing.expectEqual(@as(u64, 12), response.usage.input_tokens);
}

test "an image goes to JSON and back as its type and its bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = contract.Part.of_image(.{
        .media_type = "image/png",
        .data = "iVBORw0KGgo=",
    });
    const asked = [_]contract.Message{.{
        .role = .user,
        .parts = &.{image},
    }};
    const json = try contract.request_json(arena, .{
        .messages = &asked,
    });
    const back = try contract.request_of(arena, json);

    try std.testing.expectEqual(contract.PartKind.image, back.messages[0].parts[0].kind);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", back.messages[0].parts[0].data.?);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\"") == null);
}

test "text that is not UTF-8 is made so, and valid text is left alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("zażółć", try contract.valid_text(arena, "zażółć"));
    // Cut in the middle of "ć", and a Windows-1250 "ł".
    try std.testing.expectEqualStrings("za\u{FFFD}", try contract.valid_text(arena, "za\xc4"));
    try std.testing.expectEqualStrings("\u{FFFD}ad", try contract.valid_text(arena, "\xb3ad"));
}

test "a response that stops for tool calls without any is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const empty = "{\"parts\":[{\"kind\":\"text\",\"text\":\"hm\"}],\"stop\":\"tool_calls\"}";
    try std.testing.expectError(error.InvalidResponse, contract.response_of(arena_state.allocator(), empty));
    try std.testing.expectError(error.SyntaxError, contract.response_of(arena_state.allocator(), "{]"));
}
