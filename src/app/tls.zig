//! App-level TLS config: CA bundle and certificate setup.
const std = @import("std");
const core_tls = @import("../core/tls.zig");

const fixtures = @import("../test/fixtures.zig");

fn defaultIo() std.Io {
    return @import("../core/rt_io.zig").default();
}

pub fn loadCaFileAlloc(alloc: std.mem.Allocator, ca_file: ?[]const u8) !?[]u8 {
    if (ca_file) |path| return try alloc.dupe(u8, path);
    return null;
}

pub fn initClient(alloc: std.mem.Allocator, io: std.Io, ca_file: ?[]const u8) !std.http.Client {
    var http = std.http.Client{ .allocator = alloc, .io = io };
    errdefer http.deinit();
    try applyCaFile(&http, alloc, ca_file);
    return http;
}

pub fn initRuntimeClient(alloc: std.mem.Allocator, io: std.Io, ca_file: ?[]const u8) !std.http.Client {
    return try initClient(alloc, io, ca_file);
}

pub fn applyCaFile(client: *std.http.Client, alloc: std.mem.Allocator, ca_file: ?[]const u8) !void {
    try core_tls.applyCaFile(client, alloc, ca_file);
}

pub fn writeTestCert(dir: std.Io.Dir, name: []const u8) ![:0]u8 {
    return fixtures.writeCert(dir, name);
}

test "loadCaFileAlloc returns duped path when set" {
    const got = try loadCaFileAlloc(std.testing.allocator, "/tmp/ca.pem");
    defer if (got) |path| std.testing.allocator.free(path);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("/tmp/ca.pem", got.?);
}

test "loadCaFileAlloc returns null when unset" {
    const got = try loadCaFileAlloc(std.testing.allocator, null);
    try std.testing.expect(got == null);
}

test "initClient loads custom ca bundle and disables rescan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cert_path = try writeTestCert(tmp.dir, "ca.pem");
    defer std.testing.allocator.free(cert_path);

    var http = try initClient(std.testing.allocator, defaultIo(), cert_path);
    defer http.deinit();

    try std.testing.expect(http.ca_bundle.map.size != 0);
    try std.testing.expect(http.now != null);
}

test "initClient fails closed on invalid custom ca bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.pem", .data = "-----BEGIN CERTIFICATE-----\nnot-base64\n" });
    const bad_path = try tmp.dir.realPathFileAlloc(std.testing.io, "bad.pem", std.testing.allocator);
    defer std.testing.allocator.free(bad_path);

    try std.testing.expectError(error.MissingEndCertificateMarker, initClient(std.testing.allocator, defaultIo(), bad_path));
}

test "initClient preloads default ca bundle and disables rescan" {
    if (std.http.Client.disable_tls) return error.SkipZigTest;

    var http = try initClient(std.testing.allocator, defaultIo(), null);
    defer http.deinit();

    try std.testing.expect(http.ca_bundle.map.size != 0);
    try std.testing.expect(http.now != null);
}
