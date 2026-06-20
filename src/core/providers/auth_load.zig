//! Credential loading, file I/O, and persistence for auth entries.
const std = @import("std");
const builtin = @import("builtin");
const fs_secure = @import("../fs_secure.zig");
const audit = @import("../audit.zig");
const policy = @import("../policy.zig");
const auth = @import("auth.zig");

const Dir = std.Io.Dir;
const File = std.Io.File;

const Auth = auth.Auth;
const OAuth = auth.OAuth;
const Provider = auth.Provider;
const Hooks = auth.Hooks;
const AuthEntry = auth.AuthEntry;
const AuthFile = auth.AuthFile;

pub const providerName = auth.providerName;

// ── Environment variable helpers ──────────────────────────────────────

const oauth_no_expiry: i64 = std.math.maxInt(i64);
const anthropic_oauth_env = "ANTHROPIC_OAUTH_TOKEN";
const anthropic_api_key_env = "ANTHROPIC_API_KEY";
const openai_api_key_env = "OPENAI_API_KEY";
const auth_file_limit = 1024 * 1024;

const EnvAuth = struct {
    oauth: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

fn readEnv(ar: std.mem.Allocator, key: []const u8) error{ OutOfMemory, Unexpected }!?[]const u8 {
    var env_len: usize = 0;
    while (std.c.environ[env_len] != null) : (env_len += 1) {}
    var env = try std.process.Environ.createMap(.{
        .block = .{ .slice = std.c.environ[0..env_len :null] },
    }, ar);
    defer env.deinit();

    const value = env.get(key) orelse return null;
    const dup = try ar.dupe(u8, value);
    return @as(?[]const u8, dup);
}

fn defaultIo() std.Io {
    return @import("../rt_io.zig").default();
}

fn accessPath(path: []const u8) !void {
    return Dir.cwd().access(defaultIo(), path, .{});
}

fn readPathAlloc(ar: std.mem.Allocator, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(defaultIo(), path, ar, .limited(auth_file_limit));
}

fn readOpenFileAlloc(ar: std.mem.Allocator, file: File) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(defaultIo(), &buffer);
    return reader.interface.allocRemaining(ar, .limited(auth_file_limit));
}

fn openAuthDir(dir_path: []const u8, options: Dir.OpenOptions) !Dir {
    const active_io = defaultIo();
    if (std.fs.path.isAbsolute(dir_path)) return Dir.openDirAbsolute(active_io, dir_path, options);
    return Dir.cwd().openDir(active_io, dir_path, options);
}

fn providerEnvAuth(ar: std.mem.Allocator, provider: Provider) error{ OutOfMemory, Unexpected }!EnvAuth {
    return switch (provider) {
        .anthropic => .{
            .oauth = try readEnv(ar, anthropic_oauth_env),
            .api_key = try readEnv(ar, anthropic_api_key_env),
        },
        .openai => .{
            .oauth = null,
            .api_key = try readEnv(ar, openai_api_key_env),
        },
        // API-key-only providers with no dedicated env-var mapping yet: file
        // auth only. No OAuth, no env credential.
        .google, .mistral, .groq, .deepseek, .openrouter => .{},
    };
}

fn authFromEnv(env: EnvAuth) ?Auth {
    if (env.oauth) |token| {
        if (token.len > 0) return .{ .oauth = .{
            .access = token,
            .refresh = "",
            .expires = oauth_no_expiry,
        } };
    }
    if (env.api_key) |key| {
        if (key.len > 0) return .{ .api_key = key };
    }
    return null;
}

// ── Home resolution ────────────────────────────────────────────────────

pub fn resolveHome(alloc: std.mem.Allocator, hooks: Hooks) ![]u8 {
    if (hooks.home_override) |path| {
        if (hooks.lock.auth) return error.AuthStoreLocked;
        return alloc.dupe(u8, path);
    }
    return hooks.get_home(alloc, "HOME");
}

// ── File path helpers ──────────────────────────────────────────────────

pub fn authFilePath(ar: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(ar, &.{ home, ".pz", "auth.json" });
}

/// Primary auth dir (for writes). Uses ~/.pz/ by default.
fn primaryAuthDir(ar: std.mem.Allocator, home: []const u8) ![]const u8 {
    return try std.fs.path.join(ar, &.{ home, ".pz" });
}

fn findAuthFile(ar: std.mem.Allocator, home: []const u8) ![]const u8 {
    // Primary: ~/.pz/auth.json
    const path = try authFilePath(ar, home);
    if (accessPath(path)) |_| return path else |_| {}

    // Legacy: ~/.pi/agent/auth.json -- migrate once, then use primary
    const legacy = try std.fs.path.join(ar, &.{ home, ".pi", "agent", "auth.json" });
    defer ar.free(legacy);
    if (accessPath(legacy)) |_| {
        migrateAuth(ar, home, legacy, path) catch {
            ar.free(path);
            return error.AuthNotFound;
        };
        return path;
    } else |_| {}
    ar.free(path);
    return error.AuthNotFound;
}

/// Copy legacy ~/.pi/agent/auth.json to ~/.pz/auth.json.
fn migrateAuth(ar: std.mem.Allocator, home: []const u8, legacy: []const u8, dest: []const u8) !void {
    _ = dest;
    const dir_path = try primaryAuthDir(ar, home);
    defer ar.free(dir_path);
    try fs_secure.ensureDirPath(dir_path);
    const data = try readPathAlloc(ar, legacy);
    defer ar.free(data);
    if (!std.fs.path.isAbsolute(dir_path)) return error.AuthNotFound;
    var dir = try Dir.openDirAbsolute(defaultIo(), dir_path, .{});
    defer dir.close(defaultIo());
    try fs_secure.atomicWriteAt(dir, "auth.json", data);
    if (!builtin.is_test) std.log.warn("migrated auth from ~/.pi/agent/auth.json to ~/.pz/auth.json", .{});
}

/// Check if a resolved auth file path is a legacy ~/.pi/ path.
fn isLegacyPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/.pi/") != null;
}

// ── Loading ────────────────────────────────────────────────────────────

pub fn load(alloc: std.mem.Allocator) !auth.Result {
    return loadForProvider(alloc, .anthropic);
}

pub fn loadForProvider(alloc: std.mem.Allocator, provider: Provider) !auth.Result {
    return loadForProviderWithHooks(alloc, provider, .{});
}

pub fn loadForProviderWithHooks(alloc: std.mem.Allocator, provider: Provider, hooks: Hooks) !auth.Result {
    return loadForProviderHome(alloc, hooks, provider);
}

fn loadForProviderHome(
    alloc: std.mem.Allocator,
    hooks: Hooks,
    provider: Provider,
) !auth.Result {
    var result: auth.Result = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .auth = undefined,
    };
    errdefer result.arena.deinit();
    const ar = result.arena.allocator();

    if (!hooks.lock.auth) if (authFromEnv(try providerEnvAuth(ar, provider))) |a| {
        result.auth = a;
        return result;
    };

    const home = try resolveHome(ar, hooks);
    result.auth = try loadFileAuthForProvider(ar, home, provider);
    return result;
}

fn loadFileAuth(alloc: std.mem.Allocator, home: []const u8) !Auth {
    return loadFileAuthForProvider(alloc, home, .anthropic);
}

pub fn loadFileAuthForProvider(alloc: std.mem.Allocator, home: []const u8, provider: Provider) !Auth {
    const ar = alloc;

    const path = findAuthFile(ar, home) catch return error.AuthNotFound;
    const is_legacy = isLegacyPath(path);

    // Legacy path: use openConfined for safe read
    const raw = if (is_legacy) blk: {
        const dir_path = std.fs.path.dirname(path) orelse return error.AuthNotFound;
        var dir = Dir.cwd().openDir(defaultIo(), dir_path, .{}) catch return error.AuthNotFound;
        defer dir.close(defaultIo());
        const basename = std.fs.path.basename(path);
        const file = fs_secure.openConfined(dir, basename, .{}) catch return error.AuthNotFound;
        defer file.close(defaultIo());
        break :blk readOpenFileAlloc(ar, file) catch return error.AuthNotFound;
    } else blk: {
        break :blk readPathAlloc(ar, path) catch return error.AuthNotFound;
    };

    // Strict parsing for primary path; allow unknown fields for legacy compat
    const parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = is_legacy,
    }) catch return error.AuthCorrupt;
    const entry = (switch (provider) {
        inline else => |p| @field(parsed.value, @tagName(p)),
    }) orelse return error.AuthNotFound;

    const AuthType = enum { oauth, api_key };
    const auth_map = std.StaticStringMap(AuthType).initComptime(.{
        .{ "oauth", .oauth },
        .{ "api_key", .api_key },
    });
    const typ = entry.type orelse return error.AuthNotFound;
    const resolved = auth_map.get(typ) orelse return error.AuthNotFound;
    return switch (resolved) {
        .oauth => blk: {
            const access = entry.access orelse return error.AuthNotFound;
            const refresh = entry.refresh orelse return error.AuthNotFound;
            const access_duped = try alloc.dupe(u8, access);
            errdefer alloc.free(access_duped);
            const refresh_duped = try alloc.dupe(u8, refresh);
            errdefer alloc.free(refresh_duped);
            const expires = entry.expires orelse 0;
            break :blk .{
                .oauth = .{
                    .access = access_duped,
                    .refresh = refresh_duped,
                    .expires = if (expires == 0) 0 else expires, // 0 = always-expired, triggers refresh
                },
            };
        },
        .api_key => blk: {
            const key = entry.key orelse return error.AuthNotFound;
            break :blk .{ .api_key = try alloc.dupe(u8, key) };
        },
    };
}

// ── Saving ─────────────────────────────────────────────────────────────

/// Shared read-modify-write for auth entries (OAuth tokens and API keys).
pub fn saveAuthEntry(alloc: std.mem.Allocator, home: []const u8, provider: Provider, entry: AuthEntry) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const home_dup = try ar.dupe(u8, home);
    const dir_path = try primaryAuthDir(ar, home_dup);
    try fs_secure.ensureDirPath(dir_path);
    const path = try authFilePath(ar, home_dup);

    var auth_file: AuthFile = .{};
    if (readPathAlloc(ar, path)) |raw| {
        auth_file = (try std.json.parseFromSlice(AuthFile, ar, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
        })).value;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    switch (provider) {
        inline else => |p| @field(auth_file, @tagName(p)) = entry,
    }

    const out = try std.json.Stringify.valueAlloc(ar, auth_file, .{ .whitespace = .indent_2 });
    try atomicAuthWrite(dir_path, "auth.json", out);
}

/// Atomic auth file write: temp + fsync + rename into dir_path.
fn atomicAuthWrite(dir_path: []const u8, name: []const u8, data: []const u8) !void {
    var dir = try openAuthDir(dir_path, .{});
    defer dir.close(defaultIo());
    try fs_secure.atomicWriteAt(dir, name, data);
}

pub fn saveOAuthForProviderWithHooks(alloc: std.mem.Allocator, provider: Provider, oauth: OAuth, hooks: Hooks) !void {
    const home = try resolveHome(alloc, hooks);
    defer alloc.free(home);
    return saveOAuthForProviderHome(alloc, home, provider, oauth);
}

fn saveOAuthForProviderHome(alloc: std.mem.Allocator, home: []const u8, provider: Provider, oauth: OAuth) !void {
    return saveAuthEntry(alloc, home, provider, .{
        .type = "oauth",
        .access = oauth.access,
        .refresh = oauth.refresh,
        .expires = oauth.expires,
    });
}

fn saveApiKeyHome(alloc: std.mem.Allocator, home: []const u8, provider: Provider, key: []const u8) !void {
    return saveApiKeyHomeWithHooks(alloc, home, provider, key, .{});
}

fn saveApiKeyHomeWithHooks(alloc: std.mem.Allocator, home: []const u8, provider: Provider, key: []const u8, hooks: Hooks) !void {
    try emitAuthAudit(alloc, hooks, 1, provider, "save_api_key", "api_key", .ok, .info, .{ .text = "api key save start", .vis = .@"pub" });
    saveApiKeyHomeRaw(alloc, home, provider, key) catch |err| {
        try emitAuthAudit(alloc, hooks, 2, provider, "save_api_key", "api_key", .fail, .err, .{ .text = @errorName(err), .vis = .mask });
        return err;
    };
    try emitAuthAudit(alloc, hooks, 2, provider, "save_api_key", "api_key", .ok, .notice, .{ .text = "api key save complete", .vis = .@"pub" });
}

fn saveApiKeyHomeRaw(alloc: std.mem.Allocator, home: []const u8, provider: Provider, key: []const u8) !void {
    return saveAuthEntry(alloc, home, provider, .{ .type = "api_key", .key = key });
}

/// Save API key for a provider. Writes to primary auth dir (~/.pz/).
pub fn saveApiKey(alloc: std.mem.Allocator, provider: Provider, key: []const u8) !void {
    return saveApiKeyWithHooks(alloc, provider, key, .{});
}

pub fn saveApiKeyWithHooks(alloc: std.mem.Allocator, provider: Provider, key: []const u8, hooks: Hooks) !void {
    const home = try resolveHome(alloc, hooks);
    defer alloc.free(home);
    return saveApiKeyHomeWithHooks(alloc, home, provider, key, hooks);
}

// ── List / Logout ──────────────────────────────────────────────────────

/// List providers that have credentials stored (merges all auth files).
pub fn listLoggedIn(alloc: std.mem.Allocator, home: ?[]const u8) ![]Provider {
    const h = home orelse return try alloc.alloc(Provider, 0);
    return listLoggedInHome(alloc, h);
}

fn listLoggedInHome(alloc: std.mem.Allocator, home: []const u8) ![]Provider {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const path = authFilePath(ar, home) catch return try alloc.alloc(Provider, 0);
    const raw = readPathAlloc(ar, path) catch return try alloc.alloc(Provider, 0);
    const parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.AuthCorrupt;
    const merged = parsed.value;

    var result = std.ArrayList(Provider).empty;
    errdefer result.deinit(alloc);
    // Preserve enum declaration order so callers see a stable provider list.
    inline for (@typeInfo(Provider).@"enum".fields) |field| {
        if (@field(merged, field.name) != null) {
            try result.append(alloc, @field(Provider, field.name));
        }
    }
    return try result.toOwnedSlice(alloc);
}

/// Remove credentials for a provider from all auth files.
pub fn logout(alloc: std.mem.Allocator, provider: Provider) !void {
    return logoutWithHooks(alloc, provider, .{});
}

pub fn logoutWithHooks(alloc: std.mem.Allocator, provider: Provider, hooks: Hooks) !void {
    const home = try resolveHome(alloc, hooks);
    defer alloc.free(home);
    return logoutHomeWithHooks(alloc, home, provider, hooks);
}

fn logoutHomeWithHooks(alloc: std.mem.Allocator, home: []const u8, provider: Provider, hooks: Hooks) !void {
    try emitAuthAudit(alloc, hooks, 1, provider, "logout", "stored", .ok, .info, .{ .text = "logout start", .vis = .@"pub" });
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const home_dup = try ar.dupe(u8, home);
    const dir_path = try primaryAuthDir(ar, home_dup);
    const path = try authFilePath(ar, home_dup);
    const raw = readPathAlloc(ar, path) catch |err| {
        if (err == error.FileNotFound) {
            try emitAuthAudit(alloc, hooks, 2, provider, "logout", "stored", .ok, .notice, .{ .text = "logout noop", .vis = .@"pub" });
            return;
        }
        try emitAuthAudit(alloc, hooks, 2, provider, "logout", "stored", .fail, .err, .{ .text = @errorName(err), .vis = .mask });
        return err;
    };
    var parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch {
        try emitAuthAudit(alloc, hooks, 2, provider, "logout", "stored", .fail, .err, .{ .text = "AuthCorrupt", .vis = .mask });
        return error.AuthCorrupt;
    };

    switch (provider) {
        inline else => |p| @field(parsed.value, @tagName(p)) = null,
    }

    const out = try std.json.Stringify.valueAlloc(ar, parsed.value, .{ .whitespace = .indent_2 });
    atomicAuthWrite(dir_path, "auth.json", out) catch |err| {
        try emitAuthAudit(alloc, hooks, 2, provider, "logout", "stored", .fail, .err, .{ .text = @errorName(err), .vis = .mask });
        return err;
    };
    try emitAuthAudit(alloc, hooks, 2, provider, "logout", "stored", .ok, .notice, .{ .text = "logout complete", .vis = .@"pub" });
}

// ── Audit helper ───────────────────────────────────────────────────────

pub fn emitAuthAudit(
    alloc: std.mem.Allocator,
    hooks: Hooks,
    seq: u64,
    provider: Provider,
    op: []const u8,
    mech: []const u8,
    out: audit.Outcome,
    sev: audit.Severity,
    msg: audit.Str,
) !void {
    if (hooks.audit_emitter) |e| try e.emit(alloc, .{
        .ts_ms = hooks.now_ms(),
        .sid = "auth",
        .seq = seq,
        .outcome = out,
        .severity = sev,
        .actor = .{ .kind = .sys },
        .res = .{
            .kind = .auth,
            .name = .{ .text = providerName(provider), .vis = .@"pub" },
            .op = op,
        },
        .msg = msg,
        .data = .{
            .auth = .{
                .mechanism = mech,
                .subject = .{ .text = providerName(provider), .vis = .@"pub" },
            },
        },
    });
}

// ── Tests ──────────────────────────────────────────────────────────────

const AuditRows = struct {
    emitter: audit.Emitter = .{ .vt = &audit.Emitter.Bind(@This(), emitAudit).vt },
    rows: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.rows.items) |row| alloc.free(row);
        self.rows.deinit(alloc);
    }

    fn emitAudit(self: *@This(), alloc: std.mem.Allocator, ent: audit.Entry) !void {
        const raw = try audit.encodeAlloc(alloc, ent);
        try self.rows.append(alloc, raw);
    }
};

test "saveApiKeyHome writes provider auth without process HOME" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    try saveApiKeyHome(std.testing.allocator, home, .openai, "sk-openai");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try loadFileAuthForProvider(arena.allocator(), home, .openai);
    try oh.snap(@src(),
        \\core.providers.auth.Auth
        \\  .api_key: []const u8
        \\    "sk-openai"
    ).expectEqual(a);

    if (builtin.os.tag != .windows) {
        const st = try tmp.dir.statFile(std.testing.io, ".pz/auth.json", .{});
        try std.testing.expectEqual(fs_secure.file_mode.toMode(), st.permissions.toMode() & 0o777);
    }
}

test "auth audit covers api key save" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);
    try saveApiKeyHomeWithHooks(std.testing.allocator, home, .openai, "sk-openai", .{
        .audit_emitter = &rows.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 11;
            }
        }.f,
    });

    const joined = try std.mem.join(std.testing.allocator, "\n", rows.rows.items);
    defer std.testing.allocator.free(joined);
    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":11,"sid":"auth","seq":1,"kind":"auth","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"auth","name":{"text":"openai","vis":"pub"},"op":"save_api_key"},"msg":{"text":"api key save start","vis":"pub"},"data":{"mech":"api_key","sub":{"text":"openai","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":11,"sid":"auth","seq":2,"kind":"auth","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"auth","name":{"text":"openai","vis":"pub"},"op":"save_api_key"},"msg":{"text":"api key save complete","vis":"pub"},"data":{"mech":"api_key","sub":{"text":"openai","vis":"pub"}},"attrs":[]}"
    ).expectEqual(joined);
}

test "auth audit covers logout" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try saveApiKeyHome(std.testing.allocator, home, .anthropic, "sk-ant");

    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);
    try logoutHomeWithHooks(std.testing.allocator, home, .anthropic, .{
        .audit_emitter = &rows.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 44;
            }
        }.f,
    });

    const joined = try std.mem.join(std.testing.allocator, "\n", rows.rows.items);
    defer std.testing.allocator.free(joined);
    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":44,"sid":"auth","seq":1,"kind":"auth","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"auth","name":{"text":"anthropic","vis":"pub"},"op":"logout"},"msg":{"text":"logout start","vis":"pub"},"data":{"mech":"stored","sub":{"text":"anthropic","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":44,"sid":"auth","seq":2,"kind":"auth","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"auth","name":{"text":"anthropic","vis":"pub"},"op":"logout"},"msg":{"text":"logout complete","vis":"pub"},"data":{"mech":"stored","sub":{"text":"anthropic","vis":"pub"}},"attrs":[]}"
    ).expectEqual(joined);
}

test "listLoggedInHome returns stored providers without leaks" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    try saveApiKeyHome(std.testing.allocator, home, .anthropic, "sk-ant");
    try saveApiKeyHome(std.testing.allocator, home, .openai, "sk-openai");

    const providers = try listLoggedInHome(std.testing.allocator, home);
    defer std.testing.allocator.free(providers);

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(std.testing.allocator);
    for (providers) |provider| {
        try out_buf.print(std.testing.allocator, "{s}\n", .{providerName(provider)});
    }

    try oh.snap(@src(),
        \\[]u8
        \\  "anthropic
        \\openai
        \\"
    ).expectEqual(out_buf.items);
}

test "auth lock still allows canonical file auth" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try saveApiKeyHome(std.testing.allocator, home, .openai, "sk-file");

    const Home = struct {
        var path: []const u8 = undefined;

        fn get(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
            try std.testing.expectEqualStrings("HOME", key);
            return alloc.dupe(u8, path);
        }
    };
    Home.path = home;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const resolved = try resolveHome(ar, .{
        .lock = .{ .auth = true },
        .get_home = Home.get,
    });
    const got = try loadFileAuthForProvider(ar, resolved, .openai);
    const key = switch (got) {
        .api_key => |v| try std.testing.allocator.dupe(u8, v),
        else => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(key);

    try oh.snap(@src(),
        \\[]u8
        \\  "sk-file"
    ).expectEqual(key);
}

test "saveApiKeyWithHooks rejects home override under auth lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    try std.testing.expectError(error.AuthStoreLocked, saveApiKeyWithHooks(std.testing.allocator, .openai, "sk-openai", .{
        .home_override = home,
        .lock = .{ .auth = true },
    }));
}

test "authFromEnv prefers oauth token over api key" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const a = authFromEnv(.{
        .oauth = "sk-ant-oat-123",
        .api_key = "sk-ant-123",
    }) orelse return error.TestUnexpectedResult;
    try oh.snap(@src(),
        \\core.providers.auth.Auth
        \\  .oauth: core.providers.auth.OAuth
        \\    .access: []const u8
        \\      "sk-ant-oat-123"
        \\    .refresh: []const u8
        \\      ""
        \\    .expires: i64 = 9223372036854775807
    ).expectEqual(a);
}

test "authFromEnv uses api key when oauth token is missing" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const a = authFromEnv(.{
        .oauth = null,
        .api_key = "sk-ant-123",
    }) orelse return error.TestUnexpectedResult;
    try oh.snap(@src(),
        \\core.providers.auth.Auth
        \\  .api_key: []const u8
        \\    "sk-ant-123"
    ).expectEqual(a);
}

test "loadFileAuth parses anthropic api_key entry" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/auth.json",
        .data =
        \\{
        \\  "anthropic": {
        \\    "type": "api_key",
        \\    "key": "sk-ant-file"
        \\  }
        \\}
        ,
    });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try loadFileAuth(arena.allocator(), home);
    try oh.snap(@src(),
        \\core.providers.auth.Auth
        \\  .api_key: []const u8
        \\    "sk-ant-file"
    ).expectEqual(a);
}

test "loadFileAuth returns AuthNotFound when file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = loadFileAuth(arena.allocator(), home);
    try std.testing.expectError(error.AuthNotFound, res);
}

test "findAuthFile migrates legacy .pi auth to .pz" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create legacy auth only (no .pz/auth.json)
    try tmp.dir.createDirPath(std.testing.io, ".pi/agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pi/agent/auth.json",
        .data =
        \\{
        \\  "anthropic": {
        \\    "type": "api_key",
        \\    "key": "sk-legacy"
        \\  }
        \\}
        ,
    });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    // Load should migrate and return from primary path
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try loadFileAuth(arena.allocator(), home);
    try oh.snap(@src(),
        \\core.providers.auth.Auth
        \\  .api_key: []const u8
        \\    "sk-legacy"
    ).expectEqual(a);

    // Verify migrated file exists at primary path
    try tmp.dir.access(std.testing.io, ".pz/auth.json", .{});
}

test "loadFileAuthForProvider parses openai oauth entry" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/auth.json",
        .data =
        \\{
        \\  "openai": {
        \\    "type": "oauth",
        \\    "access": "oa-access",
        \\    "refresh": "oa-refresh",
        \\    "expires": 123
        \\  }
        \\}
        ,
    });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try loadFileAuthForProvider(arena.allocator(), home, .openai);
    try oh.snap(@src(),
        \\core.providers.auth.Auth
        \\  .oauth: core.providers.auth.OAuth
        \\    .access: []const u8
        \\      "oa-access"
        \\    .refresh: []const u8
        \\      "oa-refresh"
        \\    .expires: i64 = 123
    ).expectEqual(a);
}

test "loadFileAuthForProvider returns AuthNotFound when provider missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/auth.json",
        .data =
        \\{
        \\  "anthropic": {
        \\    "type": "api_key",
        \\    "key": "sk-ant-file"
        \\  }
        \\}
        ,
    });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.AuthNotFound, loadFileAuthForProvider(arena.allocator(), home, .openai));
}

test "loadFileAuthForProvider fails closed on corrupt auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/auth.json", .data = "not json" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.AuthCorrupt, loadFileAuthForProvider(arena.allocator(), home, .anthropic));
}

test "loadFileAuthForProvider rejects unknown fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/auth.json", .data = "{\"anthropic\":{\"type\":\"api_key\",\"key\":\"k\"},\"bogus\":1}" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.AuthCorrupt, loadFileAuthForProvider(arena.allocator(), home, .anthropic));
}

test "listLoggedInHome fails closed on corrupt auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/auth.json", .data = "garbage" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try std.testing.expectError(error.AuthCorrupt, listLoggedInHome(std.testing.allocator, home));
}

test "logout removes provider entry from auth file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    // Save two providers
    try saveApiKeyHome(std.testing.allocator, home, .anthropic, "sk-ant");
    try saveApiKeyHome(std.testing.allocator, home, .openai, "sk-openai");

    // Logout anthropic
    try logoutHomeWithHooks(std.testing.allocator, home, .anthropic, .{});

    // Anthropic gone, openai remains
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.AuthNotFound, loadFileAuthForProvider(arena.allocator(), home, .anthropic));
    const oa = try loadFileAuthForProvider(arena.allocator(), home, .openai);
    try std.testing.expect(oa == .api_key);
}

test "P0-3 regression: listLoggedInHome deallocs cleanly with no providers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(home);

    const result = try listLoggedInHome(alloc, home);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "P0-3 regression: listLoggedInHome deallocs cleanly with all providers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(home);

    try saveApiKeyHome(alloc, home, .anthropic, "sk-a");
    try saveApiKeyHome(alloc, home, .openai, "sk-o");
    try saveApiKeyHome(alloc, home, .google, "sk-g");

    const result = try listLoggedInHome(alloc, home);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "P0-3 regression: listLoggedInHome deallocs cleanly on corrupt auth" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/auth.json", .data = "{invalid json" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(home);

    try std.testing.expectError(error.AuthCorrupt, listLoggedInHome(alloc, home));
}
