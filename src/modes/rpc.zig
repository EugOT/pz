//! RPC mode: JSON-RPC 2.0 dispatch to an external plugin process.
//!
//! `pz` serializes a tool/command call (call_id, kind, args, cancel_token) into a
//! JSON-RPC 2.0 request, hands it to a transport, then parses the response and
//! integrates the result into the transcript. The transport is a child process
//! speaking JSON-RPC over stdin/stdout (one request, one response per call), but
//! is abstracted behind a comptime `Transport` interface so unit tests can inject
//! a mock without spawning a real subprocess.
//!
//! Process isolation is provided by `ProcTransport` (env scrubbing + protected
//! path checks, mirroring `core/providers/proc_transport.zig`). Audit emission of
//! RPC calls is DEFERRED to EXT-WIRE.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("../core.zig");
const sandbox = @import("../core/sandbox.zig");
const shell = @import("../core/shell.zig");
const writeJsonStr = @import("../core/json.zig").writeJsonStr;

/// Cancel polling reuses the provider vtable so callers can pass the same token
/// they already hold for the streaming loop.
pub const CancelPoll = core.providers.CancelPoll;

pub const Error = error{
    OutOfMemory,
    InvalidUtf8,
    Canceled,
    /// Transport failed to deliver the request or read the response.
    TransportFailure,
    /// Response was not valid JSON-RPC 2.0 or referenced a different call.
    BadResponse,
    /// The plugin returned a JSON-RPC error object.
    PluginError,
};

/// What kind of call this is. The `method` field of the JSON-RPC request.
pub const Kind = enum {
    tool,
    command,

    pub fn method(self: Kind) []const u8 {
        return switch (self) {
            .tool => "tool",
            .command => "command",
        };
    }
};

/// A single dispatch request. `args` is a raw JSON value (object/string) already
/// produced by the caller; it is embedded verbatim into `params.args`.
pub const Call = struct {
    id: []const u8,
    kind: Kind,
    /// Raw JSON for the params payload (e.g. `{"path":"a"}`). Must be valid JSON.
    args: []const u8,
    /// Optional opaque token forwarded to the plugin so it can correlate a
    /// cancel notification. Empty string means "no token".
    cancel_token: []const u8 = "",
};

/// Result of a successful dispatch. `output` is the raw JSON text of the
/// `result` field; `owned` is the backing allocation to free via `deinit`.
pub const Result = struct {
    output: []const u8,
    is_err: bool = false,
    owned: []u8,

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.owned);
        self.* = undefined;
    }
};

/// Serialize `call` into a JSON-RPC 2.0 request line (newline-terminated so the
/// plugin can read line-delimited). Caller owns the returned slice.
pub fn buildCall(alloc: std.mem.Allocator, call: Call) Error![]u8 {
    try ensureUtf8(call.id);
    try ensureUtf8(call.args);
    try ensureUtf8(call.cancel_token);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    writeCall(w, call) catch return error.OutOfMemory;

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeCall(w: *std.Io.Writer, call: Call) std.Io.Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonStr(w, call.id);
    try w.writeAll(",\"method\":");
    try writeJsonStr(w, call.kind.method());
    try w.writeAll(",\"params\":{\"call_id\":");
    try writeJsonStr(w, call.id);
    if (call.cancel_token.len > 0) {
        try w.writeAll(",\"cancel_token\":");
        try writeJsonStr(w, call.cancel_token);
    }
    try w.writeAll(",\"args\":");
    // args is embedded verbatim as a JSON value.
    try w.writeAll(call.args);
    try w.writeAll("}}\n");
}

/// Parse a JSON-RPC 2.0 response. Verifies `jsonrpc == "2.0"` and that the
/// response `id` matches `expect_id`. On a `result` field, returns the raw JSON
/// text of that field. On an `error` field, returns a `Result` with `is_err`.
pub fn parseResult(
    alloc: std.mem.Allocator,
    expect_id: []const u8,
    raw: []const u8,
) Error!Result {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.BadResponse;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadResponse,
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadResponse,
    };

    // jsonrpc must be exactly "2.0".
    const ver = obj.get("jsonrpc") orelse return error.BadResponse;
    switch (ver) {
        .string => |s| if (!std.mem.eql(u8, s, "2.0")) return error.BadResponse,
        else => return error.BadResponse,
    }

    // id must match the request id.
    const id = obj.get("id") orelse return error.BadResponse;
    switch (id) {
        .string => |s| if (!std.mem.eql(u8, s, expect_id)) return error.BadResponse,
        else => return error.BadResponse,
    }

    if (obj.get("error")) |err_val| {
        const text = try reencode(alloc, err_val);
        return .{ .output = text, .is_err = true, .owned = text };
    }

    const result = obj.get("result") orelse return error.BadResponse;
    const text = try reencode(alloc, result);
    return .{ .output = text, .is_err = false, .owned = text };
}

/// Re-serialize a parsed JSON value back to compact text (the value text is not
/// retained verbatim by std.json, so we re-encode the result/error payload).
fn reencode(alloc: std.mem.Allocator, val: std.json.Value) Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, val, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Dispatch `call` through `transport`, honoring `cancel`. `transport` must
/// expose `pub fn roundTrip(self: *T, alloc, req_wire: []const u8) anyerror![]u8`
/// returning the response bytes (caller frees). Cancellation is checked before
/// the round-trip and again before parsing, so a token tripped during transport
/// aborts cleanly.
pub fn dispatch(
    comptime T: type,
    alloc: std.mem.Allocator,
    transport: *T,
    call: Call,
    cancel: ?*CancelPoll,
) Error!Result {
    if (cancel) |c| if (c.isCanceled()) return error.Canceled;

    const req = try buildCall(alloc, call);
    defer alloc.free(req);

    const resp = transport.roundTrip(alloc, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TransportFailure,
    };
    defer alloc.free(resp);

    if (cancel) |c| if (c.isCanceled()) return error.Canceled;

    var res = try parseResult(alloc, call.id, resp);
    errdefer res.deinit(alloc);
    if (res.is_err) {
        // The caller still gets the error payload; surface it as a typed error
        // only when they ask. We hand back the Result so the transcript can show
        // the plugin's error text. is_err is set; no PluginError thrown here.
    }
    return res;
}

// --- Child-process transport (process isolation) ---

/// JSON-RPC transport backed by a child process: writes the request to the
/// plugin's stdin, reads the full response from its stdout. Mirrors the spawn
/// idiom of `core/providers/proc_transport.zig` (env scrub, protected-path
/// guard, real Io so spawn can allocate).
pub const ProcTransport = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cmd: []u8,
    cwd: ?[]u8 = null,
    max_resp: usize = 1024 * 1024,

    pub const Init = struct {
        alloc: std.mem.Allocator,
        io: std.Io,
        cmd: []const u8,
        cwd: ?[]const u8 = null,
        max_resp: usize = 1024 * 1024,
    };

    pub fn init(cfg: Init) !ProcTransport {
        if (cfg.cmd.len == 0) return error.InvalidCommand;
        if (cfg.max_resp == 0) return error.InvalidChunkSize;
        if (try shell.touchesProtectedPath(cfg.alloc, cfg.cmd)) return error.InvalidCommand;
        return .{
            .alloc = cfg.alloc,
            .io = cfg.io,
            .cmd = try cfg.alloc.dupe(u8, cfg.cmd),
            .cwd = if (cfg.cwd) |c| try cfg.alloc.dupe(u8, c) else null,
            .max_resp = cfg.max_resp,
        };
    }

    pub fn deinit(self: *ProcTransport) void {
        self.alloc.free(self.cmd);
        if (self.cwd) |c| self.alloc.free(c);
        self.* = undefined;
    }

    /// One request, one response. Caller frees the returned slice.
    pub fn roundTrip(self: *ProcTransport, alloc: std.mem.Allocator, req_wire: []const u8) ![]u8 {
        const argv = [_][]const u8{ "/bin/bash", "-lc", self.cmd };

        var env_len: usize = 0;
        while (std.c.environ[env_len] != null) : (env_len += 1) {}
        var env = try std.process.Environ.createMap(.{
            .block = .{ .slice = std.c.environ[0..env_len :null] },
        }, alloc);
        defer env.deinit();
        sandbox.scrubEnv(&env);

        var child = try std.process.spawn(self.io, .{
            .argv = argv[0..],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .cwd = if (self.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env,
            .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
        });
        errdefer _ = child.wait(self.io) catch {};

        var stdin = child.stdin orelse return error.Closed;
        child.stdin = null;
        try stdin.writeStreamingAll(self.io, req_wire);
        stdin.close(self.io);

        const stdout = child.stdout orelse return error.Closed;
        child.stdout = null;

        var read_buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(self.io, &read_buf);
        const resp = reader.interface.allocRemaining(alloc, .limited(self.max_resp)) catch |err| {
            stdout.close(self.io);
            return err;
        };
        errdefer alloc.free(resp);
        stdout.close(self.io);

        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.BadExit,
            else => return error.BadExit,
        }
        return resp;
    }
};

const ensureUtf8 = @import("tui/frame.zig").ensureUtf8;

// --- Tests ---

const expectSnapText = @import("../test/helpers.zig").expectSnapText;

/// In-memory transport: returns a canned response, records the request it saw,
/// and (optionally) trips a cancel flag mid-flight. No subprocess.
const MockTransport = struct {
    resp: []const u8,
    seen_req: ?[]u8 = null,
    alloc: std.mem.Allocator,
    cancel_on_call: ?*CancelFlag = null,
    fail: bool = false,

    fn roundTrip(self: *MockTransport, alloc: std.mem.Allocator, req_wire: []const u8) ![]u8 {
        if (self.seen_req) |old| self.alloc.free(old);
        self.seen_req = try self.alloc.dupe(u8, req_wire);
        if (self.cancel_on_call) |flag| flag.canceled = true;
        if (self.fail) return error.Closed;
        return try alloc.dupe(u8, self.resp);
    }

    fn deinit(self: *MockTransport) void {
        if (self.seen_req) |r| self.alloc.free(r);
    }
};

const CancelFlag = struct {
    canceled: bool = false,
    cancel_poll: CancelPoll = .{ .vt = &CancelPoll.Bind(@This(), isCanceled).vt },

    fn isCanceled(self: *CancelFlag) bool {
        return self.canceled;
    }
};

test "rpc buildCall serializes JSON-RPC 2.0 request with cancel token" {
    const wire = try buildCall(std.testing.allocator, .{
        .id = "call-7",
        .kind = .tool,
        .args = "{\"path\":\"a\"}",
        .cancel_token = "tok-9",
    });
    defer std.testing.allocator.free(wire);
    try expectSnapText(
        @src(),
        "{\"jsonrpc\":\"2.0\",\"id\":\"call-7\",\"method\":\"tool\",\"params\":{\"call_id\":\"call-7\",\"cancel_token\":\"tok-9\",\"args\":{\"path\":\"a\"}}}\n",
        wire,
    );
}

test "rpc buildCall omits cancel_token when empty" {
    const wire = try buildCall(std.testing.allocator, .{
        .id = "c1",
        .kind = .command,
        .args = "{}",
    });
    defer std.testing.allocator.free(wire);
    try expectSnapText(
        @src(),
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"command\",\"params\":{\"call_id\":\"c1\",\"args\":{}}}\n",
        wire,
    );
}

test "rpc round-trips a tool call through transport" {
    var mock = MockTransport{
        .alloc = std.testing.allocator,
        .resp = "{\"jsonrpc\":\"2.0\",\"id\":\"call-1\",\"result\":{\"ok\":true,\"n\":42}}",
    };
    defer mock.deinit();

    var res = try dispatch(MockTransport, std.testing.allocator, &mock, .{
        .id = "call-1",
        .kind = .tool,
        .args = "{\"q\":\"hi\"}",
    }, null);
    defer res.deinit(std.testing.allocator);

    try std.testing.expect(!res.is_err);
    // The request the plugin saw is the serialized JSON-RPC call.
    const req = mock.seen_req orelse return error.TestUnexpectedResult;
    const combined = try std.fmt.allocPrint(std.testing.allocator, "req={s}\nout={s}", .{ req, res.output });
    defer std.testing.allocator.free(combined);
    try expectSnapText(
        @src(),
        "req={\"jsonrpc\":\"2.0\",\"id\":\"call-1\",\"method\":\"tool\",\"params\":{\"call_id\":\"call-1\",\"args\":{\"q\":\"hi\"}}}\n\nout={\"ok\":true,\"n\":42}",
        combined,
    );
}

test "rpc surfaces plugin error payload as is_err result" {
    var mock = MockTransport{
        .alloc = std.testing.allocator,
        .resp = "{\"jsonrpc\":\"2.0\",\"id\":\"c2\",\"error\":{\"code\":-32000,\"message\":\"boom\"}}",
    };
    defer mock.deinit();

    var res = try dispatch(MockTransport, std.testing.allocator, &mock, .{
        .id = "c2",
        .kind = .tool,
        .args = "{}",
    }, null);
    defer res.deinit(std.testing.allocator);

    try std.testing.expect(res.is_err);
    try expectSnapText(@src(), "{\"code\":-32000,\"message\":\"boom\"}", res.output);
}

test "rpc honors cancel token set before dispatch" {
    var mock = MockTransport{
        .alloc = std.testing.allocator,
        .resp = "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"result\":{}}",
    };
    defer mock.deinit();

    var flag = CancelFlag{ .canceled = true };
    try std.testing.expectError(error.Canceled, dispatch(MockTransport, std.testing.allocator, &mock, .{
        .id = "x",
        .kind = .tool,
        .args = "{}",
    }, &flag.cancel_poll));
    // Transport never ran.
    try std.testing.expect(mock.seen_req == null);
}

test "rpc honors cancel token tripped during transport" {
    var flag = CancelFlag{};
    var mock = MockTransport{
        .alloc = std.testing.allocator,
        .resp = "{\"jsonrpc\":\"2.0\",\"id\":\"y\",\"result\":{}}",
        .cancel_on_call = &flag,
    };
    defer mock.deinit();

    // Transport runs (sets cancel), but the post-transport cancel check aborts
    // before the result is delivered to the caller.
    try std.testing.expectError(error.Canceled, dispatch(MockTransport, std.testing.allocator, &mock, .{
        .id = "y",
        .kind = .tool,
        .args = "{}",
    }, &flag.cancel_poll));
    try std.testing.expect(mock.seen_req != null);
}

test "rpc rejects response with mismatched id" {
    try std.testing.expectError(error.BadResponse, parseResult(
        std.testing.allocator,
        "want",
        "{\"jsonrpc\":\"2.0\",\"id\":\"other\",\"result\":{}}",
    ));
}

test "rpc rejects non-2.0 jsonrpc version" {
    try std.testing.expectError(error.BadResponse, parseResult(
        std.testing.allocator,
        "c",
        "{\"jsonrpc\":\"1.0\",\"id\":\"c\",\"result\":{}}",
    ));
}

test "rpc reports transport failure" {
    var mock = MockTransport{
        .alloc = std.testing.allocator,
        .resp = "{}",
        .fail = true,
    };
    defer mock.deinit();
    try std.testing.expectError(error.TransportFailure, dispatch(MockTransport, std.testing.allocator, &mock, .{
        .id = "c",
        .kind = .tool,
        .args = "{}",
    }, null));
}

test "rpc buildCall rejects invalid utf8 args" {
    const bad = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, buildCall(std.testing.allocator, .{
        .id = "c",
        .kind = .tool,
        .args = bad[0..],
    }));
}
