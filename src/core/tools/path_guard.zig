//! TOCTOU-safe path resolution and directory traversal guard.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const native_os = builtin.os.tag;
const Dir = std.Io.Dir;
const File = std.Io.File;

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn setDirAsCwd(dir: Dir) !void {
    switch (posix.errno(std.c.fchdir(dir.handle))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn closeFd(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}

pub const RaceHook = struct {
    vt: *const Vt,

    pub const Vt = struct {
        after_open: *const fn (self: *RaceHook, dir: Dir, path: []const u8) anyerror!void,
    };

    pub fn call(self: *RaceHook, dir: Dir, path: []const u8) !void {
        return self.vt.after_open(self, dir, path);
    }

    pub fn Bind(comptime T: type, comptime after_open_fn: fn (*T, Dir, []const u8) anyerror!void) type {
        return struct {
            pub const vt = Vt{
                .after_open = afterOpenFn,
            };
            fn afterOpenFn(rh: *RaceHook, dir: Dir, path: []const u8) anyerror!void {
                const self_ptr: *T = @fieldParentPtr("race_hook", rh);
                return after_open_fn(self_ptr, dir, path);
            }
        };
    }
};

var race_mu: std.Io.Mutex = .init;
var race_hook: ?*RaceHook = null;

pub const CwdGuard = struct {
    prev: Dir,

    var mu: std.Io.Mutex = .init;

    pub fn enter(dir: Dir) !CwdGuard {
        const active_io = defaultIo();
        mu.lockUncancelable(active_io);
        errdefer mu.unlock(active_io);

        var prev = try Dir.cwd().openDir(active_io, ".", .{});
        errdefer prev.close(active_io);

        try setDirAsCwd(dir);
        return .{ .prev = prev };
    }

    pub fn deinit(self: *CwdGuard) void {
        const active_io = defaultIo();
        setDirAsCwd(self.prev) catch |err| {
            std.log.warn("CwdGuard: failed to restore cwd: {}", .{err});
        };
        self.prev.close(active_io);
        mu.unlock(active_io);
        self.* = undefined;
    }
};

pub const RaceGuard = struct {
    pub fn deinit(self: *RaceGuard) void {
        race_hook = null;
        race_mu.unlock(defaultIo());
        self.* = undefined;
    }
};

pub fn installRaceHook(hook: *RaceHook) RaceGuard {
    race_mu.lockUncancelable(defaultIo());
    race_hook = hook;
    return .{};
}

pub fn openDir(path: []const u8, opts: Dir.OpenOptions) !Dir {
    const active_io = defaultIo();
    const rel = try relPath(path);
    if (rel.len == 0) return Dir.cwd().openDir(active_io, ".", opts);

    var parent = try openParentDir(rel);
    errdefer parent.dir.close(active_io);

    const leaf = parent.leaf orelse return error.FileNotFound;
    const dir = parent.dir.openDir(active_io, leaf, noFollowDirOpts(opts)) catch |err|
        return mapParentDirErr(parent.dir, leaf, err);
    parent.dir.close(active_io);
    return dir;
}

pub fn openFile(path: []const u8, flags: Dir.OpenFileOptions) !File {
    const rel = try relPath(path);
    if (rel.len == 0) return error.FileNotFound;

    var parent = try openParentDir(rel);
    defer parent.dir.close(defaultIo());

    const leaf = parent.leaf orelse return error.FileNotFound;
    return switch (native_os) {
        .windows => error.AccessDenied,
        else => openFileAt(parent.dir.handle, leaf, flags),
    };
}

pub fn openFileInDir(dir: Dir, name: []const u8, flags: Dir.OpenFileOptions) !File {
    const leaf = try leafName(name);
    return switch (native_os) {
        .windows => error.AccessDenied,
        else => openFileAt(dir.handle, leaf, flags),
    };
}

pub fn createFileInDir(dir: Dir, name: []const u8, flags: Dir.CreateFileOptions) !File {
    const leaf = try leafName(name);
    return switch (native_os) {
        .windows => error.AccessDenied,
        else => createFileAt(dir.handle, leaf, flags),
    };
}

pub fn createFile(path: []const u8, flags: Dir.CreateFileOptions) !File {
    const rel = try relPath(path);
    if (rel.len == 0) return error.FileNotFound;

    var parent = try openParentDir(rel);
    defer parent.dir.close(defaultIo());

    const leaf = parent.leaf orelse return error.FileNotFound;
    return switch (native_os) {
        .windows => error.AccessDenied,
        else => createFileAt(parent.dir.handle, leaf, flags),
    };
}

const ParentDir = struct {
    dir: Dir,
    leaf: ?[]const u8,
};

fn openParentDir(rel_path: []const u8) !ParentDir {
    const active_io = defaultIo();
    var dir = try Dir.cwd().openDir(active_io, ".", .{ .access_sub_paths = true });
    errdefer dir.close(active_io);

    var it = std.fs.path.componentIterator(rel_path);
    var leaf: ?[]const u8 = null;
    while (it.next()) |part| {
        if (isDot(part.name)) continue;
        if (isDotDot(part.name)) return error.AccessDenied;

        if (leaf) |name| {
            const next = dir.openDir(active_io, name, .{
                .access_sub_paths = true,
                .follow_symlinks = false,
            }) catch |err| return mapParentDirErr(dir, name, err);
            dir.close(active_io);
            dir = next;
        }
        leaf = part.name;
    }

    return .{
        .dir = dir,
        .leaf = leaf,
    };
}

fn mapParentDirErr(dir: Dir, name: []const u8, err: anyerror) anyerror {
    if (err != error.NotDir) return err;
    if (native_os == .windows) return err;

    const st = fstatatNoFollow(dir.handle, name) catch |stat_err| switch (stat_err) {
        error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return error.AccessDenied,
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    if ((st.mode & posix.S.IFMT) == posix.S.IFLNK) return error.AccessDenied;
    return error.FileNotFound;
}

fn fstatatNoFollow(dir_fd: posix.fd_t, name: []const u8) !std.c.Stat {
    var name_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (name.len >= name_buf.len) return error.NameTooLong;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    var st: std.c.Stat = undefined;
    switch (posix.errno(std.c.fstatat(dir_fd, name_buf[0..name.len :0].ptr, &st, std.c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => return st,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .LOOP => return error.SymLinkLoop,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}

fn relPath(path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return path;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try Dir.cwd().realPathFile(defaultIo(), ".", &root_buf);
    const root = root_buf[0..root_len];

    if (path.len < root.len) return error.AccessDenied;
    if (!std.mem.eql(u8, path[0..root.len], root)) return error.AccessDenied;
    if (path.len == root.len) return "";
    if (!std.fs.path.isSep(path[root.len])) return error.AccessDenied;

    var rel = path[root.len..];
    while (rel.len > 0 and std.fs.path.isSep(rel[0])) rel = rel[1..];
    return rel;
}

fn noFollowDirOpts(opts: Dir.OpenOptions) Dir.OpenOptions {
    var out = opts;
    out.follow_symlinks = false;
    return out;
}

fn isDot(name: []const u8) bool {
    return name.len == 1 and name[0] == '.';
}

fn isDotDot(name: []const u8) bool {
    return name.len == 2 and name[0] == '.' and name[1] == '.';
}

fn leafName(name: []const u8) ![]const u8 {
    if (name.len == 0) return error.AccessDenied;
    if (isDot(name) or isDotDot(name)) return error.AccessDenied;
    for (name) |c| {
        if (std.fs.path.isSep(c)) return error.AccessDenied;
    }
    return name;
}

fn setPortableFlags(os_flags: *posix.O) void {
    if (@hasField(posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
}

const LockKind = enum { none, shared, exclusive };

fn setFlockOpenFlags(os_flags: *posix.O, lock: LockKind, nonblocking: bool) bool {
    const has = @hasField(posix.O, "EXLOCK");
    if (has) switch (lock) {
        .none => {},
        .shared => {
            os_flags.SHLOCK = true;
            os_flags.NONBLOCK = nonblocking;
        },
        .exclusive => {
            os_flags.EXLOCK = true;
            os_flags.NONBLOCK = nonblocking;
        },
    };
    return has;
}

fn applyFlock(fd: posix.fd_t, has_flock_open_flags: bool, lock: LockKind, nonblocking: bool) !void {
    if (@TypeOf(std.c.flock) != void and !has_flock_open_flags and lock != .none) {
        const nb: c_int = if (nonblocking) posix.LOCK.NB else 0;
        try flockFd(fd, switch (lock) {
            .none => unreachable,
            .shared => posix.LOCK.SH | nb,
            .exclusive => posix.LOCK.EX | nb,
        });
    }

    if (has_flock_open_flags and nonblocking) {
        const cur = std.c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
        switch (posix.errno(cur)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
        const nonblock: c_int = @bitCast(posix.O{ .NONBLOCK = true });
        const rc = std.c.fcntl(fd, posix.F.SETFL, cur & ~nonblock);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn flockFd(fd: posix.fd_t, operation: c_int) !void {
    while (true) {
        switch (posix.errno(std.c.flock(fd, operation))) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable,
            .INVAL => unreachable,
            .NOLCK => return error.SystemResources,
            else => |errno| return posix.unexpectedErrno(errno),
        }
    }
}

fn openFileAt(dir_fd: posix.fd_t, path: []const u8, flags: Dir.OpenFileOptions) !File {
    var os_flags: posix.O = switch (native_os) {
        .wasi => .{
            .read = flags.mode != .write_only,
            .write = flags.mode != .read_only,
        },
        else => .{
            .ACCMODE = switch (flags.mode) {
                .read_only => .RDONLY,
                .write_only => .WRONLY,
                .read_write => .RDWR,
            },
            .NOFOLLOW = true,
        },
    };
    setPortableFlags(&os_flags);
    if (@hasField(posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;

    const lock: LockKind = switch (flags.lock) {
        .none => .none,
        .shared => .shared,
        .exclusive => .exclusive,
    };
    const has_flock_open = setFlockOpenFlags(&os_flags, lock, flags.lock_nonblocking);

    const fd = try posix.openat(dir_fd, path, os_flags, 0);
    errdefer closeFd(fd);

    try applyFlock(fd, has_flock_open, lock, flags.lock_nonblocking);
    try maybeRace(dir_fd, path);
    try ensureStableFile(dir_fd, path, fd);

    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn createFileAt(dir_fd: posix.fd_t, path: []const u8, flags: Dir.CreateFileOptions) !File {
    var os_flags: posix.O = .{
        .ACCMODE = if (flags.read) .RDWR else .WRONLY,
        .CREAT = true,
        .TRUNC = false,
        .EXCL = flags.exclusive,
        .NOFOLLOW = true,
    };
    setPortableFlags(&os_flags);

    const lock: LockKind = switch (flags.lock) {
        .none => .none,
        .shared => .shared,
        .exclusive => .exclusive,
    };
    const has_flock_open = setFlockOpenFlags(&os_flags, lock, flags.lock_nonblocking);

    const fd = try posix.openat(dir_fd, path, os_flags, flags.permissions.toMode());
    errdefer closeFd(fd);

    try applyFlock(fd, has_flock_open, lock, flags.lock_nonblocking);
    try maybeRace(dir_fd, path);
    try ensureStableFile(dir_fd, path, fd);
    if (flags.truncate) {
        switch (posix.errno(std.c.ftruncate(fd, 0))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn maybeRace(dir_fd: posix.fd_t, path: []const u8) !void {
    if (race_hook) |hook| {
        try hook.call(.{ .handle = dir_fd }, path);
    }
}

fn ensureStableFile(dir_fd: posix.fd_t, path: []const u8, fd: posix.fd_t) !void {
    const got = fstatFd(fd) catch return error.AccessDenied;
    if (!isReg(got.mode)) return error.AccessDenied;
    if (got.nlink != 1) return error.AccessDenied;

    const want = fstatatNoFollow(dir_fd, path) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.SymLinkLoop,
        => return error.AccessDenied,
        else => return err,
    };
    if (!isReg(want.mode)) return error.AccessDenied;
    if (want.nlink != 1) return error.AccessDenied;
    if (!sameFile(got, want)) return error.AccessDenied;
}

fn fstatFd(fd: posix.fd_t) !std.c.Stat {
    var st: std.c.Stat = undefined;
    switch (posix.errno(std.c.fstat(fd, &st))) {
        .SUCCESS => return st,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BADF => return error.FileNotFound,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}

fn isReg(mode: posix.mode_t) bool {
    return (mode & posix.S.IFMT) == posix.S.IFREG;
}

fn sameFile(a: posix.Stat, b: posix.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino;
}

/// Resolve `path` component-by-component under `root`, following symlinks at
/// each step via readlinkat, and verify the final resolved path stays within
/// `root`. Returns error.AccessDenied if any symlink resolves outside root.
pub fn resolveConfined(
    alloc: std.mem.Allocator,
    root: []const u8,
    path: []const u8,
) ![]u8 {
    if (native_os == .windows) return error.AccessDenied;

    // Normalize root to realpath
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = try Dir.cwd().realPathFile(defaultIo(), root, &root_buf);
    const real_root = root_buf[0..real_root_len];

    // Build resolved path component by component
    var resolved: std.ArrayListUnmanaged(u8) = .empty;
    defer resolved.deinit(alloc);
    try resolved.appendSlice(alloc, real_root);

    var it = std.fs.path.componentIterator(path);
    var hops: usize = 0;
    const max_hops: usize = 40; // symlink follow limit

    while (it.next()) |part| {
        if (isDot(part.name)) continue;
        if (isDotDot(part.name)) {
            // Walk up, but not above root
            if (resolved.items.len > real_root.len) {
                // Strip last component
                while (resolved.items.len > real_root.len and
                    !std.fs.path.isSep(resolved.items[resolved.items.len - 1]))
                {
                    _ = resolved.pop();
                }
                // Strip trailing sep (but keep root)
                while (resolved.items.len > real_root.len and
                    std.fs.path.isSep(resolved.items[resolved.items.len - 1]))
                {
                    _ = resolved.pop();
                }
            }
            continue;
        }

        // Append separator + component
        try resolved.append(alloc, '/');
        try resolved.appendSlice(alloc, part.name);

        // Check if this component is a symlink
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_len = Dir.readLinkAbsolute(
            defaultIo(),
            resolved.items,
            &link_buf,
        ) catch |err| switch (err) {
            error.NotLink => continue, // regular file/dir, keep going
            else => return error.AccessDenied,
        };
        const link_target = link_buf[0..link_len];

        hops += 1;
        if (hops > max_hops) return error.AccessDenied;

        if (std.fs.path.isAbsolute(link_target)) {
            // Absolute symlink: replace resolved entirely
            resolved.clearRetainingCapacity();
            try resolved.appendSlice(alloc, link_target);
        } else {
            // Relative symlink: pop component, append target
            while (resolved.items.len > 0 and
                !std.fs.path.isSep(resolved.items[resolved.items.len - 1]))
            {
                _ = resolved.pop();
            }
            // Keep the separator
            try resolved.appendSlice(alloc, link_target);
        }

        // Re-resolve to realpath to canonicalize
        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon_len = Dir.cwd().realPathFile(defaultIo(), resolved.items, &canon_buf) catch
            return error.AccessDenied;
        const canon = canon_buf[0..canon_len];
        resolved.clearRetainingCapacity();
        try resolved.appendSlice(alloc, canon);

        // Confinement check
        if (!isConfined(resolved.items, real_root))
            return error.AccessDenied;
    }

    // Final confinement check
    var final_buf: [std.fs.max_path_bytes]u8 = undefined;
    const final_len = Dir.cwd().realPathFile(defaultIo(), resolved.items, &final_buf) catch
        return error.AccessDenied;
    const final_path = final_buf[0..final_len];

    if (!isConfined(final_path, real_root))
        return error.AccessDenied;

    return try alloc.dupe(u8, final_path);
}

fn isConfined(path: []const u8, root: []const u8) bool {
    if (path.len < root.len) return false;
    if (!std.mem.eql(u8, path[0..root.len], root)) return false;
    if (path.len == root.len) return true;
    return std.fs.path.isSep(path[root.len]);
}

test "resolveConfined allows path within root" {
    if (native_os == .windows or native_os == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sub/deep");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/deep/file.txt", .data = "ok" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const resolved = try resolveConfined(std.testing.allocator, root, "sub/deep/file.txt");
    defer std.testing.allocator.free(resolved);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ root, "sub/deep/file.txt" });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "resolveConfined denies symlink chain escaping root" {
    if (native_os == .windows or native_os == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create root/jail and an outside directory
    try tmp.dir.createDirPath(std.testing.io, "jail/sub");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/secret.txt", .data = "stolen" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "jail", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const outside_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "outside", std.testing.allocator);
    defer std.testing.allocator.free(outside_abs);

    // Create symlink chain: jail/sub/link1 -> link2, jail/sub/link2 -> /outside
    try tmp.dir.symLink(std.testing.io, outside_abs, "jail/sub/escape", .{});

    // Attempt to resolve through symlink that escapes
    try std.testing.expectError(
        error.AccessDenied,
        resolveConfined(std.testing.allocator, root, "sub/escape/secret.txt"),
    );
}

test "resolveConfined denies dotdot escape" {
    if (native_os == .windows or native_os == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "jail/sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.txt", .data = "secret" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "jail", std.testing.allocator);
    defer std.testing.allocator.free(root);

    // ../../outside.txt should be confined to root (dotdot stops at root)
    // The resolved path would be jail/outside.txt which doesn't exist
    try std.testing.expectError(
        error.AccessDenied,
        resolveConfined(std.testing.allocator, root, "sub/../../outside.txt"),
    );
}

test "openFile denies hardlinked leaf" {
    if (native_os == .windows or native_os == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "base.txt", .data = "secret\n" });
    try tmp.dir.hardLink("base.txt", tmp.dir, "alias.txt", std.testing.io, .{});

    try std.testing.expectError(error.AccessDenied, openFile("alias.txt", .{ .mode = .read_only }));
}

test "createFile denies hardlinked leaf before truncation" {
    if (native_os == .windows or native_os == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "base.txt", .data = "secret\n" });
    try tmp.dir.hardLink("base.txt", tmp.dir, "alias.txt", std.testing.io, .{});

    try std.testing.expectError(error.AccessDenied, createFile("alias.txt", .{ .truncate = true }));
    const kept = try tmp.dir.readFileAlloc(std.testing.io, "base.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("secret\n", kept);
}

test "openFile denies replaced leaf after open" {
    if (native_os == .windows or native_os == .wasi) return;

    const Ctx = struct {
        race_hook: RaceHook = .{ .vt = &Bind.vt },
        fn run(_: *@This(), dir: Dir, path: []const u8) !void {
            try dir.rename(path, dir, "gone.txt", std.testing.io);
            try dir.rename("swap.txt", dir, path, std.testing.io);
        }
        const Bind = RaceHook.Bind(@This(), run);
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim.txt", .data = "keep\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "swap.txt", .data = "swap\n" });

    var ctx = Ctx{};
    var guard = installRaceHook(&ctx.race_hook);
    defer guard.deinit();

    try std.testing.expectError(error.AccessDenied, openFile("victim.txt", .{ .mode = .read_only }));
    const now = try tmp.dir.readFileAlloc(std.testing.io, "victim.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(now);
    try std.testing.expectEqualStrings("swap\n", now);
}

test "createFile denies replaced leaf before truncation" {
    if (native_os == .windows or native_os == .wasi) return;

    const Ctx = struct {
        race_hook: RaceHook = .{ .vt = &Bind.vt },
        fn run(_: *@This(), dir: Dir, path: []const u8) !void {
            try dir.rename(path, dir, "gone.txt", std.testing.io);
            try dir.rename("swap.txt", dir, path, std.testing.io);
        }
        const Bind = RaceHook.Bind(@This(), run);
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim.txt", .data = "keep\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "swap.txt", .data = "swap\n" });

    var ctx = Ctx{};
    var guard = installRaceHook(&ctx.race_hook);
    defer guard.deinit();

    try std.testing.expectError(error.AccessDenied, createFile("victim.txt", .{ .truncate = true }));
    const now = try tmp.dir.readFileAlloc(std.testing.io, "victim.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(now);
    try std.testing.expectEqualStrings("swap\n", now);
}
