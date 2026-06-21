//! Resource discovery: scan ~/.pz/{prompts,context} for PROMPT.md / CONTEXT.md
//! metadata. Mirrors src/core/skill.zig's directory-walk + frontmatter-parse
//! approach (Zig 0.16 std.Io idiom).
//!
//! Loaded resources are exposed as ordered, enabled-only lists sorted by
//! descending priority. The EXT-WIRE integration PR consumes this data:
//!   - prompts are merged into the system message (mergePromptsAlloc)
//!   - context is prepended to the first user turn (prependContextAlloc)
const std = @import("std");

fn defaultIo() std.Io {
    return @import("rt_io.zig").default();
}

/// Which resource kind a directory tree holds.
pub const Kind = enum {
    prompts,
    context,

    /// Subdirectory under ~/.pz that holds this kind.
    fn subdir(self: Kind) []const u8 {
        return switch (self) {
            .prompts => "prompts",
            .context => "context",
        };
    }

    /// The metadata file name expected inside each resource directory.
    fn fileName(self: Kind) []const u8 {
        return switch (self) {
            .prompts => "PROMPT.md",
            .context => "CONTEXT.md",
        };
    }
};

pub const ResourceMeta = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
    enabled: bool = true,
    priority: i64 = 0,
};

pub const ResourceInfo = struct {
    meta: ResourceMeta,
    dir_name: []const u8,
    kind: Kind,
};

const max_frontmatter: usize = 4096;
const max_file: usize = 64 * 1024;

const FrontmatterResult = struct {
    meta: ResourceMeta,
    body: []const u8,
};

pub fn parseFrontmatter(alloc: std.mem.Allocator, raw: []const u8) !?FrontmatterResult {
    // Strip BOM
    var content = raw;
    if (content.len >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
        content = content[3..];
    }

    // Must start with ---\n or ---\r\n
    const open_end = if (std.mem.startsWith(u8, content, "---\r\n"))
        @as(usize, 5)
    else if (std.mem.startsWith(u8, content, "---\n"))
        @as(usize, 4)
    else
        return null;

    // Find closing fence
    const after_open = content[open_end..];
    const close_idx = findClosingFence(after_open) orelse return null;

    const fm_block = after_open[0..close_idx];
    if (fm_block.len > max_frontmatter) return null;

    // Body starts after the closing fence line
    const fence_line_end = blk: {
        const rest = after_open[close_idx..];
        if (std.mem.startsWith(u8, rest, "---\r\n")) break :blk close_idx + 5;
        if (std.mem.startsWith(u8, rest, "---\n")) break :blk close_idx + 4;
        // fence at EOF with no trailing newline
        if (std.mem.startsWith(u8, rest, "---")) break :blk close_idx + 3;
        return null;
    };

    const body = try alloc.dupe(u8, after_open[fence_line_end..]);
    errdefer alloc.free(body);

    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    var enabled: bool = true;
    var priority: i64 = 0;

    var name_d: ?[]const u8 = null;
    errdefer if (name_d) |n| alloc.free(n);
    var desc_d: ?[]const u8 = null;
    errdefer if (desc_d) |d| alloc.free(d);

    var it = LineIter{ .buf = fm_block };
    while (it.next()) |line| {
        if (parseKV(line)) |kv| {
            const key = kv[0];
            const val = stripQuotes(kv[1]);
            if (std.mem.eql(u8, key, "name")) {
                if (name_d) |old| alloc.free(old);
                name_d = try alloc.dupe(u8, val);
                name = name_d;
            } else if (std.mem.eql(u8, key, "description")) {
                if (desc_d) |old| alloc.free(old);
                desc_d = try alloc.dupe(u8, val);
                desc = desc_d;
            } else if (std.mem.eql(u8, key, "enabled")) {
                enabled = std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "priority")) {
                priority = std.fmt.parseInt(i64, val, 10) catch 0;
            }
        }
    }

    return .{
        .meta = .{
            .name = name orelse "",
            .description = desc orelse "",
            .body = body,
            .enabled = enabled,
            .priority = priority,
        },
        .body = body,
    };
}

const LineIter = struct {
    buf: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.buf.len) return null;
        const start = self.pos;
        while (self.pos < self.buf.len and self.buf[self.pos] != '\n') : (self.pos += 1) {}
        var end = self.pos;
        if (self.pos < self.buf.len) self.pos += 1; // skip \n
        // strip \r
        if (end > start and self.buf[end - 1] == '\r') end -= 1;
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
        // advance to next line
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
    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        return val[1 .. val.len - 1];
    }
    return val;
}

pub fn isValidDirName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Discover every resource of every kind under `home`/.pz/{prompts,context}.
/// Returns ALL parsed entries (including disabled ones), unsorted, in
/// directory-iteration order. Callers that want runtime-ready ordering should
/// use `enabledSortedAlloc`. Ownership: caller frees with `freeResources`.
pub fn discoverAndRead(alloc: std.mem.Allocator, home: ?[]const u8) ![]ResourceInfo {
    var resources = std.ArrayList(ResourceInfo).empty;
    errdefer {
        for (resources.items) |r| freeResource(alloc, r);
        resources.deinit(alloc);
    }

    if (home) |h| {
        inline for (.{ Kind.prompts, Kind.context }) |kind| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const base_path = std.fmt.bufPrint(&path_buf, "{s}/.pz/{s}", .{ h, kind.subdir() }) catch "";
            if (base_path.len > 0) {
                try scanDir(alloc, &resources, base_path, kind);
            }
        }
    }

    return try resources.toOwnedSlice(alloc);
}

fn scanDir(
    alloc: std.mem.Allocator,
    resources: *std.ArrayList(ResourceInfo),
    base_path: []const u8,
    kind: Kind,
) !void {
    const active_io = defaultIo();
    var dir = std.Io.Dir.openDirAbsolute(active_io, base_path, .{ .iterate = true }) catch return; // dir not found or inaccessible
    defer dir.close(active_io);

    var iter = dir.iterate();
    while (try iter.next(active_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!isValidDirName(entry.name)) continue;

        var sub = dir.openDir(active_io, entry.name, .{}) catch continue; // subdir inaccessible
        defer sub.close(active_io);
        const res_file = sub.openFile(active_io, kind.fileName(), .{}) catch continue; // no PROMPT.md/CONTEXT.md
        defer res_file.close(active_io);

        var file_buf: [4096]u8 = undefined;
        var reader = res_file.readerStreaming(active_io, &file_buf);
        const content = reader.interface.allocRemaining(alloc, .limited(max_file)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // I/O read failed
        };
        defer alloc.free(content);

        if (!std.unicode.utf8ValidateSlice(content)) continue;

        const parsed = (try parseFrontmatter(alloc, content)) orelse continue;
        // parsed.meta owns body/name/desc allocations
        errdefer freeMeta(alloc, parsed.meta);

        const dir_name = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(dir_name);

        try resources.append(alloc, .{
            .meta = parsed.meta,
            .dir_name = dir_name,
            .kind = kind,
        });
    }
}

fn freeMeta(alloc: std.mem.Allocator, meta: ResourceMeta) void {
    if (meta.body.len > 0) alloc.free(meta.body);
    if (meta.name.len > 0) alloc.free(meta.name);
    if (meta.description.len > 0) alloc.free(meta.description);
}

fn freeResource(alloc: std.mem.Allocator, r: ResourceInfo) void {
    alloc.free(r.dir_name);
    freeMeta(alloc, r.meta);
}

pub fn freeResources(alloc: std.mem.Allocator, resources: []ResourceInfo) void {
    for (resources) |r| freeResource(alloc, r);
    alloc.free(resources);
}

/// Stable sort comparator: higher priority first; ties keep input order via
/// dir_name lexical tiebreak for determinism.
fn priorityDesc(_: void, a: ResourceInfo, b: ResourceInfo) bool {
    if (a.meta.priority != b.meta.priority) return a.meta.priority > b.meta.priority;
    return std.mem.lessThan(u8, a.dir_name, b.dir_name);
}

/// Filter `resources` to enabled entries of `kind`, sorted by descending
/// priority. Returns borrowed pointers into `resources`; the returned slice
/// itself is owned by the caller (free with `alloc.free`). Callers must keep
/// `resources` alive while using the result.
pub fn enabledSortedAlloc(
    alloc: std.mem.Allocator,
    resources: []const ResourceInfo,
    kind: Kind,
) ![]const *const ResourceInfo {
    var out = std.ArrayList(*const ResourceInfo).empty;
    errdefer out.deinit(alloc);

    for (resources) |*r| {
        if (r.kind != kind) continue;
        if (!r.meta.enabled) continue;
        try out.append(alloc, r);
    }

    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(*const ResourceInfo, slice, {}, struct {
        fn lt(_: void, a: *const ResourceInfo, b: *const ResourceInfo) bool {
            return priorityDesc({}, a.*, b.*);
        }
    }.lt);
    return slice;
}

/// Merge enabled prompts (highest priority first) into a single block suitable
/// for appending to the system message. Bodies are joined by `\n\n`. Returns an
/// allocated string owned by the caller (may be empty if no enabled prompts).
pub fn mergePromptsAlloc(alloc: std.mem.Allocator, resources: []const ResourceInfo) ![]u8 {
    return joinBodiesAlloc(alloc, resources, .prompts);
}

/// Render enabled context (highest priority first) as a block to PREPEND to the
/// first user turn, followed by `\n\n` and then the original user text by the
/// caller. Returns an allocated string owned by the caller (may be empty).
pub fn prependContextAlloc(alloc: std.mem.Allocator, resources: []const ResourceInfo) ![]u8 {
    return joinBodiesAlloc(alloc, resources, .context);
}

fn joinBodiesAlloc(
    alloc: std.mem.Allocator,
    resources: []const ResourceInfo,
    kind: Kind,
) ![]u8 {
    const ordered = try enabledSortedAlloc(alloc, resources, kind);
    defer alloc.free(ordered);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (ordered, 0..) |r, i| {
        if (i != 0) try out.appendSlice(alloc, "\n\n");
        // Trim both \n and \r so CRLF-terminated bodies (Windows-authored
        // PROMPT.md/CONTEXT.md) don't leave a stray \r in the merged output.
        try out.appendSlice(alloc, std.mem.trimEnd(u8, r.meta.body, "\r\n"));
    }

    return out.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn testRealPathAlloc(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    const resolved = try dir.realPathFileAlloc(std.testing.io, sub_path, alloc);
    defer alloc.free(resolved);
    return try alloc.dupe(u8, resolved);
}

test "parseFrontmatter: prompt with enabled+priority" {
    const input =
        \\---
        \\name: 'plan'
        \\description: 'planning prompt'
        \\enabled: true
        \\priority: 7
        \\---
        \\Always plan first.
    ;
    const result = try parseFrontmatter(std.testing.allocator, input);
    defer if (result) |r| freeMeta(std.testing.allocator, r.meta);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqualStrings("plan", r.meta.name);
    try std.testing.expectEqualStrings("planning prompt", r.meta.description);
    try std.testing.expect(r.meta.enabled);
    try std.testing.expectEqual(@as(i64, 7), r.meta.priority);
    try std.testing.expectEqualStrings("Always plan first.", r.meta.body);
}

test "parseFrontmatter: defaults enabled=true priority=0" {
    const input = "---\nname: bare\n---\nbody";
    const result = try parseFrontmatter(std.testing.allocator, input);
    defer if (result) |r| freeMeta(std.testing.allocator, r.meta);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.meta.enabled);
    try std.testing.expectEqual(@as(i64, 0), result.?.meta.priority);
}

test "parseFrontmatter: enabled false and negative priority" {
    const input = "---\nname: off\nenabled: false\npriority: -3\n---\nx";
    const result = try parseFrontmatter(std.testing.allocator, input);
    defer if (result) |r| freeMeta(std.testing.allocator, r.meta);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.meta.enabled);
    try std.testing.expectEqual(@as(i64, -3), result.?.meta.priority);
}

test "parseFrontmatter: CRLF line endings parse like LF" {
    // Windows-authored files use \r\n; the parser must accept ---\r\n fences
    // and not leave \r in parsed field values.
    const input = "---\r\nname: win\r\ndescription: crlf file\r\nenabled: true\r\npriority: 2\r\n---\r\nbody line";
    const result = try parseFrontmatter(std.testing.allocator, input);
    defer if (result) |r| freeMeta(std.testing.allocator, r.meta);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqualStrings("win", r.meta.name);
    try std.testing.expectEqualStrings("crlf file", r.meta.description);
    try std.testing.expect(r.meta.enabled);
    try std.testing.expectEqual(@as(i64, 2), r.meta.priority);
}

test "parseFrontmatter: leading UTF-8 BOM is stripped" {
    const input = "\xEF\xBB\xBF---\nname: bomtest\n---\nbody";
    const result = try parseFrontmatter(std.testing.allocator, input);
    defer if (result) |r| freeMeta(std.testing.allocator, r.meta);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("bomtest", result.?.meta.name);
}

test "mergePromptsAlloc trims trailing CRLF so no stray \\r leaks into output" {
    // Regression for the body-trim bug: trimEnd("\n") alone left a trailing
    // \r on CRLF bodies. The merged output must end at the last real char.
    const res = [_]ResourceInfo{
        .{ .kind = .prompts, .dir_name = "p", .meta = .{
            .name = "p",
            .description = "",
            .body = "hello\r\n",
            .enabled = true,
            .priority = 0,
        } },
    };
    const merged = try mergePromptsAlloc(std.testing.allocator, &res);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqualStrings("hello", merged);
}

// Criterion 1: discoverAndRead finds prompts/*/PROMPT.md and context/*/CONTEXT.md
// and parses their frontmatter.
test "discoverAndRead finds PROMPT.md and CONTEXT.md and parses frontmatter" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/plan");
    try tmp.dir.createDirPath(std.testing.io, ".pz/context/repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/plan/PROMPT.md",
        .data = "---\nname: 'plan'\ndescription: 'planning'\nenabled: true\npriority: 5\n---\nPlan body",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/context/repo/CONTEXT.md",
        .data = "---\nname: 'repo'\ndescription: 'repo facts'\npriority: 2\n---\nRepo body",
    });

    const home = try testRealPathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const resources = try discoverAndRead(alloc, home);
    defer freeResources(alloc, resources);

    // Sort by (kind, dir_name) for a deterministic snapshot independent of FS order.
    std.mem.sort(ResourceInfo, resources, {}, struct {
        fn lt(_: void, a: ResourceInfo, b: ResourceInfo) bool {
            if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
            return std.mem.lessThan(u8, a.dir_name, b.dir_name);
        }
    }.lt);

    const Row = struct {
        kind: Kind,
        dir_name: []const u8,
        name: []const u8,
        description: []const u8,
        enabled: bool,
        priority: i64,
        body: []const u8,
    };
    var rows: [2]Row = undefined;
    for (resources, 0..) |r, i| {
        rows[i] = .{
            .kind = r.kind,
            .dir_name = r.dir_name,
            .name = r.meta.name,
            .description = r.meta.description,
            .enabled = r.meta.enabled,
            .priority = r.meta.priority,
            .body = r.meta.body,
        };
    }
    try std.testing.expectEqual(@as(usize, 2), resources.len);
    try oh.snap(@src(),
        \\[2]core.resource.test.discoverAndRead finds PROMPT.md and CONTEXT.md and parses frontmatter.Row
        \\  [0]: core.resource.test.discoverAndRead finds PROMPT.md and CONTEXT.md and parses frontmatter.Row
        \\    .kind: core.resource.Kind
        \\      .prompts
        \\    .dir_name: []const u8
        \\      "plan"
        \\    .name: []const u8
        \\      "plan"
        \\    .description: []const u8
        \\      "planning"
        \\    .enabled: bool = true
        \\    .priority: i64 = 5
        \\    .body: []const u8
        \\      "Plan body"
        \\  [1]: core.resource.test.discoverAndRead finds PROMPT.md and CONTEXT.md and parses frontmatter.Row
        \\    .kind: core.resource.Kind
        \\      .context
        \\    .dir_name: []const u8
        \\      "repo"
        \\    .name: []const u8
        \\      "repo"
        \\    .description: []const u8
        \\      "repo facts"
        \\    .enabled: bool = true
        \\    .priority: i64 = 2
        \\    .body: []const u8
        \\      "Repo body"
    ).expectEqual(rows);
}

// Criterion 3: disabled entries (enabled:false) are skipped from the runtime lists.
test "enabledSortedAlloc skips disabled entries" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/on");
    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/off");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/on/PROMPT.md",
        .data = "---\nname: on\nenabled: true\npriority: 1\n---\nON",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/off/PROMPT.md",
        .data = "---\nname: off\nenabled: false\npriority: 9\n---\nOFF",
    });

    const home = try testRealPathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const resources = try discoverAndRead(alloc, home);
    defer freeResources(alloc, resources);

    const ordered = try enabledSortedAlloc(alloc, resources, .prompts);
    defer alloc.free(ordered);

    // Only the enabled prompt survives, even though the disabled one has higher priority.
    try std.testing.expectEqual(@as(usize, 1), ordered.len);
    try std.testing.expectEqualStrings("on", ordered[0].dir_name);
}

// Criterion 4: priority order is respected (higher priority first).
test "enabledSortedAlloc orders by descending priority" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/low");
    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/mid");
    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/high");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/low/PROMPT.md",
        .data = "---\nname: low\npriority: 1\n---\nLOW",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/mid/PROMPT.md",
        .data = "---\nname: mid\npriority: 5\n---\nMID",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/high/PROMPT.md",
        .data = "---\nname: high\npriority: 10\n---\nHIGH",
    });

    const home = try testRealPathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const resources = try discoverAndRead(alloc, home);
    defer freeResources(alloc, resources);

    const ordered = try enabledSortedAlloc(alloc, resources, .prompts);
    defer alloc.free(ordered);

    try std.testing.expectEqual(@as(usize, 3), ordered.len);
    try std.testing.expectEqualStrings("high", ordered[0].dir_name);
    try std.testing.expectEqualStrings("mid", ordered[1].dir_name);
    try std.testing.expectEqualStrings("low", ordered[2].dir_name);
}

// Criterion 2: prompts are exposed merged for the system message, and context
// is exposed prepend-ready for the first user turn. Both respect priority and
// skip disabled entries.
test "mergePromptsAlloc and prependContextAlloc expose ordered runtime blocks" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/a");
    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/b");
    try tmp.dir.createDirPath(std.testing.io, ".pz/prompts/dead");
    try tmp.dir.createDirPath(std.testing.io, ".pz/context/c1");
    try tmp.dir.createDirPath(std.testing.io, ".pz/context/c2");
    // priority: b(8) > a(3); dead disabled
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/a/PROMPT.md",
        .data = "---\nname: a\npriority: 3\n---\nA-PROMPT\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/b/PROMPT.md",
        .data = "---\nname: b\npriority: 8\n---\nB-PROMPT\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/prompts/dead/PROMPT.md",
        .data = "---\nname: dead\nenabled: false\npriority: 99\n---\nDEAD\n",
    });
    // priority: c2(4) > c1(1)
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/context/c1/CONTEXT.md",
        .data = "---\nname: c1\npriority: 1\n---\nCTX-1\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/context/c2/CONTEXT.md",
        .data = "---\nname: c2\npriority: 4\n---\nCTX-2\n",
    });

    const home = try testRealPathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const resources = try discoverAndRead(alloc, home);
    defer freeResources(alloc, resources);

    const sys = try mergePromptsAlloc(alloc, resources);
    defer alloc.free(sys);
    const ctx = try prependContextAlloc(alloc, resources);
    defer alloc.free(ctx);

    // Higher priority prompt first; disabled prompt omitted.
    try std.testing.expectEqualStrings("B-PROMPT\n\nA-PROMPT", sys);
    // Higher priority context first.
    try std.testing.expectEqualStrings("CTX-2\n\nCTX-1", ctx);
}
