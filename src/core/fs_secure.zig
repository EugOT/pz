//! Secure filesystem helpers: restrictive modes, safe dir creation,
//! openat/O_NOFOLLOW confinement, hardlink rejection, atomic writes.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Dir = std.Io.Dir;
const File = std.Io.File;

pub const dir_mode: File.Permissions = .fromMode(0o700);
pub const file_mode: File.Permissions = .fromMode(0o600);

fn defaultIo() std.Io {
    return @import("rt_io.zig").default();
}

fn fileFromFd(fd: posix.fd_t) File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn expectMode(st: File.Stat, mode: File.Permissions) !void {
    try std.testing.expectEqual(mode.toMode(), st.permissions.toMode() & 0o777);
}

pub fn ensureDirAt(dir: Dir, sub_path: []const u8) !void {
    const active_io = defaultIo();
    try dir.createDirPath(active_io, sub_path);
    var sub = try dir.openDir(active_io, sub_path, .{ .iterate = true });
    defer sub.close(active_io);
    try sub.setPermissions(active_io, dir_mode);
}

pub fn ensureDirPath(path: []const u8) !void {
    const active_io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        if (builtin.os.tag == .windows) return error.Unsupported;
        const rel = std.mem.trimStart(u8, path, "/");
        var root = try Dir.openDirAbsolute(active_io, "/", .{});
        defer root.close(active_io);
        try root.createDirPath(active_io, rel);
        var dir = try root.openDir(active_io, rel, .{ .iterate = true });
        defer dir.close(active_io);
        try dir.setPermissions(active_io, dir_mode);
    } else {
        try Dir.cwd().createDirPath(active_io, path);
        var dir = try Dir.cwd().openDir(active_io, path, .{ .iterate = true });
        defer dir.close(active_io);
        try dir.setPermissions(active_io, dir_mode);
    }
}

pub fn createFileAt(dir: Dir, sub_path: []const u8, flags: Dir.CreateFileOptions) !File {
    const active_io = defaultIo();
    var secure = flags;
    secure.permissions = file_mode;
    return dir.createFile(active_io, sub_path, secure);
}

pub fn createFilePath(path: []const u8, flags: Dir.CreateFileOptions) !File {
    const active_io = defaultIo();
    var secure = flags;
    secure.permissions = file_mode;
    if (std.fs.path.isAbsolute(path)) return Dir.createFileAbsolute(active_io, path, secure);
    return Dir.cwd().createFile(active_io, path, secure);
}

// ---------------------------------------------------------------------------
// openat/O_NOFOLLOW confined open + hardlink rejection
// ---------------------------------------------------------------------------

/// Open an existing file confined to `dir` with O_NOFOLLOW and hardlink
/// check.  Rejects symlinks and files with nlink != 1.
pub fn openConfined(dir: Dir, name: []const u8, flags: Dir.OpenFileOptions) !File {
    const active_io = defaultIo();
    if (builtin.os.tag == .windows) return dir.openFile(active_io, name, flags);
    try validateLeaf(name);

    var os_flags: posix.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = true,
    };
    if (@hasField(posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;

    const fd = try posix.openat(dir.handle, name, os_flags, 0);
    const file = fileFromFd(fd);
    errdefer file.close(active_io);
    try rejectBadFile(active_io, file);
    return file;
}

/// Create or open a file confined to `dir` with O_NOFOLLOW, O_CREAT,
/// hardlink check, and secure mode.
pub fn createConfined(dir: Dir, name: []const u8, flags: Dir.CreateFileOptions) !File {
    const active_io = defaultIo();
    if (builtin.os.tag == .windows) return createFileAt(dir, name, flags);
    try validateLeaf(name);

    var os_flags: posix.O = .{
        .ACCMODE = if (flags.read) .RDWR else .WRONLY,
        .CREAT = true,
        .EXCL = flags.exclusive,
        .NOFOLLOW = true,
    };
    if (@hasField(posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;

    const fd = try posix.openat(dir.handle, name, os_flags, file_mode.toMode());
    const file = fileFromFd(fd);
    errdefer file.close(active_io);
    // Skip hardlink check for newly created exclusive files (nlink is 1
    // by definition and fstat is redundant).
    if (!flags.exclusive) try rejectBadFile(active_io, file);
    if (flags.truncate) {
        switch (posix.errno(std.c.ftruncate(file.handle, 0))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    return file;
}

/// Validate that `name` is a plain leaf (no path separators, not empty,
/// not "." or "..").
fn validateLeaf(name: []const u8) !void {
    if (name.len == 0) return error.AccessDenied;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.AccessDenied;
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return error.AccessDenied;
    }
}

/// Reject non-regular files and hardlinks (nlink > 1).
fn rejectBadFile(active_io: std.Io, file: File) !void {
    const st = file.stat(active_io) catch return error.AccessDenied;
    if (st.kind != .file) return error.AccessDenied;
    if (st.nlink != 1) return error.AccessDenied;
}

// ---------------------------------------------------------------------------
// Atomic write: temp + fsync + rename
// ---------------------------------------------------------------------------

/// Atomically write `data` into `dir/name` via a temp file.
/// Steps: delete stale tmp -> create exclusive -> write -> fsync -> rename.
pub fn atomicWriteAt(dir: Dir, name: []const u8, data: []const u8) !void {
    const active_io = defaultIo();
    try validateLeaf(name);

    var tmp_buf: [256]u8 = undefined;
    const tmp_name = tmpName(name, &tmp_buf) catch return error.NameTooLong;

    // Clean up stale temp from prior interrupted writes.
    dir.deleteFile(active_io, tmp_name) catch {}; // cleanup: propagation impossible

    var tmp_file = try createConfined(dir, tmp_name, .{
        .exclusive = true,
        .truncate = true,
    });
    errdefer {
        tmp_file.close(active_io);
        dir.deleteFile(active_io, tmp_name) catch {}; // cleanup: propagation impossible
    }

    try tmp_file.writeStreamingAll(active_io, data);
    try tmp_file.sync(active_io);
    tmp_file.close(active_io);

    try dir.rename(tmp_name, dir, name, active_io);
}

/// Streaming atomic write via callback, for large data.
pub fn atomicWriteAtFn(
    dir: Dir,
    name: []const u8,
    ctx: anytype,
    writeFn: fn (@TypeOf(ctx), File) anyerror!void,
) !void {
    const active_io = defaultIo();
    try validateLeaf(name);

    var tmp_buf: [256]u8 = undefined;
    const tmp_name = tmpName(name, &tmp_buf) catch return error.NameTooLong;

    dir.deleteFile(active_io, tmp_name) catch {}; // cleanup: propagation impossible

    var tmp_file = try createConfined(dir, tmp_name, .{
        .exclusive = true,
        .truncate = true,
    });
    errdefer {
        tmp_file.close(active_io);
        dir.deleteFile(active_io, tmp_name) catch {}; // cleanup: propagation impossible
    }

    try writeFn(ctx, tmp_file);
    try tmp_file.sync(active_io);
    tmp_file.close(active_io);

    try dir.rename(tmp_name, dir, name, active_io);
}

fn tmpName(name: []const u8, buf: *[256]u8) ![]const u8 {
    const needed = 1 + name.len + 4;
    if (needed > buf.len) return error.NameTooLong;
    buf[0] = '.';
    @memcpy(buf[1 .. 1 + name.len], name);
    @memcpy(buf[1 + name.len .. 1 + name.len + 4], ".tmp");
    return buf[0..needed];
}

// ---------------------------------------------------------------------------
// Agent artifact orphan cleanup
// ---------------------------------------------------------------------------

/// Remove orphan agent artifact files (matching `agent-*.stdout`) from `dir`.
/// Best-effort: individual delete failures are ignored since we cannot
/// propagate per-file errors during cleanup.
pub fn cleanupAgentArtifacts(dir: Dir) void {
    const active_io = defaultIo();
    var it = dir.iterate();
    while (it.next(active_io) catch null) |ent| { // cleanup: iteration failure ends scan
        if (ent.kind != .file) continue;
        if (!std.mem.startsWith(u8, ent.name, "agent-")) continue;
        if (!std.mem.endsWith(u8, ent.name, ".stdout")) continue;
        dir.deleteFile(active_io, ent.name) catch {}; // cleanup: propagation impossible
    }
}

// ============================================================================
// Tests
// ============================================================================

test "cleanupAgentArtifacts removes orphans" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create some artifact files and a non-artifact.
    var f1 = try tmp.dir.createFile(std.testing.io, "agent-123.stdout", .{});
    f1.close(std.testing.io);
    var f2 = try tmp.dir.createFile(std.testing.io, "agent-456.stdout", .{});
    f2.close(std.testing.io);
    var f3 = try tmp.dir.createFile(std.testing.io, "other.txt", .{});
    f3.close(std.testing.io);

    cleanupAgentArtifacts(tmp.dir);

    // Artifacts deleted, other file preserved.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "agent-123.stdout", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "agent-456.stdout", .{}));
    _ = try tmp.dir.statFile(std.testing.io, "other.txt", .{});
}

test "ensureDirAt locks directory mode to 0700" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try ensureDirAt(tmp.dir, "state");
    const st = try tmp.dir.statFile(std.testing.io, "state", .{});
    try expectMode(st, dir_mode);
}

test "ensureDirPath creates nested absolute directories" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "b", "c" });
    defer std.testing.allocator.free(path);

    try ensureDirPath(path);
    var dir = try Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    const st = try dir.stat(std.testing.io);
    try expectMode(st, dir_mode);
}

test "createFileAt locks file mode to 0600" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try createFileAt(tmp.dir, "state.json", .{ .truncate = true });
    file.close(std.testing.io);

    const st = try tmp.dir.statFile(std.testing.io, "state.json", .{});
    try expectMode(st, file_mode);
}

test "openConfined rejects symlinks" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(std.testing.io, "real.txt", .{});
    f.close(std.testing.io);
    try tmp.dir.symLink(std.testing.io, "real.txt", "link.txt", .{});

    try std.testing.expectError(error.SymLinkLoop, openConfined(tmp.dir, "link.txt", .{}));
}

test "openConfined rejects path traversal" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.AccessDenied, openConfined(tmp.dir, "..", .{}));
    try std.testing.expectError(error.AccessDenied, openConfined(tmp.dir, "a/b", .{}));
    try std.testing.expectError(error.AccessDenied, openConfined(tmp.dir, "", .{}));
}

test "createConfined rejects symlinks" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.symLink(std.testing.io, "target.txt", "link.txt", .{});
    try std.testing.expectError(error.SymLinkLoop, createConfined(tmp.dir, "link.txt", .{}));
}

test "openConfined rejects hardlinks" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(std.testing.io, "orig.txt", .{});
    try f.writeStreamingAll(std.testing.io, "data");
    f.close(std.testing.io);

    tmp.dir.hardLink("orig.txt", tmp.dir, "hard.txt", std.testing.io, .{}) catch return;
    try std.testing.expectError(error.AccessDenied, openConfined(tmp.dir, "hard.txt", .{}));
    try std.testing.expectError(error.AccessDenied, openConfined(tmp.dir, "orig.txt", .{}));
}

test "createConfined rejects hardlinks before truncating" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(std.testing.io, "orig.txt", .{});
    try f.writeStreamingAll(std.testing.io, "data");
    f.close(std.testing.io);

    tmp.dir.hardLink("orig.txt", tmp.dir, "hard.txt", std.testing.io, .{}) catch return;
    try std.testing.expectError(error.AccessDenied, createConfined(tmp.dir, "hard.txt", .{ .truncate = true }));

    const content = try tmp.dir.readFileAlloc(std.testing.io, "orig.txt", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("data", content);
}

test "atomicWriteAt creates file atomically" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try atomicWriteAt(tmp.dir, "out.json", "{\"ok\":true}\n");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "out.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", content);

    const st = try tmp.dir.statFile(std.testing.io, "out.json", .{});
    try expectMode(st, file_mode);
}

test "atomicWriteAt overwrites existing file" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try atomicWriteAt(tmp.dir, "f.txt", "old");
    try atomicWriteAt(tmp.dir, "f.txt", "new");

    const content = try tmp.dir.readFileAlloc(std.testing.io, "f.txt", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("new", content);
}

test "atomicWriteAt rejects path traversal" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.AccessDenied, atomicWriteAt(tmp.dir, "../escape", "x"));
    try std.testing.expectError(error.AccessDenied, atomicWriteAt(tmp.dir, "a/b", "x"));
}

test "atomicWriteAtFn streams large data" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Ctx = struct {
        fn write(_: *const @This(), file: File) !void {
            try file.writeStreamingAll(std.testing.io, "chunk1");
            try file.writeStreamingAll(std.testing.io, "chunk2");
        }
    };
    const ctx = Ctx{};
    try atomicWriteAtFn(tmp.dir, "streamed.txt", &ctx, Ctx.write);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "streamed.txt", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("chunk1chunk2", content);
}

test "createConfined enforces 0600 mode" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try createConfined(tmp.dir, "sec.txt", .{});
    f.close(std.testing.io);

    const st = try tmp.dir.statFile(std.testing.io, "sec.txt", .{});
    try expectMode(st, file_mode);
}
