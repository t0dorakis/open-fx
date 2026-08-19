//! Identity of this build as a fork rather than an upstream fx release.

const std = @import("std");

/// Marks the version as a fork of the upstream release it precedes, so
/// "0.0.3-codex.1" reads as the first fork build on top of upstream 0.0.3.
pub const version_marker = "-codex";

/// Upstream's release feed only ever serves upstream binaries. Installing one
/// would replace this fork with stock fx and silently take the Codex provider
/// with it, leaving a signed-in user with a binary that cannot reach Codex. So
/// the fork declines to upgrade itself and says why, instead of treating a
/// higher upstream version as an improvement.
///
/// Matched anywhere in the string rather than at the end, because fork builds
/// carry their own trailing number.
pub fn isForkBuild(version: []const u8) bool {
    return std.mem.find(u8, version, version_marker) != null;
}

test isForkBuild {
    try std.testing.expect(isForkBuild("0.0.3-codex"));
    try std.testing.expect(isForkBuild("0.0.3-codex.1"));
    try std.testing.expect(!isForkBuild("0.0.3"));
    try std.testing.expect(!isForkBuild("0.0.4"));
}
