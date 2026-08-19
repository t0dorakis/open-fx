const std = @import("std");

const Allocator = std.mem.Allocator;

/// Namespaced claim in a ChatGPT access token that carries account metadata.
pub const auth_claim_path = "https://api.openai.com/auth";

/// Largest access token we will decode. Observed tokens are ~1.7 KB; this is a
/// generous bound that still rejects anything absurd.
const max_token_bytes: usize = 32 * 1024;

pub const JwtError = error{
    MalformedToken,
    ClaimMissing,
};

/// Decodes the payload of a JWT without verifying its signature.
///
/// Verification belongs to the authorization server. These claims are read only
/// to learn the account id and to render status output, never to make a trust
/// decision, so an unverified decode is sufficient and avoids carrying a JWKS
/// client for no benefit.
///
/// Caller owns the returned parsed value and must call `deinit`.
pub fn decodePayload(
    alloc: Allocator,
    token: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (token.len == 0 or token.len > max_token_bytes) return JwtError.MalformedToken;

    const first = std.mem.findScalar(u8, token, '.') orelse return JwtError.MalformedToken;
    const rest = token[first + 1 ..];
    const second = std.mem.findScalar(u8, rest, '.') orelse return JwtError.MalformedToken;
    const payload_b64 = rest[0..second];
    if (payload_b64.len == 0) return JwtError.MalformedToken;
    // A third dot would mean this is not a well formed JWT.
    if (std.mem.findScalar(u8, rest[second + 1 ..], '.') != null) return JwtError.MalformedToken;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return JwtError.MalformedToken;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    decoder.decode(decoded, payload_b64) catch return JwtError.MalformedToken;

    return std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch
        JwtError.MalformedToken;
}

fn claimObject(payload: std.json.Value) ?std.json.ObjectMap {
    if (payload != .object) return null;
    const claim = payload.object.get(auth_claim_path) orelse return null;
    if (claim != .object) return null;
    return claim.object;
}

fn claimString(payload: std.json.Value, key: []const u8) ?[]const u8 {
    const claim = claimObject(payload) orelse return null;
    const value = claim.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

/// The ChatGPT account id the Codex backend requires as a request header.
///
/// It is only available inside the access token, not in the token endpoint
/// response, so it has to be decoded rather than read off the wire.
/// Caller owns the returned slice.
pub fn accountIdAlloc(alloc: Allocator, token: []const u8) ![]u8 {
    var parsed = try decodePayload(alloc, token);
    defer parsed.deinit();
    const account_id = claimString(parsed.value, "chatgpt_account_id") orelse
        return JwtError.ClaimMissing;
    return alloc.dupe(u8, account_id);
}

pub const AccountSummary = struct {
    account_id: ?[]u8 = null,
    plan: ?[]u8 = null,

    pub fn deinit(self: *AccountSummary, alloc: Allocator) void {
        if (self.account_id) |value| alloc.free(value);
        if (self.plan) |value| alloc.free(value);
        self.* = .{};
    }
};

/// Best effort account description for status output. Missing fields are left
/// null rather than treated as an error; nothing here is required to work.
pub fn accountSummaryAlloc(alloc: Allocator, token: []const u8) !AccountSummary {
    var parsed = try decodePayload(alloc, token);
    defer parsed.deinit();

    var summary: AccountSummary = .{};
    errdefer summary.deinit(alloc);
    if (claimString(parsed.value, "chatgpt_account_id")) |value| {
        summary.account_id = try alloc.dupe(u8, value);
    }
    if (claimString(parsed.value, "chatgpt_plan_type")) |value| {
        summary.plan = try alloc.dupe(u8, value);
    }
    return summary;
}

fn testToken(alloc: Allocator, payload_json: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = "eyJhbGciOiJub25lIn0";
    const payload_len = encoder.calcSize(payload_json.len);
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    _ = encoder.encode(payload, payload_json);
    return std.fmt.allocPrint(alloc, "{s}.{s}.signature", .{ header, payload });
}

test "accountIdAlloc reads the namespaced claim" {
    const alloc = std.testing.allocator;
    const token = try testToken(
        alloc,
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}
        ,
    );
    defer alloc.free(token);

    const account_id = try accountIdAlloc(alloc, token);
    defer alloc.free(account_id);
    try std.testing.expectEqualStrings("acct_123", account_id);
}

test "accountIdAlloc reports a missing claim rather than guessing" {
    const alloc = std.testing.allocator;
    const token = try testToken(alloc, "{\"email\":\"user@example.test\"}");
    defer alloc.free(token);
    try std.testing.expectError(JwtError.ClaimMissing, accountIdAlloc(alloc, token));
}

test "accountIdAlloc rejects tokens that are not JWTs" {
    const alloc = std.testing.allocator;
    // A platform API key is the realistic wrong input here: it authenticates,
    // but against API billing rather than the subscription.
    try std.testing.expectError(JwtError.MalformedToken, accountIdAlloc(alloc, "sk-proj-abc"));
    try std.testing.expectError(JwtError.MalformedToken, accountIdAlloc(alloc, ""));
    try std.testing.expectError(JwtError.MalformedToken, accountIdAlloc(alloc, "a.b"));
    try std.testing.expectError(JwtError.MalformedToken, accountIdAlloc(alloc, "a.b.c.d"));
    try std.testing.expectError(JwtError.MalformedToken, accountIdAlloc(alloc, "a.!!!.c"));
}

test "accountSummaryAlloc leaves absent fields null" {
    const alloc = std.testing.allocator;
    const token = try testToken(
        alloc,
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123","chatgpt_plan_type":"team"}}
        ,
    );
    defer alloc.free(token);

    var full = try accountSummaryAlloc(alloc, token);
    defer full.deinit(alloc);
    try std.testing.expectEqualStrings("acct_123", full.account_id.?);
    try std.testing.expectEqualStrings("team", full.plan.?);

    const partial_token = try testToken(
        alloc,
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}
        ,
    );
    defer alloc.free(partial_token);
    var partial = try accountSummaryAlloc(alloc, partial_token);
    defer partial.deinit(alloc);
    try std.testing.expectEqualStrings("acct_123", partial.account_id.?);
    try std.testing.expect(partial.plan == null);
}
