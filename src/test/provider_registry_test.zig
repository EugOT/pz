//! Test entry point that pulls the MP1 provider registry + compat transform
//! into the test build. The real assertions live as `test {}` blocks inside
//! registry.zig and compat.zig; referencing the modules here makes them
//! reachable from the `src/tests.zig` aggregation root so `zig build test`
//! runs them. These modules are intentionally NOT wired into runtime yet (MP7).
const std = @import("std");

const registry = @import("../core/providers/registry.zig");
const compat = @import("../core/providers/compat.zig");

comptime {
    _ = registry;
    _ = compat;
}

// A cross-module integration test that proves the registry and compat layer
// agree: a provider's declared thinking field flows through the compat
// extractor, and an OpenAI-compatible provider's tool_call id survives the
// request/response round-trip. (The fine-grained unit tests are in the
// respective modules.)
const testing = std.testing;
const api = @import("../core/providers/api.zig");

test "registry thinking field drives compat extractThinking end to end" {
    const a = testing.allocator;
    const info = registry.resolveProvider("deepseek").?;
    const field = compat.thinkingFieldName(info.thinking_field_name);
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"reasoning_content":"chain of thought"}
    , .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("chain of thought", compat.extractThinking(parsed.value, field).?);
}

test "openai-compat provider tool_call id is preserved through canonical mapping" {
    const info = registry.resolveProvider("openrouter").?;
    try testing.expectEqual(registry.RequestFormat.openai_compat, info.request_format);

    const tc = compat.toolCallToCanonical(.{
        .id = "call_round_trip",
        .function = .{ .name = "grep", .arguments = "{\"q\":\"x\"}" },
    });
    const result = api.ToolResult{ .id = tc.id, .output = "matched" };
    try testing.expectEqualStrings("call_round_trip", compat.toolResultCallId(result));
}
