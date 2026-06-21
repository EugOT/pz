//! Terminal color depth detection from environment variables.

const std = @import("std");
const frame = @import("frame.zig");

pub const ColorDepth = enum {
    none,
    basic,
    c256,
    truecolor,
};

fn getenv(comptime name: []const u8) ?[:0]const u8 {
    return std.Io.Threaded.global_single_threaded.environString(name);
}

pub fn detect() ColorDepth {
    if (getenv("NO_COLOR") != null) return .none;

    if (getenv("COLORTERM")) |ct| {
        const ct_map = std.StaticStringMap(ColorDepth).initComptime(.{
            .{ "truecolor", .truecolor },
            .{ "24bit", .truecolor },
        });
        if (ct_map.get(ct)) |cap| return cap;
    }

    if (getenv("TERM")) |term| {
        const term_map = std.StaticStringMap(ColorDepth).initComptime(.{
            .{ "dumb", .none },
            .{ "linux", .basic },
            .{ "vt100", .basic },
        });
        if (term_map.get(term)) |cap| return cap;
        if (std.mem.indexOf(u8, term, "256color") != null) return .c256;
    }

    // Most modern terminals support truecolor even without advertising it
    return .truecolor;
}

/// Convert 0-255 channel to 6-level cube index.
fn chanTo6(v: u8) u8 {
    if (v < 48) return 0;
    return @intCast((@as(u16, v) - 35) / 40);
}

/// Reverse: cube index → representative 0-255 value.
fn cubeVal(i: u8) u8 {
    if (i == 0) return 0;
    return @as(u8, i) * 40 + 55;
}

/// Squared distance between two u8 values.
fn sq(a: u8, b: u8) u32 {
    const d: i32 = @as(i32, a) - @as(i32, b);
    return @intCast(d * d);
}

pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Cube approximation
    const cr = chanTo6(r);
    const cg = chanTo6(g);
    const cb = chanTo6(b);
    const cube_idx: u8 = 16 + 36 * cr + 6 * cg + cb;
    const cube_dist = sq(r, cubeVal(cr)) + sq(g, cubeVal(cg)) + sq(b, cubeVal(cb));

    // Grayscale approximation (values 8, 18, 28, ..., 238)
    const avg: u8 = @intCast((@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3);
    const gi: u8 = if (avg < 4) 0 else if (avg > 243) 23 else @intCast((@as(u16, avg) - 3) / 10);
    const gv: u8 = gi * 10 + 8;
    const gray_dist = sq(r, gv) + sq(g, gv) + sq(b, gv);

    if (gray_dist < cube_dist) {
        return 232 + gi;
    }
    return cube_idx;
}

/// Map RGB to nearest basic color (0-7).
pub fn rgbToBasic(r: u8, g: u8, b: u8) u3 {
    // Basic ANSI: 0=black 1=red 2=green 3=yellow 4=blue 5=magenta 6=cyan 7=white
    // Use simple threshold decomposition.
    const rb: u1 = if (r >= 128) 1 else 0;
    const gb: u1 = if (g >= 128) 1 else 0;
    const bb: u1 = if (b >= 128) 1 else 0;
    // ANSI order: bit0=red, bit1=green, bit2=blue
    return @as(u3, bb) << 2 | @as(u3, gb) << 1 | rb;
}

pub fn writeColor(out: anytype, layer: Layer, c: frame.Color, cap: ColorDepth) !void {
    const base = @intFromEnum(layer);
    switch (cap) {
        .none => {},
        .truecolor => switch (c) {
            .default => {},
            .idx => |n| try writeFmt(out, ";{};5;{}", .{ base, n }),
            .rgb => |v| try writeFmt(out, ";{};2;{};{};{}", .{
                base, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff,
            }),
        },
        .c256 => switch (c) {
            .default => {},
            .idx => |n| try writeFmt(out, ";{};5;{}", .{ base, n }),
            .rgb => |v| {
                const r: u8 = @intCast((v >> 16) & 0xff);
                const g: u8 = @intCast((v >> 8) & 0xff);
                const b: u8 = @intCast(v & 0xff);
                try writeFmt(out, ";{};5;{}", .{ base, rgbTo256(r, g, b) });
            },
        },
        .basic => switch (c) {
            .default => {},
            .idx => |n| {
                // idx 0-7 → basic, 8-15 → bright basic, else → convert
                if (n < 8) {
                    const off: u8 = if (base == 38) 30 else 40;
                    try writeFmt(out, ";{}", .{off + n});
                } else if (n < 16) {
                    const off: u8 = if (base == 38) 90 else 100;
                    try writeFmt(out, ";{}", .{off + n - 8});
                } else {
                    // Convert 256-color idx to rgb, then to basic
                    const rgb = idx256ToRgb(n);
                    const bi = rgbToBasic(rgb[0], rgb[1], rgb[2]);
                    const off: u8 = if (base == 38) 30 else 40;
                    try writeFmt(out, ";{}", .{off + @as(u8, bi)});
                }
            },
            .rgb => |v| {
                const r: u8 = @intCast((v >> 16) & 0xff);
                const g: u8 = @intCast((v >> 8) & 0xff);
                const b: u8 = @intCast(v & 0xff);
                const bi = rgbToBasic(r, g, b);
                const off: u8 = if (base == 38) 30 else 40;
                try writeFmt(out, ";{}", .{off + @as(u8, bi)});
            },
        },
    }
}

fn idx256ToRgb(n: u8) [3]u8 {
    if (n < 16) {
        // Standard colors - approximate
        const table = [16][3]u8{
            .{ 0, 0, 0 },       .{ 128, 0, 0 },   .{ 0, 128, 0 },   .{ 128, 128, 0 },
            .{ 0, 0, 128 },     .{ 128, 0, 128 }, .{ 0, 128, 128 }, .{ 192, 192, 192 },
            .{ 128, 128, 128 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
            .{ 0, 0, 255 },     .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
        };
        return table[n];
    } else if (n < 232) {
        const ci = n - 16;
        const ri = ci / 36;
        const gi = (ci % 36) / 6;
        const bi = ci % 6;
        return .{ cubeVal(ri), cubeVal(gi), cubeVal(bi) };
    } else {
        const v = (n - 232) * 10 + 8;
        return .{ v, v, v };
    }
}

pub const Layer = enum(u8) {
    fg = 38,
    bg = 48,
};

/// Inferred terminal background luminance from the COLORFGBG env var.
pub const TermBg = enum { dark, light };

/// Classify a single COLORFGBG color index into a background luminance.
///
/// Convention (matches widely deployed terminals): the 16 ANSI palette
/// slots split as
///   - dark backgrounds:  0,1,2,3,4,5,6  and 8 (bright black)
///   - light backgrounds: 7 (white) and 9..15 (bright colors)
/// Index 8 is deliberately treated as dark because it is "bright black",
/// while 7 ("white") is the canonical light-background marker.
fn bgFromIndex(idx: u8) ?TermBg {
    return switch (idx) {
        0...6, 8 => .dark,
        7, 9...15 => .light,
        else => null, // out of the 0..15 palette: no reliable signal
    };
}

/// Detect terminal background luminance from a COLORFGBG value.
///
/// `value` is the raw COLORFGBG string (or null when the var is unset).
/// COLORFGBG is "fg;bg" or, on some terminals, "fg;default;bg"; the
/// background is always the last semicolon-separated field. The field is
/// parsed as a decimal palette index and classified via `bgFromIndex`.
///
/// Returns null — meaning "no usable signal" — when:
///   - `value` is null (var unset),
///   - the string is empty or has no background field,
///   - the background field is not a base-10 integer, or
///   - the index falls outside the 0..15 ANSI palette.
/// The caller is responsible for choosing an explicit default; this
/// function never guesses a luminance from malformed input.
pub fn detectTermBg(value: ?[]const u8) ?TermBg {
    const raw = value orelse return null;
    // Background is the final field; supports both "fg;bg" and
    // "fg;default;bg" layouts.
    const sep = std.mem.lastIndexOfScalar(u8, raw, ';') orelse return null;
    const bg_str = raw[sep + 1 ..];
    if (bg_str.len == 0) return null;
    const idx = std.fmt.parseInt(u8, bg_str, 10) catch return null;
    return bgFromIndex(idx);
}

/// Thin env-reading wrapper: reads COLORFGBG and classifies it.
/// Kept separate from `detectTermBg` so the parsing logic stays unit
/// testable without mutating the real process environment.
pub fn detectTermBgFromEnv() ?TermBg {
    return detectTermBg(getenvRuntime("COLORFGBG"));
}

/// Runtime env read for variables not known at comptime (COLORFGBG is not
/// a field of the comptime `environString` table). Mirrors the env-access
/// pattern used elsewhere in the codebase (e.g. theme.zig, image.zig).
fn getenvRuntime(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
}

fn writeFmt(out: anytype, comptime fmt: []const u8, args: anytype) !void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.NoSpaceLeft;
    try out.writeAll(msg);
}

// ---- Tests ----

test "rgbTo256 pure black" {
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
}

test "rgbTo256 pure white" {
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
}

test "rgbTo256 midgray hits grayscale ramp" {
    const idx = rgbTo256(128, 128, 128);
    // Should be in grayscale range 232-255
    try std.testing.expect(idx >= 232 and idx <= 255);
    // Value should be close to 128: idx 232+12 = 244, val = 128
    try std.testing.expectEqual(@as(u8, 244), idx);
}

test "rgbTo256 saturated red" {
    // Pure red (255,0,0) → cube index 16 + 36*5 + 0 + 0 = 196
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
}

test "rgbTo256 saturated green" {
    try std.testing.expectEqual(@as(u8, 46), rgbTo256(0, 255, 0));
}

test "rgbTo256 saturated blue" {
    try std.testing.expectEqual(@as(u8, 21), rgbTo256(0, 0, 255));
}

test "rgbToBasic thresholds" {
    try std.testing.expectEqual(@as(u3, 0), rgbToBasic(0, 0, 0)); // black
    try std.testing.expectEqual(@as(u3, 7), rgbToBasic(255, 255, 255)); // white
    try std.testing.expectEqual(@as(u3, 1), rgbToBasic(255, 0, 0)); // red
    try std.testing.expectEqual(@as(u3, 2), rgbToBasic(0, 255, 0)); // green
    try std.testing.expectEqual(@as(u3, 4), rgbToBasic(0, 0, 255)); // blue
    try std.testing.expectEqual(@as(u3, 3), rgbToBasic(255, 255, 0)); // yellow
    try std.testing.expectEqual(@as(u3, 5), rgbToBasic(255, 0, 255)); // magenta
    try std.testing.expectEqual(@as(u3, 6), rgbToBasic(0, 255, 255)); // cyan
}

test "writeColor truecolor emits rgb" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff8000 }, .truecolor);
    try std.testing.expectEqualStrings(";38;2;255;128;0", out.view());
}

test "writeColor c256 converts rgb to index" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff0000 }, .c256);
    try std.testing.expectEqualStrings(";38;5;196", out.view());
}

test "writeColor basic converts rgb" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff0000 }, .basic);
    try std.testing.expectEqualStrings(";31", out.view());
}

test "writeColor none emits nothing" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff0000 }, .none);
    try std.testing.expectEqualStrings("", out.view());
}

test "writeColor basic idx passthrough for 0-7" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .idx = 3 }, .basic);
    try std.testing.expectEqualStrings(";33", out.view());
}

test "writeColor basic bg idx" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .bg, .{ .idx = 1 }, .basic);
    try std.testing.expectEqualStrings(";41", out.view());
}

test "detectTermBg dark bg index 0" {
    try std.testing.expectEqual(TermBg.dark, detectTermBg("15;0").?);
}

test "detectTermBg light bg index 15" {
    try std.testing.expectEqual(TermBg.light, detectTermBg("0;15").?);
}

test "detectTermBg index 7 is light, index 8 is dark" {
    // 7 = white (light bg), 8 = bright black (dark bg)
    try std.testing.expectEqual(TermBg.light, detectTermBg("0;7").?);
    try std.testing.expectEqual(TermBg.dark, detectTermBg("15;8").?);
}

test "detectTermBg handles fg;default;bg layout" {
    try std.testing.expectEqual(TermBg.light, detectTermBg("15;default;15").?);
    try std.testing.expectEqual(TermBg.dark, detectTermBg("15;default;0").?);
}

test "detectTermBg null when var unset" {
    try std.testing.expect(detectTermBg(null) == null);
}

test "detectTermBg null on malformed input" {
    try std.testing.expect(detectTermBg("") == null);
    try std.testing.expect(detectTermBg("nosemicolon") == null);
    try std.testing.expect(detectTermBg("15;") == null);
    try std.testing.expect(detectTermBg("15;abc") == null);
    try std.testing.expect(detectTermBg("15;999") == null); // out of u8 range
    try std.testing.expect(detectTermBg("15;42") == null); // outside 0..15 palette
}

const TestBuf = @import("test_buf.zig").TestBuf;
