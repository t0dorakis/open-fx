const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

/// ChatGPT/Codex OAuth application. A PKCE public client, so there is no
/// secret to protect and the id is safe to compile in.
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";

pub const default_auth_base_url = "https://auth.openai.com";
pub const default_backend_base_url = "https://chatgpt.com/backend-api";
pub const default_originator = "fx_codex";

const auth_base_url_env = "FX_CODEX_AUTH_BASE_URL";
const backend_base_url_env = "FX_CODEX_BACKEND_URL";
const originator_env = "FX_CODEX_ORIGINATOR";

/// The authorization server accepts only this registered redirect, so the
/// callback listener cannot move to another port.
pub const callback_port: u16 = 1455;
pub const redirect_uri = "http://localhost:1455/auth/callback";
pub const scope = "openid profile email offline_access";

/// The model catalog endpoint rejects a request without a client version.
pub const models_client_version = "0.0.0";

pub const credential_file_name = "codex-auth.json";
pub const mutation_lock_file_name = "codex-auth.lock";

/// Refresh this far ahead of expiry. A single turn can stream for minutes, so
/// a token that is merely valid at request time is not good enough to start on.
pub const refresh_skew_ms: i64 = 5 * 60 * 1000;

fn override(name: []const u8, fallback: []const u8) []const u8 {
    const value = io_mod.getenv(name) orelse return fallback;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) fallback else trimmed;
}

pub fn authBaseUrl() []const u8 {
    return override(auth_base_url_env, default_auth_base_url);
}

pub fn backendBaseUrl() []const u8 {
    return override(backend_base_url_env, default_backend_base_url);
}

/// Identifies this client to the Codex backend. A non-Codex originator is
/// accepted; this is deliberately not impersonating the official CLI.
pub fn originator() []const u8 {
    return override(originator_env, default_originator);
}

pub fn tokenUrlAlloc(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/oauth/token", .{authBaseUrl()});
}

pub fn authorizeUrlBaseAlloc(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/oauth/authorize", .{authBaseUrl()});
}

pub fn responsesUrlAlloc(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/codex/responses", .{backendBaseUrl()});
}

pub fn modelsUrlAlloc(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/codex/models?client_version={s}", .{
        backendBaseUrl(),
        models_client_version,
    });
}

test "endpoints derive from the configured base urls" {
    const alloc = std.testing.allocator;

    const token_url = try tokenUrlAlloc(alloc);
    defer alloc.free(token_url);
    try std.testing.expectEqualStrings("https://auth.openai.com/oauth/token", token_url);

    const responses_url = try responsesUrlAlloc(alloc);
    defer alloc.free(responses_url);
    try std.testing.expectEqualStrings(
        "https://chatgpt.com/backend-api/codex/responses",
        responses_url,
    );

    const models_url = try modelsUrlAlloc(alloc);
    defer alloc.free(models_url);
    try std.testing.expectEqualStrings(
        "https://chatgpt.com/backend-api/codex/models?client_version=0.0.0",
        models_url,
    );
}

test "redirect uri matches the port the callback listener must bind" {
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &buf,
        "http://localhost:{d}/auth/callback",
        .{callback_port},
    );
    try std.testing.expectEqualStrings(expected, redirect_uri);
}
