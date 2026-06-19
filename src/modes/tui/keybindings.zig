//! Dynamic keybindings: load `~/.pz/keybindings.json`, map raw keys to
//! rebound keys, and report conflicting bindings.
//!
//! The JSON file is a flat object whose keys are *source* key specs and whose
//! values are *target* key specs, e.g.:
//!
//!     {
//!       "ctrl_t": "ctrl_p",
//!       "alt_y":  "ctrl_y"
//!     }
//!
//! When the input reader sees a source key, it emits the target key instead.
//! Because the remap happens at the `Reader` layer, the rebound key flows
//! through the existing `Event`/`Key` path that the runtime already audits —
//! no new audit surface is introduced.
const std = @import("std");
const editor = @import("editor.zig");

const Key = editor.Key;

fn defaultIo() std.Io {
    return @import("../../core/rt_io.zig").default();
}

/// Hard cap on file size; a keybindings file larger than this is rejected.
const max_file: usize = 64 * 1024;

/// Hard cap on number of bindings (also bounds the conflict report).
pub const max_bindings: usize = 256;

pub const Error = error{
    /// A key spec (source or target) is not a recognized key.
    UnknownKey,
    /// The JSON root is not an object, or a value is not a string, or the
    /// document is malformed / unreadable / oversize.
    BadShape,
    /// More than `max_bindings` entries.
    TooManyBindings,
    OutOfMemory,
};

/// One remap rule: when `from` is seen, emit `to`.
pub const Binding = struct {
    from: Key,
    to: Key,
};

/// A reported conflict: `name` was bound to multiple targets. The first
/// binding wins; later ones are dropped and recorded here.
pub const Conflict = struct {
    name: []const u8,
};

pub const Bindings = struct {
    rules: []Binding,

    pub const empty = Bindings{ .rules = &.{} };

    pub fn deinit(self: *Bindings, alloc: std.mem.Allocator) void {
        if (self.rules.len > 0) alloc.free(self.rules);
        self.* = .{ .rules = &.{} };
    }

    /// Resolve a raw key through the bindings. Returns the rebound key if a
    /// rule matches, otherwise the original key. First match wins; conflicting
    /// sources are dropped at parse time so at most one rule can match.
    pub fn apply(self: *const Bindings, key: Key) Key {
        for (self.rules) |rule| {
            if (keyEql(rule.from, key)) return rule.to;
        }
        return key;
    }
};

/// Result of parsing: the usable bindings plus any conflicts that were found.
/// Conflicts are never silently swallowed — the caller MUST inspect
/// `conflicts` (via `hadConflict`) and report them. Hard errors (bad shape,
/// unknown key, oversize) fail outright with `Error` and never reach here.
pub const ParseResult = struct {
    bindings: Bindings,
    conflicts: []Conflict,

    pub fn hadConflict(self: *const ParseResult) bool {
        return self.conflicts.len > 0;
    }

    pub fn deinit(self: *ParseResult, alloc: std.mem.Allocator) void {
        self.bindings.deinit(alloc);
        for (self.conflicts) |c| alloc.free(c.name);
        if (self.conflicts.len > 0) alloc.free(self.conflicts);
        self.* = .{ .bindings = Bindings.empty, .conflicts = &.{} };
    }
};

/// Load and parse `~/.pz/keybindings.json`. Missing file yields empty bindings
/// (not an error). A malformed file is a hard error — no silent fallback.
pub fn load(alloc: std.mem.Allocator, home: ?[]const u8) Error!ParseResult {
    const h = home orelse return emptyResult();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.pz/keybindings.json", .{h}) catch
        return emptyResult();

    const active_io = defaultIo();
    const file = std.Io.Dir.openFileAbsolute(active_io, path, .{}) catch
        return emptyResult(); // no file → empty
    defer file.close(active_io);

    var file_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(active_io, &file_buf);
    const content = reader.interface.allocRemaining(alloc, .limited(max_file)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadShape, // unreadable/oversize → reject
    };
    defer alloc.free(content);

    return parse(alloc, content);
}

fn emptyResult() ParseResult {
    return .{ .bindings = Bindings.empty, .conflicts = &.{} };
}

/// Parse keybindings JSON text. Conflicts are returned in
/// `ParseResult.conflicts`; the first binding for a key wins and conflicting
/// later bindings are dropped (and reported). Structural problems are errors.
pub fn parse(alloc: std.mem.Allocator, raw: []const u8) Error!ParseResult {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.BadShape;
    defer parsed.deinit();

    if (parsed.value != .object) return error.BadShape;
    const obj = parsed.value.object;

    if (obj.count() > max_bindings) return error.TooManyBindings;

    var rules = std.ArrayList(Binding).empty;
    errdefer rules.deinit(alloc);

    var conflicts = std.ArrayList(Conflict).empty;
    errdefer {
        for (conflicts.items) |c| alloc.free(c.name);
        conflicts.deinit(alloc);
    }

    var it = obj.iterator();
    while (it.next()) |entry| {
        const from_name = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .string) return error.BadShape;
        const to_name = val.string;

        const from = parseKey(from_name) orelse return error.UnknownKey;
        const to = parseKey(to_name) orelse return error.UnknownKey;

        // A source key already bound is a conflict: keep the first, report this.
        var conflict = false;
        for (rules.items) |existing| {
            if (keyEql(existing.from, from)) {
                conflict = true;
                break;
            }
        }
        if (conflict) {
            const owned = try alloc.dupe(u8, from_name);
            errdefer alloc.free(owned);
            try conflicts.append(alloc, .{ .name = owned });
            continue; // first binding wins; conflicting one is dropped
        }

        try rules.append(alloc, .{ .from = from, .to = to });
    }

    const conflicts_slice = try conflicts.toOwnedSlice(alloc);
    errdefer {
        for (conflicts_slice) |c| alloc.free(c.name);
        if (conflicts_slice.len > 0) alloc.free(conflicts_slice);
    }
    const rules_slice = try rules.toOwnedSlice(alloc);

    return .{
        .bindings = .{ .rules = rules_slice },
        .conflicts = conflicts_slice,
    };
}

fn keyEql(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .char => |ca| ca == b.char,
        else => true,
    };
}

/// Map a key-spec string to an `editor.Key`. Recognizes every named variant of
/// `editor.Key` plus `char:<cp>` for a literal codepoint (e.g. `char:97` = 'a').
pub fn parseKey(name: []const u8) ?Key {
    if (std.mem.startsWith(u8, name, "char:")) {
        const cp = std.fmt.parseInt(u21, name["char:".len..], 10) catch return null;
        return .{ .char = cp };
    }
    const info = @typeInfo(Key).@"union";
    inline for (info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "char")) continue;
        if (std.mem.eql(u8, field.name, name)) {
            return @unionInit(Key, field.name, {});
        }
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "parseKey: named void keys" {
    try std.testing.expect(parseKey("ctrl_p") != null);
    try std.testing.expect(std.meta.activeTag(parseKey("ctrl_p").?) == .ctrl_p);
    try std.testing.expect(std.meta.activeTag(parseKey("enter").?) == .enter);
    try std.testing.expect(std.meta.activeTag(parseKey("alt_up").?) == .alt_up);
}

test "parseKey: char codepoint" {
    const k = parseKey("char:97") orelse return error.TestUnexpectedResult;
    switch (k) {
        .char => |cp| try std.testing.expectEqual(@as(u21, 'a'), cp),
        else => return error.TestUnexpectedResult,
    }
}

test "parseKey: unknown returns null" {
    try std.testing.expect(parseKey("not_a_key") == null);
    try std.testing.expect(parseKey("char") == null);
    try std.testing.expect(parseKey("char:notanum") == null);
    try std.testing.expect(parseKey("") == null);
}

test "parse: simple remap applies" {
    const json =
        \\{ "ctrl_t": "ctrl_p", "alt_y": "ctrl_y" }
    ;
    var result = try parse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.bindings.rules.len);
    try std.testing.expect(!result.hadConflict());

    // ctrl_t → ctrl_p
    try std.testing.expect(std.meta.activeTag(result.bindings.apply(.ctrl_t)) == .ctrl_p);
    // alt_y → ctrl_y
    try std.testing.expect(std.meta.activeTag(result.bindings.apply(.alt_y)) == .ctrl_y);
    // unmapped key passes through
    try std.testing.expect(std.meta.activeTag(result.bindings.apply(.enter)) == .enter);
}

test "parse: char source and target remap" {
    const json =
        \\{ "char:97": "char:98" }
    ;
    var result = try parse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);

    const out = result.bindings.apply(.{ .char = 'a' });
    switch (out) {
        .char => |cp| try std.testing.expectEqual(@as(u21, 'b'), cp),
        else => return error.TestUnexpectedResult,
    }
    // A different char is untouched.
    const z = result.bindings.apply(.{ .char = 'z' });
    switch (z) {
        .char => |cp| try std.testing.expectEqual(@as(u21, 'z'), cp),
        else => return error.TestUnexpectedResult,
    }
}

test "parse: textual duplicate keys collapse per JSON object semantics" {
    // std.json's default object semantics keep the last value for a repeated
    // textual key, so this yields a single rule (no conflict surfaces).
    const json =
        \\{ "ctrl_t": "ctrl_p", "ctrl_t": "ctrl_y" }
    ;
    var result = try parse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.bindings.rules.len);
}

test "parse: distinct specs colliding on same key are reported" {
    // 'char:97' and 'char:0097' both resolve to the same .char key → conflict.
    const json =
        \\{ "char:97": "ctrl_p", "char:0097": "ctrl_y" }
    ;
    var result = try parse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.hadConflict());
    try std.testing.expectEqual(@as(usize, 1), result.conflicts.len);
    try std.testing.expectEqualStrings("char:0097", result.conflicts[0].name);
    // First binding still wins.
    try std.testing.expect(std.meta.activeTag(result.bindings.apply(.{ .char = 'a' })) == .ctrl_p);
}

test "parse: enter and char:13 are distinct keys (no conflict)" {
    // char:13 is the CR codepoint — a .char key, NOT the .enter key.
    const json =
        \\{ "enter": "ctrl_j", "char:13": "ctrl_k" }
    ;
    var result = try parse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.bindings.rules.len);
    try std.testing.expect(!result.hadConflict());
}

test "parse: unknown source key is hard error" {
    const json =
        \\{ "bogus": "ctrl_p" }
    ;
    try std.testing.expectError(error.UnknownKey, parse(std.testing.allocator, json));
}

test "parse: unknown target is hard error" {
    const json =
        \\{ "ctrl_t": "bogus" }
    ;
    try std.testing.expectError(error.UnknownKey, parse(std.testing.allocator, json));
}

test "parse: non-object root is bad shape" {
    try std.testing.expectError(error.BadShape, parse(std.testing.allocator, "[1,2,3]"));
}

test "parse: non-string value is bad shape" {
    const json =
        \\{ "ctrl_t": 5 }
    ;
    try std.testing.expectError(error.BadShape, parse(std.testing.allocator, json));
}

test "parse: invalid json is bad shape" {
    try std.testing.expectError(error.BadShape, parse(std.testing.allocator, "{not json"));
}

test "parse: empty object yields empty bindings" {
    var result = try parse(std.testing.allocator, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.bindings.rules.len);
    // empty bindings pass everything through
    try std.testing.expect(std.meta.activeTag(result.bindings.apply(.tab)) == .tab);
}

test "load: missing home yields empty bindings" {
    var result = try load(std.testing.allocator, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.bindings.rules.len);
}

test "load: nonexistent file yields empty bindings" {
    var result = try load(std.testing.allocator, "/nonexistent-pz-home-xyz");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.bindings.rules.len);
}

test "Bindings.empty applies identity" {
    const b = Bindings.empty;
    try std.testing.expect(std.meta.activeTag(b.apply(.ctrl_c)) == .ctrl_c);
}
