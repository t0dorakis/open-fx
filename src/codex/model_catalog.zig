const std = @import("std");

const model_catalog = @import("../core/gateway/model_catalog.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ModelCatalogEntry = model_catalog.ModelCatalogEntry;

/// Parses the Codex `/codex/models` payload into fx's catalog entries.
///
/// Only models the backend marks `visibility: "list"` are offered; the rest are
/// internal (for example `codex-auto-review`) and are not meant to be picked by
/// hand. Ordering mirrors the backend's own `priority`, so its preferred model
/// lands at the top of fx's picker.
pub fn parse(alloc: Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    var entries: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
        return error.MalformedResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;

    const models = parsed.value.object.get("models") orelse return error.MalformedResponse;
    if (models != .array) return error.MalformedResponse;

    for (models.array.items) |model| {
        const entry = (try parseEntry(alloc, model)) orelse continue;
        entries.append(alloc, entry) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, entry);
            return err;
        };
    }
    if (entries.items.len == 0) return error.MalformedResponse;

    std.mem.sort(ModelCatalogEntry, entries.items, {}, compareByReleasedDesc);
    return entries;
}

fn compareByReleasedDesc(_: void, a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.released != b.released) return a.released > b.released;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn parseEntry(alloc: Allocator, value: std.json.Value) !?ModelCatalogEntry {
    if (value != .object) return null;
    const object = value.object;

    const visibility = stringField(object, "visibility") orelse return null;
    if (!std.mem.eql(u8, visibility, "list")) return null;

    const slug = stringField(object, "slug") orelse return null;
    if (slug.len == 0) return null;

    var efforts = try parseEfforts(alloc, object.get("supported_reasoning_levels"));
    errdefer efforts.deinit(alloc);

    // fx namespaces catalog ids by provider, and its sorting groups by that
    // prefix, so keep the same convention.
    const id = try std.fmt.allocPrint(alloc, "openai/{s}", .{slug});
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);

    return .{
        .id = id,
        .model_type = model_type,
        // fx sorts by `released` descending; mirroring the backend's priority
        // preserves its intended order without inventing dates.
        .released = 10_000 - (integerField(object, "priority") orelse 999),
        .has_tool_use = true,
        .has_reasoning = efforts.items.len > 0,
        .reasoning_efforts = efforts,
        // Fast mode is a Gateway routing feature with no Codex equivalent.
        .supports_fast_mode = false,
        .has_vision = modalitiesContain(object.get("input_modalities"), "image"),
        .has_file_input = false,
        .has_web_search = false,
        .has_explicit_caching = false,
        .has_implicit_caching = true,
        .context_window = clampU32(integerField(object, "context_window")),
        .max_tokens = 0,
        .web_search_price = null,
    };
}

fn parseEfforts(alloc: Allocator, value: ?std.json.Value) !std.ArrayList(types.ReasoningEffort) {
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);

    const levels = value orelse return efforts;
    if (levels != .array) return efforts;
    for (levels.array.items) |level| {
        if (efforts.items.len >= types.ReasoningEffort.max_options) break;
        if (level != .object) continue;
        const effort = stringField(level.object, "effort") orelse continue;
        const parsed = types.ReasoningEffort.parse(effort) orelse continue;
        if (parsed.isDefault()) continue;
        try efforts.append(alloc, parsed);
    }
    return efforts;
}

fn modalitiesContain(value: ?std.json.Value, needle: []const u8) bool {
    const actual = value orelse return false;
    if (actual != .array) return false;
    for (actual.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn clampU32(value: ?i64) u32 {
    const actual = value orelse return 0;
    if (actual <= 0) return 0;
    if (actual > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(actual);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\{"models":[
    \\{"slug":"gpt-5.6-terra","visibility":"list","priority":2,"context_window":272000,
    \\ "input_modalities":["text","image"],
    \\ "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"xhigh"}]},
    \\{"slug":"gpt-5.6-sol","visibility":"list","priority":1,"context_window":272000,
    \\ "input_modalities":["text","image"],
    \\ "supported_reasoning_levels":[{"effort":"medium"}]},
    \\{"slug":"text-only","visibility":"list","priority":30,"context_window":128000,
    \\ "input_modalities":["text"],"supported_reasoning_levels":[]},
    \\{"slug":"codex-auto-review","visibility":"hide","priority":43}
    \\]}
;

test "hidden models are not offered" {
    const alloc = testing.allocator;
    var entries = try parse(alloc, sample);
    defer model_catalog.freeModelCatalog(alloc, &entries);

    for (entries.items) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.id, "openai/codex-auto-review"));
    }
    try testing.expectEqual(@as(usize, 3), entries.items.len);
}

test "entries carry the fx catalog shape and namespaced id" {
    const alloc = testing.allocator;
    var entries = try parse(alloc, sample);
    defer model_catalog.freeModelCatalog(alloc, &entries);

    const terra = for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.id, "openai/gpt-5.6-terra")) break entry;
    } else return error.TestExpectedModelMissing;

    try testing.expectEqualStrings("language", terra.model_type);
    try testing.expect(terra.has_tool_use);
    try testing.expect(terra.has_reasoning);
    try testing.expect(terra.has_vision);
    try testing.expect(terra.has_implicit_caching);
    // Fast mode is a Gateway concept and must not be advertised here.
    try testing.expect(!terra.supports_fast_mode);
    try testing.expectEqual(@as(u32, 272000), terra.context_window);
    try testing.expectEqual(@as(usize, 3), terra.reasoning_efforts.items.len);
}

test "a text-only model is not marked as supporting vision" {
    const alloc = testing.allocator;
    var entries = try parse(alloc, sample);
    defer model_catalog.freeModelCatalog(alloc, &entries);

    const text_only = for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.id, "openai/text-only")) break entry;
    } else return error.TestExpectedModelMissing;

    try testing.expect(!text_only.has_vision);
    try testing.expect(!text_only.has_reasoning);
}

test "ordering follows the backend priority" {
    const alloc = testing.allocator;
    var entries = try parse(alloc, sample);
    defer model_catalog.freeModelCatalog(alloc, &entries);

    // priority 1 outranks priority 2, which outranks 30.
    try testing.expectEqualStrings("openai/gpt-5.6-sol", entries.items[0].id);
    try testing.expectEqualStrings("openai/gpt-5.6-terra", entries.items[1].id);
    try testing.expectEqualStrings("openai/text-only", entries.items[2].id);
}

test "the live Codex catalog parses into usable entries" {
    // Captured from chatgpt.com/backend-api/codex/models, trimmed to the fields
    // this parser reads plus a few it must ignore.
    const alloc = testing.allocator;
    const live = @embedFile("testdata/models.json");
    var entries = try parse(alloc, live);
    defer model_catalog.freeModelCatalog(alloc, &entries);

    // Six listed models; codex-auto-review is hidden.
    try testing.expectEqual(@as(usize, 6), entries.items.len);
    try testing.expectEqualStrings("openai/gpt-5.6-sol", entries.items[0].id);

    for (entries.items) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.id, "openai/"));
        try testing.expectEqualStrings("language", entry.model_type);
        try testing.expect(entry.has_tool_use);
        try testing.expect(entry.has_reasoning);
        try testing.expect(entry.context_window > 0);
        try testing.expect(!entry.supports_fast_mode);
        // Every effort the backend advertises must survive parsing, or the
        // picker would silently drop tiers.
        try testing.expect(entry.reasoning_efforts.items.len >= 4);
    }
}

test "a malformed or empty payload is reported rather than silently empty" {
    const alloc = testing.allocator;
    try testing.expectError(error.MalformedResponse, parse(alloc, "not json"));
    try testing.expectError(error.MalformedResponse, parse(alloc, "[]"));
    try testing.expectError(error.MalformedResponse, parse(alloc, "{}"));
    try testing.expectError(error.MalformedResponse, parse(alloc, "{\"models\":[]}"));
    // Every model hidden is indistinguishable from an unusable catalog.
    try testing.expectError(
        error.MalformedResponse,
        parse(alloc, "{\"models\":[{\"slug\":\"x\",\"visibility\":\"hide\"}]}"),
    );
}
