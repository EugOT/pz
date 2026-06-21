//! Per-model config loader (MP6).
//!
//! Loads `~/.pz/models.json` at startup and merges it over the static
//! `models.zig` registry. The FILE OVERRIDES the static entry: a JSON entry
//! whose `name` equals a registry model replaces that model's `ModelInfo`;
//! a new name is added; a wildcard pattern (e.g. `"openrouter/*"`) applies to
//! every model name that matches the pattern when no exact entry wins.
//!
//! Design invariants:
//!   - Arena ownership: the loaded map, every duped string, and the wildcard
//!     list live in `Config.arena`. `Config.deinit()` frees them all at once.
//!     Callers must keep the `Config` alive for as long as any returned
//!     `ModelInfo` (its string fields alias arena memory).
//!   - O(1) exact lookup: `find` first probes a `StringHashMap` keyed by model
//!     name (the hot path). Wildcards are consulted only on an exact miss, via
//!     a short linear scan of declared patterns — never inside the hot path.
//!   - NO silent failures: a missing file is the one benign case (the registry
//!     alone is a valid config). A present-but-malformed file, an invalid
//!     `ctx_win`, or an invalid cost field returns `error.BadModelConfig`. The
//!     loader never swallows a parse/validation error into a default.
//!
//! File schema (`~/.pz/models.json`):
//!   {
//!     "models": [
//!       { "name": "claude-opus-4", "provider": "anthropic", "ctx_win": 500000,
//!         "in_cost": 1500, "out_cost": 7500, "cache_read": 150,
//!         "cache_write": 1875, "thinking": true,
//!         "thinking_default_budget": 64000, "rate_limit_tpm": 200000 },
//!       { "name": "openrouter/*", "provider": "openrouter", "ctx_win": 128000,
//!         "in_cost": 0, "out_cost": 0, "cache_read": 0, "cache_write": 0,
//!         "thinking": false }
//!     ]
//!   }
//! A trailing `*` in `name` marks a wildcard pattern; the text before it is the
//! match prefix. Every other field maps 1:1 onto `models.ModelInfo`.
const std = @import("std");
const models = @import("models.zig");

const Dir = std.Io.Dir;

pub const ModelInfo = models.ModelInfo;
pub const Provider = models.Provider;

/// Hard errors. `BadModelConfig` is the single named failure for any malformed
/// or invalid file content — never a silent fallback to the static registry.
pub const Error = error{BadModelConfig};

/// Upper bound on the on-disk config size. A file larger than this is treated
/// as malformed rather than read unbounded.
const max_file: usize = 1024 * 1024;

fn defaultIo() std.Io {
    return @import("../rt_io.zig").default();
}

/// One declared wildcard pattern plus the `ModelInfo` it expands to. `prefix`
/// is the text before the trailing `*` (may be empty for a catch-all `"*"`).
const Wildcard = struct {
    prefix: []const u8,
    info: ModelInfo,
};

/// JSON shape of a single `models[]` entry. Mirrors `ModelInfo`, but `provider`
/// is decoded from the lowercase `ProviderTag` enum name and the optional
/// override fields default to null. `ignore_unknown_fields = false` (the std
/// default) makes a stray key a parse error → `BadModelConfig`.
const Entry = struct {
    name: []const u8,
    provider: Provider,
    ctx_win: u32,
    in_cost: u64,
    out_cost: u64,
    cache_read: u64,
    cache_write: u64,
    thinking: bool,
    thinking_default_budget: u32 = 0,
    rate_limit_tpm: u32 = 0,
    base_url: ?[]const u8 = null,
    api_path: ?[]const u8 = null,
};

const File = struct {
    models: []const Entry = &.{},
};

/// Merged model configuration: the static registry with the file's overrides
/// and additions applied. Owns all of its memory in `arena`.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Exact-name → ModelInfo. The hot-path lookup table (O(1)).
    map: std.StringHashMapUnmanaged(ModelInfo),
    /// Declared wildcard patterns, consulted only on an exact-name miss.
    wildcards: std.ArrayListUnmanaged(Wildcard),

    /// Frees the map, the wildcard list, and every string they alias.
    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// Resolve a model by exact name first (O(1) hash probe). On a miss, fall
    /// back to the longest matching wildcard prefix. Returns null when nothing
    /// matches — never a silent default. The returned `ModelInfo` aliases
    /// arena memory and is valid until `deinit`.
    pub fn find(self: *const Config, name: []const u8) ?ModelInfo {
        if (self.map.get(name)) |m| return m;
        var best: ?ModelInfo = null;
        var best_len: usize = 0;
        for (self.wildcards.items) |w| {
            if (name.len >= w.prefix.len and
                std.mem.startsWith(u8, name, w.prefix) and
                (best == null or w.prefix.len > best_len))
            {
                best = w.info;
                best_len = w.prefix.len;
            }
        }
        return best;
    }
};

/// Load `<home>/.pz/models.json` and merge it over the static registry.
///
/// `home` is the resolved home directory (mirrors `auth_load.zig`'s home param
/// so tests pass a tmp dir instead of touching real `$HOME`). When the file is
/// absent, the returned `Config` is the static registry verbatim — the one
/// benign "no file" case. Any present-but-malformed/invalid content returns
/// `error.BadModelConfig`.
///
/// Caller owns the returned `Config` and must call `deinit`.
pub fn load(gpa: std.mem.Allocator, home: []const u8) !Config {
    var cfg = try seedFromRegistry(gpa);
    errdefer cfg.deinit();
    const ar = cfg.arena.allocator();

    const path = try std.fs.path.join(ar, &.{ home, ".pz", "models.json" });
    const raw = readPath(ar, path) catch |err| switch (err) {
        // Missing file is the one valid "no overrides" case.
        error.FileNotFound => return cfg,
        // An oversized file is content the loader refuses to parse — a
        // malformed-config condition, not a filesystem fault.
        error.StreamTooLong => return error.BadModelConfig,
        // Every genuine filesystem/IO fault (permission denied, path is a
        // directory, read error, OOM) propagates unchanged. Collapsing these
        // into BadModelConfig would make a permissions bug indistinguishable
        // from a typo in the JSON — the caller could never tell which to fix.
        else => |e| return e,
    };

    try applyFile(&cfg, raw);
    return cfg;
}

/// Parse an in-memory JSON document and merge it over the static registry.
/// Split out from `load` so the merge/validation logic is testable without
/// the filesystem. The `home` overload remains the production entry point.
pub fn loadFromBytes(gpa: std.mem.Allocator, raw: []const u8) !Config {
    var cfg = try seedFromRegistry(gpa);
    errdefer cfg.deinit();
    try applyFile(&cfg, raw);
    return cfg;
}

fn readPath(ar: std.mem.Allocator, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(defaultIo(), path, ar, .limited(max_file));
}

/// Build the base `Config` from `models.findModel`'s table. The registry is the
/// single source of truth for the starting set; the file mutates it in place.
fn seedFromRegistry(gpa: std.mem.Allocator) !Config {
    var cfg: Config = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .map = .empty,
        .wildcards = .empty,
    };
    errdefer cfg.arena.deinit();
    const ar = cfg.arena.allocator();

    // `models.zig` keeps its registry private, so re-resolve each known name
    // through the public `findModel` API. Names are stable literals from the
    // registry; duping into the arena keeps `Config` self-contained even if a
    // later override replaces the value. Resolution cannot fail at runtime —
    // the comptime block below proves every name resolves, so this is an
    // unconditional fetch, not a checked-with-panic fallback.
    for (registry_names) |name| {
        const info = registry_info.get(name).?;
        try cfg.map.put(ar, try ar.dupe(u8, name), info);
    }
    return cfg;
}

/// Resolve every `registry_names` entry through `models.findModel` at comptime.
/// `findModel` iterates a comptime-known table, so this is fully evaluable at
/// build time: a name that no longer matches a `models.zig` row (a rename or a
/// removal) fails the build with a clear message instead of `@panic`-ing in a
/// user's process. The result is a comptime map of name → `ModelInfo` consumed
/// by `seedFromRegistry`, so the resolution happens exactly once, at build.
const registry_info = blk: {
    // Resolving every registry name through `models.findModel` (a linear scan
    // with per-row string compares) costs more than the default 1000-branch
    // comptime budget once this module is actually compiled into a target.
    @setEvalBranchQuota(20_000);
    const map = std.StaticStringMap(ModelInfo).initComptime(pairs: {
        var kv: [registry_names.len]struct { []const u8, ModelInfo } = undefined;
        for (registry_names, 0..) |name, i| {
            const info = models.findModel(name) orelse @compileError(
                "config: registry name '" ++ name ++
                    "' no longer resolves via models.findModel — " ++
                    "models.zig and config.registry_names have diverged",
            );
            kv[i] = .{ name, info };
        }
        break :pairs kv;
    });
    break :blk map;
};

/// Names mirrored from the `models.zig` registry. Divergence (a removed or
/// renamed row) is caught at build time by the `registry_info` comptime block,
/// never at runtime. Adding a new model to `models.zig` without listing it here
/// simply leaves it unseeded; the static `findModel` lookup still serves it.
const registry_names = [_][]const u8{
    "claude-opus-4",
    "claude-sonnet-4",
    "claude-haiku-3",
    "claude-3-5-sonnet",
    "claude-3-5-haiku",
    "gpt-4o",
    "gpt-4o-mini",
    "gpt-4-turbo",
    "o1",
    "o1-mini",
    "o1-pro",
    "o3",
    "o3-mini",
    "o4-mini",
    "openrouter/auto",
    "anthropic/claude-sonnet-4",
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-2.0-flash",
    "mistral-large",
    "mistral-small",
    "llama-3.3-70b-versatile",
    "deepseek-r1-distill-llama-70b",
    "deepseek-chat",
    "deepseek-reasoner",
};

/// Parse `raw` and merge every entry over `cfg`. Strict: a parse error, an
/// unknown field, an empty name, an invalid ctx_win, or an invalid cost all
/// return `error.BadModelConfig`.
fn applyFile(cfg: *Config, raw: []const u8) !void {
    const ar = cfg.arena.allocator();
    const parsed = std.json.parseFromSlice(File, ar, raw, .{
        .allocate = .alloc_always,
        // Reject unknown keys: a typo'd field must fail loudly, not be ignored.
        .ignore_unknown_fields = false,
    }) catch return error.BadModelConfig;

    for (parsed.value.models) |e| {
        try validate(e);
        const info = try dupEntry(ar, e);
        if (std.mem.endsWith(u8, e.name, "*")) {
            const prefix = e.name[0 .. e.name.len - 1];
            try cfg.wildcards.append(ar, .{
                .prefix = try ar.dupe(u8, prefix),
                .info = info,
            });
        } else {
            // File overrides static entry for an existing name; adds a new name
            // otherwise. `getOrPut` reuses the existing key slot on override so
            // no stale key leaks (arena reclaims any dup regardless).
            const gop = try cfg.map.getOrPut(ar, info.name);
            gop.value_ptr.* = info;
        }
    }
}

/// Field-level validation. Each rule rejects a value the static table would
/// never carry, so a fat-fingered file cannot misroute or misprice a request.
fn validate(e: Entry) Error!void {
    if (e.name.len == 0) return error.BadModelConfig;
    // ctx_win is a token budget: zero is meaningless and would make every
    // request appear to overflow (or underflow) the window.
    if (e.ctx_win == 0) return error.BadModelConfig;
    // A model named as a wildcard pattern beyond a single trailing `*` is
    // ambiguous (`a*b`): reject so the match semantics stay prefix-only.
    if (std.mem.indexOfScalar(u8, e.name, '*')) |star| {
        if (star != e.name.len - 1) return error.BadModelConfig;
    }
    // Costs are micents/Mtoken: any value fits u64, but a thinking model with a
    // zero budget (or a non-thinking model with a non-zero budget) contradicts
    // the registry contract validated at comptime in models.zig.
    if (e.thinking and e.thinking_default_budget == 0) return error.BadModelConfig;
    if (!e.thinking and e.thinking_default_budget != 0) return error.BadModelConfig;
    // Path override, when present, must be absolute (mirrors models.zig).
    if (e.api_path) |p| {
        if (p.len == 0 or p[0] != '/') return error.BadModelConfig;
    }
    if (e.base_url) |h| {
        if (h.len == 0) return error.BadModelConfig;
    }
}

/// Copy a validated entry into an arena-owned `ModelInfo`. Every string field
/// is duped so the result outlives the JSON parse arena slice it came from
/// (both share `ar`, but duping keeps ownership explicit and self-documenting).
fn dupEntry(ar: std.mem.Allocator, e: Entry) !ModelInfo {
    return .{
        .name = try ar.dupe(u8, e.name),
        .provider = e.provider,
        .ctx_win = e.ctx_win,
        .in_cost = e.in_cost,
        .out_cost = e.out_cost,
        .cache_read = e.cache_read,
        .cache_write = e.cache_write,
        .thinking = e.thinking,
        .thinking_default_budget = e.thinking_default_budget,
        .rate_limit_tpm = e.rate_limit_tpm,
        .base_url = if (e.base_url) |h| try ar.dupe(u8, h) else null,
        .api_path = if (e.api_path) |p| try ar.dupe(u8, p) else null,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "load reads ~/.pz/models.json and parses entries (criterion 1)" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pz/models.json",
        .data =
        \\{
        \\  "models": [
        \\    { "name": "my-custom-model", "provider": "openai", "ctx_win": 256000,
        \\      "in_cost": 100, "out_cost": 200, "cache_read": 10, "cache_write": 0,
        \\      "thinking": false }
        \\  ]
        \\}
        ,
    });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    var cfg = try load(testing.allocator, home);
    defer cfg.deinit();

    const m = cfg.find("my-custom-model").?;
    try oh.snap(@src(),
        \\core.providers.models.ModelInfo
        \\  .name: []const u8
        \\    "my-custom-model"
        \\  .provider: core.providers.registry.ProviderTag
        \\    .openai
        \\  .ctx_win: u32 = 256000
        \\  .in_cost: u64 = 100
        \\  .out_cost: u64 = 200
        \\  .cache_read: u64 = 10
        \\  .cache_write: u64 = 0
        \\  .thinking: bool = false
        \\  .thinking_default_budget: u32 = 0
        \\  .rate_limit_tpm: u32 = 0
        \\  .base_url: ?[]const u8
        \\    null
        \\  .api_path: ?[]const u8
        \\    null
    ).expectEqual(m);
}

test "missing file falls back to registry, no error (criterion 1 benign case)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    var cfg = try load(testing.allocator, home);
    defer cfg.deinit();

    // Static registry still resolves; no override added.
    const opus = cfg.find("claude-opus-4").?;
    try testing.expectEqual(@as(u32, 200_000), opus.ctx_win);
    try testing.expect(cfg.find("my-custom-model") == null);
}

test "file entry overrides static registry by name (criterion 2)" {
    var cfg = try loadFromBytes(testing.allocator,
        \\{
        \\  "models": [
        \\    { "name": "claude-opus-4", "provider": "anthropic", "ctx_win": 500000,
        \\      "in_cost": 999, "out_cost": 1000, "cache_read": 1, "cache_write": 2,
        \\      "thinking": true, "thinking_default_budget": 64000,
        \\      "rate_limit_tpm": 123456 }
        \\  ]
        \\}
    );
    defer cfg.deinit();

    const opus = cfg.find("claude-opus-4").?;
    // File wins over the static 200_000 / 1500 / 7500.
    try testing.expectEqual(@as(u32, 500_000), opus.ctx_win);
    try testing.expectEqual(@as(u64, 999), opus.in_cost);
    try testing.expectEqual(@as(u64, 1000), opus.out_cost);
    try testing.expectEqual(@as(u32, 64_000), opus.thinking_default_budget);
    try testing.expectEqual(@as(u32, 123_456), opus.rate_limit_tpm);

    // A model not in the file keeps its static value.
    const sonnet = cfg.find("claude-sonnet-4").?;
    try testing.expectEqual(@as(u32, 200_000), sonnet.ctx_win);
    try testing.expectEqual(@as(u64, 300), sonnet.in_cost);
}

test "new name is added alongside the registry (criterion 2)" {
    var cfg = try loadFromBytes(testing.allocator,
        \\{
        \\  "models": [
        \\    { "name": "brand-new-7b", "provider": "groq", "ctx_win": 32000,
        \\      "in_cost": 5, "out_cost": 9, "cache_read": 0, "cache_write": 0,
        \\      "thinking": false }
        \\  ]
        \\}
    );
    defer cfg.deinit();

    const novel = cfg.find("brand-new-7b").?;
    try testing.expectEqual(Provider.groq, novel.provider);
    try testing.expectEqual(@as(u32, 32_000), novel.ctx_win);
    // Registry entries are still present.
    try testing.expect(cfg.find("gpt-4o") != null);
}

test "wildcard pattern applies to matching names (criterion 3)" {
    var cfg = try loadFromBytes(testing.allocator,
        \\{
        \\  "models": [
        \\    { "name": "openrouter/*", "provider": "openrouter", "ctx_win": 64000,
        \\      "in_cost": 1, "out_cost": 2, "cache_read": 0, "cache_write": 0,
        \\      "thinking": false }
        \\  ]
        \\}
    );
    defer cfg.deinit();

    // An exact registry name is untouched by the wildcard.
    const auto = cfg.find("openrouter/auto").?;
    try testing.expectEqual(@as(u32, 128_000), auto.ctx_win);

    // A name with no exact entry resolves through the wildcard.
    const wild = cfg.find("openrouter/some-new-slug").?;
    try testing.expectEqual(Provider.openrouter, wild.provider);
    try testing.expectEqual(@as(u32, 64_000), wild.ctx_win);
    try testing.expectEqual(@as(u64, 1), wild.in_cost);

    // A non-matching unknown name still returns null.
    try testing.expect(cfg.find("anthropic/unknown") == null);
}

test "longest wildcard prefix wins on overlap (criterion 3)" {
    var cfg = try loadFromBytes(testing.allocator,
        \\{
        \\  "models": [
        \\    { "name": "openrouter/*", "provider": "openrouter", "ctx_win": 64000,
        \\      "in_cost": 1, "out_cost": 2, "cache_read": 0, "cache_write": 0,
        \\      "thinking": false },
        \\    { "name": "openrouter/meta/*", "provider": "openrouter", "ctx_win": 8000,
        \\      "in_cost": 3, "out_cost": 4, "cache_read": 0, "cache_write": 0,
        \\      "thinking": false }
        \\  ]
        \\}
    );
    defer cfg.deinit();

    const meta = cfg.find("openrouter/meta/llama").?;
    try testing.expectEqual(@as(u32, 8_000), meta.ctx_win);
    const other = cfg.find("openrouter/google/gemini").?;
    try testing.expectEqual(@as(u32, 64_000), other.ctx_win);
}

test "lookup is O(1) hash probe, not a linear scan (criterion 4)" {
    var cfg = try loadFromBytes(testing.allocator, "{}");
    defer cfg.deinit();

    // The exact path is a StringHashMap probe: assert the map is the lookup
    // structure and that a known key resolves through it directly.
    try testing.expect(cfg.map.count() == registry_names.len);
    try testing.expect(cfg.map.get("gpt-4o") != null);
    try testing.expect(cfg.map.get("does-not-exist") == null);
    // `find` returns the same value the map holds for an exact name (no scan).
    const direct = cfg.map.get("o3-mini").?;
    const viaFind = cfg.find("o3-mini").?;
    try testing.expectEqualStrings(direct.name, viaFind.name);
    try testing.expectEqual(direct.in_cost, viaFind.in_cost);
}

test "malformed JSON returns BadModelConfig (criterion 5)" {
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator, "not json at all"));
}

test "unknown field returns BadModelConfig (criterion 5)" {
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator,
        \\{ "models": [ { "name": "x", "provider": "openai", "ctx_win": 1000,
        \\  "in_cost": 0, "out_cost": 0, "cache_read": 0, "cache_write": 0,
        \\  "thinking": false, "bogus_field": 1 } ] }
    ));
}

test "zero ctx_win returns BadModelConfig (criterion 5)" {
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator,
        \\{ "models": [ { "name": "x", "provider": "openai", "ctx_win": 0,
        \\  "in_cost": 10, "out_cost": 20, "cache_read": 0, "cache_write": 0,
        \\  "thinking": false } ] }
    ));
}

test "negative cost is rejected as malformed (criterion 5)" {
    // A negative number cannot decode into u64 → parse error → BadModelConfig.
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator,
        \\{ "models": [ { "name": "x", "provider": "openai", "ctx_win": 1000,
        \\  "in_cost": -5, "out_cost": 20, "cache_read": 0, "cache_write": 0,
        \\  "thinking": false } ] }
    ));
}

test "thinking model without budget is rejected (criterion 5)" {
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator,
        \\{ "models": [ { "name": "x", "provider": "openai", "ctx_win": 1000,
        \\  "in_cost": 1, "out_cost": 2, "cache_read": 0, "cache_write": 0,
        \\  "thinking": true } ] }
    ));
}

test "non-absolute api_path override is rejected (criterion 5)" {
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator,
        \\{ "models": [ { "name": "x", "provider": "openrouter", "ctx_win": 1000,
        \\  "in_cost": 1, "out_cost": 2, "cache_read": 0, "cache_write": 0,
        \\  "thinking": false, "api_path": "no-leading-slash" } ] }
    ));
}

test "interior wildcard star is rejected as ambiguous" {
    try testing.expectError(error.BadModelConfig, loadFromBytes(testing.allocator,
        \\{ "models": [ { "name": "open*er/x", "provider": "openrouter", "ctx_win": 1000,
        \\  "in_cost": 1, "out_cost": 2, "cache_read": 0, "cache_write": 0,
        \\  "thinking": false } ] }
    ));
}

test "empty document leaves registry intact, no leaks" {
    var cfg = try loadFromBytes(testing.allocator, "{}");
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 200_000), cfg.find("claude-opus-4").?.ctx_win);
    try testing.expectEqual(registry_names.len, cfg.map.count());
    try testing.expectEqual(@as(usize, 0), cfg.wildcards.items.len);
}

test "every registry name seeds via comptime-resolved info, not a runtime panic" {
    // The comptime `registry_info` map proves each name resolves at build time;
    // here we assert the runtime seed reproduces every name with the same value
    // `models.findModel` would return — i.e. no name silently dropped or remapped.
    var cfg = try loadFromBytes(testing.allocator, "{}");
    defer cfg.deinit();
    for (registry_names) |name| {
        const seeded = cfg.find(name) orelse {
            std.debug.print("registry name not seeded: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        const canonical = models.findModel(name).?;
        try testing.expectEqualStrings(canonical.name, seeded.name);
        try testing.expectEqual(canonical.provider, seeded.provider);
        try testing.expectEqual(canonical.ctx_win, seeded.ctx_win);
        try testing.expectEqual(canonical.in_cost, seeded.in_cost);
    }
}

test "directory at config path surfaces a filesystem error, not BadModelConfig" {
    // Regression for the read-error conflation finding: a real filesystem fault
    // (here, `models.json` is a directory) must NOT be reported as a config
    // validation error. The caller has to be able to tell "I have a perms/path
    // problem" apart from "my JSON is malformed".
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".pz/models.json");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    const res = load(testing.allocator, home);
    try testing.expect(std.meta.isError(res));
    if (res) |cfg_ok| {
        var c = cfg_ok;
        c.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        // The exact errno varies by platform (IsDir on most POSIX, AccessDenied
        // on some); the contract under test is only that it is NOT remapped to
        // the config-validation error.
        try testing.expect(err != error.BadModelConfig);
    }
}

test "oversized config file is malformed config, not a benign miss" {
    // A present-but-too-large file is content the loader refuses to parse. It
    // maps to BadModelConfig (malformed), and crucially is NOT treated like a
    // missing file (which would silently fall back to the bare registry).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".pz");

    const big = try testing.allocator.alloc(u8, max_file + 16);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/models.json", .data = big });

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);

    try testing.expectError(error.BadModelConfig, load(testing.allocator, home));
}
