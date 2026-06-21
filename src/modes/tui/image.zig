//! Terminal image protocol detection and rendering.

const std = @import("std");

pub const Protocol = enum {
    none,
    kitty,
    iterm,
};

const term_cap_map = std.StaticStringMap(Protocol).initComptime(.{
    .{ "xterm-kitty", .kitty },
});

const term_program_cap_map = std.StaticStringMap(Protocol).initComptime(.{
    .{ "WezTerm", .kitty },
});

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
}

fn defaultIo() std.Io {
    return @import("../../core/rt_io.zig").default();
}

pub fn detect() Protocol {
    if (getenv("KITTY_WINDOW_ID") != null) return .kitty;
    if (getenv("TERM")) |term| {
        if (term_cap_map.get(term)) |cap| return cap;
    }
    if (getenv("TERM_PROGRAM")) |tp| {
        if (term_program_cap_map.get(tp)) |cap| return cap;
        if (std.mem.indexOf(u8, tp, "iTerm") != null) return .iterm;
    }
    if (getenv("LC_TERMINAL")) |lt| {
        if (std.mem.indexOf(u8, lt, "iTerm") != null) return .iterm;
    }
    return .none;
}

test "detect returns none in test environment" {
    try std.testing.expectEqual(Protocol.none, detect());
}

/// Default image display height in terminal rows.
pub const img_rows: usize = 8;

/// Write an image file to the terminal using the appropriate protocol.
/// Positions cursor at (col, row) first using CUP sequence.
pub fn writeImageAt(out: anytype, alloc: std.mem.Allocator, path: []const u8, col: usize, row: usize, cols: usize, cap: Protocol) !void {
    switch (cap) {
        .none => return,
        .kitty => {
            // Position cursor
            try writeCup(out, col, row);
            try writeKittyFile(out, path, cols);
        },
        .iterm => {
            try writeCup(out, col, row);
            try writeItermFile(out, alloc, path, cols);
        },
    }
}

fn writeCup(out: anytype, col: usize, row: usize) !void {
    var buf: [24]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row + 1, col + 1 }) catch
        return error.Overflow;
    try out.writeAll(seq);
}

/// Kitty: transmit image by file path.
/// \x1b_Ga=T,f=100,t=f,c=COLS,r=ROWS;\x1b\\
fn writeKittyFile(out: anytype, path: []const u8, cols: usize) !void {
    var hdr: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "\x1b_Ga=T,f=100,t=f,c={d},r={d};", .{ cols, img_rows }) catch
        return error.Overflow;
    try out.writeAll(h);

    // Kitty file path payload is base64-encoded path
    const enc = std.base64.standard;
    var enc_buf: [512]u8 = undefined;
    const encoded = enc.Encoder.encode(&enc_buf, path);
    try out.writeAll(encoded);
    try out.writeAll("\x1b\\");
}

/// iTerm2: transmit image by reading file and base64-encoding data.
fn writeItermFile(out: anytype, alloc: std.mem.Allocator, path: []const u8, cols: usize) !void {
    // Read file
    const data = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(data);

    var hdr: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "\x1b]1337;File=inline=1;width={d}cols;height={d}rows:", .{ cols, img_rows }) catch
        return error.Overflow;
    try out.writeAll(h);

    // Base64 encode in chunks
    const enc = std.base64.standard;
    var enc_buf: [8192]u8 = undefined;
    var off: usize = 0;
    while (off < data.len) {
        const chunk = @min(data.len - off, (enc_buf.len / 4) * 3);
        const encoded = enc.Encoder.encode(&enc_buf, data[off .. off + chunk]);
        try out.writeAll(encoded);
        off += chunk;
    }
    try out.writeAll("\x07");
}

// ── Clipboard image-paste detection ──────────────────────────────────────
//
// DETECTION ONLY. We never decode, never read pixel bytes. On a paste event
// the runtime asks "does the clipboard currently hold an image?" and, if so,
// surfaces a `[image detected]` marker in the UI. Audit emission for the
// paste is wired separately (EXT-WIRE); this module only produces the marker.
//
// The core (`clipboardHasImage`) is pure and takes the list of pasteboard
// type identifiers as an argument, so a test can inject "image present" vs
// "no image" without touching a real clipboard. The macOS query
// (`queryClipboardTypes`) is a thin wrapper guarded behind a comptime OS
// check; non-macOS builds compile against a stub that reports no clipboard.

/// UI marker surfaced when a pasted clipboard holds an image.
pub const image_marker: []const u8 = "[image detected]";

/// Pasteboard type identifiers that indicate image content is present.
/// Covers macOS UTIs (`public.image` and its concrete subtypes) plus the
/// MIME-style names some terminals report. Matching is case-insensitive and
/// also treats any `public.<...>` / `image/<...>` family member as an image.
const image_type_exact = [_][]const u8{
    "public.image",
    "public.png",
    "public.jpeg",
    "public.tiff",
    "public.heic",
    "public.heif",
    "com.compuserve.gif",
    "com.apple.pict",
    "com.apple.icns",
    "com.microsoft.bmp",
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn isImageType(t: []const u8) bool {
    for (image_type_exact) |known| {
        if (eqIgnoreCase(t, known)) return true;
    }
    // MIME family: "image/png", "image/jpeg", ...
    if (t.len > 6 and std.ascii.eqlIgnoreCase(t[0..6], "image/")) return true;
    return false;
}

/// PURE detection core. Given the pasteboard type identifiers currently on the
/// clipboard, report whether any of them denotes image content.
///
/// Injectable: tests pass a synthetic type list to model "image present" vs
/// "no image" with no real clipboard involved.
pub fn clipboardHasImage(types: []const []const u8) bool {
    for (types) |t| {
        if (isImageType(t)) return true;
    }
    return false;
}

/// Map a detection result to the UI paste marker. Returns the marker string
/// when an image is present, `null` otherwise. No allocation: the marker is a
/// static slice.
pub fn pasteMarker(has_image: bool) ?[]const u8 {
    return if (has_image) image_marker else null;
}

/// Whether clipboard-image detection is available on the build target.
/// macOS ships `pbpaste`; other targets get the stub (no detection).
pub const clipboard_supported: bool = @import("builtin").os.tag == .macos;

/// Thin platform wrapper: query the live clipboard for its pasteboard type
/// identifiers. macOS shells out to `pbpaste -Prefer` probes; every other
/// target returns `null` (the stub) so non-macOS builds still compile.
///
/// Caller owns the returned slice and each element when non-null; free with
/// `freeTypes`.
pub fn queryClipboardTypes(alloc: std.mem.Allocator) !?[][]u8 {
    if (comptime !clipboard_supported) return null;
    return queryClipboardTypesMacos(alloc);
}

/// Free a type list returned by `queryClipboardTypes`.
pub fn freeTypes(alloc: std.mem.Allocator, types: [][]u8) void {
    for (types) |t| alloc.free(t);
    alloc.free(types);
}

/// Live convenience: query the clipboard and run the pure detector over it.
/// Returns false on any platform without clipboard support or when the query
/// yields nothing.
pub fn clipboardHasImageLive(alloc: std.mem.Allocator) !bool {
    const maybe = try queryClipboardTypes(alloc);
    const types = maybe orelse return false;
    defer freeTypes(alloc, types);
    const ptr: [*]const []const u8 = @ptrCast(types.ptr);
    return clipboardHasImage(ptr[0..types.len]);
}

/// macOS implementation of `queryClipboardTypes`. Uses `osascript` to read the
/// current pasteboard's declared type identifiers as a newline-free list, then
/// splits it. DETECTION ONLY — we ask for the *types*, never the data.
fn queryClipboardTypesMacos(alloc: std.mem.Allocator) !?[][]u8 {
    // `clipboard info` returns rows like: «class PNGf», public.png, 12345
    // We request only the type identifiers, comma-separated.
    const script =
        "set tids to (clipboard info)\n" ++
        "set out to \"\"\n" ++
        "repeat with row in tids\n" ++
        "  set out to out & (item 1 of row) & \"\\n\"\n" ++
        "end repeat\n" ++
        "return out";
    const argv = [_][]const u8{ "osascript", "-e", script };

    const res = std.process.run(alloc, defaultIo(), .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return try splitTypes(alloc, res.stdout);
}

/// Split newline-separated pasteboard type identifiers into an owned list,
/// skipping blanks. Shared by the macOS path and exercised directly in tests.
fn splitTypes(alloc: std.mem.Allocator, raw: []const u8) ![][]u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |t| alloc.free(t);
        list.deinit(alloc);
    }
    var it = std.mem.tokenizeAny(u8, raw, "\r\n,");
    while (it.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " \t");
        if (trimmed.len == 0) continue;
        try list.append(alloc, try alloc.dupe(u8, trimmed));
    }
    return list.toOwnedSlice(alloc);
}

test "clipboardHasImage detects image when an image type is present" {
    const types = [_][]const u8{ "public.utf8-plain-text", "public.png" };
    try std.testing.expect(clipboardHasImage(&types));
}

test "clipboardHasImage detects MIME-style image type" {
    const types = [_][]const u8{ "text/plain", "image/jpeg" };
    try std.testing.expect(clipboardHasImage(&types));
}

test "clipboardHasImage is false with no image type" {
    const types = [_][]const u8{ "public.utf8-plain-text", "public.url" };
    try std.testing.expect(!clipboardHasImage(&types));
}

test "clipboardHasImage is false with empty clipboard" {
    const types = [_][]const u8{};
    try std.testing.expect(!clipboardHasImage(&types));
}

test "pasteMarker surfaces [image detected] when image present" {
    // Inject "image present" via the pure core, then map to the marker.
    const present = [_][]const u8{"public.tiff"};
    const marker = pasteMarker(clipboardHasImage(&present));
    try std.testing.expect(marker != null);
    try std.testing.expectEqualStrings("[image detected]", marker.?);
}

test "pasteMarker returns null when no image present" {
    // Inject "no image" — marker must be absent.
    const absent = [_][]const u8{ "public.utf8-plain-text", "public.url" };
    try std.testing.expectEqual(@as(?[]const u8, null), pasteMarker(clipboardHasImage(&absent)));
}

test "splitTypes parses pasteboard type list and detects image" {
    const raw = "public.utf8-plain-text\npublic.png\n";
    const types = try splitTypes(std.testing.allocator, raw);
    defer freeTypes(std.testing.allocator, types);
    try std.testing.expectEqual(@as(usize, 2), types.len);
    const ptr: [*]const []const u8 = @ptrCast(types.ptr);
    try std.testing.expect(clipboardHasImage(ptr[0..types.len]));
}

test "queryClipboardTypes is a stub on non-macOS targets" {
    if (clipboard_supported) return error.SkipZigTest;
    const got = try queryClipboardTypes(std.testing.allocator);
    try std.testing.expectEqual(@as(?[][]u8, null), got);
}
