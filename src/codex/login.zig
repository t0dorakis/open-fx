const std = @import("std");
const builtin = @import("builtin");

const host = @import("../core/hosts/host.zig");
const io_mod = @import("../core/shared/io.zig");
const mcp_auth = @import("../core/mcp/mcp_auth.zig");
const oauth = @import("../core/auth/oauth.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");

const auth = @import("auth.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

const callback_read_bytes = 16 * 1024;
const callback_timeout_seconds: u32 = 300;

pub const LoginError = error{
    BrowserOpenFailed,
    InvalidCallback,
    CallbackTooLarge,
    StateMismatch,
    CallbackPortUnavailable,
    UnsupportedPlatform,
};

/// Builds the ChatGPT authorization URL.
///
/// `codex_cli_simplified_flow` and `id_token_add_organizations` are what make
/// the authorization server issue a token carrying Codex entitlements, so they
/// are not optional decoration.
pub fn authorizeUrlAlloc(alloc: Allocator, challenge: []const u8, state: []const u8) ![]u8 {
    const base = try config.authorizeUrlBaseAlloc(alloc);
    defer alloc.free(base);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(base);
    try writer.writeAll("?response_type=code");
    try writer.writeAll("&client_id=");
    try writeFormValue(writer, config.client_id);
    try writer.writeAll("&redirect_uri=");
    try writeFormValue(writer, config.redirect_uri);
    try writer.writeAll("&scope=");
    try writeFormValue(writer, config.scope);
    try writer.writeAll("&code_challenge=");
    try writeFormValue(writer, challenge);
    try writer.writeAll("&code_challenge_method=S256");
    try writer.writeAll("&state=");
    try writeFormValue(writer, state);
    try writer.writeAll("&id_token_add_organizations=true");
    try writer.writeAll("&codex_cli_simplified_flow=true");
    try writer.writeAll("&originator=");
    try writeFormValue(writer, config.originator());

    return out.toOwnedSlice();
}

fn writeFormValue(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (unreserved) {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

/// Exchanges an authorization code for tokens.
///
/// fx's oauth module has refresh and revoke but no exchange, so this is the one
/// grant that has to be built here. It reuses fx's transport, so proxy handling
/// and error mapping stay shared.
pub fn exchangeCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
) !oauth.TokenSet {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    const writer = &body.writer;

    try writer.writeAll("grant_type=authorization_code&client_id=");
    try writeFormValue(writer, config.client_id);
    try writer.writeAll("&code=");
    try writeFormValue(writer, code);
    try writer.writeAll("&code_verifier=");
    try writeFormValue(writer, verifier);
    try writer.writeAll("&redirect_uri=");
    try writeFormValue(writer, redirect_uri);

    const token_url = try config.tokenUrlAlloc(alloc);
    defer alloc.free(token_url);

    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = token_url,
        .payload = body.written(),
    });
    defer response.deinit(alloc);

    if (response.disposition != .accepted) return oauth.OAuthError.OAuthRequestFailed;
    return oauth.parseTokenSet(alloc, response.body);
}

/// Runs the browser sign-in and returns a stored-ready credential.
///
/// The listener is pinned to port 1455 because that is the only redirect the
/// authorization server accepts for this client; an ephemeral port would be
/// rejected before the user ever saw a page.
pub fn runBrowserLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !auth.Credential {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return LoginError.UnsupportedPlatform;
    }

    const io = io_mod.getIo();

    var verifier_buf: [64]u8 = undefined;
    var challenge_buf: [43]u8 = undefined;
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    // Fresh entropy from outside the process: the PKCE verifier is the only
    // thing standing between an intercepted code and a usable token.
    try io.randomSecure(&seed);
    var prng = std.Random.DefaultCsprng.init(seed);
    const pkce = mcp_auth.generatePkce(&verifier_buf, &challenge_buf, prng.random());

    var state_bytes: [16]u8 = undefined;
    try io.randomSecure(&state_bytes);
    var state_buf: [32]u8 = undefined;
    const state = std.fmt.bufPrint(&state_buf, "{x}", .{&state_bytes}) catch unreachable;

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", config.callback_port);
    var listener = address.listen(io, .{ .reuse_address = true }) catch
        return LoginError.CallbackPortUnavailable;
    defer listener.deinit(io);

    const url = try authorizeUrlAlloc(alloc, pkce.challenge, state);
    defer alloc.free(url);

    // FX_NO_OPEN_BROWSER opts out for headless and SSH sessions, matching how
    // fx's own sign-in behaves.
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = url_opener.open(alloc, url) catch false;
    }

    var response = try acceptCallback(alloc, &listener);
    defer response.deinit(alloc);

    if (!std.mem.eql(u8, response.state, state)) return LoginError.StateMismatch;

    var tokens = try exchangeCode(alloc, transport, response.code, pkce.verifier, config.redirect_uri);
    defer tokens.deinit(alloc);

    return auth.credentialFromTokenSet(alloc, tokens, io_mod.milliTimestamp());
}

fn acceptCallback(
    alloc: Allocator,
    listener: *std.Io.net.Server,
) !mcp_auth.AuthorizationResponse {
    var stream = try listener.accept(io_mod.getIo());
    defer stream.close(io_mod.getIo());

    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [callback_read_bytes]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request_bytes.len) {
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return LoginError.InvalidCallback,
            else => return err,
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
    }
    if (request_len == request_bytes.len) return LoginError.CallbackTooLarge;

    const line_end = std.mem.find(u8, request_bytes[0..request_len], "\r\n") orelse
        return LoginError.InvalidCallback;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) return LoginError.InvalidCallback;

    const target_end = std.mem.findScalarPos(u8, request_line, 4, ' ') orelse
        return LoginError.InvalidCallback;
    const target = request_line[4..target_end];
    if (!std.mem.startsWith(u8, target, "/auth/callback?")) return LoginError.InvalidCallback;

    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &writer_buffer);
    try writer.interface.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 46\r\n" ++
            "Connection: close\r\n\r\n" ++
            "Signed in to Codex. You can return to fx now.",
    );
    try writer.interface.flush();

    return mcp_auth.parseAuthorizationRedirect(alloc, target);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the authorization url carries every parameter the flow depends on" {
    const alloc = testing.allocator;
    const url = try authorizeUrlAlloc(alloc, "challenge123", "state456");
    defer alloc.free(url);

    try testing.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/oauth/authorize?"));
    try testing.expect(std.mem.find(u8, url, "response_type=code") != null);
    try testing.expect(std.mem.find(u8, url, "code_challenge=challenge123") != null);
    try testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.find(u8, url, "state=state456") != null);
    // These two are what make the issued token carry Codex entitlements.
    try testing.expect(std.mem.find(u8, url, "id_token_add_organizations=true") != null);
    try testing.expect(std.mem.find(u8, url, "codex_cli_simplified_flow=true") != null);
    try testing.expect(std.mem.find(u8, url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
}

test "the redirect uri is percent encoded rather than injected raw" {
    const alloc = testing.allocator;
    const url = try authorizeUrlAlloc(alloc, "c", "s");
    defer alloc.free(url);
    try testing.expect(std.mem.find(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);
    // A raw redirect would terminate the query early and break the flow.
    try testing.expect(std.mem.find(u8, url, "redirect_uri=http://") == null);
}

test "form encoding escapes reserved characters and leaves unreserved ones alone" {
    const alloc = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFormValue(&out.writer, "a-b_c.d~e f/g&h=i");
    try testing.expectEqualStrings("a-b_c.d~e%20f%2Fg%26h%3Di", out.written());
}

test "the exchange body is a well formed authorization_code grant" {
    const alloc = testing.allocator;
    const Fake = struct {
        var captured: [512]u8 = undefined;
        var captured_len: usize = 0;

        fn execute(_: ?*anyopaque, inner: Allocator, request: oauth_transport.Request) anyerror!oauth_transport.Response {
            const payload = request.payload orelse "";
            captured_len = @min(payload.len, captured.len);
            @memcpy(captured[0..captured_len], payload[0..captured_len]);
            const body =
                \\{"access_token":"a.b.c","refresh_token":"rt","expires_in":3600,"token_type":"Bearer","scope":"openid"}
            ;
            return .{ .disposition = .accepted, .body = try inner.dupe(u8, body) };
        }
    };

    var tokens = try exchangeCode(
        alloc,
        .{ .execute_fn = Fake.execute },
        "the code",
        "the verifier",
        config.redirect_uri,
    );
    defer tokens.deinit(alloc);

    const sent = Fake.captured[0..Fake.captured_len];
    try testing.expect(std.mem.find(u8, sent, "grant_type=authorization_code") != null);
    try testing.expect(std.mem.find(u8, sent, "code=the%20code") != null);
    try testing.expect(std.mem.find(u8, sent, "code_verifier=the%20verifier") != null);
    try testing.expectEqualStrings("a.b.c", tokens.access_token);
    try testing.expectEqualStrings("rt", tokens.refresh_token.?);
}

test "a rejected exchange surfaces as a request failure" {
    const alloc = testing.allocator;
    const Fake = struct {
        fn execute(_: ?*anyopaque, inner: Allocator, _: oauth_transport.Request) anyerror!oauth_transport.Response {
            return .{ .disposition = .rejected, .body = try inner.dupe(u8, "{\"error\":\"invalid_grant\"}") };
        }
    };
    try testing.expectError(oauth.OAuthError.OAuthRequestFailed, exchangeCode(
        alloc,
        .{ .execute_fn = Fake.execute },
        "c",
        "v",
        config.redirect_uri,
    ));
}
