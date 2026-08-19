const std = @import("std");

const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const types = @import("../core/shared/types.zig");

/// Reads `credential_source` straight from the profile settings file.
///
/// Deliberately not the merged settings loader: merging needs a workspace root,
/// and this is consulted during startup before one is resolved. Nothing is lost
/// by skipping the merge, because project config is discarded for this key
/// before it is ever parsed.
pub fn profileCredentialSource() ?types.CredentialSource {
    const alloc = std.heap.c_allocator;
    const home = io_mod.getenv("HOME") orelse return null;

    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch
        return null;
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer fx_dir.close(io_mod.getIo());

    var file = fx_dir.openFile(io_mod.getIo(), "settings.json", .{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }) catch return null;
    defer file.close(io_mod.getIo());

    const bytes = io_mod.readFileToEnd(alloc, &file, 1024 * 1024) catch return null;
    defer alloc.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const value = parsed.value.object.get("credential_source") orelse return null;
    if (value != .string) return null;
    return types.parseCredentialSource(value.string);
}

pub fn codexSelectedInProfile() bool {
    return (profileCredentialSource() orelse return false) == .codex_oauth;
}

test "an absent HOME resolves to no configured source" {
    // io_mod.getenv returns null in a bare test binary, which is the same shape
    // as a machine with no HOME: the answer must be "unset", never a crash.
    try std.testing.expect(profileCredentialSource() == null);
    try std.testing.expect(!codexSelectedInProfile());
}
