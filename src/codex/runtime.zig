const std = @import("std");

const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

/// Upper bound on remembered tool calls. A long session makes many calls, but
/// only the recent ones are ever replayed, so the oldest are dropped first.
const max_reasoning_entries: usize = 512;

const ReasoningEntry = struct {
    call_id: []u8,
    items_json: []u8,

    fn deinit(self: *ReasoningEntry, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.items_json);
        self.* = undefined;
    }
};

/// Rate-limit state scraped from Codex response headers.
///
/// A ChatGPT subscription has no credit balance, so this window is what fx
/// reports in place of one: it is the thing that actually runs out.
pub const RateLimit = struct {
    plan: [64]u8 = undefined,
    plan_len: usize = 0,
    used_percent: ?f64 = null,
    reset_after_seconds: ?u64 = null,
    known: bool = false,

    pub fn planName(self: *const RateLimit) []const u8 {
        return self.plan[0..self.plan_len];
    }
};

/// State shared between the Codex providers for the life of the process.
///
/// The reasoning store exists because fx's message history has no slot for
/// provider reasoning: it is captured as a turn streams and spliced back into
/// the next request. The rate-limit snapshot exists because Codex reports usage
/// on chat response headers rather than at a credits endpoint.
pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    alloc: ?Allocator = null,
    reasoning: std.ArrayList(ReasoningEntry) = .empty,
    rate_limit: RateLimit = .{},

    pub fn deinit(self: *Runtime) void {
        const alloc = self.alloc orelse return;
        for (self.reasoning.items) |*entry| entry.deinit(alloc);
        self.reasoning.deinit(alloc);
        self.reasoning = .empty;
        self.alloc = null;
    }

    /// Remembers the reasoning that preceded `call_id`. Silently does nothing
    /// on allocation failure: replay is an optimisation, never a correctness
    /// requirement, and a failed turn would be a far worse outcome.
    pub fn recordReasoning(self: *Runtime, alloc: Allocator, call_id: []const u8, items_json: []const u8) void {
        if (call_id.len == 0 or items_json.len == 0) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.alloc = alloc;
        if (self.findIndex(call_id)) |index| {
            const replacement = alloc.dupe(u8, items_json) catch return;
            alloc.free(self.reasoning.items[index].items_json);
            self.reasoning.items[index].items_json = replacement;
            return;
        }

        const owned_call_id = alloc.dupe(u8, call_id) catch return;
        const owned_items = alloc.dupe(u8, items_json) catch {
            alloc.free(owned_call_id);
            return;
        };
        self.reasoning.append(alloc, .{
            .call_id = owned_call_id,
            .items_json = owned_items,
        }) catch {
            alloc.free(owned_call_id);
            alloc.free(owned_items);
            return;
        };

        while (self.reasoning.items.len > max_reasoning_entries) {
            var evicted = self.reasoning.orderedRemove(0);
            evicted.deinit(alloc);
        }
    }

    /// Returns a copy of the stored reasoning JSON for a call, owned by the
    /// caller.
    ///
    /// A copy and not a pointer into the store: this runtime is shared by every
    /// agent in the process, and subagents stream in parallel. A borrowed slice
    /// stays valid only until some other thread evicts or replaces that entry,
    /// and the borrower would then splice freed memory into its next request.
    /// Holding the lock across the caller's use is not an option either, since
    /// the caller is serialising a whole request while it reads.
    pub fn lookupReasoningAlloc(self: *Runtime, alloc: Allocator, call_id: []const u8) ?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.findIndex(call_id) orelse return null;
        return alloc.dupe(u8, self.reasoning.items[index].items_json) catch null;
    }

    fn findIndex(self: *Runtime, call_id: []const u8) ?usize {
        for (self.reasoning.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.call_id, call_id)) return index;
        }
        return null;
    }

    pub fn recordRateLimit(self: *Runtime, head: std.http.Client.Response.Head) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var it = head.iterateHeaders();
        var seen = false;
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-codex-plan-type")) {
                const len = @min(header.value.len, self.rate_limit.plan.len);
                @memcpy(self.rate_limit.plan[0..len], header.value[0..len]);
                self.rate_limit.plan_len = len;
                seen = true;
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-used-percent")) {
                self.rate_limit.used_percent = std.fmt.parseFloat(f64, std.mem.trim(u8, header.value, " ")) catch null;
                seen = true;
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-reset-after-seconds")) {
                self.rate_limit.reset_after_seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " "), 10) catch null;
                seen = true;
            }
        }
        if (!seen) return;
        self.rate_limit.known = true;
        persistRateLimit(self.rate_limit);
    }

    pub fn rateLimitSnapshot(self: *Runtime) RateLimit {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.rate_limit.known) return self.rate_limit;
        // `fx credits` runs in its own process and never sees a stream, so the
        // window has to come off disk to be reportable at all.
        return loadPersistedRateLimit() orelse self.rate_limit;
    }
};

const usage_file_name = "codex-usage.json";

/// Records the window where a later process can read it.
///
/// Best effort throughout: usage reporting must never be able to fail a turn.
fn persistRateLimit(limit: RateLimit) void {
    if (!limit.known) return;
    const alloc = std.heap.c_allocator;
    const home = io_mod.getenv("HOME") orelse return;

    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "{{\"plan\":\"{s}\",\"used_percent\":{d:.2},\"reset_after_seconds\":{d}}}\n",
        .{ limit.planName(), limit.used_percent orelse -1, limit.reset_after_seconds orelse 0 },
    ) catch return;

    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return,
    };
    defer home_dir.close();
    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name) catch return;
    defer fx_dir.close();
    io_mod.durableReplaceVerified(alloc, &fx_dir, usage_file_name, text) catch return;
}

fn loadPersistedRateLimit() ?RateLimit {
    const alloc = std.heap.c_allocator;
    const home = io_mod.getenv("HOME") orelse return null;

    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return null;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer fx_dir.close(io_mod.getIo());

    var file = fx_dir.openFile(io_mod.getIo(), usage_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch return null;
    defer file.close(io_mod.getIo());

    const bytes = io_mod.readFileToEnd(alloc, &file, 4096) catch return null;
    defer alloc.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var limit = RateLimit{ .known = true };
    if (parsed.value.object.get("plan")) |value| {
        if (value == .string) {
            const len = @min(value.string.len, limit.plan.len);
            @memcpy(limit.plan[0..len], value.string[0..len]);
            limit.plan_len = len;
        }
    }
    if (parsed.value.object.get("used_percent")) |value| {
        const used = switch (value) {
            .float => value.float,
            .integer => @as(f64, @floatFromInt(value.integer)),
            else => -1,
        };
        if (used >= 0) limit.used_percent = used;
    }
    if (parsed.value.object.get("reset_after_seconds")) |value| {
        if (value == .integer and value.integer > 0) limit.reset_after_seconds = @intCast(value.integer);
    }
    return limit;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "reasoning round trips by call id" {
    const alloc = testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit();

    runtime.recordReasoning(alloc, "call_1", "[{\"type\":\"reasoning\"}]");
    const found = runtime.lookupReasoningAlloc(alloc, "call_1").?;
    defer alloc.free(found);
    try testing.expectEqualStrings("[{\"type\":\"reasoning\"}]", found);
    try testing.expect(runtime.lookupReasoningAlloc(alloc, "call_2") == null);
}

test "recording the same call twice replaces rather than duplicates" {
    const alloc = testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit();

    runtime.recordReasoning(alloc, "call_1", "[1]");
    runtime.recordReasoning(alloc, "call_1", "[2]");
    const replaced = runtime.lookupReasoningAlloc(alloc, "call_1").?;
    defer alloc.free(replaced);
    try testing.expectEqualStrings("[2]", replaced);
    try testing.expectEqual(@as(usize, 1), runtime.reasoning.items.len);
}

test "empty inputs are ignored" {
    const alloc = testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit();

    runtime.recordReasoning(alloc, "", "[1]");
    runtime.recordReasoning(alloc, "call_1", "");
    try testing.expectEqual(@as(usize, 0), runtime.reasoning.items.len);
}

test "the store stays bounded so a long session cannot grow without limit" {
    const alloc = testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit();

    var buf: [32]u8 = undefined;
    var index: usize = 0;
    while (index < max_reasoning_entries + 10) : (index += 1) {
        const call_id = try std.fmt.bufPrint(&buf, "call_{d}", .{index});
        runtime.recordReasoning(alloc, call_id, "[1]");
    }
    try testing.expectEqual(max_reasoning_entries, runtime.reasoning.items.len);
    // The oldest were evicted; the newest survive.
    try testing.expect(runtime.lookupReasoningAlloc(alloc, "call_0") == null);
    const newest = runtime.lookupReasoningAlloc(alloc, "call_521").?;
    defer alloc.free(newest);
    try testing.expectEqualStrings("[1]", newest);
}

test "rate limit starts unknown" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try testing.expect(!runtime.rateLimitSnapshot().known);
}
