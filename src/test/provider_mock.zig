//! Test mock: scripted provider with canned responses.
const std = @import("std");
const providers = @import("../core/providers.zig");

fn errnoError(rc: isize) !void {
    if (rc >= 0) return;
    return std.posix.unexpectedErrno(std.posix.errno(rc));
}

fn fdRead(fd: std.posix.fd_t, buf: []u8) !usize {
    const rc = std.c.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        const err = std.posix.errno(rc);
        // A non-blocking wake pipe with no data returns EAGAIN/EWOULDBLOCK.
        // The drain loop relies on this to stop; do NOT route it through
        // unexpectedErrno, which prints "unexpected errno: 35" and dumps a
        // stack trace in Debug test builds (flagging the test as failed).
        switch (err) {
            .AGAIN => return error.WouldBlock,
            else => return std.posix.unexpectedErrno(err),
        }
    }
    return @intCast(rc);
}

fn fdWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
    return @intCast(rc);
}

fn setNonblock(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    try errnoError(flags);
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    try errnoError(std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock));
}

fn setCloexec(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0));
    try errnoError(flags);
    try errnoError(std.c.fcntl(fd, std.posix.F.SETFD, flags | @as(c_int, std.posix.FD_CLOEXEC)));
}

pub const Step = union(enum) {
    ev: providers.Event,
    block: void,
};

pub const ScriptedProvider = struct {
    provider: providers.Provider = .{ .vt = &provider_vt },
    stream: providers.Stream = .{ .vt = &StreamBind.vt },
    aborter: providers.Aborter = .{ .vt = &StreamBind.aborter_vt },
    steps: []const Step,
    idx: usize = 0,
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,

    const provider_vt = providers.Provider.Vt{
        .start = providerStart,
    };

    const StreamBind = providers.Stream.BindAbortable(ScriptedProvider, streamNextImpl, streamDeinitImpl, streamAbortImpl);

    pub fn init(steps: []const Step) !ScriptedProvider {
        var pipe: [2]std.posix.fd_t = undefined;
        try errnoError(std.c.pipe(&pipe));
        errdefer _ = std.c.close(pipe[0]);
        errdefer _ = std.c.close(pipe[1]);
        try setCloexec(pipe[0]);
        try setCloexec(pipe[1]);
        try setNonblock(pipe[0]);
        try setNonblock(pipe[1]);
        return .{
            .steps = steps,
            .wake_r = pipe[0],
            .wake_w = pipe[1],
        };
    }

    pub fn deinit(self: *ScriptedProvider) void {
        _ = std.c.close(self.wake_r);
        _ = std.c.close(self.wake_w);
        self.* = undefined;
    }

    fn providerStart(p: *providers.Provider, _: providers.Request) !*providers.Stream {
        const self: *ScriptedProvider = @fieldParentPtr("provider", p);
        self.reset();
        return &self.stream;
    }

    fn streamNextImpl(self: *ScriptedProvider) anyerror!?providers.Event {
        if (self.idx >= self.steps.len) return null;
        const step = self.steps[self.idx];
        self.idx += 1;
        return switch (step) {
            .ev => |ev| ev,
            .block => blk: {
                var fds = [1]std.posix.pollfd{.{
                    .fd = self.wake_r,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&fds, -1);
                var buf: [8]u8 = undefined;
                _ = fdRead(self.wake_r, &buf) catch {}; // test: error irrelevant
                break :blk null;
            },
        };
    }

    pub fn streamAbortImpl(self: *ScriptedProvider) void {
        _ = fdWrite(self.wake_w, "\x01") catch {}; // test: error irrelevant
    }

    fn streamDeinitImpl(_: *ScriptedProvider) void {}

    fn reset(self: *ScriptedProvider) void {
        self.idx = 0;
        var buf: [32]u8 = undefined;
        while (true) {
            _ = fdRead(self.wake_r, &buf) catch break;
        }
    }
};

test "scripted provider emits events then aborts blocked stream" {
    const steps = [_]Step{
        .{ .ev = .{ .text = "hello" } },
        .{ .block = {} },
    };
    var provider = try ScriptedProvider.init(steps[0..]);
    defer provider.deinit();

    var stream = try provider.provider.start(.{
        .model = "m",
        .provider = null,
        .msgs = &.{},
        .tools = &.{},
        .opts = .{},
    });
    defer stream.deinit();

    const one = (try stream.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", one.text);

    const thr = try std.Thread.spawn(.{}, ScriptedProvider.streamAbortImpl, .{&provider});
    defer thr.join();
    try std.testing.expect((try stream.next()) == null);
}
