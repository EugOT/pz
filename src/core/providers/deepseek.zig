//! DeepSeek client (OpenAI Chat Completions wire format).
//!
//! DeepSeek serves Chat Completions at `api.deepseek.com/chat/completions` with
//! Bearer auth. Its reasoning channel uses the `reasoning_content` delta field
//! (distinct from the `reasoning` field used by openrouter/groq), so the shared
//! SSE parser reads `reasoning_content` for this provider.
//!
//! Shared Chat-Completions request/response logic lives in openrouter.zig; this
//! module only pins host/path/auth-tag/reasoning-field.
const std = @import("std");
const providers = @import("api.zig");
const auth_mod = @import("auth.zig");
const hc = @import("http_client.zig");
const openrouter = @import("openrouter.zig");

/// DeepSeek reuses the `.openai` auth identity for credential loading.
pub const Cfg = openrouter.ChatCfg(.{
    .auth_tag = .openai,
    .api_host = "api.deepseek.com",
    .api_path = "/chat/completions",
    .thinking_field = "reasoning_content",
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

test "deepseek buildAuthHeaders sends Bearer key at bare completions path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var auth = auth_mod.Result{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .auth = .{ .api_key = "ds-key" },
    };
    defer auth.deinit();

    const hdrs = try Cfg.buildAuthHeaders(&auth, ar);
    try testing.expectEqual(@as(usize, 2), hdrs.items.len);
    try testing.expectEqualStrings("authorization", hdrs.items[1].name);
    try testing.expectEqualStrings("Bearer ds-key", hdrs.items[1].value);
    try testing.expectEqualStrings("api.deepseek.com", Cfg.api_host);
    try testing.expectEqualStrings("/chat/completions", Cfg.api_path);
}

test "deepseek buildBody wraps request in OpenAI chat format" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const body = try Cfg.buildBody(testing.allocator, .{
        .model = "deepseek-reasoner",
        .msgs = &msgs,
        .opts = .{ .thinking = .off },
    }, false);
    defer testing.allocator.free(body);
    try hc.expectSnap(@src(), body,
        \\[]u8
        \\  "{"model":"deepseek-reasoner","stream":true,"stream_options":{"include_usage":true},"max_tokens":16384,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"
    );
}

test "deepseek parseSseData reads reasoning_content field for thinking" {
    var stream = testStream();
    defer stream.arena.deinit();
    // DeepSeek uses reasoning_content, not reasoning.
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{"reasoning_content":"chain"}}]}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("chain", ev.?.thinking);

    // The plain `reasoning` field must be ignored for deepseek.
    var stream2 = testStream();
    defer stream2.arena.deinit();
    const ev2 = try testParse(&stream2,
        \\{"choices":[{"delta":{"reasoning":"ignored"}}]}
    );
    try testing.expect(ev2 == null);
}
