//! TLS certificate bundle helpers.
const std = @import("std");

pub fn applyCaFile(client: *std.http.Client, alloc: std.mem.Allocator, ca_file: ?[]const u8) !void {
    if (std.http.Client.disable_tls) return;

    const now = std.Io.Clock.real.now(client.io);
    client.ca_bundle_lock.lockUncancelable(client.io);
    defer client.ca_bundle_lock.unlock(client.io);

    if (ca_file) |path| {
        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(alloc);
        const file = try std.Io.Dir.openFileAbsolute(client.io, path, .{});
        defer file.close(client.io);
        var buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(client.io, &buf);
        try bundle.addCertsFromFile(alloc, &reader, now.toSeconds());

        client.ca_bundle.deinit(alloc);
        client.ca_bundle = bundle;
        bundle = .empty;
    } else if (client.ca_bundle.bytes.items.len == 0) {
        try client.ca_bundle.rescan(alloc, client.io, now);
    }

    client.now = now;
}
