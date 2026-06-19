//! Mistral client (OpenAI Chat Completions wire format).
//!
//! Mistral serves Chat Completions at `api.mistral.ai/v1/chat/completions` with
//! Bearer auth. It has NO reasoning/thinking channel, so `thinking_field` is
//! null: the shared body builder omits `reasoning_effort` and the SSE parser
//! never emits thinking events for this provider.
//!
//! Shared Chat-Completions request/response logic lives in openrouter.zig; this
//! module only pins host/path/auth-tag/reasoning-field.
const std = @import("std");
const providers = @import("api.zig");
const auth_mod = @import("auth.zig");
const hc = @import("http_client.zig");
const openrouter = @import("openrouter.zig");

/// Mistral reuses the `.openai` auth identity for credential loading (it has no
/// distinct OAuth flow; an API key is supplied like other compat providers).
pub const Cfg = openrouter.ChatCfg(.{
    .auth_tag = .openai,
    .api_host = "api.mistral.ai",
    .api_path = "/v1/chat/completions",
    .thinking_field = null,
});

pub const Client = hc.SseClient(Cfg);
const Stream = hc.SseStream(Cfg);

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testStream() Stream {
    return hc.testStream(Cfg);
}

fn testParse(stream: *Stream, data: []const u8) !?providers.Event {
    return hc.testParse(Cfg, stream, data);
}

test "mistral buildAuthHeaders sends Bearer key only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var auth = auth_mod.Result{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .auth = .{ .api_key = "mst-key" },
    };
    defer auth.deinit();

    const hdrs = try Cfg.buildAuthHeaders(&auth, ar);
    try testing.expectEqual(@as(usize, 2), hdrs.items.len);
    try testing.expectEqualStrings("authorization", hdrs.items[1].name);
    try testing.expectEqualStrings("Bearer mst-key", hdrs.items[1].value);
    try testing.expectEqualStrings("api.mistral.ai", Cfg.api_host);
    try testing.expectEqualStrings("/v1/chat/completions", Cfg.api_path);
}

test "mistral buildBody omits reasoning_effort even when thinking requested" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    // Even with thinking=.adaptive, mistral (thinking_field=null) must not emit
    // reasoning_effort.
    const body = try Cfg.buildBody(testing.allocator, .{
        .model = "mistral-large-latest",
        .msgs = &msgs,
        .opts = .{ .thinking = .adaptive },
    }, false);
    defer testing.allocator.free(body);
    try hc.expectSnap(@src(), body,
        \\[]u8
        \\  "{"model":"mistral-large-latest","stream":true,"stream_options":{"include_usage":true},"max_tokens":16384,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"
    );
}

test "mistral parseSseData has no thinking channel" {
    var stream = testStream();
    defer stream.arena.deinit();
    // A reasoning field on the wire must NOT surface as a thinking event for
    // mistral; with no content it yields null.
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{"reasoning":"ignored"}}]}
    );
    try testing.expect(ev == null);
}
