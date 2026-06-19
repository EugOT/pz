//! Groq client (OpenAI Chat Completions wire format).
//!
//! Groq serves an OpenAI-compatible surface at
//! `api.groq.com/openai/v1/chat/completions` with Bearer auth. Reasoning text
//! arrives under the `reasoning` delta field.
//!
//! Shared Chat-Completions request/response logic lives in openrouter.zig; this
//! module only pins host/path/auth-tag/reasoning-field.
const std = @import("std");
const providers = @import("api.zig");
const auth_mod = @import("auth.zig");
const hc = @import("http_client.zig");
const openrouter = @import("openrouter.zig");

/// Groq reuses the `.openai` auth identity for credential loading.
pub const Cfg = openrouter.ChatCfg(.{
    .auth_tag = .openai,
    .api_host = "api.groq.com",
    .api_path = "/openai/v1/chat/completions",
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

test "groq buildAuthHeaders sends Bearer key at openai-prefixed path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var auth = auth_mod.Result{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .auth = .{ .api_key = "gsk-key" },
    };
    defer auth.deinit();

    const hdrs = try Cfg.buildAuthHeaders(&auth, ar);
    try testing.expectEqual(@as(usize, 2), hdrs.items.len);
    try testing.expectEqualStrings("authorization", hdrs.items[1].name);
    try testing.expectEqualStrings("Bearer gsk-key", hdrs.items[1].value);
    try testing.expectEqualStrings("api.groq.com", Cfg.api_host);
    try testing.expectEqualStrings("/openai/v1/chat/completions", Cfg.api_path);
}

test "groq buildBody wraps request in OpenAI chat format" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const body = try Cfg.buildBody(testing.allocator, .{
        .model = "llama-3.3-70b-versatile",
        .msgs = &msgs,
        .opts = .{ .thinking = .off },
    }, false);
    defer testing.allocator.free(body);
    try hc.expectSnap(@src(), body,
        \\[]u8
        \\  "{"model":"llama-3.3-70b-versatile","stream":true,"stream_options":{"include_usage":true},"max_tokens":16384,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"
    );
}

test "groq parseSseData reasoning delta emits thinking" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{"reasoning":"step"}}]}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("step", ev.?.thinking);
}
