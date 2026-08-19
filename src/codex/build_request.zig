const std = @import("std");

const image_attachments = @import("../core/images/image_attachments.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const tool_advertisement = @import("../core/tooling/tool_advertisement.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const BuildError = error{
    InvalidToolSchema,
};

pub const Options = struct {
    /// Cache key the backend uses to keep the prompt prefix warm across turns.
    session_id: ?[]const u8 = null,
    /// Reasoning items recorded from earlier turns, replayed before the tool
    /// call they preceded. Null disables replay.
    reasoning_replay: ?ReasoningReplay = null,
};

/// Looks up the encrypted reasoning that preceded a given tool call.
///
/// fx's history has no slot for provider reasoning, so it is kept on the side
/// and spliced back in here. Replaying it keeps the prompt cache warm and stops
/// the model re-deriving the same chain on every follow-up turn.
pub const ReasoningReplay = struct {
    context: ?*anyopaque = null,
    lookup_fn: *const fn (?*anyopaque, alloc: Allocator, call_id: []const u8) ?[]u8,

    /// The result is owned by the caller. See `codex.runtime.lookupReasoningAlloc`
    /// for why this cannot borrow from the store.
    pub fn lookupAlloc(self: ReasoningReplay, alloc: Allocator, call_id: []const u8) ?[]u8 {
        return self.lookup_fn(self.context, alloc, call_id);
    }
};

/// Strips the catalog namespace: `openai/gpt-5.6-terra` -> `gpt-5.6-terra`.
pub fn bareModelId(model: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, model, '/') orelse return model;
    return model[slash + 1 ..];
}

/// Serialises a model-neutral BuildRequest into a Codex Responses request.
///
/// Working straight from `BuildRequest` rather than from Gateway JSON keeps
/// this a single translation instead of two.
pub fn build(
    alloc: Allocator,
    request: stream_provider.BuildRequest,
    options: Options,
) ![]u8 {
    const tools_json = try mergedToolsJson(alloc, request);
    defer alloc.free(tools_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(bareModelId(request.model), .{}, writer);
    // `store:false` keeps transcripts off the backend, and is also what makes
    // encrypted reasoning available in the response.
    try writer.writeAll(",\"store\":false,\"stream\":true");
    try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    try writer.writeAll(",\"parallel_tool_calls\":true");

    try writer.writeAll(",\"instructions\":");
    try writeInstructions(alloc, writer, request.messages);

    try writer.writeAll(",\"input\":[");
    try writeInput(alloc, writer, request, options);
    try writer.writeByte(']');

    try writeTools(alloc, writer, tools_json);
    try writeToolChoice(writer, request);
    try writeReasoning(writer, request.provider_options);
    try writeText(alloc, writer, request.response_format);

    if (request.max_output_tokens) |value| {
        try writer.print(",\"max_output_tokens\":{d}", .{value});
    }
    if (options.session_id) |session_id| {
        if (session_id.len > 0) {
            try writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(session_id, .{}, writer);
        }
    }

    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn mergedToolsJson(alloc: Allocator, request: stream_provider.BuildRequest) ![]u8 {
    return tool_advertisement.buildGatewayToolsJsonWithSelectedDynamicSchemas(
        alloc,
        request.serialized_tools,
        request.selected_dynamic_tool_schemas,
    );
}

/// Leading system messages become `instructions`.
///
/// Only the leading run: fx appends a system directive mid-conversation for
/// pending permission review, and hoisting that would move it before the turn
/// it refers to.
fn writeInstructions(
    alloc: Allocator,
    writer: *std.Io.Writer,
    messages: []const types.ChatMessage,
) !void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);

    for (messages) |message| {
        if (message.role != .system) break;
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (joined.items.len > 0) try joined.appendSlice(alloc, "\n\n");
        try joined.appendSlice(alloc, content);
    }

    if (joined.items.len == 0) {
        try std.json.Stringify.value("You are a helpful assistant.", .{}, writer);
    } else {
        try std.json.Stringify.value(joined.items, .{}, writer);
    }
}

fn writeInput(
    alloc: Allocator,
    writer: *std.Io.Writer,
    request: stream_provider.BuildRequest,
    options: Options,
) !void {
    var wrote_any = false;
    var leading_system = true;

    for (request.messages, 0..) |message, index| {
        if (message.role == .system and leading_system) continue;
        leading_system = false;

        switch (message.role) {
            .system => {
                const content = message.content orelse continue;
                if (content.len == 0) continue;
                try comma(writer, &wrote_any);
                try writer.writeAll("{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":");
                try std.json.Stringify.value(content, .{}, writer);
                try writer.writeAll("}]}");
            },
            .user => try writeUserMessage(alloc, writer, &wrote_any, request, message, index),
            .assistant => try writeAssistantMessage(alloc, writer, &wrote_any, message, options),
            .tool => {
                try comma(writer, &wrote_any);
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"output\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeUserMessage(
    alloc: Allocator,
    writer: *std.Io.Writer,
    wrote_any: *bool,
    request: stream_provider.BuildRequest,
    message: types.ChatMessage,
    index: usize,
) !void {
    const verified = verifiedImagesFor(request, index);
    const has_text = if (message.content) |content| content.len > 0 else false;
    const has_images = verified != null or message.images.len > 0;
    if (!has_text and !has_images) return;

    try comma(writer, wrote_any);
    try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[");
    var wrote_part = false;

    if (has_text) {
        try comma(writer, &wrote_part);
        try writer.writeAll("{\"type\":\"input_text\",\"text\":");
        try std.json.Stringify.value(message.content.?, .{}, writer);
        try writer.writeByte('}');
    }

    if (verified) |snapshots| {
        for (snapshots) |snapshot| {
            try comma(writer, &wrote_part);
            try writeImagePart(writer, snapshot.media_type, snapshot.bytes);
        }
    } else {
        for (message.images) |image| {
            var snapshot = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch continue;
            defer snapshot.deinit(alloc);
            try comma(writer, &wrote_part);
            try writeImagePart(writer, snapshot.media_type, snapshot.bytes);
        }
    }

    try writer.writeAll("]}");
}

fn verifiedImagesFor(
    request: stream_provider.BuildRequest,
    index: usize,
) ?[]const image_attachments.VerifiedSnapshot {
    const images = request.verified_images orelse return null;
    // The verified set only ever replaces the final user message.
    if (index != request.messages.len - 1) return null;
    return images;
}

/// Codex takes images as data URLs rather than as separate media parts.
fn writeImagePart(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
    try writer.writeAll("{\"type\":\"input_image\",\"image_url\":\"data:");
    try writer.writeAll(media_type);
    try writer.writeAll(";base64,");
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}");
}

fn writeAssistantMessage(
    alloc: Allocator,
    writer: *std.Io.Writer,
    wrote_any: *bool,
    message: types.ChatMessage,
    options: Options,
) !void {
    if (message.content) |content| {
        if (content.len > 0) {
            try comma(writer, wrote_any);
            try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeAll("}]}");
        }
    }

    for (message.tool_calls) |call| {
        if (options.reasoning_replay) |replay| {
            if (replay.lookupAlloc(alloc, call.id)) |items_json| {
                defer alloc.free(items_json);
                // Already a JSON array of reasoning items; splice it in ahead of
                // the call it belongs to.
                const trimmed = std.mem.trim(u8, items_json, " \n\r\t");
                if (trimmed.len > 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \n\r\t");
                    if (inner.len > 0) {
                        try comma(writer, wrote_any);
                        try writer.writeAll(inner);
                    }
                }
            }
        }
        try comma(writer, wrote_any);
        try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
        try std.json.Stringify.value(call.id, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, writer);
        try writer.writeAll(",\"arguments\":");
        // Codex wants the arguments as a JSON *string*, not an object.
        try std.json.Stringify.value(
            if (call.arguments_json.len > 0) call.arguments_json else "{}",
            .{},
            writer,
        );
        try writer.writeByte('}');
    }
}

/// Rewrites fx's advertised tools into the Codex function-tool shape.
fn writeTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8) !void {
    const trimmed = std.mem.trim(u8, tools_json, " \n\r\t");
    if (trimmed.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch
        return BuildError.InvalidToolSchema;
    defer parsed.deinit();
    if (parsed.value != .array) return BuildError.InvalidToolSchema;
    if (parsed.value.array.items.len == 0) return;

    try writer.writeAll(",\"tools\":[");
    var wrote_any = false;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const name_value = tool.object.get("name") orelse continue;
        if (name_value != .string) continue;

        try comma(writer, &wrote_any);
        try writer.writeAll("{\"type\":\"function\",\"name\":");
        try std.json.Stringify.value(name_value.string, .{}, writer);
        try writer.writeAll(",\"description\":");
        const description = tool.object.get("description");
        if (description != null and description.? == .string) {
            try std.json.Stringify.value(description.?.string, .{}, writer);
        } else {
            try writer.writeAll("\"\"");
        }
        try writer.writeAll(",\"strict\":false,\"parameters\":");
        if (tool.object.get("inputSchema")) |schema| {
            try std.json.Stringify.value(schema, .{}, writer);
        } else {
            try writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeToolChoice(writer: *std.Io.Writer, request: stream_provider.BuildRequest) !void {
    // Vision-required turns must call the vision tool and nothing else.
    if (request.vision_mode == .required) {
        try writer.writeAll(",\"tool_choice\":{\"type\":\"function\",\"name\":\"vision\"}");
        return;
    }
    try writer.writeAll(switch (request.tool_choice) {
        .auto => ",\"tool_choice\":\"auto\"",
        .none => ",\"tool_choice\":\"none\"",
    });
}

fn writeReasoning(
    writer: *std.Io.Writer,
    options: model_capabilities.ResolvedProviderOptions,
) !void {
    const effort = options.reasoning orelse return;
    const label = effort.label();
    if (label.len == 0) return;
    try writer.writeAll(",\"reasoning\":{\"effort\":");
    // fx's "minimal" has no Codex equivalent; "low" is the nearest real tier.
    try std.json.Stringify.value(
        if (std.mem.eql(u8, label, "minimal")) "low" else label,
        .{},
        writer,
    );
    try writer.writeAll(",\"summary\":\"auto\"}");
}

fn writeText(
    alloc: Allocator,
    writer: *std.Io.Writer,
    response_format: ?stream_provider.StructuredResponseFormat,
) !void {
    const format = response_format orelse {
        try writer.writeAll(",\"text\":{\"verbosity\":\"low\"}");
        return;
    };

    var schema = std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{}) catch
        return BuildError.InvalidToolSchema;
    defer schema.deinit();

    try writer.writeAll(",\"text\":{\"verbosity\":\"low\",\"format\":{\"type\":\"json_schema\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"strict\":false,\"schema\":");
    try std.json.Stringify.value(schema.value, .{}, writer);
    try writer.writeAll("}}");
}

fn comma(writer: *std.Io.Writer, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    wrote_any.* = true;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildForTest(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    overrides: struct {
        tools_json: []const u8 = "[]",
        tool_choice: types.ToolChoice = .auto,
        provider_options: model_capabilities.ResolvedProviderOptions = .{},
        session_id: ?[]const u8 = null,
        max_output_tokens: ?u32 = null,
    },
) ![]u8 {
    return build(alloc, .{
        .model = "openai/gpt-5.6-terra",
        .serialized_tools = overrides.tools_json,
        .messages = messages,
        .tool_choice = overrides.tool_choice,
        .provider_options = overrides.provider_options,
        .max_output_tokens = overrides.max_output_tokens,
    }, .{ .session_id = overrides.session_id });
}

fn parseBody(alloc: Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, body, .{});
}

test "bareModelId strips the catalog namespace" {
    try testing.expectEqualStrings("gpt-5.6-terra", bareModelId("openai/gpt-5.6-terra"));
    try testing.expectEqualStrings("gpt-5.6-terra", bareModelId("gpt-5.6-terra"));
}

test "leading system messages become instructions" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "You are fx." },
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildForTest(alloc, &messages, .{});
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqualStrings("gpt-5.6-terra", root.get("model").?.string);
    try testing.expectEqualStrings("You are fx.", root.get("instructions").?.string);
    try testing.expectEqual(false, root.get("store").?.bool);
    try testing.expectEqual(true, root.get("stream").?.bool);

    const input = root.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 1), input.len);
    try testing.expectEqualStrings("user", input[0].object.get("role").?.string);
}

test "a trailing system message stays in place instead of being hoisted" {
    const alloc = testing.allocator;
    // fx appends this for pending permission review; hoisting it would move the
    // directive before the conversation it is about.
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "You are fx." },
        .{ .role = .user, .content = "hello" },
        .{ .role = .system, .content = "Tool call is pending review." },
    };
    const body = try buildForTest(alloc, &messages, .{});
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    try testing.expectEqualStrings("You are fx.", parsed.value.object.get("instructions").?.string);

    const input = parsed.value.object.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 2), input.len);
    try testing.expectEqualStrings("developer", input[1].object.get("role").?.string);
    try testing.expectEqualStrings(
        "Tool call is pending review.",
        input[1].object.get("content").?.array.items[0].object.get("text").?.string,
    );
}

test "assistant tool calls and their results round trip" {
    const alloc = testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "read a.txt" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read", .content = "alpha" },
    };
    const body = try buildForTest(alloc, &messages, .{});
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 3), input.len);

    const call = input[1].object;
    try testing.expectEqualStrings("function_call", call.get("type").?.string);
    try testing.expectEqualStrings("call_1", call.get("call_id").?.string);
    try testing.expectEqualStrings("read", call.get("name").?.string);
    // Arguments travel as a JSON string, not an object.
    try testing.expectEqualStrings("{\"path\":\"a.txt\"}", call.get("arguments").?.string);

    const result = input[2].object;
    try testing.expectEqualStrings("function_call_output", result.get("type").?.string);
    try testing.expectEqualStrings("call_1", result.get("call_id").?.string);
    try testing.expectEqualStrings("alpha", result.get("output").?.string);
}

test "tools are rewritten into the Codex function shape" {
    const alloc = testing.allocator;
    const tools =
        \\[{"type":"function","name":"read","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}]
    ;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const body = try buildForTest(alloc, &messages, .{ .tools_json = tools });
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    const advertised = parsed.value.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 1), advertised.len);
    const tool = advertised[0].object;
    try testing.expectEqualStrings("function", tool.get("type").?.string);
    try testing.expectEqualStrings("read", tool.get("name").?.string);
    try testing.expectEqualStrings("Read a file", tool.get("description").?.string);
    try testing.expectEqual(false, tool.get("strict").?.bool);
    // inputSchema becomes parameters.
    try testing.expectEqualStrings(
        "object",
        tool.get("parameters").?.object.get("type").?.string,
    );
    try testing.expect(tool.get("inputSchema") == null);
}

test "an empty tool list is omitted rather than sent empty" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const body = try buildForTest(alloc, &messages, .{ .tools_json = "[]" });
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tools") == null);
}

test "tool choice maps auto and none" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};

    const auto_body = try buildForTest(alloc, &messages, .{ .tool_choice = .auto });
    defer alloc.free(auto_body);
    var auto_parsed = try parseBody(alloc, auto_body);
    defer auto_parsed.deinit();
    try testing.expectEqualStrings("auto", auto_parsed.value.object.get("tool_choice").?.string);

    const none_body = try buildForTest(alloc, &messages, .{ .tool_choice = .none });
    defer alloc.free(none_body);
    var none_parsed = try parseBody(alloc, none_body);
    defer none_parsed.deinit();
    try testing.expectEqualStrings("none", none_parsed.value.object.get("tool_choice").?.string);
}

test "reasoning effort is forwarded, normalising minimal to low" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};

    const high = try buildForTest(alloc, &messages, .{
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
    });
    defer alloc.free(high);
    var high_parsed = try parseBody(alloc, high);
    defer high_parsed.deinit();
    const reasoning = high_parsed.value.object.get("reasoning").?.object;
    try testing.expectEqualStrings("high", reasoning.get("effort").?.string);
    try testing.expectEqualStrings("auto", reasoning.get("summary").?.string);

    const minimal = try buildForTest(alloc, &messages, .{
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("minimal") },
    });
    defer alloc.free(minimal);
    var minimal_parsed = try parseBody(alloc, minimal);
    defer minimal_parsed.deinit();
    try testing.expectEqualStrings(
        "low",
        minimal_parsed.value.object.get("reasoning").?.object.get("effort").?.string,
    );

    const default_body = try buildForTest(alloc, &messages, .{});
    defer alloc.free(default_body);
    var default_parsed = try parseBody(alloc, default_body);
    defer default_parsed.deinit();
    try testing.expect(default_parsed.value.object.get("reasoning") == null);
}

test "session id becomes the prompt cache key" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const body = try buildForTest(alloc, &messages, .{ .session_id = "sess-42" });
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    try testing.expectEqualStrings("sess-42", parsed.value.object.get("prompt_cache_key").?.string);
}

test "max output tokens is forwarded when set" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const body = try buildForTest(alloc, &messages, .{ .max_output_tokens = 4096 });
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 4096), parsed.value.object.get("max_output_tokens").?.integer);
}

test "encrypted reasoning is replayed immediately before its tool call" {
    const alloc = testing.allocator;
    const Replay = struct {
        fn lookup(_: ?*anyopaque, gpa: Allocator, call_id: []const u8) ?[]u8 {
            if (std.mem.eql(u8, call_id, "call_1")) {
                return gpa.dupe(u8, "[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"abc\"}]") catch null;
            }
            return null;
        }
    };

    const calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read", .arguments_json = "{}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
    };
    const body = try build(alloc, .{
        .model = "gpt-5.6-terra",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    }, .{ .reasoning_replay = .{ .lookup_fn = Replay.lookup } });
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 2), input.len);
    try testing.expectEqualStrings("reasoning", input[0].object.get("type").?.string);
    try testing.expectEqualStrings("abc", input[0].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("function_call", input[1].object.get("type").?.string);
}

test "structured output becomes a json_schema text format" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const body = try build(alloc, .{
        .model = "gpt-5.6-terra",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .response_format = .{
            .name = "answer",
            .description = "structured answer",
            .schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
    }, .{});
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    const format = parsed.value.object.get("text").?.object.get("format").?.object;
    try testing.expectEqualStrings("json_schema", format.get("type").?.string);
    try testing.expectEqualStrings("answer", format.get("name").?.string);
}

test "a vision-required turn pins tool choice to the vision tool" {
    const alloc = testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "what is this" }};
    const body = try build(alloc, .{
        .model = "gpt-5.6-terra",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .vision_mode = .required,
    }, .{});
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    const choice = parsed.value.object.get("tool_choice").?.object;
    try testing.expectEqualStrings("function", choice.get("type").?.string);
    try testing.expectEqualStrings("vision", choice.get("name").?.string);
}

test "every generated body is valid JSON for realistic histories" {
    const alloc = testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "call_\"quoted\"", .name = "read", .arguments_json = "{\"path\":\"a\\\"b.txt\"}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Line one\nLine \"two\"" },
        .{ .role = .user, .content = "unicode: \u{1F600} and \\ backslash" },
        .{ .role = .assistant, .content = "thinking", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_\"quoted\"", .content = "result with \"quotes\"" },
        .{ .role = .user, .content = "" },
    };
    const body = try buildForTest(alloc, &messages, .{});
    defer alloc.free(body);

    var parsed = try parseBody(alloc, body);
    defer parsed.deinit();
    // user, assistant text, the assistant's tool call, then the tool result.
    // The trailing empty user message contributes nothing.
    const input = parsed.value.object.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 4), input.len);
    try testing.expectEqualStrings("message", input[1].object.get("type").?.string);
    try testing.expectEqualStrings("function_call", input[2].object.get("type").?.string);
    try testing.expectEqualStrings("function_call_output", input[3].object.get("type").?.string);
}
