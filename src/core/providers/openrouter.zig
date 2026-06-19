//! OpenRouter client (OpenAI Chat Completions wire format).
//!
//! OpenRouter speaks the OpenAI Chat Completions API at
//! `openrouter.ai/api/v1/chat/completions` with Bearer auth plus two optional
//! attribution headers (`HTTP-Referer`, `X-Title`). This module is also the
//! canonical home for the SHARED Chat-Completions request builder and SSE
//! parser reused by google.zig, mistral.zig, groq.zig, and deepseek.zig — each
//! of those imports the helpers here and supplies only its host/path/headers
//! and reasoning-field name.
//!
//! Wire-format notes (differs from openai.zig, which targets /v1/responses):
//!   - Messages: `{"messages":[{"role","content"|tool_calls|...}]}`.
//!   - Streaming deltas arrive under `choices[0].delta` with `content`,
//!     optional `reasoning`/`reasoning_content`, and incremental `tool_calls`.
//!   - Tool-call ids MUST be echoed verbatim on the following tool message's
//!     `tool_call_id` (preserved losslessly via compat.zig conventions).
//!   - Usage uses prompt/completion/total token naming (see compat.usageToCanonical).
//!
//! Allocation discipline: every public function that produces owned output
//! takes an explicit `Allocator`. Named error sets only; no `anyerror` leaks
//! into provider-facing helpers. No `catch {}`, no `unreachable`, no silent
//! fallback — unsupported message parts are rejected with an error.
const std = @import("std");
const providers = @import("api.zig");
const auth_mod = @import("auth.zig");
const hc = @import("http_client.zig");
const compat = @import("compat.zig");

const default_max_output_tokens: u32 = 16384;

// ── Shared spec: per-provider knobs the generic helpers read ────────────────

/// Static description of an OpenAI-compatible Chat Completions endpoint. Every
/// provider in MP2 instantiates one of these and feeds it to the shared
/// `ChatCfg` factory below.
pub const ChatSpec = struct {
    /// Auth tag used for credential loading + OAuth refresh. OpenAI-compatible
    /// providers without their own auth identity reuse `.openai`; Google uses
    /// `.google`.
    auth_tag: auth_mod.Provider,
    api_host: []const u8,
    api_path: []const u8,
    /// Response JSON field carrying reasoning/thinking text, or null when the
    /// provider has no reasoning channel (mistral). Mirrors
    /// `registry.thinking_field_name`.
    thinking_field: ?[]const u8,
    /// Extra request headers appended verbatim after auth (e.g. OpenRouter's
    /// attribution headers). Comptime string literals; never owned.
    extra_headers: []const std.http.Header = &.{},
};

/// Named error set for header construction. No `anyerror` in the public surface.
pub const HeaderError = error{OutOfMemory};

/// Named error set for body building.
pub const BodyError = error{
    OutOfMemory,
    /// A message part is not representable in the Chat Completions schema.
    UnsupportedPartType,
};

// ── Cfg factory ─────────────────────────────────────────────────────────────

/// Build a `Cfg` type for the shared `hc.SseClient` from a comptime `ChatSpec`.
/// The returned type satisfies the full SseClient Cfg interface.
pub fn ChatCfg(comptime spec: ChatSpec) type {
    return struct {
        const CfgSelf = @This();
        pub const provider_tag = spec.auth_tag;
        pub const api_host = spec.api_host;
        pub const api_path = spec.api_path;
        pub const thinking_field = spec.thinking_field;

        // Concrete stream type for this Cfg. Private alias (distinct from the
        // module-level `Stream` for the OpenRouter Cfg) used in method signatures.
        const StreamT = hc.SseStream(CfgSelf);

        /// Per-stream tool-call assembly state. Chat Completions streams tool
        /// calls as incremental fragments indexed by position; we buffer the id
        /// and arguments until `finish_reason == "tool_calls"`.
        pub const ExtFields = struct {
            saw_tool_call: bool,
            tool_call_id: std.ArrayListUnmanaged(u8),
            have_tool: bool,
        };

        pub fn ext_init() ExtFields {
            return .{ .saw_tool_call = false, .tool_call_id = .empty, .have_tool = false };
        }

        pub fn ext_deinit(self: *StreamT, alloc: std.mem.Allocator) void {
            self.ext.tool_call_id.deinit(alloc);
        }

        pub fn ext_reset(self: *StreamT) void {
            self.ext.saw_tool_call = false;
            self.ext.have_tool = false;
            self.ext.tool_call_id.clearRetainingCapacity();
        }

        pub fn buildAuthHeaders(
            auth: *auth_mod.Result,
            ar: std.mem.Allocator,
        ) anyerror!std.ArrayListUnmanaged(std.http.Header) {
            return buildChatAuthHeaders(spec.extra_headers, auth, ar);
        }

        pub fn buildBody(alloc: std.mem.Allocator, req: providers.Request, _: bool) anyerror![]u8 {
            return buildChatBody(alloc, req, spec.thinking_field != null);
        }

        pub fn parseSseData(self: *StreamT, data: []const u8) anyerror!?providers.Event {
            return parseChatSseData(spec.thinking_field, CfgSelf, self, data);
        }
    };
}

// ── OpenRouter concrete instantiation ───────────────────────────────────────

/// OpenRouter attribution headers. Optional per the API but recommended; sent
/// as static literals so they cost no allocation.
pub const referer = "https://github.com/EugOT/pz";
pub const title = "pz";

pub const Cfg = ChatCfg(.{
    .auth_tag = .openai,
    .api_host = "openrouter.ai",
    .api_path = "/api/v1/chat/completions",
    .thinking_field = "reasoning",
    .extra_headers = &.{
        .{ .name = "HTTP-Referer", .value = referer },
        .{ .name = "X-Title", .value = title },
    },
});

pub const Client = hc.SseClient(Cfg);
const Stream = hc.SseStream(Cfg);

const writeJsonLossy = hc.writeJsonLossy;

// ── Shared auth headers ─────────────────────────────────────────────────────

/// Construct Chat Completions request headers: `content-type`, a Bearer
/// `authorization` from the resolved credential, then any provider-specific
/// extras. OAuth and api_key both map to Bearer (OpenAI-compatible convention).
pub fn buildChatAuthHeaders(
    extra: []const std.http.Header,
    auth: *auth_mod.Result,
    ar: std.mem.Allocator,
) HeaderError!std.ArrayListUnmanaged(std.http.Header) {
    var hdrs = std.ArrayListUnmanaged(std.http.Header).empty;
    try hdrs.append(ar, .{ .name = "content-type", .value = "application/json" });
    const secret = switch (auth.auth) {
        .oauth => |oauth| oauth.access,
        .api_key => |key| key,
    };
    const bearer = try std.fmt.allocPrint(ar, "Bearer {s}", .{secret});
    try hdrs.append(ar, .{ .name = "authorization", .value = bearer });
    for (extra) |h| try hdrs.append(ar, h);
    return hdrs;
}

// ── Shared body building ────────────────────────────────────────────────────

fn reasoningEffort(opts: providers.Opts) ?[]const u8 {
    return switch (opts.thinking) {
        .off => null,
        .adaptive => "medium",
        .budget => blk: {
            const b = opts.thinking_budget;
            if (b <= 1024) break :blk "minimal";
            if (b <= 4096) break :blk "low";
            if (b <= 16384) break :blk "medium";
            break :blk "high";
        },
    };
}

/// Build an OpenAI Chat Completions request body. `supports_reasoning` gates the
/// `reasoning_effort` field so providers without a reasoning channel (mistral)
/// never emit it. Rejects message parts that have no Chat Completions encoding
/// with `error.UnsupportedPartType` (no silent drop).
pub fn buildChatBody(
    alloc: std.mem.Allocator,
    req: providers.Request,
    supports_reasoning: bool,
) BodyError![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    writeChatBody(ar, &js, req, supports_reasoning) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedPartType => return error.UnsupportedPartType,
        else => return error.OutOfMemory,
    };

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeChatBody(
    ar: std.mem.Allocator,
    js: *std.json.Stringify,
    req: providers.Request,
    supports_reasoning: bool,
) !void {
    try js.beginObject();

    try js.objectField("model");
    try js.write(req.model);

    try js.objectField("stream");
    try js.write(true);

    try js.objectField("stream_options");
    try js.beginObject();
    try js.objectField("include_usage");
    try js.write(true);
    try js.endObject();

    try js.objectField("max_tokens");
    try js.write(req.opts.max_out orelse default_max_output_tokens);

    if (req.opts.temp) |temp| {
        try js.objectField("temperature");
        try js.write(temp);
    }
    if (req.opts.top_p) |top_p| {
        try js.objectField("top_p");
        try js.write(top_p);
    }

    if (supports_reasoning) {
        if (reasoningEffort(req.opts)) |effort| {
            try js.objectField("reasoning_effort");
            try js.write(effort);
        }
    }

    try js.objectField("messages");
    try writeMessages(ar, js, req.msgs);

    if (req.tools.len > 0) {
        try js.objectField("tools");
        try writeTools(ar, js, req.tools);
    }

    try js.endObject();
}

fn writeMessages(ar: std.mem.Allocator, js: *std.json.Stringify, msgs: []const providers.Msg) !void {
    try js.beginArray();
    for (msgs) |msg| {
        switch (msg.role) {
            .system => try writeTextMessage(ar, js, "system", msg.parts),
            .user => try writeTextMessage(ar, js, "user", msg.parts),
            .assistant => try writeAssistantMessage(ar, js, msg.parts),
            .tool => try writeToolMessages(ar, js, msg.parts),
        }
    }
    try js.endArray();
}

fn writeTextMessage(
    ar: std.mem.Allocator,
    js: *std.json.Stringify,
    role: []const u8,
    parts: []const providers.Part,
) !void {
    var has_text = false;
    for (parts) |part| {
        if (part == .text) has_text = true;
    }
    if (!has_text) return;

    try js.beginObject();
    try js.objectField("role");
    try js.write(role);
    try js.objectField("content");
    try js.beginArray();
    for (parts) |part| switch (part) {
        .text => |text| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("text");
            try js.objectField("text");
            try writeJsonLossy(ar, js, text);
            try js.endObject();
        },
        else => return error.UnsupportedPartType,
    };
    try js.endArray();
    try js.endObject();
}

fn writeAssistantMessage(ar: std.mem.Allocator, js: *std.json.Stringify, parts: []const providers.Part) !void {
    // Chat Completions wants ONE assistant message carrying both text content
    // and a tool_calls array. Reject tool_result inside an assistant turn.
    var has_text = false;
    var has_tool = false;
    for (parts) |part| switch (part) {
        .text => has_text = true,
        .tool_call => has_tool = true,
        .tool_result => return error.UnsupportedPartType,
    };

    try js.beginObject();
    try js.objectField("role");
    try js.write("assistant");

    try js.objectField("content");
    if (has_text) {
        try js.beginArray();
        for (parts) |part| switch (part) {
            .text => |text| {
                try js.beginObject();
                try js.objectField("type");
                try js.write("text");
                try js.objectField("text");
                try writeJsonLossy(ar, js, text);
                try js.endObject();
            },
            else => {},
        };
        try js.endArray();
    } else {
        try js.write(null);
    }

    if (has_tool) {
        try js.objectField("tool_calls");
        try js.beginArray();
        for (parts) |part| switch (part) {
            .tool_call => |tc| {
                try js.beginObject();
                try js.objectField("id");
                try js.write(tc.id);
                try js.objectField("type");
                try js.write("function");
                try js.objectField("function");
                try js.beginObject();
                try js.objectField("name");
                try writeJsonLossy(ar, js, tc.name);
                try js.objectField("arguments");
                try writeJsonLossy(ar, js, tc.args);
                try js.endObject();
                try js.endObject();
            },
            else => {},
        };
        try js.endArray();
    }

    try js.endObject();
}

fn writeToolMessages(ar: std.mem.Allocator, js: *std.json.Stringify, parts: []const providers.Part) !void {
    for (parts) |part| switch (part) {
        .tool_result => |tr| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("tool");
            try js.objectField("tool_call_id");
            try js.write(compat.toolResultCallId(tr));
            try js.objectField("content");
            try writeJsonLossy(ar, js, tr.output);
            try js.endObject();
        },
        else => return error.UnsupportedPartType,
    };
}

fn writeTools(ar: std.mem.Allocator, js: *std.json.Stringify, tools: []const providers.Tool) !void {
    try js.beginArray();
    for (tools) |tool| {
        try js.beginObject();
        try js.objectField("type");
        try js.write("function");
        try js.objectField("function");
        try js.beginObject();
        try js.objectField("name");
        try writeJsonLossy(ar, js, tool.name);
        try js.objectField("description");
        try writeJsonLossy(ar, js, tool.desc);
        try js.objectField("parameters");
        if (tool.schema.len > 0) {
            try js.beginWriteRaw();
            try js.writer.writeAll(tool.schema);
            js.endWriteRaw();
        } else {
            try js.beginObject();
            try js.objectField("type");
            try js.write("object");
            try js.objectField("properties");
            try js.beginObject();
            try js.endObject();
            try js.endObject();
        }
        try js.endObject();
        try js.endObject();
    }
    try js.endArray();
}

// ── Shared SSE parsing ──────────────────────────────────────────────────────

const json_opts: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

const ChatFn = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const ChatToolCall = struct {
    index: ?u64 = null,
    id: ?[]const u8 = null,
    function: ?ChatFn = null,
};

const ChatDelta = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const ChatToolCall = null,
};

const ChatChoice = struct {
    delta: ?ChatDelta = null,
    finish_reason: ?[]const u8 = null,
};

const ChatUsage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    prompt_tokens_details: ?Details = null,

    const Details = struct {
        cached_tokens: ?u64 = null,
    };
};

const ChatChunk = struct {
    choices: ?[]const ChatChoice = null,
    usage: ?ChatUsage = null,
};

const ChatErrObj = struct {
    message: ?[]const u8 = null,
};

const ChatErrEnvelope = struct {
    @"error": ?ChatErrObj = null,
};

/// Parse one Chat Completions SSE data line. `thinking_field` selects which
/// delta key (`reasoning` vs `reasoning_content`) maps to a thinking event; a
/// null field disables reasoning extraction entirely (mistral). `Cfg` is the
/// concrete stream config so we can reach the typed `ext` state.
pub fn parseChatSseData(
    comptime thinking_field: ?[]const u8,
    comptime CfgT: type,
    self: *hc.SseStream(CfgT),
    data: []const u8,
) anyerror!?providers.Event {
    const ar = self.arena.allocator();

    // Error envelope first: `{"error":{"message":...}}`.
    if (std.mem.indexOf(u8, data, "\"error\"") != null) {
        const err_env = std.json.parseFromSlice(ChatErrEnvelope, ar, data, json_opts) catch null;
        if (err_env) |env| {
            if (env.value.@"error") |eo| {
                const msg = eo.message orelse "unknown error";
                self.done = true;
                self.pending = .{ .stop = .{ .reason = .err } };
                return .{ .err = msg };
            }
        }
    }

    const chunk = std.json.parseFromSlice(ChatChunk, ar, data, json_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    if (chunk.value.usage) |u| {
        return onUsage(CfgT, self, u);
    }

    const choices = chunk.value.choices orelse return null;
    if (choices.len == 0) return null;
    const choice = choices[0];

    if (choice.delta) |delta| {
        if (delta.tool_calls) |tcs| {
            try accumulateToolCalls(CfgT, self, tcs);
        }
        if (delta.content) |content| {
            if (content.len > 0) return .{ .text = content };
        }
        const reasoning = pickReasoning(thinking_field, delta);
        if (reasoning) |r| {
            if (r.len > 0) return .{ .thinking = r };
        }
    }

    if (choice.finish_reason) |fr| {
        return onFinish(CfgT, self, fr);
    }

    return null;
}

fn pickReasoning(comptime thinking_field: ?[]const u8, delta: ChatDelta) ?[]const u8 {
    const field = thinking_field orelse return null;
    if (std.mem.eql(u8, field, "reasoning_content")) return delta.reasoning_content;
    return delta.reasoning;
}

fn accumulateToolCalls(comptime CfgT: type, self: *hc.SseStream(CfgT), tcs: []const ChatToolCall) !void {
    for (tcs) |tc| {
        if (tc.id) |id| {
            if (id.len > 0) {
                self.ext.tool_call_id.clearRetainingCapacity();
                try self.ext.tool_call_id.appendSlice(self.alloc, id);
                self.ext.have_tool = true;
            }
        }
        const func = tc.function orelse continue;
        if (func.name) |name| {
            if (name.len > 0) {
                self.tool_name.clearRetainingCapacity();
                try self.tool_name.appendSlice(self.alloc, name);
            }
        }
        if (func.arguments) |args| {
            try self.tool_args.appendSlice(self.alloc, args);
        }
        self.in_tool = true;
    }
}

fn onFinish(comptime CfgT: type, self: *hc.SseStream(CfgT), finish_reason: []const u8) !?providers.Event {
    // A tool_calls finish means we should flush the buffered tool call.
    const is_tool = std.mem.eql(u8, finish_reason, "tool_calls");
    if (is_tool and self.ext.have_tool) {
        const id = self.ext.tool_call_id.items;
        const name = self.tool_name.items;
        const args = if (self.tool_args.items.len > 0) self.tool_args.items else "{}";
        self.in_tool = false;
        self.ext.saw_tool_call = true;
        const stream_ar = self.arena.allocator();
        const ev: providers.Event = .{ .tool_call = .{
            .id = try stream_ar.dupe(u8, id),
            .name = try stream_ar.dupe(u8, name),
            .args = try stream_ar.dupe(u8, args),
        } };
        // Stop is delivered on the trailing usage chunk; record reason now so it
        // is correct even when usage is omitted.
        self.pending = .{ .stop = .{ .reason = .tool } };
        return ev;
    }

    self.pending = .{ .stop = .{ .reason = mapFinishReason(finish_reason, self.ext.saw_tool_call) } };
    self.done = true;
    return null;
}

fn onUsage(comptime CfgT: type, self: *hc.SseStream(CfgT), u: ChatUsage) !?providers.Event {
    const canon = compat.usageToCanonical(.{
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .total_tokens = u.total_tokens,
        .prompt_tokens_details = if (u.prompt_tokens_details) |d|
            .{ .cached_tokens = d.cached_tokens }
        else
            null,
    });
    self.in_tok = canon.in_tok;
    self.out_tok = canon.out_tok;
    self.cache_read = canon.cache_read;

    // Final chunk: usage closes the stream. Preserve a tool stop if one was set
    // by an earlier finish_reason; otherwise default to done (upgraded to tool
    // when a tool call was seen but no explicit finish arrived).
    if (self.pending == null) {
        const reason: providers.StopReason = if (self.ext.saw_tool_call) .tool else .done;
        self.pending = .{ .stop = .{ .reason = reason } };
    }
    self.done = true;

    return .{ .usage = .{
        .in_tok = canon.in_tok,
        .out_tok = canon.out_tok,
        .tot_tok = canon.tot_tok,
        .cache_read = canon.cache_read,
        .cache_write = canon.cache_write,
    } };
}

fn mapFinishReason(reason: []const u8, saw_tool: bool) providers.StopReason {
    const map = std.StaticStringMap(providers.StopReason).initComptime(.{
        .{ "stop", .done },
        .{ "length", .max_out },
        .{ "tool_calls", .tool },
        .{ "function_call", .tool },
        .{ "content_filter", .err },
    });
    const r = map.get(reason) orelse .done;
    if (r == .done and saw_tool) return .tool;
    return r;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testStream() Stream {
    return hc.testStream(Cfg);
}

fn testParse(stream: *Stream, data: []const u8) !?providers.Event {
    return hc.testParse(Cfg, stream, data);
}

fn fakeApiKeyAuth(key: []const u8) auth_mod.Result {
    return .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .auth = .{ .api_key = key },
    };
}

fn fakeOAuth(access: []const u8) auth_mod.Result {
    return .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .auth = .{ .oauth = .{ .access = access, .refresh = "r", .expires = 0 } },
    };
}

test "openrouter buildAuthHeaders sends Bearer + attribution headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var auth = fakeApiKeyAuth("sk-or-test");
    defer auth.deinit();

    const hdrs = try Cfg.buildAuthHeaders(&auth, ar);
    try testing.expectEqualStrings("content-type", hdrs.items[0].name);
    try testing.expectEqualStrings("authorization", hdrs.items[1].name);
    try testing.expectEqualStrings("Bearer sk-or-test", hdrs.items[1].value);
    try testing.expectEqualStrings("HTTP-Referer", hdrs.items[2].name);
    try testing.expectEqualStrings(referer, hdrs.items[2].value);
    try testing.expectEqualStrings("X-Title", hdrs.items[3].name);
    try testing.expectEqualStrings(title, hdrs.items[3].value);
}

test "openrouter buildAuthHeaders maps oauth access to Bearer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var auth = fakeOAuth("oauth-access-tok");
    defer auth.deinit();

    const hdrs = try Cfg.buildAuthHeaders(&auth, ar);
    try testing.expectEqualStrings("Bearer oauth-access-tok", hdrs.items[1].value);
}

test "openrouter buildBody wraps request in OpenAI chat format" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const body = try Cfg.buildBody(testing.allocator, .{
        .model = "openai/gpt-4o",
        .msgs = &msgs,
        .opts = .{ .thinking = .off },
    }, false);
    defer testing.allocator.free(body);
    try hc.expectSnap(@src(), body,
        \\[]u8
        \\  "{"model":"openai/gpt-4o","stream":true,"stream_options":{"include_usage":true},"max_tokens":16384,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"
    );
}

test "openrouter buildBody emits reasoning_effort and tool history" {
    const msgs = [_]providers.Msg{
        .{ .role = .system, .parts = &.{.{ .text = "sys" }} },
        .{ .role = .user, .parts = &.{.{ .text = "run" }} },
        .{ .role = .assistant, .parts = &.{.{ .tool_call = .{
            .id = "call_1",
            .name = "bash",
            .args = "{\"cmd\":\"ls\"}",
        } }} },
        .{ .role = .tool, .parts = &.{.{ .tool_result = .{
            .id = "call_1",
            .output = "ok",
        } }} },
    };
    const tools = [_]providers.Tool{
        .{ .name = "bash", .desc = "Run shell", .schema = "{\"type\":\"object\"}" },
    };
    const body = try Cfg.buildBody(testing.allocator, .{
        .model = "x/y",
        .msgs = &msgs,
        .tools = &tools,
        .opts = .{ .thinking = .adaptive },
    }, false);
    defer testing.allocator.free(body);
    try hc.expectSnap(@src(), body,
        \\[]u8
        \\  "{"model":"x/y","stream":true,"stream_options":{"include_usage":true},"max_tokens":16384,"reasoning_effort":"medium","messages":[{"role":"system","content":[{"type":"text","text":"sys"}]},{"role":"user","content":[{"type":"text","text":"run"}]},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"cmd\":\"ls\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"ok"}],"tools":[{"type":"function","function":{"name":"bash","description":"Run shell","parameters":{"type":"object"}}}]}"
    );
}

test "openrouter parseSseData content delta emits text" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{"content":"hello"}}]}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("hello", ev.?.text);
}

test "openrouter parseSseData reasoning delta emits thinking" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{"reasoning":"thinking..."}}]}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("thinking...", ev.?.thinking);
}

test "openrouter parseSseData tool call lifecycle emits tool_call" {
    var stream = testStream();
    defer stream.arena.deinit();
    defer stream.ext.tool_call_id.deinit(testing.allocator);
    defer stream.tool_name.deinit(testing.allocator);
    defer stream.tool_args.deinit(testing.allocator);

    _ = try testParse(&stream,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"bash","arguments":"{\"cmd\":"}}]}}]}
    );
    _ = try testParse(&stream,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}}]}}]}
    );
    const ev = try testParse(&stream,
        \\{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
    );
    const tc = switch (ev orelse return error.TestUnexpectedResult) {
        .tool_call => |tool_call| tool_call,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("call_x", tc.id);
    try testing.expectEqualStrings("bash", tc.name);
    try testing.expectEqualStrings("{\"cmd\":\"ls\"}", tc.args);
    try testing.expectEqual(providers.StopReason.tool, stream.pending.?.stop.reason);
}

test "openrouter parseSseData usage chunk emits usage and stop" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,"prompt_tokens_details":{"cached_tokens":3}}}
    );
    const usage = switch (ev orelse return error.TestUnexpectedResult) {
        .usage => |got| got,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u64, 10), usage.in_tok);
    try testing.expectEqual(@as(u64, 4), usage.out_tok);
    try testing.expectEqual(@as(u64, 14), usage.tot_tok);
    try testing.expectEqual(@as(u64, 3), usage.cache_read);
    try testing.expectEqual(providers.StopReason.done, stream.pending.?.stop.reason);
    try testing.expect(stream.done);
}

test "openrouter parseSseData error envelope emits err and stop" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"error":{"message":"boom","code":"bad"}}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("boom", ev.?.err);
    try testing.expectEqual(providers.StopReason.err, stream.pending.?.stop.reason);
}

test "openrouter buildBody rejects unsupported assistant tool_result" {
    const msgs = [_]providers.Msg{
        .{ .role = .assistant, .parts = &.{.{ .tool_result = .{ .id = "x", .output = "y" } }} },
    };
    try testing.expectError(error.UnsupportedPartType, Cfg.buildBody(testing.allocator, .{
        .model = "m",
        .msgs = &msgs,
        .opts = .{ .thinking = .off },
    }, false));
}

test "openrouter mapFinishReason maps known reasons" {
    try testing.expectEqual(providers.StopReason.done, mapFinishReason("stop", false));
    try testing.expectEqual(providers.StopReason.max_out, mapFinishReason("length", false));
    try testing.expectEqual(providers.StopReason.tool, mapFinishReason("tool_calls", false));
    try testing.expectEqual(providers.StopReason.tool, mapFinishReason("stop", true));
    try testing.expectEqual(providers.StopReason.done, mapFinishReason("mystery", false));
}
