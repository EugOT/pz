//! Application layer: CLI parsing, config, and runtime orchestration.
const std = @import("std");

pub const args = @import("app/args.zig");
pub const cli = @import("app/cli.zig");
pub const config = @import("app/config.zig");
pub const report = @import("app/report.zig");
pub const runtime = @import("app/runtime.zig");
pub const update = @import("app/update.zig");

pub fn run(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    var env = try config.Env.fromMap(alloc, init.environ_map);
    defer env.deinit(alloc);
    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    var out = &out_file.interface;
    defer out.flush() catch {};

    var cmd = cli.parse(alloc, init.io, std.Io.Dir.cwd(), argv[1..], env) catch |err| {
        if (err == error.OutOfMemory) return err;
        const msg = try report.cli(alloc, "parse arguments", err);
        try out.writeAll(msg);
        try out.flush();
        return 1;
    };
    defer cmd.deinit(alloc);

    switch (cmd) {
        .help => |txt| try out.writeAll(txt),
        .version => |txt| try out.writeAll(txt),
        .changelog => |txt| try out.writeAll(txt),
        .upgrade => {
            const outcome = try update.runOutcome(alloc, init.io, init.environ_map, env.home);
            defer outcome.deinit(alloc);
            try out.writeAll(outcome.msg);
        },
        .run => |run_cmd| {
            const sid = runtime.exec(alloc, run_cmd) catch |err| {
                if (err == error.OutOfMemory) return err;
                const msg = try report.cli(alloc, "run command", err);
                try out.writeAll(msg);
                try out.flush();
                return 1;
            };
            alloc.free(sid);
        },
    }
    try out.flush();
    return 0;
}
