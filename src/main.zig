//! Entry point.
const std = @import("std");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !u8 {
    return try app.run(init);
}
