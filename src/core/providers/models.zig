//! Centralized model metadata registry.
//! Single source of truth for context windows, pricing, and capabilities.
//!
//! MP3 extension: the model table now spans every provider the registry
//! (`registry.zig`) names — anthropic, openai, openrouter, google, mistral,
//! groq, deepseek — and each `ModelInfo` carries a default thinking budget, a
//! per-model rate limit (tokens/minute), and optional per-model host/path
//! overrides for cases where a model is reached through a non-default base URL
//! (e.g. OpenRouter-hosted models keyed by their slug).
//!
//! Design invariants:
//!   - Zero runtime allocation: the table is a comptime array of literals.
//!   - `findModel` is pure: longest-prefix wins, then substring fallback.
//!   - Existing claude/gpt/o-series names resolve exactly as before MP3.
//!   - `base_url`/`api_path` overrides are a documented READ-ONLY contract:
//!     callers may substitute them at request-build time. null means "use the
//!     provider default from registry.zig" — never a silent host guess.
const std = @import("std");
const reg = @import("registry.zig");

/// Canonical model-provider identity. Aliased to `registry.ProviderTag` so the
/// provider tag has a single source of truth across auth + models. Avoids two
/// structurally-identical enums whose ordinals coincide by accident — a
/// cross-typed `@intFromEnum` cast would otherwise silently mis-map providers.
pub const Provider = reg.ProviderTag;

pub const ModelInfo = struct {
    name: []const u8,
    provider: Provider,
    ctx_win: u32, // context window in tokens
    in_cost: u64, // micents per million input tokens
    out_cost: u64, // micents per million output tokens
    cache_read: u64, // micents per million cache-read tokens
    cache_write: u64, // micents per million cache-write tokens
    thinking: bool, // supports extended thinking
    /// Default extended-thinking token budget for this model. 0 when the model
    /// has no thinking channel (`thinking == false`).
    thinking_default_budget: u32 = 0,
    /// Per-model rate limit in tokens per minute (TPM). 0 means "unspecified —
    /// fall back to the account/provider default". Never used as a silent cap.
    rate_limit_tpm: u32 = 0,
    /// Optional host override (no scheme, no trailing slash). null means use the
    /// provider default from registry.zig. e.g. an OpenRouter-hosted model sets
    /// "openrouter.ai" here even though its `provider` may be the upstream tag.
    base_url: ?[]const u8 = null,
    /// Optional request-path override (leading slash). null means use the
    /// provider default from registry.zig.
    api_path: ?[]const u8 = null,
};

/// Known model table. Ordered for readability, not lookup.
const registry = [_]ModelInfo{
    // ── Anthropic ────────────────────────────────────────────────
    .{ .name = "claude-opus-4", .provider = .anthropic, .ctx_win = 200_000, .in_cost = 1500, .out_cost = 7500, .cache_read = 150, .cache_write = 1875, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 200_000 },
    .{ .name = "claude-sonnet-4", .provider = .anthropic, .ctx_win = 200_000, .in_cost = 300, .out_cost = 1500, .cache_read = 30, .cache_write = 375, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 400_000 },
    .{ .name = "claude-haiku-3", .provider = .anthropic, .ctx_win = 200_000, .in_cost = 80, .out_cost = 400, .cache_read = 8, .cache_write = 100, .thinking = false, .rate_limit_tpm = 400_000 },
    .{ .name = "claude-3-5-sonnet", .provider = .anthropic, .ctx_win = 200_000, .in_cost = 300, .out_cost = 1500, .cache_read = 30, .cache_write = 375, .thinking = false, .rate_limit_tpm = 400_000 },
    .{ .name = "claude-3-5-haiku", .provider = .anthropic, .ctx_win = 200_000, .in_cost = 80, .out_cost = 400, .cache_read = 8, .cache_write = 100, .thinking = false, .rate_limit_tpm = 400_000 },
    // ── OpenAI ───────────────────────────────────────────────────
    .{ .name = "gpt-4o", .provider = .openai, .ctx_win = 128_000, .in_cost = 250, .out_cost = 1000, .cache_read = 125, .cache_write = 0, .thinking = false, .rate_limit_tpm = 800_000 },
    .{ .name = "gpt-4o-mini", .provider = .openai, .ctx_win = 128_000, .in_cost = 15, .out_cost = 60, .cache_read = 7, .cache_write = 0, .thinking = false, .rate_limit_tpm = 2_000_000 },
    .{ .name = "gpt-4-turbo", .provider = .openai, .ctx_win = 128_000, .in_cost = 1000, .out_cost = 3000, .cache_read = 0, .cache_write = 0, .thinking = false, .rate_limit_tpm = 800_000 },
    .{ .name = "o1", .provider = .openai, .ctx_win = 200_000, .in_cost = 1500, .out_cost = 6000, .cache_read = 750, .cache_write = 0, .thinking = true, .thinking_default_budget = 25_000, .rate_limit_tpm = 200_000 },
    .{ .name = "o1-mini", .provider = .openai, .ctx_win = 128_000, .in_cost = 300, .out_cost = 1200, .cache_read = 150, .cache_write = 0, .thinking = true, .thinking_default_budget = 16_000, .rate_limit_tpm = 200_000 },
    .{ .name = "o1-pro", .provider = .openai, .ctx_win = 200_000, .in_cost = 15000, .out_cost = 60000, .cache_read = 0, .cache_write = 0, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 30_000 },
    .{ .name = "o3", .provider = .openai, .ctx_win = 200_000, .in_cost = 1000, .out_cost = 4000, .cache_read = 500, .cache_write = 0, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 200_000 },
    .{ .name = "o3-mini", .provider = .openai, .ctx_win = 200_000, .in_cost = 110, .out_cost = 440, .cache_read = 55, .cache_write = 0, .thinking = true, .thinking_default_budget = 25_000, .rate_limit_tpm = 200_000 },
    .{ .name = "o4-mini", .provider = .openai, .ctx_win = 200_000, .in_cost = 110, .out_cost = 440, .cache_read = 55, .cache_write = 0, .thinking = true, .thinking_default_budget = 25_000, .rate_limit_tpm = 200_000 },
    // ── OpenRouter (aggregator; reached via openrouter.ai with provider slugs) ─
    // base_url/api_path overrides document that these slugs route through the
    // OpenRouter host regardless of the upstream model family.
    .{ .name = "openrouter/auto", .provider = .openrouter, .ctx_win = 128_000, .in_cost = 0, .out_cost = 0, .cache_read = 0, .cache_write = 0, .thinking = false, .base_url = "openrouter.ai", .api_path = "/api/v1/chat/completions" },
    .{ .name = "anthropic/claude-sonnet-4", .provider = .openrouter, .ctx_win = 200_000, .in_cost = 300, .out_cost = 1500, .cache_read = 30, .cache_write = 375, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 400_000, .base_url = "openrouter.ai", .api_path = "/api/v1/chat/completions" },
    // ── Google (Gemini via OpenAI-compat endpoint) ────────────────
    .{ .name = "gemini-2.5-pro", .provider = .google, .ctx_win = 1_048_576, .in_cost = 125, .out_cost = 1000, .cache_read = 31, .cache_write = 0, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 2_000_000 },
    .{ .name = "gemini-2.5-flash", .provider = .google, .ctx_win = 1_048_576, .in_cost = 30, .out_cost = 250, .cache_read = 7, .cache_write = 0, .thinking = true, .thinking_default_budget = 24_000, .rate_limit_tpm = 4_000_000 },
    .{ .name = "gemini-2.0-flash", .provider = .google, .ctx_win = 1_048_576, .in_cost = 10, .out_cost = 40, .cache_read = 2, .cache_write = 0, .thinking = false, .rate_limit_tpm = 4_000_000 },
    // ── Mistral (no reasoning channel) ────────────────────────────
    .{ .name = "mistral-large", .provider = .mistral, .ctx_win = 128_000, .in_cost = 200, .out_cost = 600, .cache_read = 0, .cache_write = 0, .thinking = false, .rate_limit_tpm = 500_000 },
    .{ .name = "mistral-small", .provider = .mistral, .ctx_win = 128_000, .in_cost = 20, .out_cost = 60, .cache_read = 0, .cache_write = 0, .thinking = false, .rate_limit_tpm = 1_000_000 },
    // ── Groq (fast inference of open-weight models) ───────────────
    .{ .name = "llama-3.3-70b-versatile", .provider = .groq, .ctx_win = 128_000, .in_cost = 59, .out_cost = 79, .cache_read = 0, .cache_write = 0, .thinking = false, .rate_limit_tpm = 300_000 },
    .{ .name = "deepseek-r1-distill-llama-70b", .provider = .groq, .ctx_win = 128_000, .in_cost = 75, .out_cost = 99, .cache_read = 0, .cache_write = 0, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 300_000 },
    // ── DeepSeek (reasoning via reasoning_content) ────────────────
    .{ .name = "deepseek-chat", .provider = .deepseek, .ctx_win = 64_000, .in_cost = 27, .out_cost = 110, .cache_read = 7, .cache_write = 0, .thinking = false, .rate_limit_tpm = 1_000_000 },
    .{ .name = "deepseek-reasoner", .provider = .deepseek, .ctx_win = 64_000, .in_cost = 55, .out_cost = 219, .cache_read = 14, .cache_write = 0, .thinking = true, .thinking_default_budget = 32_000, .rate_limit_tpm = 1_000_000 },
};

// Comptime validation: keep the table internally consistent so malformed rows
// fail the build instead of misrouting requests at runtime.
comptime {
    for (registry) |m| {
        if (m.name.len == 0) @compileError("models: empty model name");
        // A non-zero thinking budget only makes sense for thinking models, and
        // every thinking model must declare a budget (no silent 0 default).
        if (m.thinking and m.thinking_default_budget == 0)
            @compileError("models: thinking model '" ++ m.name ++ "' missing thinking_default_budget");
        if (!m.thinking and m.thinking_default_budget != 0)
            @compileError("models: non-thinking model '" ++ m.name ++ "' must have zero thinking_default_budget");
        // Path overrides must be absolute when present (mirrors registry.zig).
        if (m.api_path) |p| {
            if (p.len == 0 or p[0] != '/')
                @compileError("models: api_path override must start with '/' for '" ++ m.name ++ "'");
        }
        if (m.base_url) |h| {
            if (h.len == 0) @compileError("models: empty base_url override for '" ++ m.name ++ "'");
        }
    }
}

/// Find model by name: longest exact-prefix match against registry entries.
/// Handles versioned names like "claude-opus-4-20250514" matching "claude-opus-4",
/// and provider-prefixed slugs like "anthropic/claude-sonnet-4-20250522".
pub fn findModel(name: []const u8) ?ModelInfo {
    // Longest prefix wins — iterate all, keep best.
    var best: ?ModelInfo = null;
    var best_len: usize = 0;
    for (&registry) |*m| {
        if (name.len >= m.name.len and
            std.mem.eql(u8, name[0..m.name.len], m.name) and
            m.name.len > best_len)
        {
            best = m.*;
            best_len = m.name.len;
        }
    }
    // Longest exact-prefix match only. No substring fallback: a flat namespace
    // mixing provider-prefixed slugs (`anthropic/claude-sonnet-4`) with bare
    // names (`claude-sonnet-4`) makes substring matching route to whichever row
    // appears first in iteration order — i.e. the wrong provider. Safe failure
    // (null) beats a silent mis-route; provider-scoped lookup lands in MP7.
    return best;
}

pub fn contextWindow(name: []const u8) ?u32 {
    return if (findModel(name)) |m| m.ctx_win else null;
}

pub fn supportsThinking(name: []const u8) bool {
    return if (findModel(name)) |m| m.thinking else false;
}

/// Default extended-thinking budget (tokens) for a model, or null if unknown.
/// Non-thinking models return 0 (they have a valid entry but no budget).
pub fn thinkingBudget(name: []const u8) ?u32 {
    return if (findModel(name)) |m| m.thinking_default_budget else null;
}

/// Per-model rate limit in tokens/minute, or null if the model is unknown.
/// A returned 0 means "unspecified" — callers fall back to provider/account
/// defaults; it is never a silent hard cap.
pub fn rateLimitTpm(name: []const u8) ?u32 {
    return if (findModel(name)) |m| m.rate_limit_tpm else null;
}

pub const CostRates = struct { in: u64, out: u64, cr: u64, cw: u64 };

pub fn costRates(name: []const u8) ?CostRates {
    const m = findModel(name) orelse return null;
    return .{ .in = m.in_cost, .out = m.out_cost, .cr = m.cache_read, .cw = m.cache_write };
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "findModel exact prefix" {
    const m = findModel("claude-opus-4-20250514").?;
    try testing.expectEqualStrings("claude-opus-4", m.name);
    try testing.expect(m.thinking);
    try testing.expectEqual(@as(u32, 200_000), m.ctx_win);
}

test "findModel versioned sonnet" {
    const m = findModel("claude-sonnet-4-20250514").?;
    try testing.expectEqualStrings("claude-sonnet-4", m.name);
    try testing.expect(m.thinking);
}

test "findModel old sonnet no thinking" {
    const m = findModel("claude-3-5-sonnet-20241022").?;
    try testing.expectEqualStrings("claude-3-5-sonnet", m.name);
    try testing.expect(!m.thinking);
}

test "findModel haiku no thinking" {
    const m = findModel("claude-haiku-3-20240307").?;
    try testing.expect(!m.thinking);
}

test "findModel openai" {
    const m = findModel("gpt-4o-mini").?;
    try testing.expectEqual(Provider.openai, m.provider);
    try testing.expectEqual(@as(u64, 15), m.in_cost);
}

test "findModel unknown returns null" {
    try testing.expect(findModel("unknown-model-xyz") == null);
}

test "contextWindow" {
    try testing.expectEqual(@as(u32, 200_000), contextWindow("claude-opus-4-6").?);
    try testing.expect(contextWindow("nonexistent") == null);
}

test "supportsThinking matches anthropic" {
    try testing.expect(supportsThinking("claude-opus-4-20250514"));
    try testing.expect(supportsThinking("claude-sonnet-4-20250514"));
    try testing.expect(!supportsThinking("claude-haiku-3-20240307"));
    try testing.expect(!supportsThinking("claude-3-5-sonnet-20241022"));
}

test "supportsThinking matches openai" {
    try testing.expect(supportsThinking("o1"));
    try testing.expect(supportsThinking("o3-mini"));
    try testing.expect(!supportsThinking("gpt-4o"));
}

test "costRates opus" {
    const r = costRates("claude-opus-4-6").?;
    try testing.expectEqual(@as(u64, 1500), r.in);
    try testing.expectEqual(@as(u64, 7500), r.out);
    try testing.expectEqual(@as(u64, 150), r.cr);
    try testing.expectEqual(@as(u64, 1875), r.cw);
}

test "costRates sonnet" {
    const r = costRates("claude-sonnet-4-6").?;
    try testing.expectEqual(@as(u64, 300), r.in);
    try testing.expectEqual(@as(u64, 1500), r.out);
}

test "costRates openai" {
    const r = costRates("gpt-4o").?;
    try testing.expectEqual(@as(u64, 250), r.in);
    try testing.expectEqual(@as(u64, 1000), r.out);
}

test "costRates unknown returns null" {
    try testing.expect(costRates("nonexistent") == null);
}

test "longest prefix wins gpt-4o vs gpt-4o-mini" {
    // "gpt-4o-mini" should match the mini entry, not "gpt-4o"
    const m = findModel("gpt-4o-mini").?;
    try testing.expectEqualStrings("gpt-4o-mini", m.name);
    try testing.expectEqual(@as(u64, 15), m.in_cost);
}

// ── MP3 additions ─────────────────────────────────────────────────

test "findModel versioned name resolves across new providers" {
    // Each new provider resolves from a versioned/suffixed name to its base row.
    try testing.expectEqualStrings("gemini-2.5-pro", findModel("gemini-2.5-pro-exp-03-25").?.name);
    try testing.expectEqualStrings("mistral-large", findModel("mistral-large-2411").?.name);
    try testing.expectEqualStrings("deepseek-reasoner", findModel("deepseek-reasoner-0528").?.name);
    try testing.expectEqualStrings("llama-3.3-70b-versatile", findModel("llama-3.3-70b-versatile").?.name);
}

test "longest prefix wins gemini-2.5-flash vs gemini-2.0-flash and pro" {
    // A "-flash" suffix on the 2.5 line must not collapse onto 2.0 or pro.
    try testing.expectEqualStrings("gemini-2.5-flash", findModel("gemini-2.5-flash-001").?.name);
    try testing.expectEqualStrings("gemini-2.0-flash", findModel("gemini-2.0-flash-001").?.name);
    try testing.expectEqualStrings("gemini-2.5-pro", findModel("gemini-2.5-pro").?.name);
}

test "longest prefix wins deepseek-chat vs deepseek-reasoner" {
    const chat = findModel("deepseek-chat-v3").?;
    try testing.expectEqualStrings("deepseek-chat", chat.name);
    try testing.expect(!chat.thinking);
    const reasoner = findModel("deepseek-reasoner").?;
    try testing.expectEqualStrings("deepseek-reasoner", reasoner.name);
    try testing.expect(reasoner.thinking);
}

test "new provider tags resolve to correct Provider" {
    try testing.expectEqual(Provider.google, findModel("gemini-2.5-pro").?.provider);
    try testing.expectEqual(Provider.mistral, findModel("mistral-small-2503").?.provider);
    try testing.expectEqual(Provider.groq, findModel("llama-3.3-70b-versatile").?.provider);
    try testing.expectEqual(Provider.deepseek, findModel("deepseek-chat").?.provider);
    try testing.expectEqual(Provider.openrouter, findModel("openrouter/auto").?.provider);
}

test "existing models unchanged after MP3 extension" {
    // Provider/cost/ctx/thinking of the original rows must not drift.
    const opus = findModel("claude-opus-4-20250514").?;
    try testing.expectEqual(Provider.anthropic, opus.provider);
    try testing.expectEqual(@as(u32, 200_000), opus.ctx_win);
    try testing.expectEqual(@as(u64, 1500), opus.in_cost);
    try testing.expectEqual(@as(u64, 7500), opus.out_cost);
    try testing.expect(opus.thinking);

    const gpt4o = findModel("gpt-4o").?;
    try testing.expectEqual(Provider.openai, gpt4o.provider);
    try testing.expectEqual(@as(u32, 128_000), gpt4o.ctx_win);
    try testing.expectEqual(@as(u64, 250), gpt4o.in_cost);
    try testing.expect(!gpt4o.thinking);

    const o3 = findModel("o3-mini").?;
    try testing.expectEqual(Provider.openai, o3.provider);
    try testing.expect(o3.thinking);
    try testing.expectEqual(@as(u64, 110), o3.in_cost);

    // Original rows declare no host/path override (still use registry defaults).
    try testing.expect(opus.base_url == null);
    try testing.expect(opus.api_path == null);
    try testing.expect(gpt4o.base_url == null);
}

test "thinkingBudget stored for thinking models, zero otherwise" {
    // Thinking models carry a non-zero budget...
    try testing.expectEqual(@as(u32, 32_000), thinkingBudget("claude-opus-4-20250514").?);
    try testing.expectEqual(@as(u32, 25_000), thinkingBudget("o1").?);
    try testing.expectEqual(@as(u32, 32_000), thinkingBudget("deepseek-reasoner").?);
    // ...non-thinking models resolve to a real entry with budget 0...
    try testing.expectEqual(@as(u32, 0), thinkingBudget("gpt-4o").?);
    try testing.expectEqual(@as(u32, 0), thinkingBudget("deepseek-chat").?);
    // ...and unknown models return null (no silent default).
    try testing.expect(thinkingBudget("unknown-model-xyz") == null);
}

test "rateLimitTpm stored per model" {
    try testing.expectEqual(@as(u32, 200_000), rateLimitTpm("claude-opus-4-20250514").?);
    try testing.expectEqual(@as(u32, 2_000_000), rateLimitTpm("gpt-4o-mini").?);
    try testing.expectEqual(@as(u32, 4_000_000), rateLimitTpm("gemini-2.5-flash").?);
    try testing.expectEqual(@as(u32, 1_000_000), rateLimitTpm("deepseek-chat").?);
    try testing.expect(rateLimitTpm("nonexistent") == null);
}

test "base_url and api_path overrides stored for openrouter slugs" {
    const auto = findModel("openrouter/auto").?;
    try testing.expectEqualStrings("openrouter.ai", auto.base_url.?);
    try testing.expectEqualStrings("/api/v1/chat/completions", auto.api_path.?);
    // A provider-prefixed slug resolves and keeps its override.
    const orsonnet = findModel("anthropic/claude-sonnet-4-20250522").?;
    try testing.expectEqual(Provider.openrouter, orsonnet.provider);
    try testing.expectEqualStrings("openrouter.ai", orsonnet.base_url.?);
    try testing.expect(orsonnet.thinking);
}

test "costRates resolves for new providers" {
    const g = costRates("gemini-2.5-pro").?;
    try testing.expectEqual(@as(u64, 125), g.in);
    try testing.expectEqual(@as(u64, 1000), g.out);
    const d = costRates("deepseek-reasoner").?;
    try testing.expectEqual(@as(u64, 55), d.in);
    try testing.expectEqual(@as(u64, 219), d.out);
}
