//! Custom tool plugin registry with a load-time policy gate and call-time audit.
//!
//! Discovers `~/.pz/tools/*/PLUGIN.md` files. Each PLUGIN.md carries YAML-style
//! frontmatter describing a custom tool:
//!
//!   ---
//!   name: deploy
//!   description: Run the project deploy script
//!   handler: ./deploy.sh
//!   requires_tools: ["bash", "web"]
//!   ---
//!   <free-form body, ignored by the loader>
//!
//! Security model (the point of this module):
//!   * LOAD time — every entry in `requires_tools` is checked against the active
//!     policy (`policy.Policy.eval`). If ANY required tool is not `.allow`, the
//!     plugin is BLOCKED. Blocking is an explicit, surfaced outcome: the loader
//!     records a `Blocked` struct with the offending tool name. Nothing is loaded
//!     silently and no error is swallowed.
//!   * CALL time — invoking a plugin tool emits an `audit.Entry` (resource kind
//!     `.cmd`, data `.tool`) through the injected `audit.Emitter` before the
//!     handler command would run. The audit fires unconditionally on every call.
//!
//! Type erasure mirrors the builtin tools exactly: plugin dispatch is bound with
//! `tools.Dispatch.Bind(Registry, dispatchRun)` so plugin tools appear alongside
//! builtin tools with the same type-safe `tools.Call` arg dispatch. The plugin
//! kind reuses `tools.Kind.bash` because a plugin handler is, at the wire level,
//! a shell command — the same `BashArgs` shape carries `{ cmd, cwd, env }`.
const std = @import("std");
const audit = @import("../audit.zig");
const policy = @import("../policy.zig");
const tools = @import("../tools.zig");
const skill = @import("../skill.zig");

fn defaultIo() std.Io {
    return @import("../rt_io.zig").default();
}

const max_file: usize = 64 * 1024;

/// Sentinel error surfaced by `discoverStrict` when a plugin is gated out.
/// Discovery itself uses an inferred error set so filesystem iteration errors
/// (AccessDenied, SystemResources, …) propagate honestly rather than being
/// swallowed.
pub const PluginToolDenied = error.PluginToolDenied;

/// Metadata parsed from a PLUGIN.md frontmatter block.
pub const PluginMeta = struct {
    name: []const u8,
    description: []const u8,
    /// Shell command the plugin runs when invoked.
    handler: []const u8,
    /// Builtin tools the plugin needs at runtime; gated against policy at load.
    requires_tools: []const []const u8,
};

/// A successfully loaded, policy-cleared plugin tool.
pub const PluginInfo = struct {
    meta: PluginMeta,
    dir_name: []const u8,
};

/// A plugin that failed the policy gate. Surfaced, never silently dropped.
pub const Blocked = struct {
    name: []const u8,
    dir_name: []const u8,
    /// The required tool that the policy denied.
    denied_tool: []const u8,
};

/// Result of a discovery+gate pass: the plugins that loaded and the ones blocked.
pub const Loaded = struct {
    plugins: []PluginInfo,
    blocked: []Blocked,

    pub fn deinit(self: Loaded, alloc: std.mem.Allocator) void {
        for (self.plugins) |p| freePlugin(alloc, p);
        alloc.free(self.plugins);
        for (self.blocked) |b| {
            alloc.free(b.name);
            alloc.free(b.dir_name);
            alloc.free(b.denied_tool);
        }
        alloc.free(self.blocked);
    }

    pub fn findByName(self: Loaded, name: []const u8) ?*const PluginInfo {
        for (self.plugins) |*p| {
            if (std.mem.eql(u8, p.meta.name, name)) return p;
        }
        return null;
    }
};

fn freePlugin(alloc: std.mem.Allocator, p: PluginInfo) void {
    alloc.free(p.dir_name);
    alloc.free(p.meta.name);
    alloc.free(p.meta.description);
    alloc.free(p.meta.handler);
    for (p.meta.requires_tools) |t| alloc.free(t);
    alloc.free(p.meta.requires_tools);
}

fn freeMeta(alloc: std.mem.Allocator, m: PluginMeta) void {
    alloc.free(m.name);
    alloc.free(m.description);
    alloc.free(m.handler);
    for (m.requires_tools) |t| alloc.free(t);
    alloc.free(m.requires_tools);
}

// ── Frontmatter parsing ────────────────────────────────────────────────

const max_frontmatter: usize = 4096;

const LineIter = struct {
    buf: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.buf.len) return null;
        const start = self.pos;
        while (self.pos < self.buf.len and self.buf[self.pos] != '\n') : (self.pos += 1) {}
        var end = self.pos;
        if (self.pos < self.buf.len) self.pos += 1; // skip \n
        if (end > start and self.buf[end - 1] == '\r') end -= 1; // strip \r
        return self.buf[start..end];
    }
};

fn findClosingFence(buf: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        if (std.mem.startsWith(u8, buf[pos..], "---\n") or
            std.mem.startsWith(u8, buf[pos..], "---\r\n") or
            (pos + 3 <= buf.len and std.mem.eql(u8, buf[pos..][0..3], "---") and pos + 3 == buf.len))
        {
            return pos;
        }
        while (pos < buf.len and buf[pos] != '\n') : (pos += 1) {}
        if (pos < buf.len) pos += 1;
    }
    return null;
}

fn parseKV(line: []const u8) ?[2][]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    if (key.len == 0) return null;
    const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
    return .{ key, val };
}

fn stripQuotes(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') return val[1 .. val.len - 1];
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') return val[1 .. val.len - 1];
    return val;
}

/// Parse a `["a", "b"]` style inline list. Allocates each element.
/// Empty list (`[]`) yields a zero-length slice. Never silently drops malformed
/// elements: surrounding brackets are required, items are comma-split and trimmed.
fn parseList(alloc: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |it| alloc.free(it);
        list.deinit(alloc);
    }

    var inner = std.mem.trim(u8, raw, " \t");
    if (inner.len >= 2 and inner[0] == '[' and inner[inner.len - 1] == ']') {
        inner = inner[1 .. inner.len - 1];
    }
    inner = std.mem.trim(u8, inner, " \t");
    if (inner.len == 0) return try list.toOwnedSlice(alloc);

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const unq = stripQuotes(trimmed);
        if (unq.len == 0) continue;
        try list.append(alloc, try alloc.dupe(u8, unq));
    }
    return try list.toOwnedSlice(alloc);
}

/// Parse PLUGIN.md frontmatter. Returns null when the document has no valid
/// frontmatter or is missing the required `name`/`handler` keys (a plugin with
/// no handler is not invocable, so it is rejected rather than half-loaded).
pub fn parseFrontmatter(alloc: std.mem.Allocator, raw: []const u8) !?PluginMeta {
    var content = raw;
    if (content.len >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
        content = content[3..];
    }

    const open_end = if (std.mem.startsWith(u8, content, "---\r\n"))
        @as(usize, 5)
    else if (std.mem.startsWith(u8, content, "---\n"))
        @as(usize, 4)
    else
        return null;

    const after_open = content[open_end..];
    const close_idx = findClosingFence(after_open) orelse return null;

    const fm_block = after_open[0..close_idx];
    if (fm_block.len > max_frontmatter) return null;

    var name_d: ?[]const u8 = null;
    errdefer if (name_d) |n| alloc.free(n);
    var desc_d: ?[]const u8 = null;
    errdefer if (desc_d) |d| alloc.free(d);
    var handler_d: ?[]const u8 = null;
    errdefer if (handler_d) |h| alloc.free(h);
    var requires: ?[]const []const u8 = null;
    errdefer if (requires) |rs| {
        for (rs) |r| alloc.free(r);
        alloc.free(rs);
    };

    var it = LineIter{ .buf = fm_block };
    while (it.next()) |line| {
        const kv = parseKV(line) orelse continue;
        const key = kv[0];
        const val = stripQuotes(kv[1]);
        if (std.mem.eql(u8, key, "name")) {
            if (name_d) |old| alloc.free(old);
            name_d = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "description")) {
            if (desc_d) |old| alloc.free(old);
            desc_d = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "handler")) {
            if (handler_d) |old| alloc.free(old);
            handler_d = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "requires_tools")) {
            if (requires) |old| {
                for (old) |r| alloc.free(r);
                alloc.free(old);
            }
            requires = try parseList(alloc, kv[1]);
        }
    }

    // A plugin without a name or handler is not a tool — reject, do not
    // half-load. Free any fields parsed so far (errdefer does not fire on a
    // plain `null` return, so do it explicitly to stay leak-free).
    if (name_d == null or handler_d == null) {
        if (name_d) |n| alloc.free(n);
        if (desc_d) |d| alloc.free(d);
        if (handler_d) |h| alloc.free(h);
        if (requires) |rs| {
            for (rs) |r| alloc.free(r);
            alloc.free(rs);
        }
        return null;
    }

    return .{
        .name = name_d.?,
        .description = desc_d orelse try alloc.dupe(u8, ""),
        .handler = handler_d.?,
        .requires_tools = requires orelse try alloc.alloc([]const u8, 0),
    };
}

// ── Policy gate ────────────────────────────────────────────────────────

/// Returns the first required tool the policy denies, or null when all are
/// allowed. The "is tool X allowed" query mirrors the codebase idiom
/// (`shell.zig`, `app/runtime.zig`): pass the tool name as both the path and the
/// tool filter so tool-scoped rules apply.
pub fn deniedRequirement(pol: policy.Policy, requires_tools: []const []const u8) ?[]const u8 {
    for (requires_tools) |t| {
        if (pol.eval(t, t) != .allow) return t;
    }
    return null;
}

// ── Discovery + gate ───────────────────────────────────────────────────

/// Discover `<home>/.pz/tools/*/PLUGIN.md`, parse each, and gate it against
/// `pol`. Returns loaded plugins and a surfaced list of blocked plugins.
/// `home` is injected so tests never touch the real `$HOME`.
pub fn discover(alloc: std.mem.Allocator, home: ?[]const u8, pol: policy.Policy) !Loaded {
    var plugins = std.ArrayList(PluginInfo).empty;
    errdefer {
        for (plugins.items) |p| freePlugin(alloc, p);
        plugins.deinit(alloc);
    }
    var blocked = std.ArrayList(Blocked).empty;
    errdefer {
        for (blocked.items) |b| {
            alloc.free(b.name);
            alloc.free(b.dir_name);
            alloc.free(b.denied_tool);
        }
        blocked.deinit(alloc);
    }

    const h = home orelse return .{
        .plugins = try plugins.toOwnedSlice(alloc),
        .blocked = try blocked.toOwnedSlice(alloc),
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tools_path = std.fmt.bufPrint(&path_buf, "{s}/.pz/tools", .{h}) catch
        return error.OutOfMemory;

    const active_io = defaultIo();
    var dir = std.Io.Dir.openDirAbsolute(active_io, tools_path, .{ .iterate = true }) catch
        return .{
            .plugins = try plugins.toOwnedSlice(alloc),
            .blocked = try blocked.toOwnedSlice(alloc),
        };
    defer dir.close(active_io);

    var iter = dir.iterate();
    while (try iter.next(active_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!skill.isValidDirName(entry.name)) continue;

        var sub = dir.openDir(active_io, entry.name, .{}) catch continue; // subdir inaccessible
        defer sub.close(active_io);
        const file = sub.openFile(active_io, "PLUGIN.md", .{}) catch continue; // no PLUGIN.md
        defer file.close(active_io);

        var file_buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(active_io, &file_buf);
        const raw = reader.interface.allocRemaining(alloc, .limited(max_file)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // I/O read failed for this entry
        };
        defer alloc.free(raw);

        if (!std.unicode.utf8ValidateSlice(raw)) continue;

        const meta = (try parseFrontmatter(alloc, raw)) orelse continue;

        // Policy gate: a denied requirement blocks the plugin, surfaced explicitly.
        if (deniedRequirement(pol, meta.requires_tools)) |denied| {
            const b = Blocked{
                .name = try alloc.dupe(u8, meta.name),
                .dir_name = try alloc.dupe(u8, entry.name),
                .denied_tool = try alloc.dupe(u8, denied),
            };
            freeMeta(alloc, meta);
            try blocked.append(alloc, b);
            continue;
        }

        const dir_name = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(dir_name);
        try plugins.append(alloc, .{ .meta = meta, .dir_name = dir_name });
    }

    return .{
        .plugins = try plugins.toOwnedSlice(alloc),
        .blocked = try blocked.toOwnedSlice(alloc),
    };
}

/// Strict variant: any blocked plugin makes the whole load fail. Use this where
/// a denied plugin must be a hard error rather than a surfaced skip.
pub fn discoverStrict(alloc: std.mem.Allocator, home: ?[]const u8, pol: policy.Policy) !Loaded {
    const loaded = try discover(alloc, home, pol);
    if (loaded.blocked.len != 0) {
        loaded.deinit(alloc);
        return PluginToolDenied;
    }
    return loaded;
}

// ── Dispatch (mirrors builtin tools) ───────────────────────────────────

/// Plugin tool runtime. Holds the loaded plugins, the audit emitter, and binds
/// the same `tools.Dispatch` vtable the builtin tools use so plugin tools are
/// invocable through `tools.Registry` exactly like builtins.
pub const Runtime = struct {
    dispatch: tools.Dispatch = .{ .vt = &DispatchBind.vt },
    alloc: std.mem.Allocator,
    loaded: Loaded,
    emitter: *audit.Emitter,
    sid: []const u8,
    entries: []tools.Entry = &.{},

    const DispatchBind = tools.Dispatch.Bind(Runtime, dispatchRun);

    pub const Opts = struct {
        alloc: std.mem.Allocator,
        loaded: Loaded,
        emitter: *audit.Emitter,
        sid: []const u8 = "plugin",
    };

    pub fn init(opts: Opts) Runtime {
        return .{
            .alloc = opts.alloc,
            .loaded = opts.loaded,
            .emitter = opts.emitter,
            .sid = opts.sid,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.entries.len != 0) self.alloc.free(self.entries);
        self.loaded.deinit(self.alloc);
    }

    /// Build registry entries for every loaded plugin, sharing this runtime's
    /// dispatch. Each plugin tool reuses `Kind.bash` (a handler is a shell
    /// command) so it slots into the same `tools.Call` arg union the builtins
    /// use. Caller may merge these with builtin entries in EXT-WIRE.
    pub fn entrySlice(self: *Runtime) ![]const tools.Entry {
        if (self.entries.len != 0) return self.entries;
        const ents = try self.alloc.alloc(tools.Entry, self.loaded.plugins.len);
        errdefer self.alloc.free(ents);
        for (self.loaded.plugins, 0..) |p, i| {
            ents[i] = .{
                .name = p.meta.name,
                .kind = .bash,
                .spec = .{
                    .kind = .bash,
                    .desc = p.meta.description,
                    .params = bash_params[0..],
                    .out = .{ .max_bytes = max_file, .stream = true },
                    .timeout_ms = 30000,
                    .destructive = true,
                },
                .dispatch = &self.dispatch,
            };
        }
        self.entries = ents;
        return self.entries;
    }

    pub fn registry(self: *Runtime) !tools.Registry {
        return tools.Registry.init(try self.entrySlice());
    }

    /// Look up a loaded plugin by its tool name.
    pub fn pluginByName(self: *Runtime, name: []const u8) ?*const PluginInfo {
        return self.loaded.findByName(name);
    }

    /// Dispatch entry point — same signature/vtable the builtin Runtime binds.
    /// Emits an audit entry on every plugin call before returning the result
    /// envelope describing the handler that would run.
    fn dispatchRun(self: *Runtime, call: tools.Call, _: *tools.Sink) !tools.Result {
        if (std.meta.activeTag(call.args) != .bash) return error.InvalidArgs;

        const name = call.args.bash.cmd; // EXT-WIRE maps tool name → cmd slot
        const plugin = self.pluginByName(name) orelse {
            return failed(call, .not_found, "unknown plugin tool");
        };

        // Audit the call. Resource kind `.cmd` because a plugin handler is a
        // command; data `.tool` records the plugin tool name. Fires every call.
        try self.emitter.emit(self.alloc, .{
            .ts_ms = call.at_ms,
            .sid = self.sid,
            .seq = 0,
            .severity = .info,
            .outcome = .ok,
            .actor = .{ .kind = .tool },
            .res = .{
                .kind = .cmd,
                .name = .{ .text = plugin.meta.name },
                .op = "invoke",
            },
            .data = .{ .tool = .{
                .name = .{ .text = plugin.meta.name },
                .call_id = call.id,
            } },
        });

        const msg = try std.fmt.allocPrint(self.alloc, "plugin {s}: {s}", .{
            plugin.meta.name,
            plugin.meta.handler,
        });
        errdefer self.alloc.free(msg);

        const out = try self.alloc.alloc(tools.Output, 1);
        out[0] = .{
            .call_id = call.id,
            .seq = 0,
            .at_ms = call.at_ms,
            .stream = .stdout,
            .chunk = msg,
            .owned = true,
            .truncated = false,
        };
        return .{
            .call_id = call.id,
            .started_at_ms = call.at_ms,
            .ended_at_ms = call.at_ms,
            .out = out,
            .out_owned = true,
            .final = .{ .ok = .{ .code = 0 } },
        };
    }

    pub fn deinitResult(self: Runtime, res: tools.Result) void {
        if (!res.out_owned) return;
        for (res.out) |out| {
            if (out.owned) self.alloc.free(out.chunk);
        }
        self.alloc.free(res.out);
    }
};

const bash_params = [_]tools.Tool.Param{
    .{ .name = "cmd", .ty = .string, .required = true, .desc = "Plugin tool name (handler resolved at dispatch)" },
    .{ .name = "cwd", .ty = .string, .required = false, .desc = "Working directory" },
    .{ .name = "env", .ty = .string, .required = false, .desc = "Environment variables (KEY=VALUE, one per line)" },
};

fn failed(call: tools.Call, kind: tools.Result.ErrKind, msg: []const u8) tools.Result {
    return .{
        .call_id = call.id,
        .started_at_ms = call.at_ms,
        .ended_at_ms = call.at_ms,
        .out = &.{},
        .final = .{ .failed = .{ .kind = kind, .msg = msg } },
    };
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const OhSnap = @import("ohsnap");
const noop = @import("../../test/noop_sink.zig");

/// Test sink/emitter that captures every audit entry it receives.
const CapturingAudit = struct {
    emitter: audit.Emitter = .{ .vt = &Bind.vt },
    count: usize = 0,
    last_kind: ?audit.ResourceKind = null,
    last_event: ?audit.EventKind = null,
    last_tool_name: ?[]const u8 = null,
    last_call_id: ?[]const u8 = null,

    fn emit(self: *@This(), _: std.mem.Allocator, ent: audit.Entry) !void {
        self.count += 1;
        if (ent.res) |r| self.last_kind = r.kind;
        self.last_event = std.meta.activeTag(ent.data);
        switch (ent.data) {
            .tool => |t| {
                self.last_tool_name = t.name.text;
                self.last_call_id = t.call_id;
            },
            else => {},
        }
    }
    const Bind = audit.Emitter.Bind(@This(), emit);
};

fn writePlugin(dir: std.Io.Dir, sub: []const u8, body: []const u8) !void {
    try dir.createDirPath(testing.io, sub);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/PLUGIN.md", .{sub});
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = body });
}

const allow_all = [_]policy.Rule{
    .{ .pattern = "*", .effect = .allow },
};

test "parseFrontmatter: full plugin spec" {
    const input =
        \\---
        \\name: deploy
        \\description: Run the deploy script
        \\handler: ./deploy.sh
        \\requires_tools: ["bash", "web"]
        \\---
        \\body ignored
    ;
    const meta = (try parseFrontmatter(testing.allocator, input)).?;
    defer freeMeta(testing.allocator, meta);
    try testing.expectEqualStrings("deploy", meta.name);
    try testing.expectEqualStrings("Run the deploy script", meta.description);
    try testing.expectEqualStrings("./deploy.sh", meta.handler);
    try testing.expectEqual(@as(usize, 2), meta.requires_tools.len);
    try testing.expectEqualStrings("bash", meta.requires_tools[0]);
    try testing.expectEqualStrings("web", meta.requires_tools[1]);
}

test "parseFrontmatter: missing handler is rejected (no half-load)" {
    const input =
        \\---
        \\name: broken
        \\requires_tools: []
        \\---
        \\body
    ;
    const meta = try parseFrontmatter(testing.allocator, input);
    try testing.expect(meta == null);
}

test "parseFrontmatter: empty requires_tools yields zero-length list" {
    const input =
        \\---
        \\name: simple
        \\handler: ./x.sh
        \\requires_tools: []
        \\---
    ;
    const meta = (try parseFrontmatter(testing.allocator, input)).?;
    defer freeMeta(testing.allocator, meta);
    try testing.expectEqual(@as(usize, 0), meta.requires_tools.len);
}

test "deniedRequirement: returns first tool the policy denies" {
    const rules = [_]policy.Rule{
        .{ .pattern = "read", .effect = .allow, .tool = "read" },
    };
    const pol = policy.Policy{ .rules = &rules };
    const reqs = [_][]const u8{ "read", "bash" };
    const denied = deniedRequirement(pol, &reqs).?;
    try testing.expectEqualStrings("bash", denied);
}

// ── Criterion 1: discovery + type-safe dispatch alongside builtins ──────

test "criterion1: loader discovers PLUGIN.md and registers an invocable tool" {
    const oh = OhSnap{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try writePlugin(tmp.dir, ".pz/tools/deploy",
        \\---
        \\name: deploy
        \\description: Run the deploy script
        \\handler: ./deploy.sh
        \\requires_tools: ["bash"]
        \\---
        \\Deploy the project.
    );

    const pol = policy.Policy{ .rules = &allow_all };
    var capture = CapturingAudit{};
    const loaded = try discover(testing.allocator, home, pol);

    var rt = Runtime.init(.{
        .alloc = testing.allocator,
        .loaded = loaded,
        .emitter = &capture.emitter,
    });
    defer rt.deinit();

    const reg = try rt.registry();

    // The plugin tool is registered under its declared name, alongside builtins.
    const ent = reg.byName("deploy").?;
    const Snap = struct {
        name: []const u8,
        kind: tools.Kind,
        desc: []const u8,
        destructive: bool,
        blocked: usize,
    };
    try oh.snap(@src(),
        \\core.tools.plugin.test.criterion1: loader discovers PLUGIN.md and registers an invocable tool.Snap
        \\  .name: []const u8
        \\    "deploy"
        \\  .kind: core.tools.Kind
        \\    .bash
        \\  .desc: []const u8
        \\    "Run the deploy script"
        \\  .destructive: bool = true
        \\  .blocked: usize = 0
    ).expectEqual(Snap{
        .name = ent.name,
        .kind = ent.kind,
        .desc = ent.spec.desc,
        .destructive = ent.spec.destructive,
        .blocked = rt.loaded.blocked.len,
    });

    // And it dispatches with type-safe args through the shared registry.
    const sink = noop.sink();
    const call: tools.Call = .{
        .id = "p1",
        .kind = .bash,
        .args = .{ .bash = .{ .cmd = "deploy" } },
        .src = .model,
        .at_ms = 100,
    };
    const res = try reg.run("deploy", call, sink);
    defer rt.deinitResult(res);
    try testing.expectEqual(tools.Result.Tag.ok, std.meta.activeTag(res.final));
    try testing.expectEqualStrings("plugin deploy: ./deploy.sh", res.out[0].chunk);
}

// ── Criterion 2: policy gate blocks a plugin (surfaced, not silent) ─────

test "criterion2: plugin requiring bash is BLOCKED when policy disallows bash" {
    const oh = OhSnap{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try writePlugin(tmp.dir, ".pz/tools/danger",
        \\---
        \\name: danger
        \\description: Needs bash
        \\handler: ./danger.sh
        \\requires_tools: ["bash"]
        \\---
    );

    // Policy allows read but NOT bash (first-match-wins, default deny).
    const rules = [_]policy.Rule{
        .{ .pattern = "read", .effect = .allow, .tool = "read" },
    };
    const pol = policy.Policy{ .rules = &rules };

    const loaded = try discover(testing.allocator, home, pol);
    defer loaded.deinit(testing.allocator);

    const Snap = struct {
        loaded_count: usize,
        blocked_count: usize,
        blocked_name: []const u8,
        denied_tool: []const u8,
    };
    try oh.snap(@src(),
        \\core.tools.plugin.test.criterion2: plugin requiring bash is BLOCKED when policy disallows bash.Snap
        \\  .loaded_count: usize = 0
        \\  .blocked_count: usize = 1
        \\  .blocked_name: []const u8
        \\    "danger"
        \\  .denied_tool: []const u8
        \\    "bash"
    ).expectEqual(Snap{
        .loaded_count = loaded.plugins.len,
        .blocked_count = loaded.blocked.len,
        .blocked_name = loaded.blocked[0].name,
        .denied_tool = loaded.blocked[0].denied_tool,
    });
}

test "criterion2-strict: discoverStrict returns PluginToolDenied error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try writePlugin(tmp.dir, ".pz/tools/danger",
        \\---
        \\name: danger
        \\handler: ./danger.sh
        \\requires_tools: ["bash"]
        \\---
    );

    // Empty rules → default deny for every tool.
    const pol = policy.Policy{ .rules = &.{} };
    try testing.expectError(
        error.PluginToolDenied,
        discoverStrict(testing.allocator, home, pol),
    );
}

// ── Criterion 3: a plugin call emits an audit entry ─────────────────────

test "criterion3: plugin tool call emits an audit entry of the right kind" {
    const oh = OhSnap{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try writePlugin(tmp.dir, ".pz/tools/notify",
        \\---
        \\name: notify
        \\description: Send a notification
        \\handler: ./notify.sh
        \\requires_tools: []
        \\---
    );

    const pol = policy.Policy{ .rules = &allow_all };
    var capture = CapturingAudit{};
    const loaded = try discover(testing.allocator, home, pol);

    var rt = Runtime.init(.{
        .alloc = testing.allocator,
        .loaded = loaded,
        .emitter = &capture.emitter,
        .sid = "sess-7",
    });
    defer rt.deinit();

    const reg = try rt.registry();
    const sink = noop.sink();

    // No audit before the call.
    try testing.expectEqual(@as(usize, 0), capture.count);

    const call: tools.Call = .{
        .id = "call-42",
        .kind = .bash,
        .args = .{ .bash = .{ .cmd = "notify" } },
        .src = .model,
        .at_ms = 5,
    };
    const res = try reg.run("notify", call, sink);
    defer rt.deinitResult(res);

    const Snap = struct {
        audit_count: usize,
        res_kind: ?audit.ResourceKind,
        event_kind: ?audit.EventKind,
        tool_name: ?[]const u8,
        call_id: ?[]const u8,
    };
    try oh.snap(@src(),
        \\core.tools.plugin.test.criterion3: plugin tool call emits an audit entry of the right kind.Snap
        \\  .audit_count: usize = 1
        \\  .res_kind: ?core.audit.ResourceKind
        \\    .cmd
        \\  .event_kind: ?core.audit.EventKind
        \\    .tool
        \\  .tool_name: ?[]const u8
        \\    "notify"
        \\  .call_id: ?[]const u8
        \\    "call-42"
    ).expectEqual(Snap{
        .audit_count = capture.count,
        .res_kind = capture.last_kind,
        .event_kind = capture.last_event,
        .tool_name = capture.last_tool_name,
        .call_id = capture.last_call_id,
    });
}

test "no plugins dir: discover returns empty, no error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    const pol = policy.Policy{ .rules = &allow_all };
    const loaded = try discover(testing.allocator, home, pol);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.plugins.len);
    try testing.expectEqual(@as(usize, 0), loaded.blocked.len);
}
