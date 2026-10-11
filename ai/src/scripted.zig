const std = @import("std");
const scripts = @This();
const message = @import("message.zig");
const interface = @import("provider.zig");
const loop = @import("loop.zig");

/// A provider that answers from a script, in order: for tests, and for checking a whole
/// turn with no network and no key. Past the script's end it is unavailable.
pub const Scripted = struct {
    responses: []const message.Response,
    /// How many requests it has answered.
    answered: u32 = 0,
    /// The last request it was given, for a test to inspect.
    last: ?message.Request = null,

    pub fn provider(scripted: *scripts.Scripted) interface.Provider {
        std.debug.assert(scripted.answered <= scripted.responses.len);

        return .{
            .context = scripted,
            .complete_fn = complete,
        };
    }

    fn complete(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: message.Request,
    ) interface.Error!message.Response {
        const scripted: *scripts.Scripted = @ptrCast(@alignCast(context));

        std.debug.assert(request.messages.len > 0);
        _ = arena;

        if (scripted.answered >= scripted.responses.len) {
            return error.Unavailable;
        }

        scripted.last = request;
        scripted.answered += 1;

        return scripted.responses[scripted.answered - 1];
    }
};

const Recorder = struct {
    said: u32 = 0,
    ran: u32 = 0,
    stop_after: u32 = std.math.maxInt(u32),

    fn observer(recorder: *Recorder) loop.Observer {
        return .{
            .context = recorder,
            .step_fn = step,
            .stopped_fn = stopped,
        };
    }

    fn step(context: *anyopaque, happened: loop.Step) anyerror!void {
        const recorder: *Recorder = @ptrCast(@alignCast(context));

        switch (happened) {
            .said => recorder.said += 1,
            .ran => recorder.ran += 1,
        }
    }

    fn stopped(context: *anyopaque) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));

        return recorder.said >= recorder.stop_after;
    }
};

const Echo = struct {
    fn tools(echo: *Echo) loop.Tools {
        return .{
            .context = echo,
            .definitions = &.{},
            .run_fn = run,
        };
    }

    fn run(context: *anyopaque, arena: std.mem.Allocator, call: message.Part) anyerror!loop.Answer {
        _ = context;
        _ = arena;

        if (std.mem.eql(u8, call.name.?, "broken")) {
            return error.ToolBroke;
        }

        if (std.mem.eql(u8, call.name.?, "remove")) {
            return .{
                .output = "listed",
                .pause = true,
            };
        }

        if (std.mem.eql(u8, call.name.?, "shot")) {
            return .{
                .output = "taken",
                .images = &.{.{
                    .media_type = "image/jpeg",
                    .data = "AA==",
                }},
            };
        }

        return .{
            .output = "done",
        };
    }
};

const call_run: message.Part = .{
    .kind = .tool_call,
    .id = "c1",
    .name = "run",
};
const call_broken: message.Part = .{
    .kind = .tool_call,
    .id = "c2",
    .name = "broken",
};
const asked = [_]message.Message{.{
    .role = .user,
    .parts = &.{message.Part.of_text("Build it")},
}};

test "a turn runs the calls the model asks for and ends with its words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var scripted: scripts.Scripted = .{
        .responses = &.{
            .{
                .parts = &.{ call_run, call_broken },
                .stop = .tool_calls,
                .usage = .{
                    .input_tokens = 5,
                },
            },
            .{
                .parts = &.{message.Part.of_text("Built.")},
                .stop = .end,
                .usage = .{
                    .input_tokens = 7,
                },
            },
        },
    };
    var recorder: Recorder = .{};
    var echo: Echo = .{};

    const outcome = try loop.run(arena_state.allocator(), scripted.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
    });

    try std.testing.expectEqual(loop.End.finished, outcome.end);
    try std.testing.expectEqualStrings("Built.", outcome.text);
    try std.testing.expectEqual(@as(u64, 12), outcome.usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 2), recorder.said);
    try std.testing.expectEqual(@as(u32, 2), recorder.ran);
    // The person's message, the calls, their answers, the last words.
    try std.testing.expectEqual(@as(usize, 4), outcome.messages.len);
    const answers = outcome.messages[2].parts;
    try std.testing.expect(!answers[0].failed);
    try std.testing.expect(answers[1].failed);
    try std.testing.expectEqualStrings("ToolBroke", answers[1].output.?);
    // The model saw the answers to its calls.
    try std.testing.expectEqual(@as(usize, 3), scripted.last.?.messages.len);
}

test "a reply cut off at the length limit is carried on from, its partial call dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var scripted: scripts.Scripted = .{
        .responses = &.{
            .{
                .parts = &.{ message.Part.of_text("Writing the page."), call_run },
                .stop = .length,
            },
            .{
                .parts = &.{message.Part.of_text("Done.")},
                .stop = .end,
            },
        },
    };
    var recorder: Recorder = .{};
    var echo: Echo = .{};

    const outcome = try loop.run(arena_state.allocator(), scripted.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
    });

    try std.testing.expectEqual(loop.End.finished, outcome.end);
    try std.testing.expectEqual(@as(u32, 0), recorder.ran);
    // The model was told it was cut off, and its half-written call was never run.
    const told = scripted.last.?.messages;
    try std.testing.expectEqual(message.Role.user, told[told.len - 1].role);
    try std.testing.expectEqual(@as(usize, 1), told[told.len - 2].parts.len);
}

test "a tool's pictures follow its result, trimmed to half all at once when too many" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const call_shot: message.Part = .{
        .kind = .tool_call,
        .id = "s",
        .name = "shot",
    };
    const shooting: message.Response = .{
        .parts = &.{call_shot},
        .stop = .tool_calls,
    };
    var scripted: scripts.Scripted = .{
        .responses = &.{
            shooting, shooting, shooting,
            .{
                .parts = &.{message.Part.of_text("Seen.")},
                .stop = .end,
            },
        },
    };
    var recorder: Recorder = .{};
    var echo: Echo = .{};

    const outcome = try loop.run(arena_state.allocator(), scripted.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
        .images_max = 2,
    });

    try std.testing.expectEqual(loop.End.finished, outcome.end);

    const sent = scripted.last.?.messages;
    var images: u32 = 0;
    var named: u32 = 0;

    for (sent) |said| {
        for (said.parts) |part| {
            images += @intFromBool(part.kind == .image);
            named += @intFromBool(part.kind == .text and std.mem.startsWith(u8, part.text.?, "(a picture"));
        }
    }

    // Three pictures over a limit of two: the history is cut to one, the oldest two each
    // a line, so the next requests start the same until it fills again.
    try std.testing.expectEqual(@as(u32, 1), images);
    try std.testing.expectEqual(@as(u32, 2), named);
    try std.testing.expectEqual(message.PartKind.text, outcome.messages[2].parts[1].kind);
}

test "a provider that takes no pictures is sent a line in each one's place" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const call_shot: message.Part = .{
        .kind = .tool_call,
        .id = "s",
        .name = "shot",
    };
    var scripted: scripts.Scripted = .{
        .responses = &.{
            .{
                .parts = &.{call_shot},
                .stop = .tool_calls,
            },
            .{
                .parts = &.{message.Part.of_text("Read it.")},
                .stop = .end,
            },
        },
    };
    var recorder: Recorder = .{};
    var echo: Echo = .{};

    _ = try loop.run(arena_state.allocator(), scripted.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
        .images_max = 0,
    });

    const tool_message = scripted.last.?.messages[2];

    try std.testing.expectEqual(message.PartKind.text, tool_message.parts[1].kind);
}

test "a turn pauses for the person once a step's calls are answered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const call_remove: message.Part = .{
        .kind = .tool_call,
        .id = "x",
        .name = "remove",
    };
    var scripted: scripts.Scripted = .{
        .responses = &.{
            .{
                .parts = &.{ call_remove, call_run },
                .stop = .tool_calls,
            },
            .{
                .parts = &.{message.Part.of_text("Never asked.")},
                .stop = .end,
            },
        },
    };
    var recorder: Recorder = .{};
    var echo: Echo = .{};

    const outcome = try loop.run(arena_state.allocator(), scripted.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
    });

    try std.testing.expectEqual(loop.End.paused, outcome.end);
    // Both calls of the step ran; the model was not asked again.
    try std.testing.expectEqual(@as(u32, 2), recorder.ran);
    try std.testing.expectEqual(@as(u32, 1), scripted.answered);
}

test "a turn is stopped between steps, and bounded by its steps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const again: message.Response = .{
        .parts = &.{call_run},
        .stop = .tool_calls,
    };
    var echo: Echo = .{};

    var stopping: scripts.Scripted = .{
        .responses = &.{ again, again, again },
    };
    var stopper: Recorder = .{
        .stop_after = 1,
    };
    const stopped = try loop.run(arena, stopping.provider(), echo.tools(), stopper.observer(), .{
        .messages = &asked,
    });
    try std.testing.expectEqual(loop.End.stopped, stopped.end);
    try std.testing.expectEqual(@as(u32, 1), stopping.answered);

    var looping: scripts.Scripted = .{
        .responses = &.{ again, again, again },
    };
    var recorder: Recorder = .{};
    const bounded = try loop.run(arena, looping.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
        .steps_max = 2,
    });
    try std.testing.expectEqual(loop.End.steps_exhausted, bounded.end);

    var empty: scripts.Scripted = .{
        .responses = &.{},
    };
    try std.testing.expectError(error.Unavailable, loop.run(arena, empty.provider(), echo.tools(), recorder.observer(), .{
        .messages = &asked,
    }));
}
