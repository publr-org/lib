//! What talking to a language model needs and nothing about any one model: messages made
//! of text, tool calls and tool results; a request and a response with its usage and why
//! it stopped; the interface a provider implements and the description it registers with;
//! and the loop that runs a turn, answering the model's tool calls until it is done.
//! Pure Zig over `std.json`.
//!
//! ## A provider
//!
//! A provider turns a `Request` into a `Response`, however its model is reached. It
//! registers with a `Description`: its id and name, its models, and how its key looks.
//!
//! ```zig
//! const ai = @import("publr_ai");
//!
//! fn complete(context: *anyopaque, arena: Allocator, request: ai.Request) ai.Error!ai.Response {
//!     // Call the model; turn its answer into parts.
//! }
//!
//! const provider: ai.Provider = .{ .context = &state, .complete_fn = complete };
//! ```
//!
//! Across a boundary (a sandbox, a process), both travel as JSON: `request_json` and
//! `request_of`, `response_json` and `response_of`.
//!
//! ## A turn
//!
//! The loop asks the model, runs the tool calls it makes, hands back their answers, and
//! asks again until the model stops asking, the observer says stop, or `steps_max` is
//! reached. The observer hears each step as it lands.
//!
//! ```zig
//! const outcome = try ai.run(arena, provider, tools, observer, .{
//!     .system = "You build websites.",
//!     .messages = &.{.{ .role = .user, .parts = &.{ai.Part.of_text(prompt)} }},
//! });
//! ```
//!
//! `Scripted` is a provider that answers from a list, for tests.
const impl_message = @import("message.zig");
const impl_provider = @import("provider.zig");
const impl_loop = @import("loop.zig");
const impl_scripted = @import("scripted.zig");

pub const Role = impl_message.Role;
pub const PartKind = impl_message.PartKind;
/// One piece of a message: text, a tool call, a tool's answer, or a picture.
pub const Part = impl_message.Part;
/// A picture the model looks at, base64.
pub const Image = impl_message.Image;
/// Text made valid UTF-8, unreadable bytes replaced.
pub const valid_text = impl_message.valid_text;
pub const Message = impl_message.Message;
/// A tool the model may call, with its input as a JSON Schema.
pub const Tool = impl_message.Tool;
pub const Request = impl_message.Request;
pub const Response = impl_message.Response;
pub const Stop = impl_message.Stop;
pub const Usage = impl_message.Usage;
pub const text_bytes_max = impl_message.text_bytes_max;
pub const request_json = impl_message.request_json;
pub const request_of = impl_message.request_of;
pub const response_json = impl_message.response_json;
pub const response_of = impl_message.response_of;
pub const calls_in = impl_message.calls_in;

pub const Error = impl_provider.Error;
/// A model provider, as the loop calls it.
pub const Provider = impl_provider.Provider;
/// What a provider registers as.
pub const Description = impl_provider.Description;
pub const Model = impl_provider.Model;
/// How a provider's key is made and how one looks.
pub const Key = impl_provider.Key;

pub const run = impl_loop.run;
pub const Tools = impl_loop.Tools;
pub const Answer = impl_loop.Answer;
pub const Observer = impl_loop.Observer;
pub const Step = impl_loop.Step;
pub const Options = impl_loop.Options;
pub const End = impl_loop.End;
pub const Outcome = impl_loop.Outcome;

/// A provider that answers from a script, for tests.
pub const Scripted = impl_scripted.Scripted;

test {
    _ = impl_message;
    _ = impl_provider;
    _ = impl_loop;
    _ = impl_scripted;
}
