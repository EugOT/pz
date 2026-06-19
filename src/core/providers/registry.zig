//! Comptime provider registry: static metadata for every supported provider.
//!
//! This is the MP1 foundation for multi-provider support. It is self-contained
//! and NOT wired into the runtime yet (that is MP7). Later PRs (MP2 provider
//! impls, MP5 dispatch) read `ProviderInfo` to construct clients and route
//! requests without hardcoding host/path/auth knowledge.
//!
//! Design invariants:
//!   - Zero runtime allocation: the table is a comptime `StaticStringMap`.
//!   - Every entry is comptime-validated (see the `comptime` block below).
//!   - `resolveProvider` is a pure, allocation-free lookup.
//!   - Base-URL override is a documented READ-ONLY design contract: callers may
//!     read `base_url_env` and substitute host/path at request-build time. The
//!     registry itself never reads the environment (keeps it pure + testable).
const std = @import("std");

/// Canonical provider identity. Broader than `auth.Provider` on purpose:
/// the registry must name OpenAI-compatible providers that auth does not yet
/// model. MP7 will reconcile auth + registry tags.
pub const ProviderTag = enum {
    anthropic,
    openai,
    openrouter,
    google,
    mistral,
    groq,
    deepseek,
};

/// Authentication scheme a provider expects.
pub const AuthType = enum {
    /// OAuth bearer token (subscription / device flow).
    oauth,
    /// Static API key.
    api_key,
};

/// Wire format the provider speaks.
pub const RequestFormat = enum {
    /// Native Anthropic Messages API shape.
    anthropic,
    /// OpenAI-compatible Chat Completions / Responses shape. Used by openai,
    /// openrouter, mistral, groq, deepseek, and (via its compat endpoint)
    /// google. Transform helpers live in `compat.zig`.
    openai_compat,
};

/// Static, comptime-known metadata for one provider. No owned memory: every
/// field is a string literal or scalar, so copies are trivially safe.
pub const ProviderInfo = struct {
    /// Canonical tag (also the lookup key's meaning).
    provider_tag: ProviderTag,
    /// API hostname, no scheme, no trailing slash. e.g. "api.openai.com".
    api_host: []const u8,
    /// Request path including leading slash. e.g. "/v1/chat/completions".
    api_path: []const u8,
    /// Default auth scheme.
    auth_type: AuthType,
    /// Wire format for request/response bodies.
    request_format: RequestFormat,
    /// HTTP header carrying the credential. e.g. "authorization", "x-api-key".
    auth_header_name: []const u8,
    /// JSON field name for extended-thinking/reasoning content in responses,
    /// or null if the provider has no reasoning channel. anthropic: "thinking";
    /// openai reasoning models surface "reasoning".
    thinking_field_name: ?[]const u8,
    /// Environment variable name a caller MAY read to override the base URL
    /// (host+path). Documented read-only contract; the registry never reads it.
    base_url_env: []const u8,
};

/// The provider table. Ordered for readability, not lookup (StaticStringMap
/// hashes at comptime). Keys are the canonical lowercase provider names that
/// `resolveProvider` accepts.
const entries = [_]struct { []const u8, ProviderInfo }{
    .{ "anthropic", .{
        .provider_tag = .anthropic,
        .api_host = "api.anthropic.com",
        .api_path = "/v1/messages",
        .auth_type = .oauth,
        .request_format = .anthropic,
        .auth_header_name = "x-api-key",
        .thinking_field_name = "thinking",
        .base_url_env = "ANTHROPIC_BASE_URL",
    } },
    .{ "openai", .{
        .provider_tag = .openai,
        .api_host = "api.openai.com",
        .api_path = "/v1/responses",
        .auth_type = .api_key,
        .request_format = .openai_compat,
        .auth_header_name = "authorization",
        .thinking_field_name = "reasoning",
        .base_url_env = "OPENAI_BASE_URL",
    } },
    .{ "openrouter", .{
        .provider_tag = .openrouter,
        .api_host = "openrouter.ai",
        .api_path = "/api/v1/chat/completions",
        .auth_type = .api_key,
        .request_format = .openai_compat,
        .auth_header_name = "authorization",
        .thinking_field_name = "reasoning",
        .base_url_env = "OPENROUTER_BASE_URL",
    } },
    .{ "google", .{
        .provider_tag = .google,
        .api_host = "generativelanguage.googleapis.com",
        .api_path = "/v1beta/openai/chat/completions",
        .auth_type = .api_key,
        .request_format = .openai_compat,
        .auth_header_name = "authorization",
        .thinking_field_name = "reasoning",
        .base_url_env = "GOOGLE_BASE_URL",
    } },
    .{ "mistral", .{
        .provider_tag = .mistral,
        .api_host = "api.mistral.ai",
        .api_path = "/v1/chat/completions",
        .auth_type = .api_key,
        .request_format = .openai_compat,
        .auth_header_name = "authorization",
        .thinking_field_name = null,
        .base_url_env = "MISTRAL_BASE_URL",
    } },
    .{ "groq", .{
        .provider_tag = .groq,
        .api_host = "api.groq.com",
        .api_path = "/openai/v1/chat/completions",
        .auth_type = .api_key,
        .request_format = .openai_compat,
        .auth_header_name = "authorization",
        .thinking_field_name = "reasoning",
        .base_url_env = "GROQ_BASE_URL",
    } },
    .{ "deepseek", .{
        .provider_tag = .deepseek,
        .api_host = "api.deepseek.com",
        .api_path = "/chat/completions",
        .auth_type = .api_key,
        .request_format = .openai_compat,
        .auth_header_name = "authorization",
        .thinking_field_name = "reasoning_content",
        .base_url_env = "DEEPSEEK_BASE_URL",
    } },
};

/// Comptime lookup table. Built once at compile time; zero runtime cost.
const table = std.StaticStringMap(ProviderInfo).initComptime(entries);

// Comptime validation: catch malformed entries at compile time, not in prod.
// Enforces the field contracts documented on `ProviderInfo`.
comptime {
    // Key/tag agreement and structural invariants.
    for (entries) |entry| {
        const name, const info = entry;
        if (name.len == 0) @compileError("registry: empty provider key");
        if (info.api_host.len == 0)
            @compileError("registry: empty api_host for '" ++ name ++ "'");
        if (info.api_path.len == 0 or info.api_path[0] != '/')
            @compileError("registry: api_path must start with '/' for '" ++ name ++ "'");
        if (info.auth_header_name.len == 0)
            @compileError("registry: empty auth_header_name for '" ++ name ++ "'");
        if (info.base_url_env.len == 0)
            @compileError("registry: empty base_url_env for '" ++ name ++ "'");
        // anthropic format implies the native anthropic host family; OpenAI-
        // compatible providers must not claim the anthropic request format.
        if (info.provider_tag != .anthropic and info.request_format == .anthropic)
            @compileError("registry: non-anthropic provider '" ++ name ++ "' must use openai_compat");
    }
    // Every ProviderTag must appear exactly once (total coverage, no dupes).
    for (std.enums.values(ProviderTag)) |tag| {
        var seen: usize = 0;
        for (entries) |entry| {
            if (entry[1].provider_tag == tag) seen += 1;
        }
        if (seen == 0) @compileError("registry: missing entry for tag " ++ @tagName(tag));
        if (seen > 1) @compileError("registry: duplicate entries for tag " ++ @tagName(tag));
    }
}

/// Resolve a provider by its canonical lowercase name. Pure, allocation-free.
/// Returns null for unknown names (no silent fallback to a default provider).
pub fn resolveProvider(name: []const u8) ?ProviderInfo {
    return table.get(name);
}

/// Comptime-built dense table indexed by `@intFromEnum(ProviderTag)`. The
/// comptime validation block proves every tag has exactly one entry, so this
/// covers all tags with no holes and no runtime fallback.
const by_tag_table = blk: {
    var arr: [std.enums.values(ProviderTag).len]ProviderInfo = undefined;
    for (entries) |entry| {
        arr[@intFromEnum(entry[1].provider_tag)] = entry[1];
    }
    break :blk arr;
};

/// Resolve by canonical tag. O(1) dense-array lookup; allocation-free. Always
/// returns the matching `ProviderInfo` because the comptime block guarantees
/// total tag coverage (no silent fallback, no sentinel).
pub fn byTag(tag: ProviderTag) ProviderInfo {
    return by_tag_table[@intFromEnum(tag)];
}

/// Number of registered providers. Comptime-known.
pub const count = entries.len;

/// All registered canonical names, in declaration order. Useful for `--help`
/// listings and validation messages. Comptime-known, no allocation.
pub fn names() [count][]const u8 {
    var out: [count][]const u8 = undefined;
    inline for (entries, 0..) |entry, i| out[i] = entry[0];
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────────
// These run wherever this file is reachable from a test root (see
// src/test/provider_registry_test.zig and src/tests.zig).

const testing = std.testing;

test "resolveProvider returns anthropic native format" {
    const info = resolveProvider("anthropic").?;
    try testing.expectEqual(ProviderTag.anthropic, info.provider_tag);
    try testing.expectEqualStrings("api.anthropic.com", info.api_host);
    try testing.expectEqualStrings("/v1/messages", info.api_path);
    try testing.expectEqual(RequestFormat.anthropic, info.request_format);
    try testing.expectEqual(AuthType.oauth, info.auth_type);
    try testing.expectEqualStrings("x-api-key", info.auth_header_name);
    try testing.expectEqualStrings("thinking", info.thinking_field_name.?);
}

test "resolveProvider returns 7 distinct OpenAI-compatible + native providers" {
    const expect_compat = [_][]const u8{ "openai", "openrouter", "google", "mistral", "groq", "deepseek" };
    for (expect_compat) |name| {
        const info = resolveProvider(name).?;
        try testing.expectEqual(RequestFormat.openai_compat, info.request_format);
        try testing.expectEqual(AuthType.api_key, info.auth_type);
        try testing.expect(info.api_host.len > 0);
        try testing.expect(info.api_path[0] == '/');
    }
    // 6 compat + anthropic = 7 total.
    try testing.expectEqual(@as(usize, 7), count);
}

test "resolveProvider host/path map per provider" {
    try testing.expectEqualStrings("openrouter.ai", resolveProvider("openrouter").?.api_host);
    try testing.expectEqualStrings("/api/v1/chat/completions", resolveProvider("openrouter").?.api_path);
    try testing.expectEqualStrings("api.groq.com", resolveProvider("groq").?.api_host);
    try testing.expectEqualStrings("/openai/v1/chat/completions", resolveProvider("groq").?.api_path);
    try testing.expectEqualStrings("api.deepseek.com", resolveProvider("deepseek").?.api_host);
    try testing.expectEqualStrings("/chat/completions", resolveProvider("deepseek").?.api_path);
}

test "resolveProvider unknown returns null (no silent fallback)" {
    try testing.expect(resolveProvider("not-a-provider") == null);
    try testing.expect(resolveProvider("") == null);
    try testing.expect(resolveProvider("Anthropic") == null); // case-sensitive
}

test "thinking_field_name present for reasoning providers, null for mistral" {
    try testing.expectEqualStrings("reasoning", resolveProvider("openai").?.thinking_field_name.?);
    try testing.expectEqualStrings("reasoning", resolveProvider("openrouter").?.thinking_field_name.?);
    try testing.expectEqualStrings("reasoning_content", resolveProvider("deepseek").?.thinking_field_name.?);
    try testing.expect(resolveProvider("mistral").?.thinking_field_name == null);
}

test "base_url_env documented per provider" {
    try testing.expectEqualStrings("ANTHROPIC_BASE_URL", resolveProvider("anthropic").?.base_url_env);
    try testing.expectEqualStrings("OPENAI_BASE_URL", resolveProvider("openai").?.base_url_env);
    try testing.expectEqualStrings("OPENROUTER_BASE_URL", resolveProvider("openrouter").?.base_url_env);
}

test "byTag matches resolveProvider for every tag" {
    inline for (std.enums.values(ProviderTag)) |tag| {
        const by_tag = byTag(tag);
        try testing.expectEqual(tag, by_tag.provider_tag);
    }
    // Cross-check name lookup agrees with tag lookup for anthropic.
    try testing.expectEqualStrings(byTag(.anthropic).api_host, resolveProvider("anthropic").?.api_host);
}

test "names returns all canonical keys in order" {
    const all = names();
    try testing.expectEqual(@as(usize, 7), all.len);
    try testing.expectEqualStrings("anthropic", all[0]);
    try testing.expectEqualStrings("openai", all[1]);
    try testing.expectEqualStrings("deepseek", all[6]);
    // Every name round-trips through resolveProvider.
    for (all) |name| try testing.expect(resolveProvider(name) != null);
}
