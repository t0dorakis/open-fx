const std = @import("std");

const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const oauth = @import("../core/auth/oauth.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const secret = @import("../core/auth/secret.zig");
const config = @import("config.zig");
const jwt = @import("jwt.zig");

const Allocator = std.mem.Allocator;

const schema_version: i64 = 1;
const max_credential_file_bytes: usize = 64 * 1024;
const mutation_lock_deadline_ms: u64 = 2000;

pub const CredentialError = error{
    MalformedCredential,
    HomeNotSet,
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

/// A ChatGPT OAuth credential for the Codex backend.
///
/// Stored separately from fx's own Vercel session so that the Gateway path
/// keeps working untouched and neither credential can invalidate the other.
pub const Credential = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    /// Decoded from the access token; the Codex backend requires it as a header.
    account_id: []u8,

    pub fn deinit(self: *Credential, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    /// True once the token is inside the refresh window. Deliberately earlier
    /// than actual expiry: a turn can stream for minutes, so starting on a
    /// token that is merely valid right now risks it dying mid-stream.
    pub fn needsRefresh(self: Credential, now_ms: i64) bool {
        return self.expires_at_ms -| config.refresh_skew_ms <= now_ms;
    }

    pub fn clone(self: Credential, alloc: Allocator) !Credential {
        const access_token = try alloc.dupe(u8, self.access_token);
        errdefer secret.zeroAndFree(alloc, access_token);
        const refresh_token = try alloc.dupe(u8, self.refresh_token);
        errdefer secret.zeroAndFree(alloc, refresh_token);
        const account_id = try alloc.dupe(u8, self.account_id);
        return .{
            .access_token = access_token,
            .refresh_token = refresh_token,
            .expires_at_ms = self.expires_at_ms,
            .account_id = account_id,
        };
    }
};

/// Builds a credential from a freshly issued token set, taking ownership of
/// nothing: the caller still owns `tokens`.
pub fn credentialFromTokenSet(alloc: Allocator, tokens: oauth.TokenSet, now_ms: i64) !Credential {
    const refresh_token = tokens.refresh_token orelse return CredentialError.MalformedCredential;
    const account_id = jwt.accountIdAlloc(alloc, tokens.access_token) catch
        return CredentialError.MalformedCredential;
    errdefer alloc.free(account_id);

    const access_token = try alloc.dupe(u8, tokens.access_token);
    errdefer secret.zeroAndFree(alloc, access_token);
    const owned_refresh = try alloc.dupe(u8, refresh_token);

    return .{
        .access_token = access_token,
        .refresh_token = owned_refresh,
        .expires_at_ms = try oauth.expiry_timestamp_ms(now_ms, tokens.expires_in),
        .account_id = account_id,
    };
}

/// The OAuth metadata the Codex token endpoint needs.
///
/// `auth.openai.com` publishes a discovery document, but nothing in it is
/// needed beyond the token endpoint, and hard-coding avoids a network round
/// trip on every refresh. Caller owns the result.
pub fn tokenMetadata(alloc: Allocator) !oauth.Metadata {
    const issuer = try alloc.dupe(u8, config.authBaseUrl());
    errdefer alloc.free(issuer);
    const token_endpoint = try config.tokenUrlAlloc(alloc);
    errdefer alloc.free(token_endpoint);
    // Codex does not use RFC 8628 device authorization; its device flow lives
    // on a different, non-standard endpoint handled elsewhere.
    const device_endpoint = try alloc.dupe(u8, "");
    return .{
        .issuer = issuer,
        .device_authorization_endpoint = device_endpoint,
        .token_endpoint = token_endpoint,
    };
}

/// Exchanges the refresh token for a fresh credential.
///
/// The authorization server rotates refresh tokens: the response carries a new
/// one and the previous one stops working. Callers must persist the result, and
/// must not run two refreshes concurrently.
pub fn refresh(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    credential: Credential,
    now_ms: i64,
) !Credential {
    var metadata = try tokenMetadata(alloc);
    defer metadata.deinit(alloc);

    var tokens = try oauth.refreshToken(
        alloc,
        transport,
        metadata,
        config.client_id,
        credential.refresh_token,
    );
    defer tokens.deinit(alloc);

    return credentialFromTokenSet(alloc, tokens, now_ms);
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

pub fn stringify(alloc: Allocator, credential: Credential) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"version\":");
    try std.json.Stringify.value(schema_version, .{}, writer);
    try writer.writeAll(",\"access_token\":");
    try std.json.Stringify.value(credential.access_token, .{}, writer);
    try writer.writeAll(",\"refresh_token\":");
    try std.json.Stringify.value(credential.refresh_token, .{}, writer);
    try writer.writeAll(",\"expires_at_ms\":");
    try std.json.Stringify.value(credential.expires_at_ms, .{}, writer);
    try writer.writeAll(",\"account_id\":");
    try std.json.Stringify.value(credential.account_id, .{}, writer);
    try writer.writeAll("}\n");

    return out.toOwnedSlice();
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Credential {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return CredentialError.MalformedCredential;
    defer parsed.deinit();
    if (parsed.value != .object) return CredentialError.MalformedCredential;
    const object = parsed.value.object;

    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try dupeRequiredString(alloc, object, "account_id");
    errdefer alloc.free(account_id);

    const expires_value = object.get("expires_at_ms") orelse
        return CredentialError.MalformedCredential;
    if (expires_value != .integer) return CredentialError.MalformedCredential;

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_value.integer,
        .account_id = account_id,
    };
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return CredentialError.MalformedCredential;
    if (value != .string or value.string.len == 0) return CredentialError.MalformedCredential;
    return alloc.dupe(u8, value.string);
}

/// Reads the stored credential, or null when there is none.
///
/// A missing or unreadable file is not an error: it means "not signed in to
/// Codex", which is the normal state for a fork still using the Gateway.
pub fn load(alloc: Allocator) !?Credential {
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("codex", "credential load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) !?Credential {
    var file = fx_dir.openFile(io_mod.getIo(), config.credential_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("codex", "credential load failed step=open err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    // A credential readable by other users is treated as absent rather than
    // used, matching how fx handles its own auth file.
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("codex", "credential load failed step=permissions err=InsecureCredentialFile", .{});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_credential_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("codex", "credential load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

/// Exclusive access to the credential file for the duration of a mutation.
///
/// fx runs subagents in parallel, and the refresh token rotates, so two
/// concurrent refreshes would race and the loser would persist a token the
/// server has already replaced. The lock makes the read-refresh-write sequence
/// atomic across processes.
pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Credential {
        return loadFromDir(alloc, &self.fx_dir.dir);
    }

    pub fn save(self: *Mutation, alloc: Allocator, credential: Credential) !void {
        const text = try stringify(alloc, credential);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(
            alloc,
            &self.fx_dir,
            config.credential_file_name,
            text,
        );
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), config.credential_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        io_mod.syncVerifiedDir(self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return CredentialError.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    errdefer fx_dir.close();

    var lock = try io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        config.mutation_lock_file_name,
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();

    return .{ .fx_dir = fx_dir, .lock = lock };
}

pub fn save(alloc: Allocator, credential: Credential) !void {
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, credential);
}

/// Returns a credential that is good for at least the refresh window,
/// refreshing and persisting first if it is not.
///
/// The whole sequence runs under the mutation lock so that the rotated refresh
/// token is written before any other process can read the old one.
pub fn currentCredential(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    var existing = (try load(alloc)) orelse return null;
    const now_ms = io_mod.milliTimestamp();
    if (!existing.needsRefresh(now_ms)) return existing;
    defer existing.deinit(alloc);

    var mutation = try beginMutation();
    defer mutation.deinit();

    // Re-read under the lock: another process may have refreshed while this one
    // was waiting, in which case its token is the live one and ours is stale.
    var locked = (try mutation.load(alloc)) orelse return null;
    if (!locked.needsRefresh(io_mod.milliTimestamp())) return locked;
    defer locked.deinit(alloc);

    var refreshed = try refresh(alloc, transport, locked, io_mod.milliTimestamp());
    errdefer refreshed.deinit(alloc);
    // Persist before returning: the previous refresh token is already dead
    // server side, so losing the new one would strand the login.
    try mutation.save(alloc, refreshed);
    return refreshed;
}

// ---------------------------------------------------------------------------

fn testCredential(alloc: Allocator, expires_at_ms: i64) !Credential {
    return .{
        .access_token = try alloc.dupe(u8, "header.payload.signature"),
        .refresh_token = try alloc.dupe(u8, "rt.1.example"),
        .expires_at_ms = expires_at_ms,
        .account_id = try alloc.dupe(u8, "acct_123"),
    };
}

test "credential round trips through its persisted form" {
    const alloc = std.testing.allocator;
    var original = try testCredential(alloc, 1787995078541);
    defer original.deinit(alloc);

    const text = try stringify(alloc, original);
    defer alloc.free(text);

    var restored = try parse(alloc, text);
    defer restored.deinit(alloc);

    try std.testing.expectEqualStrings(original.access_token, restored.access_token);
    try std.testing.expectEqualStrings(original.refresh_token, restored.refresh_token);
    try std.testing.expectEqualStrings(original.account_id, restored.account_id);
    try std.testing.expectEqual(original.expires_at_ms, restored.expires_at_ms);
}

test "parse rejects a credential missing any required field" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "{}",
        "[]",
        "not json",
        \\{"refresh_token":"r","expires_at_ms":1,"account_id":"a"}
        ,
        \\{"access_token":"a","expires_at_ms":1,"account_id":"a"}
        ,
        \\{"access_token":"a","refresh_token":"r","account_id":"a"}
        ,
        \\{"access_token":"a","refresh_token":"r","expires_at_ms":1}
        ,
        \\{"access_token":"","refresh_token":"r","expires_at_ms":1,"account_id":"a"}
        ,
        \\{"access_token":"a","refresh_token":"r","expires_at_ms":"soon","account_id":"a"}
        ,
    };
    for (cases) |case| {
        try std.testing.expectError(CredentialError.MalformedCredential, parse(alloc, case));
    }
}

test "needsRefresh fires inside the skew window, not at expiry" {
    const alloc = std.testing.allocator;
    var credential = try testCredential(alloc, 1_000_000);
    defer credential.deinit(alloc);

    // Comfortably valid.
    try std.testing.expect(!credential.needsRefresh(1_000_000 - config.refresh_skew_ms - 1));
    // Exactly on the skew boundary: refresh rather than gamble on a long stream.
    try std.testing.expect(credential.needsRefresh(1_000_000 - config.refresh_skew_ms));
    // Already expired.
    try std.testing.expect(credential.needsRefresh(1_000_001));
}

test "credentialFromTokenSet requires a rotated refresh token and a decodable account id" {
    const alloc = std.testing.allocator;

    const encoder = std.base64.url_safe_no_pad.Encoder;
    const claims =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_from_jwt"}}
    ;
    const payload = try alloc.alloc(u8, encoder.calcSize(claims.len));
    defer alloc.free(payload);
    _ = encoder.encode(payload, claims);
    const access = try std.fmt.allocPrint(alloc, "eyJhbGciOiJub25lIn0.{s}.sig", .{payload});
    defer alloc.free(access);

    {
        var tokens = oauth.TokenSet{
            .access_token = try alloc.dupe(u8, access),
            .refresh_token = try alloc.dupe(u8, "rt.2.rotated"),
            .expires_in = 864000,
            .scope = try alloc.dupe(u8, ""),
            .token_type = try alloc.dupe(u8, "Bearer"),
        };
        defer tokens.deinit(alloc);

        var credential = try credentialFromTokenSet(alloc, tokens, 1000);
        defer credential.deinit(alloc);
        try std.testing.expectEqualStrings("acct_from_jwt", credential.account_id);
        try std.testing.expectEqualStrings("rt.2.rotated", credential.refresh_token);
        try std.testing.expectEqual(@as(i64, 1000 + 864000 * 1000), credential.expires_at_ms);
    }

    {
        // A response without a refresh token would silently strand the login on
        // the next refresh, so it is rejected at the door.
        var tokens = oauth.TokenSet{
            .access_token = try alloc.dupe(u8, access),
            .refresh_token = null,
            .expires_in = 864000,
            .scope = try alloc.dupe(u8, ""),
            .token_type = try alloc.dupe(u8, "Bearer"),
        };
        defer tokens.deinit(alloc);
        try std.testing.expectError(
            CredentialError.MalformedCredential,
            credentialFromTokenSet(alloc, tokens, 1000),
        );
    }

    {
        var tokens = oauth.TokenSet{
            .access_token = try alloc.dupe(u8, "not-a-jwt"),
            .refresh_token = try alloc.dupe(u8, "rt.2"),
            .expires_in = 864000,
            .scope = try alloc.dupe(u8, ""),
            .token_type = try alloc.dupe(u8, "Bearer"),
        };
        defer tokens.deinit(alloc);
        try std.testing.expectError(
            CredentialError.MalformedCredential,
            credentialFromTokenSet(alloc, tokens, 1000),
        );
    }
}

test "tokenMetadata points at the Codex token endpoint" {
    const alloc = std.testing.allocator;
    var metadata = try tokenMetadata(alloc);
    defer metadata.deinit(alloc);
    try std.testing.expectEqualStrings("https://auth.openai.com/oauth/token", metadata.token_endpoint);
}
