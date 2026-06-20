//! Session event schema: versioned JSONL event types.
const std = @import("std");
const utf8 = @import("../utf8.zig");

pub const version_current: u16 = 1;

pub const Event = struct {
    version: u16 = version_current,
    at_ms: i64 = 0,
    data: Data = .{
        .noop = {},
    },
    /// Repository provenance for the moment the event was recorded.
    /// Optional and defaults to null so older JSONL (written before this
    /// field existed) still deserializes.
    git_meta: ?GitMeta = null,
    /// Session id this event's session was forked from, enabling
    /// fork/tree reconstruction. Null for root sessions and for older
    /// JSONL that predates this field.
    parent_sid: ?[]const u8 = null,
    /// Per-entry metadata: failure flags, originating tool, and process
    /// exit codes. Optional for backward compatibility.
    entry_meta: ?EntryMeta = null,

    /// Repository state captured alongside a session event.
    pub const GitMeta = struct {
        repo: []const u8,
        branch: []const u8,
        commit: []const u8,
    };

    /// Additional per-entry annotations carried beside the event payload.
    /// Every field is optional so partial metadata round-trips and so the
    /// whole struct can be omitted from older JSONL.
    pub const EntryMeta = struct {
        /// Wall-clock timestamp in milliseconds, distinct from `at_ms`
        /// (which is the logical event time). Lets exporters surface a
        /// human timestamp without overloading the ordering key.
        ts_ms: ?i64 = null,
        /// True when this entry records an error condition.
        is_err: ?bool = null,
        /// Tool that produced this entry, when applicable.
        tool: ?[]const u8 = null,
        /// Process exit code associated with this entry, when applicable.
        exit_code: ?i32 = null,
    };

    pub const Data = union(Tag) {
        noop: void,
        prompt: Text,
        text: Text,
        thinking: Text,
        tool_call: ToolCall,
        tool_result: ToolResult,
        usage: Usage,
        stop: Stop,
        err: Text,
    };

    pub const Tag = enum {
        noop,
        prompt,
        text,
        thinking,
        tool_call,
        tool_result,
        usage,
        stop,
        err,
    };

    pub const Text = struct {
        text: []const u8,
    };

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        args: []const u8,
    };

    pub const ToolResult = struct {
        id: []const u8,
        output: []const u8,
        is_err: bool = false,
    };

    pub const Usage = struct {
        in_tok: u64 = 0,
        out_tok: u64 = 0,
        tot_tok: u64 = 0,
        cache_read: u64 = 0,
        cache_write: u64 = 0,
    };

    pub const Stop = struct {
        reason: StopReason,
    };

    pub const StopReason = enum {
        done,
        max_out,
        tool,
        canceled,
        err,
    };

    /// Deep-copy all string slices into `alloc`. The result is fully
    /// independent of the source (e.g. a ReplayReader's per-call arena).
    pub fn dupe(self: Event, alloc: std.mem.Allocator) error{OutOfMemory}!Event {
        const data = try dupeData(alloc, self.data);
        errdefer freeData(alloc, data);

        const git_meta = try dupeGitMeta(alloc, self.git_meta);
        errdefer freeGitMeta(alloc, git_meta);

        const parent_sid: ?[]const u8 = if (self.parent_sid) |p|
            try alloc.dupe(u8, p)
        else
            null;
        errdefer if (parent_sid) |p| alloc.free(p);

        const entry_meta = try dupeEntryMeta(alloc, self.entry_meta);

        return .{
            .version = self.version,
            .at_ms = self.at_ms,
            .data = data,
            .git_meta = git_meta,
            .parent_sid = parent_sid,
            .entry_meta = entry_meta,
        };
    }

    /// Free strings previously allocated by `dupe`.
    pub fn free(self: Event, alloc: std.mem.Allocator) void {
        freeData(alloc, self.data);
        freeGitMeta(alloc, self.git_meta);
        if (self.parent_sid) |p| alloc.free(p);
        freeEntryMeta(alloc, self.entry_meta);
    }

    fn dupeGitMeta(alloc: std.mem.Allocator, gm: ?GitMeta) error{OutOfMemory}!?GitMeta {
        const g = gm orelse return null;
        const repo = try alloc.dupe(u8, g.repo);
        errdefer alloc.free(repo);
        const branch = try alloc.dupe(u8, g.branch);
        errdefer alloc.free(branch);
        const commit = try alloc.dupe(u8, g.commit);
        return .{ .repo = repo, .branch = branch, .commit = commit };
    }

    fn freeGitMeta(alloc: std.mem.Allocator, gm: ?GitMeta) void {
        const g = gm orelse return;
        alloc.free(g.repo);
        alloc.free(g.branch);
        alloc.free(g.commit);
    }

    fn dupeEntryMeta(alloc: std.mem.Allocator, em: ?EntryMeta) error{OutOfMemory}!?EntryMeta {
        const e = em orelse return null;
        const tool: ?[]const u8 = if (e.tool) |t| try alloc.dupe(u8, t) else null;
        return .{
            .ts_ms = e.ts_ms,
            .is_err = e.is_err,
            .tool = tool,
            .exit_code = e.exit_code,
        };
    }

    fn freeEntryMeta(alloc: std.mem.Allocator, em: ?EntryMeta) void {
        const e = em orelse return;
        if (e.tool) |t| alloc.free(t);
    }

    fn dupeData(alloc: std.mem.Allocator, data: Data) error{OutOfMemory}!Data {
        return switch (data) {
            .noop => .{
                .noop = {},
            },
            .prompt => |t| .{
                .prompt = .{ .text = try alloc.dupe(u8, t.text) },
            },
            .text => |t| .{
                .text = .{ .text = try alloc.dupe(u8, t.text) },
            },
            .thinking => |t| .{
                .thinking = .{ .text = try alloc.dupe(u8, t.text) },
            },
            .tool_call => |tc| blk: {
                const id = try alloc.dupe(u8, tc.id);
                errdefer alloc.free(id);
                const name = try alloc.dupe(u8, tc.name);
                errdefer alloc.free(name);
                const args = try alloc.dupe(u8, tc.args);
                break :blk .{ .tool_call = .{ .id = id, .name = name, .args = args } };
            },
            .tool_result => |tr| blk: {
                const id = try alloc.dupe(u8, tr.id);
                errdefer alloc.free(id);
                const out = try alloc.dupe(u8, tr.output);
                break :blk .{ .tool_result = .{ .id = id, .output = out, .is_err = tr.is_err } };
            },
            .usage => |u| .{ .usage = u },
            .stop => |s| .{ .stop = s },
            .err => |t| .{
                .err = .{ .text = try alloc.dupe(u8, t.text) },
            },
        };
    }

    fn freeData(alloc: std.mem.Allocator, data: Data) void {
        switch (data) {
            .noop, .usage, .stop => {},
            .prompt, .text, .thinking, .err => |t| alloc.free(t.text),
            .tool_call => |tc| {
                alloc.free(tc.id);
                alloc.free(tc.name);
                alloc.free(tc.args);
            },
            .tool_result => |tr| {
                alloc.free(tr.id);
                alloc.free(tr.output);
            },
        }
    }
};

pub const DecodeError = std.json.ParseError(std.json.Scanner) || error{
    UnsupportedVersion,
};

pub fn encodeAlloc(alloc: std.mem.Allocator, ev: Event) error{OutOfMemory}![]u8 {
    var out = ev;
    out.version = version_current;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    out.data = try sanitizeData(aa, out.data);
    out.git_meta = try sanitizeGitMeta(aa, out.git_meta);
    out.parent_sid = if (out.parent_sid) |p|
        try utf8.sanitizeMaybeAlloc(aa, p)
    else
        null;
    out.entry_meta = try sanitizeEntryMeta(aa, out.entry_meta);
    // Omit null optionals so events without the new metadata serialize
    // byte-identically to the pre-metadata format (backward compatibility).
    return std.json.Stringify.valueAlloc(alloc, out, .{ .emit_null_optional_fields = false });
}

fn sanitizeGitMeta(alloc: std.mem.Allocator, gm: ?Event.GitMeta) error{OutOfMemory}!?Event.GitMeta {
    const g = gm orelse return null;
    return .{
        .repo = try utf8.sanitizeMaybeAlloc(alloc, g.repo),
        .branch = try utf8.sanitizeMaybeAlloc(alloc, g.branch),
        .commit = try utf8.sanitizeMaybeAlloc(alloc, g.commit),
    };
}

fn sanitizeEntryMeta(alloc: std.mem.Allocator, em: ?Event.EntryMeta) error{OutOfMemory}!?Event.EntryMeta {
    const e = em orelse return null;
    return .{
        .ts_ms = e.ts_ms,
        .is_err = e.is_err,
        .tool = if (e.tool) |t| try utf8.sanitizeMaybeAlloc(alloc, t) else null,
        .exit_code = e.exit_code,
    };
}

fn sanitizeData(alloc: std.mem.Allocator, data: Event.Data) error{OutOfMemory}!Event.Data {
    return switch (data) {
        .noop => .{
            .noop = {},
        },
        .prompt => |t| .{
            .prompt = .{ .text = try utf8.sanitizeMaybeAlloc(alloc, t.text) },
        },
        .text => |t| .{
            .text = .{ .text = try utf8.sanitizeMaybeAlloc(alloc, t.text) },
        },
        .thinking => |t| .{
            .thinking = .{ .text = try utf8.sanitizeMaybeAlloc(alloc, t.text) },
        },
        .tool_call => |tc| .{
            .tool_call = .{
                .id = try utf8.sanitizeMaybeAlloc(alloc, tc.id),
                .name = try utf8.sanitizeMaybeAlloc(alloc, tc.name),
                .args = try utf8.sanitizeMaybeAlloc(alloc, tc.args),
            },
        },
        .tool_result => |tr| .{
            .tool_result = .{
                .id = try utf8.sanitizeMaybeAlloc(alloc, tr.id),
                .output = try utf8.sanitizeMaybeAlloc(alloc, tr.output),
                .is_err = tr.is_err,
            },
        },
        .usage => |u| .{ .usage = u },
        .stop => |s| .{ .stop = s },
        .err => |t| .{
            .err = .{ .text = try utf8.sanitizeMaybeAlloc(alloc, t.text) },
        },
    };
}

pub fn decodeSlice(alloc: std.mem.Allocator, raw: []const u8) DecodeError!std.json.Parsed(Event) {
    var parsed = try std.json.parseFromSlice(Event, alloc, raw, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (parsed.value.version != version_current) return error.UnsupportedVersion;

    return parsed;
}

test "session event json roundtrip" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const ev = Event{
        .version = 99,
        .at_ms = 42,
        .data = .{
            .tool_result = .{
                .id = "call-1",
                .output = "{\"ok\":true}",
                .is_err = false,
            },
        },
    };

    const raw = try encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);

    var parsed = try decodeSlice(std.testing.allocator, raw);
    defer parsed.deinit();

    try oh.snap(@src(),
        \\core.session.schema.Event
        \\  .version: u16 = 1
        \\  .at_ms: i64 = 42
        \\  .data: core.session.schema.Event.Data
        \\    .tool_result: core.session.schema.Event.ToolResult
        \\      .id: []const u8
        \\        "call-1"
        \\      .output: []const u8
        \\        "{"ok":true}"
        \\      .is_err: bool = false
        \\  .git_meta: ?core.session.schema.Event.GitMeta
        \\    null
        \\  .parent_sid: ?[]const u8
        \\    null
        \\  .entry_meta: ?core.session.schema.Event.EntryMeta
        \\    null
    ).expectEqual(parsed.value);
}

test "session event json replaces invalid utf8 lossy" {
    const utf8_case = @import("../../test/utf8_case.zig");
    const ev = Event{
        .at_ms = 7,
        .data = .{
            .tool_result = .{
                .id = "call-1",
                .output = utf8_case.bad_tool_out[0..],
                .is_err = false,
            },
        },
    };

    const raw = try encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, 0xff) == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, utf8_case.lossy_tool_out) != null);

    var parsed = try decodeSlice(std.testing.allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(utf8_case.lossy_tool_out, parsed.value.data.tool_result.output);
}

test "session event json rejects wrong version" {
    const raw = "{\"version\":7,\"at_ms\":1,\"data\":{\"noop\":{}}}";
    try std.testing.expectError(error.UnsupportedVersion, decodeSlice(std.testing.allocator, raw));
}

test "session event decodes legacy jsonl without optional metadata" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    // Exactly the byte layout written before git_meta/parent_sid/entry_meta
    // existed. The new optionals must default to null, not error.
    const raw = "{\"version\":1,\"at_ms\":7,\"data\":{\"text\":{\"text\":\"hi\"}}}";

    var parsed = try decodeSlice(std.testing.allocator, raw);
    defer parsed.deinit();

    try oh.snap(@src(),
        \\core.session.schema.Event
        \\  .version: u16 = 1
        \\  .at_ms: i64 = 7
        \\  .data: core.session.schema.Event.Data
        \\    .text: core.session.schema.Event.Text
        \\      .text: []const u8
        \\        "hi"
        \\  .git_meta: ?core.session.schema.Event.GitMeta
        \\    null
        \\  .parent_sid: ?[]const u8
        \\    null
        \\  .entry_meta: ?core.session.schema.Event.EntryMeta
        \\    null
    ).expectEqual(parsed.value);
}

test "session event omits null optional metadata when encoding" {
    // An event with no metadata must serialize byte-identically to the
    // pre-metadata format so legacy snapshots and round-trips stay valid.
    // A single exact-byte wire assertion is clearest with expectEqualStrings:
    // repo precedent reserves ohsnap for multi-field struct-shape snapshots
    // (see the Event field-tree snaps above) and uses expectEqualStrings for
    // raw byte payloads (export.zig HTML-escape test, the JSON tests below).
    const ev = Event{
        .at_ms = 7,
        .data = .{ .text = .{ .text = "hi" } },
    };
    const raw = try encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"at_ms\":7,\"data\":{\"text\":{\"text\":\"hi\"}}}",
        raw,
    );
}

test "session event roundtrips full metadata" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const ev = Event{
        .at_ms = 99,
        .data = .{ .text = .{ .text = "body" } },
        .git_meta = .{ .repo = "pz", .branch = "main", .commit = "414358b" },
        .parent_sid = "root-sid",
        .entry_meta = .{
            .ts_ms = 1718800000000,
            .is_err = true,
            .tool = "bash",
            .exit_code = 127,
        },
    };

    const raw = try encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);

    var parsed = try decodeSlice(std.testing.allocator, raw);
    defer parsed.deinit();

    try oh.snap(@src(),
        \\core.session.schema.Event
        \\  .version: u16 = 1
        \\  .at_ms: i64 = 99
        \\  .data: core.session.schema.Event.Data
        \\    .text: core.session.schema.Event.Text
        \\      .text: []const u8
        \\        "body"
        \\  .git_meta: ?core.session.schema.Event.GitMeta
        \\    .repo: []const u8
        \\      "pz"
        \\    .branch: []const u8
        \\      "main"
        \\    .commit: []const u8
        \\      "414358b"
        \\  .parent_sid: ?[]const u8
        \\    "root-sid"
        \\  .entry_meta: ?core.session.schema.Event.EntryMeta
        \\    .ts_ms: ?i64
        \\      1718800000000
        \\    .is_err: ?bool
        \\      true
        \\    .tool: ?[]const u8
        \\      "bash"
        \\    .exit_code: ?i32
        \\      127
    ).expectEqual(parsed.value);
}

test "Event.dupe deep-copies optional metadata" {
    const alloc = std.testing.allocator;
    const orig = Event{
        .at_ms = 5,
        .data = .{ .text = .{ .text = "body" } },
        .git_meta = .{ .repo = "pz", .branch = "main", .commit = "abc" },
        .parent_sid = "parent",
        .entry_meta = .{ .ts_ms = 10, .is_err = false, .tool = "edit", .exit_code = 0 },
    };
    const d = try orig.dupe(alloc);
    defer d.free(alloc);

    // Encode both; fidelity check independent of pointer identity.
    const a = try encodeAlloc(alloc, orig);
    defer alloc.free(a);
    const b = try encodeAlloc(alloc, d);
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);

    // Independent allocation: the duped strings must not alias the source.
    try std.testing.expect(d.git_meta.?.repo.ptr != orig.git_meta.?.repo.ptr);
    try std.testing.expect(d.parent_sid.?.ptr != orig.parent_sid.?.ptr);
    try std.testing.expect(d.entry_meta.?.tool.?.ptr != orig.entry_meta.?.tool.?.ptr);
}

test "session event encode replaces invalid utf8 in metadata" {
    const utf8_case = @import("../../test/utf8_case.zig");
    const ev = Event{
        .at_ms = 1,
        .data = .{ .text = .{ .text = "ok" } },
        .entry_meta = .{ .tool = utf8_case.bad_tool_out[0..] },
    };
    const raw = try encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, 0xff) == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, utf8_case.lossy_tool_out) != null);
}

test "Event.dupe deep-copies tool_call strings" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    const orig = Event{
        .at_ms = 42,
        .data = .{
            .tool_call = .{
                .id = "call-1",
                .name = "bash",
                .args = "{\"cmd\":\"ls\"}",
            },
        },
    };
    const d = try orig.dupe(alloc);
    defer d.free(alloc);

    try oh.snap(@src(),
        \\core.session.schema.Event
        \\  .version: u16 = 1
        \\  .at_ms: i64 = 42
        \\  .data: core.session.schema.Event.Data
        \\    .tool_call: core.session.schema.Event.ToolCall
        \\      .id: []const u8
        \\        "call-1"
        \\      .name: []const u8
        \\        "bash"
        \\      .args: []const u8
        \\        "{"cmd":"ls"}"
        \\  .git_meta: ?core.session.schema.Event.GitMeta
        \\    null
        \\  .parent_sid: ?[]const u8
        \\    null
        \\  .entry_meta: ?core.session.schema.Event.EntryMeta
        \\    null
    ).expectEqual(d);

    // Verify independent allocation (pointers differ)
    const tc = d.data.tool_call;
    try std.testing.expect(tc.id.ptr != orig.data.tool_call.id.ptr);
    try std.testing.expect(tc.name.ptr != orig.data.tool_call.name.ptr);
    try std.testing.expect(tc.args.ptr != orig.data.tool_call.args.ptr);
}

test "Event.dupe deep-copies tool_result strings" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    const orig = Event{
        .at_ms = 10,
        .data = .{
            .tool_result = .{
                .id = "c2",
                .output = "output-data",
                .is_err = true,
            },
        },
    };
    const d = try orig.dupe(alloc);
    defer d.free(alloc);

    try oh.snap(@src(),
        \\core.session.schema.Event
        \\  .version: u16 = 1
        \\  .at_ms: i64 = 10
        \\  .data: core.session.schema.Event.Data
        \\    .tool_result: core.session.schema.Event.ToolResult
        \\      .id: []const u8
        \\        "c2"
        \\      .output: []const u8
        \\        "output-data"
        \\      .is_err: bool = true
        \\  .git_meta: ?core.session.schema.Event.GitMeta
        \\    null
        \\  .parent_sid: ?[]const u8
        \\    null
        \\  .entry_meta: ?core.session.schema.Event.EntryMeta
        \\    null
    ).expectEqual(d);
    const tr = d.data.tool_result;
    try std.testing.expect(tr.id.ptr != orig.data.tool_result.id.ptr);
}

test "Event.dupe copies text variants" {
    const alloc = std.testing.allocator;
    const cases = [_]Event{
        .{
            .data = .{ .text = .{ .text = "hello" } },
        },
        .{
            .data = .{ .prompt = .{ .text = "prompt" } },
        },
        .{
            .data = .{ .thinking = .{ .text = "think" } },
        },
        .{
            .data = .{ .err = .{ .text = "oops" } },
        },
    };
    for (cases) |ev| {
        const d = try ev.dupe(alloc);
        defer d.free(alloc);
        // Encode both and compare — ensures full fidelity
        const a = try encodeAlloc(alloc, ev);
        defer alloc.free(a);
        const b = try encodeAlloc(alloc, d);
        defer alloc.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
}

test "Event.dupe noop/usage/stop are trivial" {
    const alloc = std.testing.allocator;
    const noop = Event{ .data = .{ .noop = {} } };
    const d1 = try noop.dupe(alloc);
    d1.free(alloc); // no-op free

    const usage = Event{ .data = .{ .usage = .{ .in_tok = 5 } } };
    const d2 = try usage.dupe(alloc);
    try std.testing.expectEqual(@as(u64, 5), d2.data.usage.in_tok);
    d2.free(alloc);

    const stop = Event{ .data = .{ .stop = .{ .reason = .done } } };
    const d3 = try stop.dupe(alloc);
    try std.testing.expectEqual(Event.StopReason.done, d3.data.stop.reason);
    d3.free(alloc);
}

// Property: encode/decode roundtrip preserves text events
test "schema property: text event roundtrip" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { ts: i64, text: zc.String }) bool {
            const alloc = std.testing.allocator;
            const ev = Event{
                .at_ms = args.ts,
                .data = .{
                    .text = .{ .text = args.text.slice() },
                },
            };
            const raw = encodeAlloc(alloc, ev) catch return true;
            defer alloc.free(raw);
            var parsed = decodeSlice(alloc, raw) catch return false;
            defer parsed.deinit();
            if (parsed.value.at_ms != args.ts) return false;
            return switch (parsed.value.data) {
                .text => |t| std.mem.eql(u8, t.text, args.text.slice()),
                else => false,
            };
        }
    }.prop, .{ .iterations = 200 });
}

// Property: encode/decode roundtrip preserves tool_call events
test "schema property: tool_call event roundtrip" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { id: zc.Id, name: zc.Id, a: zc.String }) bool {
            const alloc = std.testing.allocator;
            const ev = Event{
                .at_ms = 100,
                .data = .{
                    .tool_call = .{
                        .id = args.id.slice(),
                        .name = args.name.slice(),
                        .args = args.a.slice(),
                    },
                },
            };
            const raw = encodeAlloc(alloc, ev) catch return true;
            defer alloc.free(raw);
            var parsed = decodeSlice(alloc, raw) catch return false;
            defer parsed.deinit();
            return switch (parsed.value.data) {
                .tool_call => |tc| std.mem.eql(u8, tc.id, args.id.slice()) and
                    std.mem.eql(u8, tc.name, args.name.slice()) and
                    std.mem.eql(u8, tc.args, args.a.slice()),
                else => false,
            };
        }
    }.prop, .{ .iterations = 200 });
}

// Property: dupe+encode == encode (dupe preserves all data)
test "schema property: dupe preserves tool_call encode" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { id: zc.Id, name: zc.Id, a: zc.String }) bool {
            const alloc = std.testing.allocator;
            const ev = Event{
                .at_ms = 100,
                .data = .{
                    .tool_call = .{
                        .id = args.id.slice(),
                        .name = args.name.slice(),
                        .args = args.a.slice(),
                    },
                },
            };
            const d = ev.dupe(alloc) catch return true;
            defer d.free(alloc);
            const a = encodeAlloc(alloc, ev) catch return true;
            defer alloc.free(a);
            const b = encodeAlloc(alloc, d) catch return true;
            defer alloc.free(b);
            return std.mem.eql(u8, a, b);
        }
    }.prop, .{ .iterations = 200 });
}

test "schema property: tool_result event roundtrip" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { id: zc.Id, out: zc.String, is_err: bool }) bool {
            const alloc = std.testing.allocator;
            const ev = Event{
                .at_ms = 100,
                .data = .{
                    .tool_result = .{
                        .id = args.id.slice(),
                        .output = args.out.slice(),
                        .is_err = args.is_err,
                    },
                },
            };
            const raw = encodeAlloc(alloc, ev) catch return true;
            defer alloc.free(raw);
            var parsed = decodeSlice(alloc, raw) catch return false;
            defer parsed.deinit();
            return switch (parsed.value.data) {
                .tool_result => |tr| std.mem.eql(u8, tr.id, args.id.slice()) and
                    std.mem.eql(u8, tr.output, args.out.slice()) and
                    tr.is_err == args.is_err,
                else => false,
            };
        }
    }.prop, .{ .iterations = 200 });
}

test "schema property: dupe preserves tool_result encode" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { id: zc.Id, out: zc.String, is_err: bool }) bool {
            const alloc = std.testing.allocator;
            const ev = Event{
                .at_ms = 100,
                .data = .{
                    .tool_result = .{
                        .id = args.id.slice(),
                        .output = args.out.slice(),
                        .is_err = args.is_err,
                    },
                },
            };
            const dup = ev.dupe(alloc) catch return true;
            defer dup.free(alloc);
            const a = encodeAlloc(alloc, ev) catch return true;
            defer alloc.free(a);
            const b = encodeAlloc(alloc, dup) catch return true;
            defer alloc.free(b);
            return std.mem.eql(u8, a, b);
        }
    }.prop, .{ .iterations = 200 });
}

test "schema property: event encode/decode roundtrip across tags" {
    const pbt = @import("../prop_test.zig");
    const Text = pbt.Utf8(24);
    const Tag = enum {
        noop,
        prompt,
        text,
        thinking,
        tool_call,
        tool_result,
        usage,
        stop,
        err,
    };
    const Args = struct {
        at_ms: i64,
        tag: Tag,
        text: Text,
        id: pbt.Id,
        name: pbt.Id,
        out: Text,
        is_err: bool,
        in_tok: u64,
        out_tok: u64,
        tot_tok: u64,
        cache_read: u64,
        cache_write: u64,
        stop: Event.StopReason,
    };
    const Store = struct {
        a: [pbt.utf8MaxBytes(Text)]u8 = undefined,
        id: [pbt.Id.MAX_LEN]u8 = undefined,
        name: [pbt.Id.MAX_LEN]u8 = undefined,

        fn keepId(self: *@This(), id: pbt.Id) []const u8 {
            const raw = id.slice();
            @memcpy(self.id[0..raw.len], raw);
            return self.id[0..raw.len];
        }

        fn keepName(self: *@This(), name: pbt.Id) []const u8 {
            const raw = name.slice();
            @memcpy(self.name[0..raw.len], raw);
            return self.name[0..raw.len];
        }
    };

    const T = struct {
        fn build(args: Args, store: *Store) Event {
            return .{
                .at_ms = args.at_ms,
                .data = switch (args.tag) {
                    .noop => .{
                        .noop = {},
                    },
                    .prompt => .{
                        .prompt = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                    .text => .{
                        .text = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                    .thinking => .{
                        .thinking = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                    .tool_call => .{
                        .tool_call = .{
                            .id = store.keepId(args.id),
                            .name = store.keepName(args.name),
                            .args = pbt.utf8Slice(args.text, &store.a),
                        },
                    },
                    .tool_result => .{
                        .tool_result = .{
                            .id = store.keepId(args.id),
                            .output = pbt.utf8Slice(args.out, &store.a),
                            .is_err = args.is_err,
                        },
                    },
                    .usage => .{
                        .usage = .{
                            .in_tok = args.in_tok,
                            .out_tok = args.out_tok,
                            .tot_tok = args.tot_tok,
                            .cache_read = args.cache_read,
                            .cache_write = args.cache_write,
                        },
                    },
                    .stop => .{
                        .stop = .{ .reason = args.stop },
                    },
                    .err => .{
                        .err = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                },
            };
        }

        fn prop(args: Args) bool {
            const alloc = std.testing.allocator;
            var store: Store = .{};
            const ev = build(args, &store);
            const raw = encodeAlloc(alloc, ev) catch return false;
            defer alloc.free(raw);
            var parsed = decodeSlice(alloc, raw) catch return false;
            defer parsed.deinit();
            const got = encodeAlloc(alloc, parsed.value) catch return false;
            defer alloc.free(got);
            return std.mem.eql(u8, raw, got);
        }
    };

    try pbt.run(T.prop, .{
        .iterations = 200,
        .use_default_values = false,
    });
}

test "fuzz decodeSlice survives arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var input_buf: [512]u8 = undefined;
            const input = input_buf[0..smith.slice(&input_buf)];
            const alloc = std.testing.allocator;
            var parsed = decodeSlice(alloc, input) catch return;
            parsed.deinit();
        }
    }.f, .{ .corpus = &.{
        "{\"version\":1,\"at_ms\":0,\"data\":{\"noop\":{}}}",
        "{\"version\":1,\"at_ms\":1,\"data\":{\"text\":{\"text\":\"hi\"}}}",
        "",
        "{}",
        "{\"version\":99}",
        "\xff\xfe\x00\x01",
    } });
}

test "schema property: Event.dupe preserves encode across tags" {
    const pbt = @import("../prop_test.zig");
    const Text = pbt.Utf8(24);
    const Tag = enum {
        noop,
        prompt,
        text,
        thinking,
        tool_call,
        tool_result,
        usage,
        stop,
        err,
    };
    const Args = struct {
        at_ms: i64,
        tag: Tag,
        text: Text,
        id: pbt.Id,
        name: pbt.Id,
        out: Text,
        is_err: bool,
        in_tok: u64,
        out_tok: u64,
        tot_tok: u64,
        cache_read: u64,
        cache_write: u64,
        stop: Event.StopReason,
    };
    const Store = struct {
        a: [pbt.utf8MaxBytes(Text)]u8 = undefined,
        id: [pbt.Id.MAX_LEN]u8 = undefined,
        name: [pbt.Id.MAX_LEN]u8 = undefined,

        fn keepId(self: *@This(), id: pbt.Id) []const u8 {
            const raw = id.slice();
            @memcpy(self.id[0..raw.len], raw);
            return self.id[0..raw.len];
        }

        fn keepName(self: *@This(), name: pbt.Id) []const u8 {
            const raw = name.slice();
            @memcpy(self.name[0..raw.len], raw);
            return self.name[0..raw.len];
        }
    };

    const T = struct {
        fn build(args: Args, store: *Store) Event {
            return .{
                .at_ms = args.at_ms,
                .data = switch (args.tag) {
                    .noop => .{
                        .noop = {},
                    },
                    .prompt => .{
                        .prompt = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                    .text => .{
                        .text = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                    .thinking => .{
                        .thinking = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                    .tool_call => .{
                        .tool_call = .{
                            .id = store.keepId(args.id),
                            .name = store.keepName(args.name),
                            .args = pbt.utf8Slice(args.text, &store.a),
                        },
                    },
                    .tool_result => .{
                        .tool_result = .{
                            .id = store.keepId(args.id),
                            .output = pbt.utf8Slice(args.out, &store.a),
                            .is_err = args.is_err,
                        },
                    },
                    .usage => .{
                        .usage = .{
                            .in_tok = args.in_tok,
                            .out_tok = args.out_tok,
                            .tot_tok = args.tot_tok,
                            .cache_read = args.cache_read,
                            .cache_write = args.cache_write,
                        },
                    },
                    .stop => .{
                        .stop = .{ .reason = args.stop },
                    },
                    .err => .{
                        .err = .{ .text = pbt.utf8Slice(args.text, &store.a) },
                    },
                },
            };
        }

        fn prop(args: Args) bool {
            const alloc = std.testing.allocator;
            var store: Store = .{};
            const ev = build(args, &store);
            const raw = encodeAlloc(alloc, ev) catch return false;
            defer alloc.free(raw);
            const dup = ev.dupe(alloc) catch return false;
            defer dup.free(alloc);
            const got = encodeAlloc(alloc, dup) catch return false;
            defer alloc.free(got);
            return std.mem.eql(u8, raw, got);
        }
    };

    try pbt.run(T.prop, .{
        .iterations = 200,
        .use_default_values = false,
    });
}
