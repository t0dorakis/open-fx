const std = @import("std");

const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const max_json_response_bytes: usize = 4 * 1024 * 1024;
const send_buffer_bytes = 8 * 1024;
const transfer_buffer_bytes = 64 * 1024;

pub const HttpError = error{
    Cancelled,
    CodexRequestFailed,
};

/// Product identifier sent to the Codex backend. Deliberately not the official
/// Codex CLI's user agent: this is a different client and says so.
///
/// This is a wire value the backend has been observed to accept, not the
/// project name, so it does not follow the repository if that is renamed.
pub fn userAgent() []const u8 {
    return "fx-codex";
}

/// Closes the socket when the cancel flag is raised.
///
/// Without this a blocked read would keep the turn alive after the user hits
/// Esc, because nothing else wakes a socket that is waiting for the next token.
pub const CancelWatcher = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *CancelWatcher, cancel_flag: *std.atomic.Value(bool), stream: std.Io.net.Stream) void {
        self.thread = std.Thread.spawn(.{}, run, .{ &self.done, cancel_flag, stream }) catch null;
    }

    pub fn stop(self: *CancelWatcher) void {
        self.done.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn run(done: *std.atomic.Value(bool), cancel_flag: *std.atomic.Value(bool), stream: std.Io.net.Stream) void {
        while (!done.load(.seq_cst)) {
            if (cancel_flag.load(.seq_cst)) {
                stream.shutdown(io_mod.getIo(), .both) catch {};
                return;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

/// Headers every authenticated Codex backend request carries.
pub const Auth = struct {
    access_token: []const u8,
    account_id: []const u8,
    session_id: ?[]const u8 = null,
};

pub const HeaderSet = struct {
    authorization: []u8,
    extra: [5]std.http.Header,
    extra_len: usize,

    pub fn deinit(self: *HeaderSet, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.authorization);
        self.* = undefined;
    }

    pub fn slice(self: *const HeaderSet) []const std.http.Header {
        return self.extra[0..self.extra_len];
    }
};

pub fn buildHeaders(alloc: Allocator, auth: Auth, accept: []const u8) !HeaderSet {
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{auth.access_token});
    errdefer secret.zeroAndFree(alloc, authorization);

    var set = HeaderSet{
        .authorization = authorization,
        .extra = undefined,
        .extra_len = 0,
    };
    set.extra[set.extra_len] = .{ .name = "chatgpt-account-id", .value = auth.account_id };
    set.extra_len += 1;
    set.extra[set.extra_len] = .{ .name = "originator", .value = config.originator() };
    set.extra_len += 1;
    set.extra[set.extra_len] = .{ .name = "accept", .value = accept };
    set.extra_len += 1;
    if (auth.session_id) |session_id| {
        if (session_id.len > 0) {
            set.extra[set.extra_len] = .{ .name = "session-id", .value = session_id };
            set.extra_len += 1;
            set.extra[set.extra_len] = .{ .name = "x-client-request-id", .value = session_id };
            set.extra_len += 1;
        }
    }
    return set;
}

fn clientHeaders(authorization: []const u8) std.http.Client.Request.Headers {
    var headers: std.http.Client.Request.Headers = .{};
    // SSE must arrive uncompressed, and the catalog is small enough not to care.
    headers.accept_encoding = .omit;
    headers.user_agent = .{ .override = userAgent() };
    headers.authorization = .{ .override = authorization };
    return headers;
}

pub const JsonResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *JsonResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

/// Issues a GET and reads the whole body. Used for the model catalog.
pub fn getJson(
    alloc: Allocator,
    url: []const u8,
    auth: Auth,
    cancel_flag: ?*std.atomic.Value(bool),
) !JsonResponse {
    if (isCancelled(cancel_flag)) return HttpError.Cancelled;

    var headers = try buildHeaders(alloc, auth, "application/json");
    defer headers.deinit(alloc);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .headers = clientHeaders(headers.authorization),
        .extra_headers = headers.slice(),
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    try req.sendBodiless();
    if (req.connection) |conn| try conn.flush();

    var response = try req.receiveHead(&.{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = try reader.streamRemaining(&out.writer);

    return .{ .status = response.head.status, .body = try out.toOwnedSlice() };
}

/// Issues a POST with a JSON body and reads the whole body.
///
/// Separate from the streaming path because the Codex device-authorization
/// endpoints speak JSON request bodies, which fx's own OAuth transport cannot
/// express (it only knows GET and form POST).
pub fn postJson(
    alloc: Allocator,
    url: []const u8,
    payload: []const u8,
    auth: ?Auth,
    cancel_flag: ?*std.atomic.Value(bool),
) !JsonResponse {
    if (isCancelled(cancel_flag)) return HttpError.Cancelled;

    var maybe_headers: ?HeaderSet = if (auth) |value|
        try buildHeaders(alloc, value, "application/json")
    else
        null;
    defer if (maybe_headers) |*value| value.deinit(alloc);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    var request_headers: std.http.Client.Request.Headers = .{};
    request_headers.accept_encoding = .omit;
    request_headers.user_agent = .{ .override = userAgent() };
    request_headers.content_type = .{ .override = "application/json" };
    if (maybe_headers) |value| request_headers.authorization = .{ .override = value.authorization };

    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{
        .headers = request_headers,
        .extra_headers = if (maybe_headers) |value| value.slice() else &.{},
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var send_buf: [send_buffer_bytes]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&send_buf);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (req.connection) |conn| try conn.flush();

    var response = try req.receiveHead(&.{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = try reader.streamRemaining(&out.writer);

    return .{ .status = response.head.status, .body = try out.toOwnedSlice() };
}

pub fn isCancelled(cancel_flag: ?*std.atomic.Value(bool)) bool {
    const flag = cancel_flag orelse return false;
    return flag.load(.seq_cst);
}

/// Reads `retry-after-ms` or `retry-after` from a response head.
pub fn retryAfterMs(head: std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    var seconds: ?u64 = null;
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after-ms")) {
            const value = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " "), 10) catch continue;
            return value;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            const value = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " "), 10) catch continue;
            seconds = value;
        }
    }
    if (seconds) |value| return value * std.time.ms_per_s;
    return null;
}

test "buildHeaders carries the account id and originator" {
    const alloc = std.testing.allocator;
    var headers = try buildHeaders(alloc, .{
        .access_token = "tok",
        .account_id = "acct_1",
        .session_id = "sess-1",
    }, "text/event-stream");
    defer headers.deinit(alloc);

    try std.testing.expectEqualStrings("Bearer tok", headers.authorization);

    var saw_account = false;
    var saw_session = false;
    var saw_client_request = false;
    var saw_accept = false;
    for (headers.slice()) |header| {
        if (std.mem.eql(u8, header.name, "chatgpt-account-id")) {
            saw_account = std.mem.eql(u8, header.value, "acct_1");
        } else if (std.mem.eql(u8, header.name, "session-id")) {
            saw_session = std.mem.eql(u8, header.value, "sess-1");
        } else if (std.mem.eql(u8, header.name, "x-client-request-id")) {
            saw_client_request = std.mem.eql(u8, header.value, "sess-1");
        } else if (std.mem.eql(u8, header.name, "accept")) {
            saw_accept = std.mem.eql(u8, header.value, "text/event-stream");
        }
    }
    try std.testing.expect(saw_account);
    try std.testing.expect(saw_session);
    try std.testing.expect(saw_client_request);
    try std.testing.expect(saw_accept);
}

test "buildHeaders omits session headers when there is no session" {
    const alloc = std.testing.allocator;
    var headers = try buildHeaders(alloc, .{
        .access_token = "tok",
        .account_id = "acct_1",
    }, "application/json");
    defer headers.deinit(alloc);

    for (headers.slice()) |header| {
        try std.testing.expect(!std.mem.eql(u8, header.name, "session-id"));
        try std.testing.expect(!std.mem.eql(u8, header.name, "x-client-request-id"));
    }
}
