//! OpenAI-compatible request/response transform helpers.
//!
//! MP1 foundation: pure mapping functions between the OpenAI Chat Completions
//! wire conventions and pz's canonical provider taxonomy (`api.Usage`,
//! `api.ToolCall`, error classes). NOT wired into the runtime yet (MP7).
//!
//! OpenAI-compatible providers (openrouter, groq, mistral, deepseek, and
//! Google's compat endpoint) all share these conventions but differ in small
//! ways from Anthropic's native shape:
//!
//!   - Thinking/reasoning lives under a provider-specific field name
//!     (`reasoning`, `reasoning_content`, …) — see `registry.thinking_field_name`.
//!   - Tool calls carry an `id` that MUST be echoed back verbatim in the
//!     following `tool` message's `tool_call_id`. We preserve it losslessly.
//!   - Usage uses `prompt_tokens`/`completion_tokens`/`total_tokens` with
//!     cached input under `prompt_tokens_details.cached_tokens`.
//!   - Errors are `{"error":{"code":..,"message":..,"type":..}}` where `code`
//!     (OpenAI) is the discriminant Anthropic puts under `type`.
//!
//! Allocation discipline: functions that only read/borrow take no allocator.
//! Functions that must produce owned output take an explicit `Allocator`.
const std = @import("std");
const api = @import("api.zig");

/// Named error set for transform failures. No `anyerror` in the public API.
pub const TransformError = error{
    /// Allocation failed while building owned output.
    OutOfMemory,
    /// JSON did not match the expected OpenAI-compatible shape.
    MalformedResponse,
};

// ── Usage mapping ────────────────────────────────────────────────────────

/// OpenAI Chat Completions usage block (subset we consume). Optional fields
/// model providers that omit pieces (groq omits cache details, etc.).
pub const CompatUsage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    prompt_tokens_details: ?PromptTokensDetails = null,

    pub const PromptTokensDetails = struct {
        cached_tokens: ?u64 = null,
    };
};

/// Map an OpenAI-compatible usage block onto the canonical `api.Usage`.
/// Pure: borrows the input, allocates nothing. `total` is synthesized from the
/// parts when the provider omits it (no silent zero — we sum what we have).
pub fn usageToCanonical(u: CompatUsage) api.Usage {
    const in_tok = u.prompt_tokens orelse 0;
    const out_tok = u.completion_tokens orelse 0;
    const cache_read: u64 = if (u.prompt_tokens_details) |d| (d.cached_tokens orelse 0) else 0;
    const total = if (u.total_tokens) |t| t else in_tok + out_tok;
    return .{
        .in_tok = in_tok,
        .out_tok = out_tok,
        .tot_tok = total,
        .cache_read = cache_read,
        // OpenAI-compatible providers do not bill a separate cache-write tier;
        // it stays 0 by design rather than guessing.
        .cache_write = 0,
    };
}

// ── Tool call mapping ──────────────────────────────────────────────────────

/// OpenAI tool_call function payload (Chat Completions shape).
pub const CompatToolCall = struct {
    id: []const u8,
    function: Function,

    pub const Function = struct {
        name: []const u8,
        /// Arguments are a JSON string, not an object (OpenAI convention).
        arguments: []const u8 = "{}",
    };
};

/// Map an OpenAI tool_call onto the canonical `api.ToolCall`, preserving the
/// `id` verbatim (required so the follow-up tool result can echo it back).
/// Borrows the input strings; the returned `ToolCall` aliases them — caller
/// owns lifetime. Allocation-free.
pub fn toolCallToCanonical(tc: CompatToolCall) api.ToolCall {
    return .{
        .id = tc.id,
        .name = tc.function.name,
        .args = tc.function.arguments,
    };
}

/// Map a canonical `api.ToolResult` back onto the field name OpenAI expects:
/// the result message's `tool_call_id` MUST equal the originating call's id.
/// This returns just the id so the body builder can place it; allocation-free.
pub fn toolResultCallId(tr: api.ToolResult) []const u8 {
    return tr.id;
}

// ── Thinking / reasoning field rename ───────────────────────────────────────

/// Resolve the response JSON field that carries reasoning/thinking text for a
/// provider, given its registry-declared name. Returns the canonical event
/// constructor input: the caller reads `json[field]` and wraps it as
/// `api.Event{ .thinking = text }`. Pure; here for a single source of truth on
/// the rename direction (compat field name → canonical `.thinking`).
pub fn thinkingFieldName(registry_field: ?[]const u8) ?[]const u8 {
    return registry_field;
}

/// Extract reasoning/thinking text from a parsed JSON object using the
/// provider's field name. Returns null when absent or not a string. Borrows
/// the slice out of `obj`; allocation-free.
pub fn extractThinking(obj: std.json.Value, field: ?[]const u8) ?[]const u8 {
    const name = field orelse return null;
    if (obj != .object) return null;
    const v = obj.object.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── Error code vs type ──────────────────────────────────────────────────────

/// Canonical error discriminant extracted from an OpenAI-compatible or
/// Anthropic error envelope. We unify `error.code` (OpenAI) and `error.type`
/// (Anthropic) into one string the caller can classify.
pub const ErrorDiscriminant = struct {
    /// The discriminant string (code or type), or empty if neither present.
    kind: []const u8,
    /// Human-readable message, or empty if absent.
    message: []const u8,
};

/// Parse an error envelope and extract the discriminant. Tries `error.code`
/// first (OpenAI), then falls back to `error.type` (Anthropic). Borrows out of
/// `obj`; allocation-free. Returns empty strings (not null) when a field is
/// missing so callers always get a usable struct.
pub fn errorDiscriminant(obj: std.json.Value) ErrorDiscriminant {
    var out = ErrorDiscriminant{ .kind = "", .message = "" };
    if (obj != .object) return out;
    const err_obj = obj.object.get("error") orelse return out;
    if (err_obj != .object) return out;
    // OpenAI: error.code is the discriminant. Anthropic: error.type.
    if (err_obj.object.get("code")) |c| {
        if (c == .string) out.kind = c.string;
    }
    if (out.kind.len == 0) {
        if (err_obj.object.get("type")) |t| {
            if (t == .string) out.kind = t.string;
        }
    }
    if (err_obj.object.get("message")) |m| {
        if (m == .string) out.message = m.string;
    }
    return out;
}

/// Owned-copy variant of `errorDiscriminant`: duplicates both strings into
/// `alloc` so the result outlives the parsed JSON. Caller frees `kind` and
/// `message`. Takes the allocator explicitly per allocation discipline.
pub fn errorDiscriminantOwned(
    alloc: std.mem.Allocator,
    obj: std.json.Value,
) TransformError!ErrorDiscriminant {
    const borrowed = errorDiscriminant(obj);
    const kind = alloc.dupe(u8, borrowed.kind) catch return error.OutOfMemory;
    errdefer alloc.free(kind);
    const message = alloc.dupe(u8, borrowed.message) catch return error.OutOfMemory;
    return .{ .kind = kind, .message = message };
}

// ── Tests ──────────────────────────────────────────────────────────────────
// Run wherever this file is reachable from a test root (see
// src/test/provider_registry_test.zig and src/tests.zig).

const testing = std.testing;

test "usageToCanonical maps OpenAI token naming" {
    const c = usageToCanonical(.{
        .prompt_tokens = 100,
        .completion_tokens = 25,
        .total_tokens = 125,
        .prompt_tokens_details = .{ .cached_tokens = 40 },
    });
    try testing.expectEqual(@as(u64, 100), c.in_tok);
    try testing.expectEqual(@as(u64, 25), c.out_tok);
    try testing.expectEqual(@as(u64, 125), c.tot_tok);
    try testing.expectEqual(@as(u64, 40), c.cache_read);
    try testing.expectEqual(@as(u64, 0), c.cache_write);
}

test "usageToCanonical synthesizes total when omitted" {
    const c = usageToCanonical(.{ .prompt_tokens = 10, .completion_tokens = 7 });
    try testing.expectEqual(@as(u64, 17), c.tot_tok);
    try testing.expectEqual(@as(u64, 0), c.cache_read);
}

test "usageToCanonical all-null is zeroed, not crashing" {
    const c = usageToCanonical(.{});
    try testing.expectEqual(@as(u64, 0), c.in_tok);
    try testing.expectEqual(@as(u64, 0), c.tot_tok);
}

test "toolCallToCanonical preserves id verbatim" {
    const tc = toolCallToCanonical(.{
        .id = "call_abc123",
        .function = .{ .name = "read_file", .arguments = "{\"path\":\"a.zig\"}" },
    });
    try testing.expectEqualStrings("call_abc123", tc.id);
    try testing.expectEqualStrings("read_file", tc.name);
    try testing.expectEqualStrings("{\"path\":\"a.zig\"}", tc.args);
}

test "toolResultCallId round-trips the call id" {
    // Simulate the request->response loop: a tool_call id must equal the
    // tool_result's tool_call_id so the provider can correlate them.
    const call = toolCallToCanonical(.{ .id = "call_xyz", .function = .{ .name = "ls" } });
    const result = api.ToolResult{ .id = call.id, .output = "ok" };
    try testing.expectEqualStrings("call_xyz", toolResultCallId(result));
    try testing.expectEqualStrings(call.id, toolResultCallId(result));
}

test "extractThinking reads provider-specific field" {
    const a = testing.allocator;
    const json =
        \\{"reasoning":"let me think","content":"answer"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("let me think", extractThinking(parsed.value, "reasoning").?);
    // deepseek-style field name.
    const json2 =
        \\{"reasoning_content":"deepthought"}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, json2, .{});
    defer parsed2.deinit();
    try testing.expectEqualStrings("deepthought", extractThinking(parsed2.value, "reasoning_content").?);
}

test "extractThinking returns null when field absent or provider has none" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"content":"x"}
    , .{});
    defer parsed.deinit();
    try testing.expect(extractThinking(parsed.value, "reasoning") == null);
    // mistral has no thinking field at all.
    try testing.expect(extractThinking(parsed.value, null) == null);
}

test "errorDiscriminant prefers OpenAI code over Anthropic type" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"error":{"code":"context_length_exceeded","message":"too long","type":"invalid_request_error"}}
    , .{});
    defer parsed.deinit();
    const d = errorDiscriminant(parsed.value);
    try testing.expectEqualStrings("context_length_exceeded", d.kind);
    try testing.expectEqualStrings("too long", d.message);
}

test "errorDiscriminant falls back to Anthropic type when no code" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"error":{"type":"request_too_large","message":"big"}}
    , .{});
    defer parsed.deinit();
    const d = errorDiscriminant(parsed.value);
    try testing.expectEqualStrings("request_too_large", d.kind);
    try testing.expectEqualStrings("big", d.message);
}

test "errorDiscriminant on non-error JSON yields empty, not crash" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"ok":true}
    , .{});
    defer parsed.deinit();
    const d = errorDiscriminant(parsed.value);
    try testing.expectEqualStrings("", d.kind);
    try testing.expectEqualStrings("", d.message);
}

test "errorDiscriminantOwned duplicates and survives parse deinit" {
    const a = testing.allocator;
    var d: ErrorDiscriminant = undefined;
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, a,
            \\{"error":{"code":"rate_limit","message":"slow down"}}
        , .{});
        defer parsed.deinit();
        d = try errorDiscriminantOwned(a, parsed.value);
    }
    // Parsed JSON is freed; owned copy must still be valid.
    defer a.free(d.kind);
    defer a.free(d.message);
    try testing.expectEqualStrings("rate_limit", d.kind);
    try testing.expectEqualStrings("slow down", d.message);
}

test "thinkingFieldName is identity passthrough for single source of truth" {
    try testing.expectEqualStrings("reasoning", thinkingFieldName("reasoning").?);
    try testing.expect(thinkingFieldName(null) == null);
}
