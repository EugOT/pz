//! Canonical JSON string encoder.
const std = @import("std");

/// Write a JSON-escaped string (with surrounding quotes) to `w`.
/// Handles ALL control chars 0x00-0x1f per RFC 8259.
pub fn writeJsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\x08' => try w.writeAll("\\b"),
            '\x0c' => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x07, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                const esc = [6]u8{
                    '\\',
                    'u',
                    '0',
                    '0',
                    hex[c >> 4],
                    hex[c & 0x0f],
                };
                try w.writeAll(&esc);
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "writeJsonStr escapes control chars" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();

    try writeJsonStr(&buf.writer, "a\x00b\x1f\n\r\t\"\\\x08\x0c");
    const got = try buf.toOwnedSlice();
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "\"a\\u0000b\\u001f\\n\\r\\t\\\"\\\\\\b\\f\"",
        got,
    );
}
