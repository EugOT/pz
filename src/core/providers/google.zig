//! Google Gemini client via its OpenAI-compatible endpoint.
//!
//! Google exposes an OpenAI Chat Completions surface at
//! `generativelanguage.googleapis.com/v1beta/openai/chat/completions`. We send
//! the credential as a Bearer token (the compat endpoint accepts
//! `Authorization: Bearer <key>` in lieu of the native `?key=` query param),
//! which keeps auth uniform with the other OpenAI-compatible providers and
//! avoids leaking the key into the URL/logs.
//!
//! Shared Chat-Completions request/response logic lives in openrouter.zig; this
//! module only pins host/path/auth-tag/reasoning-field.
const std = @import("std");
const providers = @import("api.zig");
const auth_mod = @import("auth.zig");
const hc = @import("http_client.zig");
const openrouter = @import("openrouter.zig");

/// Google has its own auth identity (`auth_mod.Provider.google`) for credential
/// loading and refresh.
pub const Cfg = openrouter.ChatCfg(.{
    .auth_tag = .google,
    .api_host = "generativelanguage.googleapis.com",
    .api_path = "/v1beta/openai/chat/completions",
    .thinking_field = "reasoning",
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

test "google buildAuthHeaders sends Bearer key, no attribution headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var auth = auth_mod.Result{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .auth = .{ .api_key = "goog-key" },
    };
    defer auth.deinit();

    const hdrs = try Cfg.buildAuthHeaders(&auth, ar);
    try testing.expectEqual(@as(usize, 2), hdrs.items.len);
    try testing.expectEqualStrings("content-type", hdrs.items[0].name);
    try testing.expectEqualStrings("authorization", hdrs.items[1].name);
    try testing.expectEqualStrings("Bearer goog-key", hdrs.items[1].value);
}

test "google uses google auth tag and compat endpoint" {
    try testing.expectEqual(auth_mod.Provider.google, Cfg.provider_tag);
    try testing.expectEqualStrings("generativelanguage.googleapis.com", Cfg.api_host);
    try testing.expectEqualStrings("/v1beta/openai/chat/completions", Cfg.api_path);
}

test "google buildBody wraps request in OpenAI chat format" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const body = try Cfg.buildBody(testing.allocator, .{
        .model = "gemini-2.0-flash",
        .msgs = &msgs,
        .opts = .{ .thinking = .off },
    }, false);
    defer testing.allocator.free(body);
    try hc.expectSnap(@src(), body,
        \\[]u8
        \\  "{"model":"gemini-2.0-flash","stream":true,"stream_options":{"include_usage":true},"max_tokens":16384,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"
    );
}

test "google parseSseData content delta emits text" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{"content":"world"}}]}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("world", ev.?.text);
}
