const std = @import("std");

const builtin_gateway = @import("../builtins/gateway.zig");
const credentials = @import("../core/auth/credentials.zig");
const generation_usage_provider = @import("../core/session/generation_usage_provider.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");

const auth = @import("auth.zig");
const build_request = @import("build_request.zig");
const codex_credits = @import("credits.zig");
const codex_model_catalog = @import("model_catalog.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const jwt = @import("jwt.zig");
const runtime_mod = @import("runtime.zig");
const stream = @import("stream.zig");

const Allocator = std.mem.Allocator;

pub const default_model = "openai/gpt-5.6-terra";

/// Process-wide state shared by the Codex providers.
var runtime: runtime_mod.Runtime = .{};

pub fn deinit() void {
    runtime.deinit();
}

// ---------------------------------------------------------------------------
// Chat URL
// ---------------------------------------------------------------------------

const default_chat_url = config.default_backend_base_url ++ "/codex/responses";
var chat_url_buffer: [512]u8 = undefined;
var chat_url_len: usize = 0;
var chat_url_ready = std.atomic.Value(bool).init(false);

/// The Codex responses endpoint, as a stable borrowed slice.
///
/// fx's contract hands back a borrowed URL with no allocator, so the overridden
/// form is rendered once into static storage. The default needs no storage at
/// all because it is known at compile time.
pub fn chatUrl() []const u8 {
    const base = config.backendBaseUrl();
    if (std.mem.eql(u8, base, config.default_backend_base_url)) return default_chat_url;
    if (chat_url_ready.load(.seq_cst)) return chat_url_buffer[0..chat_url_len];

    const rendered = std.fmt.bufPrint(&chat_url_buffer, "{s}/codex/responses", .{base}) catch
        return default_chat_url;
    chat_url_len = rendered.len;
    chat_url_ready.store(true, .seq_cst);
    return chat_url_buffer[0..chat_url_len];
}

fn resolveChatUrl(_: ?*anyopaque, _: []const u8) []const u8 {
    return chatUrl();
}

// ---------------------------------------------------------------------------
// Agent stream
// ---------------------------------------------------------------------------

fn lookupReasoning(_: ?*anyopaque, call_id: []const u8) ?[]const u8 {
    return runtime.lookupReasoning(call_id);
}

fn recordReasoning(raw: ?*anyopaque, call_id: []const u8, items_json: []const u8) void {
    const alloc: *const Allocator = @ptrCast(@alignCast(raw.?));
    runtime.recordReasoning(alloc.*, call_id, items_json);
}

fn recordHead(_: ?*anyopaque, head: std.http.Client.Response.Head) void {
    runtime.recordRateLimit(head);
}

fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) anyerror![]u8 {
    return build_request.build(alloc, request, .{
        .reasoning_replay = .{ .lookup_fn = lookupReasoning },
    });
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) anyerror!stream_provider.Result {
    // The Codex backend needs the account id alongside the bearer, and it is
    // only available inside the token itself.
    const account_id = try jwt.accountIdAlloc(alloc, request.api_key);
    defer alloc.free(account_id);

    var sink_alloc = alloc;
    const outcome = try stream.execute(
        alloc,
        .{
            .url = chatUrl(),
            .auth = .{
                .access_token = request.api_key,
                .account_id = account_id,
                .session_id = request.session_id,
            },
            .payload = request.payload,
            .model = request.model,
            .content_capture_limit = request.content_capture_limit,
            .reasoning_sink = .{ .context = &sink_alloc, .record_fn = recordReasoning },
            .head_sink = .{ .record_fn = recordHead },
        },
        .{
            .ctx = request.callback_ctx,
            .on_content_chunk = request.on_content_chunk,
            .on_tool_start = request.on_tool_start,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
        },
        request.cancel_flag,
        request.delivery,
    );

    return .{
        .status = outcome.status,
        .completion = outcome.completion,
        .err_body = outcome.err_body,
        .retry_after_seconds = outcome.retry_after_seconds,
        .ownership = .owned,
    };
}

// ---------------------------------------------------------------------------
// Model catalog
// ---------------------------------------------------------------------------

/// Fetches the catalog using the stored Codex credential.
///
/// fx passes its own catalog endpoint and access in `input`; both are Gateway
/// concepts and are deliberately ignored here.
fn fetchCatalog(alloc: Allocator, cancel_flag: ?*std.atomic.Value(bool)) !std.ArrayList(codex_model_catalog.ModelCatalogEntry) {
    var credential = (try auth.currentCredential(alloc, builtin_gateway.oauth_transport_provider)) orelse
        return error.AuthenticationRejected;
    defer credential.deinit(alloc);

    const url = try config.modelsUrlAlloc(alloc);
    defer alloc.free(url);

    var response = try http.getJson(alloc, url, .{
        .access_token = credential.access_token,
        .account_id = credential.account_id,
    }, cancel_flag);
    defer response.deinit(alloc);

    if (response.status != .ok) {
        return if (response.status == .unauthorized or response.status == .forbidden)
            error.AuthenticationRejected
        else
            error.Unavailable;
    }
    return codex_model_catalog.parse(alloc, response.body);
}

fn modelCatalogFetch(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const catalog = fetchCatalog(alloc, input.cancel_flag) catch |err| return .{
        .failure = failureFor(err),
    };
    return .{ .catalog = catalog };
}

fn cliModelCatalogFetch(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    var catalog = fetchCatalog(alloc, input.cancel_flag) catch |err| return .{
        .failure = .{
            .access = .init(input.access),
            .anonymous_fallback_used = false,
            .failure = failureFor(err),
        },
    };
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{
        .failure = .{
            .access = .init(input.access),
            .anonymous_fallback_used = false,
            .failure = .{ .category = .resource_exhausted },
        },
    };
    return .{ .loaded = .{
        .ids = ids,
        .provenance = .{ .access = .init(input.access) },
    } };
}

fn failureFor(err: anyerror) model_catalog.Failure {
    return switch (err) {
        error.AuthenticationRejected => .{ .category = .authentication, .http_status = .unauthorized },
        error.OutOfMemory => .{ .category = .resource_exhausted },
        error.Cancelled => .{ .category = .cancellation },
        error.MalformedResponse => .{ .category = .malformed_response },
        else => .{ .category = .transport, .retryable = true },
    };
}

// ---------------------------------------------------------------------------
// Credits
// ---------------------------------------------------------------------------

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return codex_credits.snapshot(alloc, runtime.rateLimitSnapshot());
}

// ---------------------------------------------------------------------------
// Web search
// ---------------------------------------------------------------------------

/// Codex exposes no Gateway-style search worker, so web search is reported as
/// unavailable rather than silently routed somewhere that would bill elsewhere.
fn preferredBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
    return null;
}

fn executeWebSearch(
    _: ?*anyopaque,
    _: Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse {
    return error.WebSearchUnavailable;
}

// ---------------------------------------------------------------------------

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

pub const provider = gateway_provider.Provider{
    .agent_stream = agent_stream_provider,
    // Plain HTTP with no Gateway semantics, so fx's own transport is reused
    // rather than duplicated.
    .oauth_transport = builtin_gateway.oauth_transport_provider,
    .chat_url = .{ .resolve_fn = resolveChatUrl },
    .cli_model_catalog = .{ .fetch_fn = cliModelCatalogFetch },
    .credits = .{ .fetch_fn = fetchCredits },
    // Generation reconciliation is a Gateway billing concept with no Codex
    // equivalent.
    .generation_usage = generation_usage_provider.unavailable_provider,
    .web_search = .{
        .policy = .{},
        .preferred_backends_fn = preferredBackends,
        .execute_fn = executeWebSearch,
    },
    .model_catalog = .{ .fetch_fn = modelCatalogFetch },
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the default chat url needs no runtime storage" {
    try testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", chatUrl());
}

test "the provider advertises a Codex model by default" {
    try testing.expect(std.mem.startsWith(u8, default_model, "openai/"));
}

test "web search is reported as having no admitted backend" {
    const backends = try provider.web_search.preferredBackends();
    try testing.expect(backends == null);
    try testing.expectEqual(@as(usize, 0), provider.web_search.policy.backend_policies.len);
}

test "credits report an explanation before any turn has run" {
    const alloc = testing.allocator;
    var snapshot = provider.credits.fetch(alloc, .{ .credential = null, .tenant = null });
    defer snapshot.deinit(alloc);
    try testing.expect(snapshot.err_message != null);
}
