const std = @import("std");
const turn = @This();
const message = @import("message.zig");
const interface = @import("provider.zig");

/// What a tool answered: its output as text, whether the call failed, and any pictures
/// it took for the model to look at.
pub const Answer = struct {
    output: []const u8,
    failed: bool = false,
    images: []const message.Image = &.{},
    /// The turn waits for the person once this step's calls are answered: something only
    /// they may decide (a removal they confirm). The model is not asked again.
    pause: bool = false,
};

/// The tools the model may call, and how a call is turn.run.
pub const Tools = struct {
    context: *anyopaque,
    definitions: []const message.Tool,
    run_fn: *const fn (context: *anyopaque, arena: std.mem.Allocator, call: message.Part) anyerror!turn.Answer,
};

/// One thing that happened in a turn, as it happens.
pub const Step = union(enum) {
    /// The model answered: its text and the calls it asked for.
    said: message.Response,
    /// A tool ran: the call and its answer.
    ran: struct {
        call: message.Part,
        answer: turn.Answer,
    },
};

/// Told of each step as it lands, and asked between steps whether to go on.
pub const Observer = struct {
    context: *anyopaque,
    step_fn: *const fn (context: *anyopaque, step: turn.Step) anyerror!void,
    /// Asked when the model would end the turn: words for it to act on first (a check it
    /// skipped), or null to let it end. The observer decides how often it says something.
    finishing_fn: ?*const fn (context: *anyopaque) ?[]const u8 = null,
    stopped_fn: *const fn (context: *anyopaque) bool,
};

pub const Options = struct {
    model: []const u8 = "",
    system: []const u8 = "",
    /// The conversation so far, ending with the person's new message.
    messages: []const message.Message,
    /// Model calls in one turn, at most.
    steps_max: u32 = 32,
    output_tokens_max: u32 = 4096,
    /// Images sent with each call, at most: the newest. An older one is named, not sent,
    /// so a long turn of screenshots stays within what a request may carry. 0 for a
    /// provider that takes none.
    images_max: u32 = 6,
    /// How hard the model thinks this turn (`low`, `medium`, `high`); empty for its default.
    effort: []const u8 = "",
};

/// How a turn ended: the model finished, it ran out of steps or room, it declined, the
/// person stopped it, or it waits for the person to decide something.
pub const End = enum { finished, steps_exhausted, length, refused, stopped, paused };

pub const Outcome = struct {
    end: turn.End,
    /// The conversation with this turn's messages added.
    messages: []const message.Message,
    /// The model's last words.
    text: []const u8,
    usage: message.Usage,
    steps: u32,
};

/// Runs one turn: asks the model, runs the calls it makes, hands back their answers, and
/// asks again, until it stops asking or a bound is reached.
pub fn run(
    arena: std.mem.Allocator,
    provider: interface.Provider,
    tools: turn.Tools,
    observer: turn.Observer,
    options: turn.Options,
) !turn.Outcome {
    std.debug.assert(options.messages.len > 0);
    std.debug.assert(options.steps_max > 0);

    var messages: std.ArrayList(message.Message) = .empty;
    try messages.appendSlice(arena, options.messages);
    var usage: message.Usage = .{};
    var text: []const u8 = "";
    var steps: u32 = 0;
    var cut_off: u32 = 0;

    while (steps < options.steps_max) {
        if (observer.stopped_fn(observer.context)) {
            return outcome(.stopped, messages.items, text, usage, steps);
        }

        const response = try provider.complete(arena, .{
            .model = options.model,
            .system = options.system,
            .messages = try trimmed_images(arena, messages.items, options.images_max),
            .tools = tools.definitions,
            .output_tokens_max = options.output_tokens_max,
            .effort = options.effort,
        });
        steps += 1;
        usage.input_tokens += response.usage.input_tokens;
        usage.output_tokens += response.usage.output_tokens;
        usage.cached_tokens += response.usage.cached_tokens;
        text = last_text(response.parts) orelse text;

        // Cut off at the length limit: a call it was writing never finished. The words
        // stand; the model is told, and carries on, a few times at most.
        if (response.stop == .length and cut_off < cut_off_max) {
            cut_off += 1;
            const words = try words_of(arena, response.parts);

            try messages.append(arena, .{
                .role = .assistant,
                .parts = words,
            });
            try messages.append(arena, .{
                .role = .user,
                .parts = try arena.dupe(message.Part, &.{message.Part.of_text(carry_on)}),
            });
            try observer.step_fn(observer.context, .{
                .said = response,
            });
            continue;
        }

        cut_off = 0;
        try messages.append(arena, .{
            .role = .assistant,
            .parts = response.parts,
        });
        try observer.step_fn(observer.context, .{
            .said = response,
        });

        switch (response.stop) {
            .end => {
                const finishing = observer.finishing_fn orelse {
                    return outcome(.finished, messages.items, text, usage, steps);
                };
                const nudge = finishing(observer.context) orelse {
                    return outcome(.finished, messages.items, text, usage, steps);
                };

                try messages.append(arena, .{
                    .role = .user,
                    .parts = try arena.dupe(message.Part, &.{message.Part.of_text(nudge)}),
                });
                continue;
            },
            .length => return outcome(.length, messages.items, text, usage, steps),
            .refused => return outcome(.refused, messages.items, text, usage, steps),
            .tool_calls => {},
        }

        const answered = try answer_calls(arena, tools, observer, response.parts);
        try messages.append(arena, .{
            .role = .tool,
            .parts = answered.parts,
        });

        if (answered.pause) {
            return outcome(.paused, messages.items, "", usage, steps);
        }
    }

    return outcome(.steps_exhausted, messages.items, text, usage, steps);
}

/// A reply cut off at the length limit, carried on from, this many times in a row at most.
pub const cut_off_max: u32 = 3;

const carry_on = "Your last reply was cut off at the length limit, so a tool call you were " ++
    "writing never arrived. Carry on from there; write a long file in smaller parts.";

/// A reply's words, without the calls it was making: a cut-off reply's calls are partial.
fn words_of(arena: std.mem.Allocator, parts: []const message.Part) ![]const message.Part {
    std.debug.assert(parts.len <= std.math.maxInt(u32));

    var words: std.ArrayList(message.Part) = .empty;

    for (parts) |part| {
        if (part.kind == .text) {
            try words.append(arena, part);
        }
    }

    if (words.items.len == 0) {
        try words.append(arena, message.Part.of_text("..."));
    }

    return words.items;
}

fn outcome(
    end: turn.End,
    messages: []const message.Message,
    text: []const u8,
    usage: message.Usage,
    steps: u32,
) turn.Outcome {
    std.debug.assert(messages.len > 0);
    std.debug.assert(end != .finished or steps > 0);

    return .{
        .end = end,
        .messages = messages,
        .text = text,
        .usage = usage,
        .steps = steps,
    };
}

/// Runs every call among `parts`, in order. A tool that fails answers the model with why,
/// so it can try another way; only the observer's own failure ends the turn.
const Answered = struct {
    parts: []const message.Part,
    pause: bool,
};

fn answer_calls(
    arena: std.mem.Allocator,
    tools: turn.Tools,
    observer: turn.Observer,
    parts: []const message.Part,
) !Answered {
    std.debug.assert(message.calls_in(parts) > 0);
    std.debug.assert(tools.definitions.len > 0 or parts.len > 0);

    var results: std.ArrayList(message.Part) = .empty;
    var images: std.ArrayList(message.Part) = .empty;
    var pause = false;

    for (parts) |part| {
        if (part.kind != .tool_call) {
            continue;
        }

        std.debug.assert(part.id != null and part.name != null);

        const answer = tools.run_fn(tools.context, arena, part) catch |err| turn.Answer{
            .output = @errorName(err),
            .failed = true,
        };

        const sendable = try sendable_images(arena, answer.images);
        // A picture that cannot travel (empty, or larger than a part may be) is left out
        // and the model told so: one bad screenshot never ends a turn.
        const left_out = answer.images.len - sendable.len;
        const told = if (left_out == 0) answer.output else try std.fmt.allocPrint(
            arena,
            "{s}\n\n({d} picture(s) left out: empty or too large to send)",
            .{ answer.output, left_out },
        );
        const output = try message.valid_text(arena, told);
        const said: turn.Answer = .{
            .output = output,
            .failed = answer.failed,
            .images = sendable,
        };

        pause = pause or answer.pause;

        try observer.step_fn(observer.context, .{
            .ran = .{
                .call = part,
                .answer = said,
            },
        });
        try results.append(arena, message.Part.of_result(part.id.?, output, answer.failed));

        for (sendable) |image| {
            try images.append(arena, message.Part.of_image(image));
        }
    }

    try results.appendSlice(arena, images.items);

    return .{
        .parts = results.items,
        .pause = pause,
    };
}

/// The pictures a part can carry: not empty, within a part's size.
fn sendable_images(
    arena: std.mem.Allocator,
    images: []const message.Image,
) ![]const message.Image {
    std.debug.assert(message.text_bytes_max > 0);
    std.debug.assert(images.len <= std.math.maxInt(u32));

    var kept: std.ArrayList(message.Image) = .empty;

    for (images) |image| {
        if (image.data.len > 0 and image.data.len <= message.text_bytes_max) {
            try kept.append(arena, image);
        }
    }

    return kept.items;
}

const image_dropped = "(a picture, not sent with this request)";

/// Keeps the pictures a request carries within `images_max`, in the history itself: once
/// there are more, the oldest become a line of text until half are left. Every provider's
/// cache is a prefix match, so the history changes rarely and all at once, never one
/// picture per call; between trims each request starts as the last one did.
fn trimmed_images(
    arena: std.mem.Allocator,
    messages: []message.Message,
    images_max: u32,
) ![]const message.Message {
    std.debug.assert(messages.len > 0);

    var count: u32 = 0;

    for (messages) |said| {
        for (said.parts) |part| {
            count += @intFromBool(part.kind == .image);
        }
    }

    if (count <= images_max) {
        return messages;
    }

    var dropping = count - images_max / 2;

    for (messages) |*said| {
        if (dropping == 0) {
            break;
        }

        const holds = for (said.parts) |part| {
            if (part.kind == .image) break true;
        } else false;

        if (!holds) {
            continue;
        }

        const parts = try arena.dupe(message.Part, said.parts);

        for (parts) |*part| {
            if (part.kind == .image and dropping > 0) {
                part.* = message.Part.of_text(image_dropped);
                dropping -= 1;
            }
        }

        said.parts = parts;
    }

    std.debug.assert(dropping == 0);

    return messages;
}

fn last_text(parts: []const message.Part) ?[]const u8 {
    std.debug.assert(parts.len <= std.math.maxInt(u32));

    var found: ?[]const u8 = null;

    for (parts) |part| {
        if (part.kind == .text and part.text != null) {
            found = part.text;
        }
    }

    return found;
}

test "a picture that cannot travel is left out, the rest kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const too_large = try arena.alloc(u8, message.text_bytes_max + 1);
    @memset(too_large, 'A');

    const given = [_]message.Image{
        .{
            .media_type = "image/jpeg",
            .data = "",
        },
        .{
            .media_type = "image/jpeg",
            .data = too_large,
        },
        .{
            .media_type = "image/jpeg",
            .data = "/9j/",
        },
    };
    const kept = try sendable_images(arena, &given);

    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("/9j/", kept[0].data);
}
