const std = @import("std");

const http = @import("http.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const max_sse_line_bytes: usize = 8 * 1024 * 1024;

pub const StreamError = error{
    Cancelled,
    CodexSseReadFailed,
};

pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;
pub const ToolStartCallback = *const fn (
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
) void;

/// Receives the encrypted reasoning that preceded a tool call, so a later turn
/// can replay it. Optional: turns work without it, they just lose prompt cache
/// hits and make the model re-derive its reasoning.
pub const ReasoningSink = struct {
    context: ?*anyopaque = null,
    record_fn: *const fn (?*anyopaque, call_id: []const u8, items_json: []const u8) void,

    pub fn record(self: ReasoningSink, call_id: []const u8, items_json: []const u8) void {
        self.record_fn(self.context, call_id, items_json);
    }
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback = null,
    on_reasoning_chunk: ?StreamCallback = null,
    on_tool_input_chunk: ?StreamCallback = null,
};

pub const ConsumeOptions = struct {
    /// Reported back as the resolved model, so fx's billing record names
    /// something meaningful.
    model: []const u8,
    content_capture_limit: ?usize = null,
    reasoning_sink: ?ReasoningSink = null,
};

const PendingToolCall = struct {
    item_id: std.ArrayList(u8) = .empty,
    call_id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    finished: bool = false,

    fn deinit(self: *PendingToolCall, alloc: Allocator) void {
        self.item_id.deinit(alloc);
        self.call_id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

/// Translates a Codex Responses SSE stream into a GatewayCompletion, invoking
/// fx's streaming callbacks as events arrive.
///
/// Two details drive the shape of this. Argument deltas are keyed by the
/// `fc_...` item id while fx correlates a tool call end to end by its
/// `call_id`, so item ids are mapped to call ids as items are announced. And
/// `response.completed` arrives with an empty `output` array, so whether the
/// turn ended in tool calls has to be tracked as events go by rather than read
/// off the terminal event.
pub fn consume(
    alloc: Allocator,
    reader: anytype,
    callbacks: Callbacks,
    cancel_flag: *std.atomic.Value(bool),
    options: ConsumeOptions,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);

    var calls: std.ArrayList(PendingToolCall) = .empty;
    defer {
        for (calls.items) |*call| call.deinit(alloc);
        calls.deinit(alloc);
    }

    // Reasoning items seen since the last tool call, kept as raw JSON so they
    // can be replayed verbatim.
    var pending_reasoning: std.ArrayList(u8) = .empty;
    defer pending_reasoning.deinit(alloc);
    var pending_reasoning_count: usize = 0;

    var failure_detail: ?[]u8 = null;
    errdefer if (failure_detail) |detail| alloc.free(detail);

    var usage: types.Usage = .{};
    var billing: ?types.GatewayBilling = null;
    errdefer if (billing) |value| alloc.free(@constCast(value.model));

    var finish_reason: ?types.ProviderFinishReason = null;
    var created_at_ms: ?i64 = null;
    var saw_tool_call = false;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) return StreamError.Cancelled;

        const line = switch (try readLine(alloc, reader, &line_buffer)) {
            .line => |value| value,
            .eof => break,
            .read_failed => {
                if (cancel_flag.load(.seq_cst)) return StreamError.Cancelled;
                return StreamError.CodexSseReadFailed;
            },
        };

        const payload = sseDataPayload(line) orelse continue;
        if (std.mem.eql(u8, payload, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event = parsed.value.object;

        const type_value = event.get("type") orelse continue;
        if (type_value != .string) continue;
        const event_type = type_value.string;

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (objectField(event, "response")) |response| {
                if (response.get("created_at")) |value| {
                    if (value == .integer) created_at_ms = value.integer * std.time.ms_per_s;
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = objectField(event, "item") orelse continue;
            const item_type = stringField(item, "type") orelse continue;
            if (!std.mem.eql(u8, item_type, "function_call")) continue;
            const call_id = stringField(item, "call_id") orelse continue;
            const name = stringField(item, "name") orelse "";

            var pending = PendingToolCall{};
            errdefer pending.deinit(alloc);
            if (stringField(item, "id")) |item_id| try pending.item_id.appendSlice(alloc, item_id);
            try pending.call_id.appendSlice(alloc, call_id);
            try pending.name.appendSlice(alloc, name);
            try calls.append(alloc, pending);
            saw_tool_call = true;

            if (callbacks.on_tool_start) |cb| cb(callbacks.ctx, call_id, name, null);

            // Attribute the reasoning accumulated so far to this call.
            if (pending_reasoning_count > 0) {
                if (options.reasoning_sink) |sink| {
                    const items = try std.fmt.allocPrint(alloc, "[{s}]", .{pending_reasoning.items});
                    defer alloc.free(items);
                    sink.record(call_id, items);
                }
                pending_reasoning.clearRetainingCapacity();
                pending_reasoning_count = 0;
            }
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const delta = stringField(event, "delta") orelse continue;
            if (findCall(calls.items, event)) |index| {
                try calls.items[index].arguments.appendSlice(alloc, delta);
            }
            if (callbacks.on_tool_input_chunk) |cb| cb(callbacks.ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const index = findCall(calls.items, event) orelse continue;
            if (stringField(event, "arguments")) |arguments| {
                calls.items[index].arguments.clearRetainingCapacity();
                try calls.items[index].arguments.appendSlice(alloc, arguments);
            }
            calls.items[index].finished = true;
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const delta = stringField(event, "delta") orelse continue;
            if (delta.len == 0) continue;
            const retained = if (options.content_capture_limit) |limit|
                delta[0..@min(delta.len, limit -| content.items.len)]
            else
                delta;
            try content.appendSlice(alloc, retained);
            callbacks.on_content_chunk(callbacks.ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            const delta = stringField(event, "delta") orelse continue;
            if (delta.len == 0) continue;
            if (callbacks.on_reasoning_chunk) |cb| cb(callbacks.ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = objectField(event, "item") orelse continue;
            const item_type = stringField(item, "type") orelse continue;
            if (std.mem.eql(u8, item_type, "reasoning")) {
                if (options.reasoning_sink == null) continue;
                if (stringField(item, "encrypted_content") == null) continue;
                var rendered: std.Io.Writer.Allocating = .init(alloc);
                defer rendered.deinit();
                try std.json.Stringify.value(std.json.Value{ .object = item }, .{}, &rendered.writer);
                if (pending_reasoning_count > 0) try pending_reasoning.append(alloc, ',');
                try pending_reasoning.appendSlice(alloc, rendered.written());
                pending_reasoning_count += 1;
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                if (stringField(item, "arguments")) |arguments| {
                    if (findCallByCallId(calls.items, stringField(item, "call_id") orelse "")) |index| {
                        calls.items[index].arguments.clearRetainingCapacity();
                        try calls.items[index].arguments.appendSlice(alloc, arguments);
                        calls.items[index].finished = true;
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            const response = objectField(event, "response");
            usage = parseUsage(response);
            const incomplete_reason = incompleteReason(response);
            finish_reason = if (incomplete_reason != null and
                std.mem.eql(u8, incomplete_reason.?, "max_output_tokens"))
                .length
            else if (saw_tool_call)
                .tool_calls
            else
                .stop;
            billing = try buildBilling(alloc, response, created_at_ms, options.model);
            break;
        } else if (std.mem.eql(u8, event_type, "response.failed") or
            std.mem.eql(u8, event_type, "error"))
        {
            if (failure_detail == null) failure_detail = try captureFailure(alloc, event);
            finish_reason = .provider_error;
            break;
        }
    }

    var completion: types.GatewayCompletion = .{};
    if (content.items.len > 0) completion.content = try alloc.dupe(u8, content.items);
    errdefer if (completion.content) |value| alloc.free(@constCast(value));

    completion.tool_calls = try materializeToolCalls(alloc, calls.items);
    completion.finish_reason = finish_reason;
    completion.usage = usage;
    completion.billing = billing;
    billing = null;
    completion.provider_failure_detail = failure_detail;
    failure_detail = null;
    return completion;
}

fn materializeToolCalls(alloc: Allocator, pending: []const PendingToolCall) ![]const types.ToolCall {
    if (pending.len == 0) return &.{};
    var out = try alloc.alloc(types.ToolCall, pending.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |call| types.freeToolCall(alloc, call);
        alloc.free(out);
    }

    for (pending) |call| {
        const id = try alloc.dupe(u8, call.call_id.items);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, call.name.items);
        errdefer alloc.free(name);
        const arguments = try alloc.dupe(
            u8,
            if (call.arguments.items.len > 0) call.arguments.items else "{}",
        );
        out[built] = .{ .id = id, .name = name, .arguments_json = arguments };
        built += 1;
    }
    return out;
}

fn findCall(calls: []const PendingToolCall, event: std.json.ObjectMap) ?usize {
    if (stringField(event, "item_id")) |item_id| {
        for (calls, 0..) |call, index| {
            if (std.mem.eql(u8, call.item_id.items, item_id)) return index;
        }
    }
    if (stringField(event, "call_id")) |call_id| return findCallByCallId(calls, call_id);
    // A single in-flight call is unambiguous even without a usable id.
    if (calls.len == 1) return 0;
    return null;
}

fn findCallByCallId(calls: []const PendingToolCall, call_id: []const u8) ?usize {
    if (call_id.len == 0) return null;
    for (calls, 0..) |call, index| {
        if (std.mem.eql(u8, call.call_id.items, call_id)) return index;
    }
    return null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn incompleteReason(response: ?std.json.ObjectMap) ?[]const u8 {
    const actual = response orelse return null;
    const details = objectField(actual, "incomplete_details") orelse return null;
    return stringField(details, "reason");
}

fn parseUsage(response: ?std.json.ObjectMap) types.Usage {
    const actual = response orelse return .{};
    const usage = objectField(actual, "usage") orelse return .{};
    return .{
        .input_tokens = integerField(usage, "input_tokens"),
        .output_tokens = integerField(usage, "output_tokens"),
    };
}

/// Builds the billing record fx renders as token usage.
///
/// Subscription turns are not metered per request, so cost is a well formed
/// zero rather than a guess. Cache and reasoning counts are clamped to their
/// totals because fx discards the whole record if any sub-count exceeds them.
fn buildBilling(
    alloc: Allocator,
    response: ?std.json.ObjectMap,
    created_at_ms: ?i64,
    model: []const u8,
) !?types.GatewayBilling {
    const actual = response orelse return null;
    const created = created_at_ms orelse return null;
    const usage = objectField(actual, "usage") orelse return null;

    const input_tokens = integerField(usage, "input_tokens") orelse 0;
    const output_tokens = integerField(usage, "output_tokens") orelse 0;

    var cache_read: u64 = 0;
    var cache_write: u64 = 0;
    if (objectField(usage, "input_tokens_details")) |details| {
        cache_read = @min(integerField(details, "cached_tokens") orelse 0, input_tokens);
        cache_write = @min(integerField(details, "cache_write_tokens") orelse 0, input_tokens);
    }
    var reasoning_tokens: ?u64 = null;
    if (objectField(usage, "output_tokens_details")) |details| {
        if (integerField(details, "reasoning_tokens")) |value| {
            reasoning_tokens = @min(value, output_tokens);
        }
    }

    return .{
        .created_at_ms = created,
        .model = try alloc.dupe(u8, model),
        .total_cost = 0,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read,
        .cache_write_tokens = cache_write,
        .reasoning_tokens = reasoning_tokens,
        .billable_web_search_calls = 0,
    };
}

fn captureFailure(alloc: Allocator, event: std.json.ObjectMap) !?[]u8 {
    if (objectField(event, "response")) |response| {
        if (objectField(response, "error")) |err| {
            if (stringField(err, "message")) |message| return try alloc.dupe(u8, message);
        }
    }
    if (objectField(event, "error")) |err| {
        if (stringField(err, "message")) |message| return try alloc.dupe(u8, message);
    }
    if (stringField(event, "error")) |message| return try alloc.dupe(u8, message);
    if (stringField(event, "message")) |message| return try alloc.dupe(u8, message);
    return null;
}

/// Extracts the payload of an SSE `data:` line, tolerating a missing space.
fn sseDataPayload(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len == 0 or trimmed[0] == ':') return null;
    if (!std.mem.startsWith(u8, trimmed, "data:")) return null;
    return std.mem.trimStart(u8, trimmed["data:".len..], " ");
}

const LineRead = union(enum) {
    line: []const u8,
    eof,
    read_failed,
};

fn readLine(alloc: Allocator, reader: anytype, buffer: *std.ArrayList(u8)) !LineRead {
    buffer.clearRetainingCapacity();
    while (true) {
        const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const buffered = reader.buffered();
                if (buffered.len == 0) return .read_failed;
                if (buffer.items.len + buffered.len > max_sse_line_bytes) return .read_failed;
                try buffer.appendSlice(alloc, buffered);
                reader.tossBuffered();
                continue;
            },
            error.ReadFailed => return .read_failed,
        } orelse {
            if (buffer.items.len > 0) return .{ .line = buffer.items };
            return .eof;
        };

        if (buffer.items.len + fragment.len > max_sse_line_bytes) return .read_failed;
        if (buffer.items.len == 0) return .{ .line = fragment };
        try buffer.appendSlice(alloc, fragment);
        return .{ .line = buffer.items };
    }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/// Receives the response head so rate-limit headers can be recorded.
///
/// Codex reports usage on chat responses rather than at a credits endpoint, so
/// this is the only place the window is observable.
pub const HeadSink = struct {
    context: ?*anyopaque = null,
    record_fn: *const fn (?*anyopaque, std.http.Client.Response.Head) void,
};

pub const ExecuteOptions = struct {
    url: []const u8,
    auth: http.Auth,
    payload: []const u8,
    model: []const u8,
    content_capture_limit: ?usize = null,
    reasoning_sink: ?ReasoningSink = null,
    head_sink: ?HeadSink = null,
};

pub const Outcome = struct {
    status: std.http.Status,
    completion: types.GatewayCompletion = .{},
    err_body: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,
};

const send_buffer_bytes = 8 * 1024;
const transfer_buffer_bytes = 64 * 1024;

/// POSTs a Codex Responses request and streams the reply into a completion.
///
/// A non-200 is returned as an outcome with the error body rather than an
/// error, because fx renders provider failures itself and needs the body to do
/// it. Transport failures still surface as errors.
pub fn execute(
    alloc: Allocator,
    options: ExecuteOptions,
    callbacks: Callbacks,
    cancel_flag: *std.atomic.Value(bool),
    delivery: ?*@import("../core/agent/stream_provider.zig").DeliveryCertainty,
) !Outcome {
    if (cancel_flag.load(.seq_cst)) return StreamError.Cancelled;

    var headers = try http.buildHeaders(alloc, options.auth, "text/event-stream");
    defer headers.deinit(alloc);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const uri = try std.Uri.parse(options.url);
    var request_headers: std.http.Client.Request.Headers = .{};
    request_headers.accept_encoding = .omit;
    request_headers.user_agent = .{ .override = http.userAgent() };
    request_headers.content_type = .{ .override = "application/json" };
    request_headers.authorization = .{ .override = headers.authorization };

    var extra: [6]std.http.Header = undefined;
    var extra_len: usize = 0;
    for (headers.slice()) |header| {
        extra[extra_len] = header;
        extra_len += 1;
    }
    // The Responses surface on the Codex backend is gated behind this.
    extra[extra_len] = .{ .name = "openai-beta", .value = "responses=experimental" };
    extra_len += 1;

    var req = try client.request(.POST, uri, .{
        .headers = request_headers,
        .extra_headers = extra[0..extra_len],
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    // Esc must be able to abort a turn that is blocked waiting for the next
    // token, and only closing the socket wakes that read.
    var watcher: http.CancelWatcher = .{};
    if (req.connection) |conn| watcher.start(cancel_flag, conn.stream_writer.stream);
    defer watcher.stop();

    if (delivery) |value| value.markPossiblySent();

    req.transfer_encoding = .{ .content_length = options.payload.len };
    var send_buf: [send_buffer_bytes]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&send_buf);
    try body_writer.writer.writeAll(options.payload);
    try body_writer.end();
    if (req.connection) |conn| try conn.flush();
    if (cancel_flag.load(.seq_cst)) return StreamError.Cancelled;

    var response = try req.receiveHead(&.{});
    if (options.head_sink) |sink| sink.record_fn(sink.context, response.head);
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    if (response.head.status != .ok) {
        var body: std.Io.Writer.Allocating = .init(alloc);
        errdefer body.deinit();
        _ = reader.streamRemaining(&body.writer) catch {};
        const retry_after_ms = http.retryAfterMs(response.head);
        return .{
            .status = response.head.status,
            .err_body = try body.toOwnedSlice(),
            .retry_after_seconds = if (retry_after_ms) |ms| (ms + 999) / std.time.ms_per_s else null,
        };
    }

    const completion = try consume(alloc, reader, callbacks, cancel_flag, .{
        .model = options.model,
        .content_capture_limit = options.content_capture_limit,
        .reasoning_sink = options.reasoning_sink,
    });
    return .{ .status = .ok, .completion = completion };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const text_fixture = @embedFile("testdata/probe-text.sse");
const tool_fixture = @embedFile("testdata/probe-tool.sse");
const reasoning_fixture = @embedFile("testdata/probe-reasoning.sse");

const Collector = struct {
    alloc: Allocator,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    tool_starts: std.ArrayList([]u8) = .empty,
    recorded_call_id: std.ArrayList(u8) = .empty,
    recorded_items: std.ArrayList(u8) = .empty,

    fn deinit(self: *Collector) void {
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        self.tool_input.deinit(self.alloc);
        for (self.tool_starts.items) |item| self.alloc.free(item);
        self.tool_starts.deinit(self.alloc);
        self.recorded_call_id.deinit(self.alloc);
        self.recorded_items.deinit(self.alloc);
    }

    fn onContent(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.content.appendSlice(self.alloc, chunk) catch {};
    }

    fn onReasoning(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.reasoning.appendSlice(self.alloc, chunk) catch {};
    }

    fn onToolInput(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.tool_input.appendSlice(self.alloc, chunk) catch {};
    }

    fn onToolStart(ctx: *anyopaque, tool_id: []const u8, tool_name: []const u8, _: ?[]const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        const entry = std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ tool_id, tool_name }) catch return;
        self.tool_starts.append(self.alloc, entry) catch self.alloc.free(entry);
    }

    fn onReasoningRecord(ctx: ?*anyopaque, call_id: []const u8, items_json: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx.?));
        self.recorded_call_id.appendSlice(self.alloc, call_id) catch {};
        self.recorded_items.appendSlice(self.alloc, items_json) catch {};
    }

    fn callbacks(self: *Collector) Callbacks {
        return .{
            .ctx = self,
            .on_content_chunk = onContent,
            .on_tool_start = onToolStart,
            .on_reasoning_chunk = onReasoning,
            .on_tool_input_chunk = onToolInput,
        };
    }
};

fn consumeFixture(
    alloc: Allocator,
    fixture: []const u8,
    collector: *Collector,
    with_sink: bool,
) !types.GatewayCompletion {
    var reader: std.Io.Reader = .fixed(fixture);
    var cancel_flag = std.atomic.Value(bool).init(false);
    return consume(alloc, &reader, collector.callbacks(), &cancel_flag, .{
        .model = "openai/gpt-5.6-terra",
        .reasoning_sink = if (with_sink)
            ReasoningSink{ .context = collector, .record_fn = Collector.onReasoningRecord }
        else
            null,
    });
}

test "text turn produces content and a stop finish" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    var completion = try consumeFixture(alloc, text_fixture, &collector, false);
    defer freeCompletion(alloc, &completion);

    try testing.expectEqualStrings("fx-codex probe ok", completion.content.?);
    try testing.expectEqualStrings("fx-codex probe ok", collector.content.items);
    try testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
}

test "tool turn reports tool-calls rather than stop" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    // response.completed carries an empty output array, so the finish reason
    // has to come from what was observed mid-stream.
    var completion = try consumeFixture(alloc, tool_fixture, &collector, false);
    defer freeCompletion(alloc, &completion);

    try testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try testing.expectEqual(@as(usize, 1), completion.tool_calls.len);

    const call = completion.tool_calls[0];
    try testing.expectEqualStrings("get_weather", call.name);
    try testing.expect(std.mem.startsWith(u8, call.id, "call_"));
    try testing.expectEqualStrings("{\"city\":\"Berlin\"}", call.arguments_json);

    // fx correlates start and call by one id even though upstream deltas are
    // keyed by the fc_... item id.
    try testing.expectEqual(@as(usize, 1), collector.tool_starts.items.len);
    try testing.expect(std.mem.endsWith(u8, collector.tool_starts.items[0], ":get_weather"));
    try testing.expect(std.mem.startsWith(u8, collector.tool_starts.items[0], call.id));
    try testing.expectEqualStrings("{\"city\":\"Berlin\"}", collector.tool_input.items);
}

test "reasoning turn streams reasoning deltas" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    var completion = try consumeFixture(alloc, reasoning_fixture, &collector, false);
    defer freeCompletion(alloc, &completion);

    try testing.expect(collector.reasoning.items.len > 0);
    try testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
}

test "usage and billing stay within the bounds fx validates" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    var completion = try consumeFixture(alloc, tool_fixture, &collector, false);
    defer freeCompletion(alloc, &completion);

    try testing.expect(completion.usage.input_tokens.? > 0);
    try testing.expect(completion.usage.output_tokens.? > 0);

    const billing = completion.billing.?;
    try testing.expectEqualStrings("openai/gpt-5.6-terra", billing.model);
    try testing.expectEqual(@as(f64, 0), billing.total_cost);
    try testing.expect(billing.created_at_ms > 0);
    // fx drops the whole billing record if any sub-count exceeds its total.
    try testing.expect(billing.cache_read_tokens <= billing.input_tokens);
    try testing.expect(billing.cache_write_tokens <= billing.output_tokens + billing.input_tokens);
    if (billing.reasoning_tokens) |value| try testing.expect(value <= billing.output_tokens);
}

test "a stream that stops without a terminal event still yields what it saw" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    const truncated =
        "data: {\"type\":\"response.created\",\"response\":{\"created_at\":1}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\",\"item_id\":\"m\"}\n\n";
    var reader: std.Io.Reader = .fixed(truncated);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var completion = try consume(alloc, &reader, collector.callbacks(), &cancel_flag, .{
        .model = "m",
    });
    defer freeCompletion(alloc, &completion);

    try testing.expectEqualStrings("partial", completion.content.?);
    // No finish event arrived, so no finish reason is invented.
    try testing.expect(completion.finish_reason == null);
}

test "an upstream failure is captured as provider failure detail" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    const failed =
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"boom\"}}}\n\n";
    var reader: std.Io.Reader = .fixed(failed);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var completion = try consume(alloc, &reader, collector.callbacks(), &cancel_flag, .{
        .model = "m",
    });
    defer freeCompletion(alloc, &completion);

    try testing.expectEqual(types.ProviderFinishReason.provider_error, completion.finish_reason.?);
    try testing.expectEqualStrings("boom", completion.provider_failure_detail.?);
}

test "cancellation stops the stream promptly" {
    const alloc = testing.allocator;
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    var reader: std.Io.Reader = .fixed(text_fixture);
    var cancel_flag = std.atomic.Value(bool).init(true);
    try testing.expectError(StreamError.Cancelled, consume(
        alloc,
        &reader,
        collector.callbacks(),
        &cancel_flag,
        .{ .model = "m" },
    ));
}

test "data lines are accepted with or without the conventional space" {
    try testing.expectEqualStrings("{}", sseDataPayload("data: {}").?);
    try testing.expectEqualStrings("{}", sseDataPayload("data:{}").?);
    try testing.expectEqualStrings("[DONE]", sseDataPayload("data: [DONE]\r").?);
    try testing.expect(sseDataPayload("event: response.created") == null);
    try testing.expect(sseDataPayload(": keep-alive") == null);
    try testing.expect(sseDataPayload("") == null);
}

fn freeCompletion(alloc: Allocator, completion: *types.GatewayCompletion) void {
    if (completion.content) |value| alloc.free(@constCast(value));
    if (completion.billing) |value| alloc.free(@constCast(value.model));
    if (completion.provider_failure_detail) |value| alloc.free(@constCast(value));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    completion.* = .{};
}
