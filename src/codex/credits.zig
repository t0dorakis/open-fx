const std = @import("std");

const output_contracts = @import("../core/output/output_contracts.zig");
const runtime_mod = @import("runtime.zig");

const Allocator = std.mem.Allocator;

/// Renders the Codex rate-limit window as fx's credits snapshot.
///
/// A ChatGPT subscription has no credit balance to report, so the usage window
/// stands in for one: it is the quantity that actually runs out, and fx already
/// has a place to show it.
pub fn snapshot(alloc: Allocator, limit: runtime_mod.RateLimit) output_contracts.CreditsSnapshot {
    if (!limit.known) {
        return .{
            .err_message = alloc.dupe(
                u8,
                "Codex usage is reported on the first model response; run a prompt first.",
            ) catch null,
        };
    }

    var result: output_contracts.CreditsSnapshot = .{};
    if (limit.plan_len > 0) result.plan = alloc.dupe(u8, limit.planName()) catch null;

    if (limit.used_percent) |used| {
        result.used = std.fmt.allocPrint(alloc, "{d:.0}% of limit", .{used}) catch null;
        const remaining = @max(0, 100 - used);
        result.balance = if (limit.reset_after_seconds) |seconds|
            std.fmt.allocPrint(alloc, "{d:.0}% remaining, resets in {d}h", .{
                remaining,
                seconds / 3600,
            }) catch null
        else
            std.fmt.allocPrint(alloc, "{d:.0}% remaining", .{remaining}) catch null;
    }
    return result;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn limitWithPlan(plan: []const u8, used: ?f64, reset: ?u64) runtime_mod.RateLimit {
    var limit = runtime_mod.RateLimit{ .known = true, .used_percent = used, .reset_after_seconds = reset };
    @memcpy(limit.plan[0..plan.len], plan);
    limit.plan_len = plan.len;
    return limit;
}

test "an unknown window explains itself instead of reporting a false zero" {
    const alloc = testing.allocator;
    var result = snapshot(alloc, .{});
    defer result.deinit(alloc);
    try testing.expect(result.balance == null);
    try testing.expect(result.err_message != null);
}

test "a known window reports plan, usage and reset" {
    const alloc = testing.allocator;
    var result = snapshot(alloc, limitWithPlan("team", 12, 7200));
    defer result.deinit(alloc);

    try testing.expectEqualStrings("team", result.plan.?);
    try testing.expectEqualStrings("12% of limit", result.used.?);
    try testing.expectEqualStrings("88% remaining, resets in 2h", result.balance.?);
}

test "a window with no reset time still reports remaining" {
    const alloc = testing.allocator;
    var result = snapshot(alloc, limitWithPlan("pro", 40, null));
    defer result.deinit(alloc);
    try testing.expectEqualStrings("60% remaining", result.balance.?);
}

test "usage over the limit clamps to zero rather than going negative" {
    const alloc = testing.allocator;
    var result = snapshot(alloc, limitWithPlan("free", 130, null));
    defer result.deinit(alloc);
    try testing.expectEqualStrings("0% remaining", result.balance.?);
}
