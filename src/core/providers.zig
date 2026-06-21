//! Provider layer: LLM API clients, auth, streaming, retry.
pub const retry = @import("providers/retry.zig");
pub const types = @import("providers/types.zig");
pub const stream_parse = @import("providers/stream_parse.zig");
pub const client = @import("providers/client.zig");
pub const proc_transport = @import("providers/proc_transport.zig");
pub const auth = @import("providers/auth.zig");
pub const oauth_callback = @import("providers/oauth_callback.zig");
pub const http_client = @import("providers/http_client.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const openai = @import("providers/openai.zig");
pub const models = @import("providers/models.zig");

// MP7: provider registry, OpenAI-compatible body/SSE helpers, per-model config
// loader, and the OpenAI-compatible provider clients are surfaced here so the
// runtime constructs and routes them through the same `providers.*` namespace
// as the native anthropic/openai clients. Each module already exists on main;
// MP7 only wires the exports + the comptime interface checks below.
pub const registry = @import("providers/registry.zig");
pub const compat = @import("providers/compat.zig");
pub const config = @import("providers/config.zig");
pub const openrouter = @import("providers/openrouter.zig");
pub const google = @import("providers/google.zig");
pub const mistral = @import("providers/mistral.zig");
pub const groq = @import("providers/groq.zig");
pub const deepseek = @import("providers/deepseek.zig");

const c = @import("providers/api.zig");

pub const Role = c.Role;
pub const Request = c.Request;
pub const Msg = c.Msg;
pub const Part = c.Part;
pub const Tool = c.Tool;
pub const ToolCall = c.ToolCall;
pub const ToolResult = c.ToolResult;
pub const Opts = c.Opts;
pub const Event = c.Event;
pub const Usage = c.Usage;
pub const Stop = c.Stop;
pub const StopReason = c.StopReason;
pub const Provider = c.Provider;
pub const Stream = c.Stream;
pub const Aborter = c.Aborter;
pub const AbortSlot = c.AbortSlot;
pub const CancelPoll = c.CancelPoll;

// MP7: dispatch surface. `Provider` (the request enum tag) comes from api.zig;
// the registry's `ProviderTag` is the broader canonical identity. Both are
// surfaced here so the runtime can reconcile auth tags, registry metadata, and
// request dispatch without reaching into submodules.
pub const ProviderTag = registry.ProviderTag;
pub const ProviderInfo = registry.ProviderInfo;
pub const resolveProvider = registry.resolveProvider;
pub const Dispatch = c.Dispatch;
pub const DispatchError = c.DispatchError;
pub const resolveDispatch = c.resolveDispatch;

// ── Comptime interface checks (MP7) ──────────────────────────────────────────
// Prove at build time — not in a user's process — that every wired provider
// module exposes the Cfg/Client interface the runtime depends on, and that
// every registry entry resolves. A future module that drops `Cfg.api_host` or a
// registry tag that loses its entry fails the build with a precise message
// instead of surfacing as a runtime `unreachable` or a silent mis-route.
comptime {
    // The OpenAI-compatible provider modules the runtime dispatches to. The
    // native anthropic/openai clients are checked by the shared SseClient/Cfg
    // contract already; these are the MP7 additions whose wiring is new.
    const compat_modules = .{
        .{ "openrouter", openrouter },
        .{ "google", google },
        .{ "mistral", mistral },
        .{ "groq", groq },
        .{ "deepseek", deepseek },
    };
    for (compat_modules) |entry| {
        const name = entry[0];
        const mod = entry[1];

        // Cfg must exist and carry the static endpoint identity the SseClient
        // generic and the request builder read.
        if (!@hasDecl(mod, "Cfg"))
            @compileError("provider '" ++ name ++ "' is missing pub const Cfg");
        const Cfg = mod.Cfg;
        if (!@hasDecl(Cfg, "provider_tag"))
            @compileError("provider '" ++ name ++ "' Cfg is missing provider_tag");
        if (!@hasDecl(Cfg, "api_host"))
            @compileError("provider '" ++ name ++ "' Cfg is missing api_host");
        if (!@hasDecl(Cfg, "api_path"))
            @compileError("provider '" ++ name ++ "' Cfg is missing api_path");
        if (!@hasDecl(Cfg, "buildAuthHeaders"))
            @compileError("provider '" ++ name ++ "' Cfg is missing buildAuthHeaders");
        if (!@hasDecl(Cfg, "buildBody"))
            @compileError("provider '" ++ name ++ "' Cfg is missing buildBody");
        if (!@hasDecl(Cfg, "parseSseData"))
            @compileError("provider '" ++ name ++ "' Cfg is missing parseSseData");

        // The provider tag must be a member of the canonical auth.Provider set
        // so credential loading + the login path can resolve it.
        if (@TypeOf(Cfg.provider_tag) != auth.Provider)
            @compileError("provider '" ++ name ++ "' Cfg.provider_tag must be auth.Provider");

        // Client must exist, embed a `provider: Provider` field (so the runtime
        // can hand `&client.provider` to the loop / router), and expose the
        // lifecycle methods the native fast paths use.
        if (!@hasDecl(mod, "Client"))
            @compileError("provider '" ++ name ++ "' is missing pub const Client");
        const Client = mod.Client;
        if (!@hasField(Client, "provider"))
            @compileError("provider '" ++ name ++ "' Client is missing a `provider` field");
        if (@FieldType(Client, "provider") != Provider)
            @compileError("provider '" ++ name ++ "' Client.provider must be providers.Provider");
        if (!@hasDecl(Client, "init"))
            @compileError("provider '" ++ name ++ "' Client is missing init");
        if (!@hasDecl(Client, "deinit"))
            @compileError("provider '" ++ name ++ "' Client is missing deinit");
        if (!@hasDecl(Client, "isSub"))
            @compileError("provider '" ++ name ++ "' Client is missing isSub");
    }

    // Every registry tag must resolve through the by-tag table (registry proves
    // this internally too; re-checking here ties the wired surface to it). The
    // dense table returns a `ProviderInfo` for each tag with no runtime miss.
    for (@import("std").enums.values(ProviderTag)) |tag| {
        const info = registry.byTag(tag);
        if (info.provider_tag != tag)
            @compileError("registry byTag disagreement for " ++ @tagName(tag));
    }

    // Every registry canonical name must resolve via resolveProvider — i.e. the
    // names the runtime accepts from `--provider`/dispatch round-trip.
    for (registry.names()) |reg_name| {
        if (registry.resolveProvider(reg_name) == null)
            @compileError("registry name does not resolve: " ++ reg_name);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

// ── Export + dispatch surface tests (MP7) ────────────────────────────────────

const testing = @import("std").testing;

test "providers exports every new module's Cfg/Client (criterion 1)" {
    // Each wired OpenAI-compatible module is reachable through `providers.*` and
    // exposes the Cfg/Client interface the runtime constructs. The comptime
    // block above proves the full interface; here we assert the exports resolve
    // and carry the right static identity so a missing/renamed export fails the
    // test, not just the build.
    try testing.expectEqualStrings("openrouter.ai", openrouter.Cfg.api_host);
    try testing.expectEqualStrings("generativelanguage.googleapis.com", google.Cfg.api_host);
    try testing.expectEqualStrings("api.mistral.ai", mistral.Cfg.api_host);
    try testing.expectEqualStrings("api.groq.com", groq.Cfg.api_host);
    try testing.expectEqualStrings("api.deepseek.com", deepseek.Cfg.api_host);
    // registry/compat/config exports resolve to the expected modules.
    try testing.expect(registry.count == 7);
    try testing.expect(@hasDecl(compat, "usageToCanonical"));
    try testing.expect(@hasDecl(config, "load"));
}

test "providers surfaces the dispatch + registry tags consistently (criterion 1)" {
    // ProviderTag (registry) and the dispatch resolver are both surfaced here so
    // the runtime reconciles them without reaching into submodules.
    try testing.expect(resolveProvider("mistral") != null);
    try testing.expect(resolveProvider("not-real") == null);
    const d = try resolveDispatch(.{ .model = "llama:groq", .msgs = &.{} });
    try testing.expectEqualStrings("groq", d.provider);
    try testing.expectEqualStrings("llama", d.model);
    try testing.expectEqual(ProviderTag.groq, d.info.provider_tag);
    // A request that names no provider is a named error, never a default.
    try testing.expectError(error.NoProvider, resolveDispatch(.{ .model = "bare", .msgs = &.{} }));
    try testing.expectError(error.UnknownProvider, resolveDispatch(.{ .model = "m", .provider = "nope", .msgs = &.{} }));
}
