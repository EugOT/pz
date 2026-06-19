//! Provider authentication: API key and OAuth token resolution.
//!
//! This module defines auth types and re-exports the public API from:
//!   - auth_load.zig: credential loading, file I/O, persistence
//!   - oauth_flow.zig: OAuth protocol, PKCE, token exchange, refresh
const std = @import("std");
const audit = @import("../audit.zig");
const policy = @import("../policy.zig");
const core_time = @import("../time.zig");

// ── Submodules (pull in their tests) ───────────────────────────────────

const auth_load = @import("auth_load.zig");
const oauth_flow = @import("oauth_flow.zig");

comptime {
    _ = auth_load;
    _ = oauth_flow;
}

// ── Types ──────────────────────────────────────────────────────────────

pub const Auth = union(enum) {
    oauth: OAuth,
    api_key: []const u8, // x-api-key
};

pub const OAuth = struct {
    access: []const u8,
    refresh: []const u8,
    expires: i64, // ms since epoch
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    auth: Auth,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

pub const AuthEntry = struct {
    type: ?[]const u8 = null,
    access: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    expires: ?i64 = null,
    key: ?[]const u8 = null,
};

pub const Provider = enum {
    anthropic,
    openai,
    google,
    mistral,
    groq,
    deepseek,
    openrouter,
};

/// Display/lookup names, indexed by `@intFromEnum(Provider)`. Order MUST match
/// the `Provider` enum declaration order exactly.
pub const provider_names = [_][]const u8{
    "anthropic",
    "openai",
    "google",
    "mistral",
    "groq",
    "deepseek",
    "openrouter",
};

comptime {
    // Fail the build if a Provider variant is added without a matching name.
    if (provider_names.len != @typeInfo(Provider).@"enum".fields.len) {
        @compileError("provider_names must cover every Provider variant");
    }
}

pub fn providerName(p: Provider) []const u8 {
    return provider_names[@intFromEnum(p)];
}

pub const Hooks = struct {
    const Self = @This();

    home_override: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
    lock: policy.Lock = .{},
    get_home: *const fn (std.mem.Allocator, []const u8) anyerror![]u8 = defaultGetHome,
    exchange_code: *const fn (std.mem.Allocator, *const OAuthSpec, []const u8, []const u8, []const u8, []const u8, Self) anyerror!OAuth = oauth_flow.exchangeAuthorizationCode,
    refresh_fetch: *const fn (std.mem.Allocator, Provider, OAuth, Self) anyerror!OAuth = oauth_flow.fetchRefreshedOAuthForProvider,
    audit_emitter: ?*audit.Emitter = null,
    now_ms: *const fn () i64 = core_time.milliTimestamp,
};

fn defaultGetHome(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_len: usize = 0;
    while (std.c.environ[env_len] != null) : (env_len += 1) {}
    var env = try std.process.Environ.createMap(.{
        .block = .{ .slice = std.c.environ[0..env_len :null] },
    }, alloc);
    defer env.deinit();

    const value = env.get(name) orelse return error.EnvironmentVariableMissing;
    return alloc.dupe(u8, value);
}

pub const OAuthTokenBody = enum {
    json_with_state,
    form_no_state,
    form_with_state,
};

pub const OAuthParam = struct {
    key: []const u8,
    value: []const u8,
};

pub const OAuthSpec = struct {
    provider: Provider,
    client_id: []const u8,
    authorize_url: []const u8,
    token_host: []const u8,
    token_path: []const u8,
    default_redirect_uri: []const u8,
    success_redirect_url: ?[]const u8 = null,
    scopes: []const u8,
    refresh_scope: ?[]const u8 = null,
    local_callback_path: []const u8,
    local_redirect_host: []const u8,
    start_action: []const u8,
    complete_action: []const u8,
    api_key_prefix: ?[]const u8 = null,
    token_body: OAuthTokenBody,
    token_accept: ?[]const u8 = null,
    extra_authorize: []const OAuthParam = &.{},
};

pub const OAuthStart = struct {
    url: []u8,
    state: []u8,
    verifier: []u8,

    pub fn deinit(self: *OAuthStart, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.state);
        alloc.free(self.verifier);
        self.* = undefined;
    }
};

pub const OAuthCodeInput = struct {
    code: []u8,
    state: ?[]u8 = null,
    redirect_uri: ?[]u8 = null,

    pub fn deinit(self: *OAuthCodeInput, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        if (self.state) |s| alloc.free(s);
        if (self.redirect_uri) |u| alloc.free(u);
        self.* = undefined;
    }
};

pub const AuthFile = struct {
    anthropic: ?AuthEntry = null,
    openai: ?AuthEntry = null,
    google: ?AuthEntry = null,
    mistral: ?AuthEntry = null,
    groq: ?AuthEntry = null,
    deepseek: ?AuthEntry = null,
    openrouter: ?AuthEntry = null,
};

pub const OAuthLoginInfo = struct {
    callback_path: []const u8,
    redirect_host: []const u8,
    success_redirect_url: ?[]const u8,
    start_action: []const u8,
    complete_action: []const u8,
};

// ── Re-exports: auth_load ──────────────────────────────────────────────

pub const load = auth_load.load;
pub const loadForProvider = auth_load.loadForProvider;
pub const loadForProviderWithHooks = auth_load.loadForProviderWithHooks;
pub const saveApiKey = auth_load.saveApiKey;
pub const saveApiKeyWithHooks = auth_load.saveApiKeyWithHooks;
pub const listLoggedIn = auth_load.listLoggedIn;
pub const logout = auth_load.logout;
pub const logoutWithHooks = auth_load.logoutWithHooks;

// ── Re-exports: oauth_flow ─────────────────────────────────────────────

pub const oauthLoginInfo = oauth_flow.oauthLoginInfo;
pub const oauthCapable = oauth_flow.oauthCapable;
pub const looksLikeApiKey = oauth_flow.looksLikeApiKey;
pub const beginOAuth = oauth_flow.beginOAuth;
pub const beginOAuthWithRedirect = oauth_flow.beginOAuthWithRedirect;
pub const completeOAuth = oauth_flow.completeOAuth;
pub const completeOAuthWithHooks = oauth_flow.completeOAuthWithHooks;
pub const completeOAuthFromLocalCallback = oauth_flow.completeOAuthFromLocalCallback;
pub const completeOAuthFromLocalCallbackWithHooks = oauth_flow.completeOAuthFromLocalCallbackWithHooks;
pub const parseOAuthInput = oauth_flow.parseOAuthInput;
pub const openBrowser = oauth_flow.openBrowser;
pub const refreshOAuth = oauth_flow.refreshOAuth;
pub const refreshOAuthForProvider = oauth_flow.refreshOAuthForProvider;
pub const refreshOAuthForProviderWithHooks = oauth_flow.refreshOAuthForProviderWithHooks;

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Providers added in MP4 that authenticate with a static API key only and
/// have no OAuth flow.
const api_key_only_providers = [_]Provider{ .mistral, .groq, .deepseek, .openrouter };

test "providerName covers every Provider variant" {
    // Every enum value resolves to a name, and the name round-trips back to the
    // same variant via std.meta.stringToEnum. Proves provider_names stays in
    // lockstep with the enum (the comptime guard above enforces length parity).
    inline for (@typeInfo(Provider).@"enum".fields) |field| {
        const p: Provider = @field(Provider, field.name);
        const name = providerName(p);
        try testing.expectEqualStrings(field.name, name);
        const back = std.meta.stringToEnum(Provider, name) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(p, back);
    }

    // The MP4 additions are present and distinctly named.
    try testing.expectEqualStrings("mistral", providerName(.mistral));
    try testing.expectEqualStrings("groq", providerName(.groq));
    try testing.expectEqualStrings("deepseek", providerName(.deepseek));
    try testing.expectEqualStrings("openrouter", providerName(.openrouter));
}

test "api-key-only providers are not OAuth capable" {
    // None of the new providers expose an OAuth spec, so the login path treats
    // their credentials as API keys instead of starting an OAuth flow.
    for (api_key_only_providers) |p| {
        try testing.expect(!oauthCapable(p));
        // looksLikeApiKey has no prefix to match, so any non-empty value counts
        // as a key (and an empty value does not).
        try testing.expect(looksLikeApiKey(p, "secret-token"));
        try testing.expect(!looksLikeApiKey(p, ""));
    }
}

test "api-key entry loads from disk for an api-key-only provider" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try auth_load.saveAuthEntry(testing.allocator, home, .openrouter, .{
        .type = "api_key",
        .key = "sk-or-test",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try auth_load.loadFileAuthForProvider(arena.allocator(), home, .openrouter);
    try testing.expect(loaded == .api_key);
    try testing.expectEqualStrings("sk-or-test", loaded.api_key);
}

test "loadForProviderWithHooks resolves api key without attempting OAuth" {
    // Drive the full resolution entry point (the same one runtime uses). With a
    // home override and no env credentials, an api-key-only provider must
    // resolve straight to its stored key — never the OAuth branch.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try auth_load.saveAuthEntry(testing.allocator, home, .mistral, .{
        .type = "api_key",
        .key = "ml-key-123",
    });

    // Sentinel hooks: if resolution ever touched the OAuth exchange/refresh
    // paths it would invoke these and fail the test.
    const Guard = struct {
        fn home_fn(alloc: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return alloc.dupe(u8, "");
        }
        fn exchange(_: std.mem.Allocator, _: *const OAuthSpec, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: Hooks) anyerror!OAuth {
            return error.OAuthShouldNotRun;
        }
        fn refresh(_: std.mem.Allocator, _: Provider, _: OAuth, _: Hooks) anyerror!OAuth {
            return error.OAuthShouldNotRun;
        }
    };

    var result = try loadForProviderWithHooks(testing.allocator, .mistral, .{
        .home_override = home,
        .get_home = Guard.home_fn,
        .exchange_code = Guard.exchange,
        .refresh_fetch = Guard.refresh,
    });
    defer result.deinit();

    try testing.expect(result.auth == .api_key);
    try testing.expectEqualStrings("ml-key-123", result.auth.api_key);
}
