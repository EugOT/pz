const upstream = @import("ohsnap_upstream");
const SourceLocation = @import("std").builtin.SourceLocation;

pub const default_pretty_options = upstream.default_pretty_options;
pub const default = upstream.default;
pub const OhSnap = upstream.OhSnap;
pub const Snap = upstream.Snap;

pub fn snap(_: @This(), location: SourceLocation, text: []const u8) upstream.Snap(upstream.default_pretty_options) {
    return upstream.default.snap(location, text);
}
