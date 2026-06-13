//! Test mock: UDP syslog collector.
const std = @import("std");
const net = std.Io.net;
const max_msgs: usize = 16;
const max_msg_len: usize = 4096;

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn connectLocal(port: u16) !net.Stream {
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    return addr.connect(defaultIo(), .{ .mode = .stream });
}

fn fdWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
    return @intCast(rc);
}

fn fdWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try fdWrite(fd, bytes[off..]);
}

pub const UdpCollector = struct {
    socket: net.Socket,
    goal: usize = 1,
    count: usize = 0,
    bufs: [max_msgs][max_msg_len]u8 = undefined,
    lens: [max_msgs]usize = [_]usize{0} ** max_msgs,

    pub fn init() !UdpCollector {
        const addr = try net.IpAddress.parse("127.0.0.1", 0);
        const socket = try addr.bind(defaultIo(), .{ .mode = .dgram, .protocol = .udp });
        return .{ .socket = socket };
    }

    pub fn deinit(self: *UdpCollector) void {
        self.socket.close(defaultIo());
        self.* = undefined;
    }

    pub fn port(self: *const UdpCollector) u16 {
        return self.socket.address.getPort();
    }

    pub fn spawn(self: *UdpCollector) !std.Thread {
        return self.spawnCount(1);
    }

    pub fn spawnCount(self: *UdpCollector, n: usize) !std.Thread {
        if (n == 0 or n > max_msgs) return error.InvalidCount;
        self.goal = n;
        self.count = 0;
        self.lens = [_]usize{0} ** max_msgs;
        return std.Thread.spawn(.{}, runUdp, .{self});
    }

    pub fn message(self: *const UdpCollector) []const u8 {
        return self.messageAt(0);
    }

    pub fn messageAt(self: *const UdpCollector, idx: usize) []const u8 {
        return self.bufs[idx][0..self.lens[idx]];
    }

    pub fn msgCount(self: *const UdpCollector) usize {
        return self.count;
    }
};

pub const TcpCollector = struct {
    server: net.Server,
    goal: usize = 1,
    count: usize = 0,
    bufs: [max_msgs][max_msg_len]u8 = undefined,
    lens: [max_msgs]usize = [_]usize{0} ** max_msgs,

    pub fn init() !TcpCollector {
        const addr = try net.IpAddress.parse("127.0.0.1", 0);
        const server = try addr.listen(defaultIo(), .{ .reuse_address = true });
        return .{ .server = server };
    }

    pub fn deinit(self: *TcpCollector) void {
        self.server.deinit(defaultIo());
        self.* = undefined;
    }

    pub fn port(self: *const TcpCollector) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn spawn(self: *TcpCollector) !std.Thread {
        return self.spawnCount(1);
    }

    pub fn spawnCount(self: *TcpCollector, n: usize) !std.Thread {
        if (n == 0 or n > max_msgs) return error.InvalidCount;
        self.goal = n;
        self.count = 0;
        self.lens = [_]usize{0} ** max_msgs;
        return std.Thread.spawn(.{}, runTcp, .{self});
    }

    pub fn message(self: *const TcpCollector) []const u8 {
        return self.messageAt(0);
    }

    pub fn messageAt(self: *const TcpCollector, idx: usize) []const u8 {
        return self.bufs[idx][0..self.lens[idx]];
    }

    pub fn msgCount(self: *const TcpCollector) usize {
        return self.count;
    }
};

fn runUdp(self: *UdpCollector) void {
    while (self.count < self.goal) : (self.count += 1) {
        self.lens[self.count] = recvUdp(&self.socket, self.bufs[self.count][0..]) catch return;
    }
}

fn runTcp(self: *TcpCollector) void {
    while (self.count < self.goal) {
        const conn = self.server.accept(defaultIo()) catch return;
        defer conn.close(defaultIo());
        while (self.count < self.goal) {
            self.lens[self.count] = readOctetFrame(conn.socket.handle, self.bufs[self.count][0..]) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return,
            };
            self.count += 1;
        }
    }
}

fn recvUdp(socket: *const net.Socket, buf: []u8) !usize {
    const msg = try socket.receive(defaultIo(), buf);
    return msg.data.len;
}

fn readOctetFrame(fd: std.posix.socket_t, buf: []u8) !usize {
    var len_buf: [32]u8 = undefined;
    var len_used: usize = 0;

    while (true) {
        var byte: [1]u8 = undefined;
        const got = try readFd(fd, byte[0..]);
        if (got == 0) return error.EndOfStream;
        if (byte[0] == ' ') break;
        if (byte[0] < '0' or byte[0] > '9') return error.InvalidFrame;
        if (len_used >= len_buf.len) return error.FrameTooLarge;
        len_buf[len_used] = byte[0];
        len_used += 1;
    }
    if (len_used == 0) return error.InvalidFrame;

    const frame_len = try std.fmt.parseInt(usize, len_buf[0..len_used], 10);
    if (frame_len > buf.len) return error.FrameTooLarge;

    var off: usize = 0;
    while (off < frame_len) {
        const got = try readFd(fd, buf[off..frame_len]);
        if (got == 0) return error.EndOfStream;
        off += got;
    }
    return frame_len;
}

fn readFd(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.FileDescriptorClosed,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

test "udp collector captures datagram" {
    var collector = try UdpCollector.init();
    defer collector.deinit();

    const t = try collector.spawn();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const socket = try bind_addr.bind(defaultIo(), .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(defaultIo());
    var dest = try net.IpAddress.parse("127.0.0.1", collector.port());
    try socket.send(defaultIo(), &dest, "udp-mock");

    t.join();
    try std.testing.expectEqualStrings("udp-mock", collector.message());
}

test "udp collector captures multiple datagrams" {
    var collector = try UdpCollector.init();
    defer collector.deinit();

    const t = try collector.spawnCount(2);

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const socket = try bind_addr.bind(defaultIo(), .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(defaultIo());
    var dest = try net.IpAddress.parse("127.0.0.1", collector.port());
    try socket.send(defaultIo(), &dest, "udp-1");
    try socket.send(defaultIo(), &dest, "udp-2");

    t.join();
    try std.testing.expectEqual(@as(usize, 2), collector.msgCount());
    try std.testing.expectEqualStrings("udp-1", collector.messageAt(0));
    try std.testing.expectEqualStrings("udp-2", collector.messageAt(1));
}

test "tcp collector captures octet-counted frame" {
    var collector = try TcpCollector.init();
    defer collector.deinit();

    const t = try collector.spawn();

    const stream = try connectLocal(collector.port());
    defer stream.close(defaultIo());
    try fdWriteAll(stream.socket.handle, "8 tcp-mock");

    t.join();
    try std.testing.expectEqualStrings("tcp-mock", collector.message());
}

test "tcp collector captures multiple octet-counted frames" {
    var collector = try TcpCollector.init();
    defer collector.deinit();

    const t = try collector.spawnCount(2);

    const stream = try connectLocal(collector.port());
    defer stream.close(defaultIo());
    try fdWriteAll(stream.socket.handle, "5 tcp-1");
    try fdWriteAll(stream.socket.handle, "5 tcp-2");

    t.join();
    try std.testing.expectEqual(@as(usize, 2), collector.msgCount());
    try std.testing.expectEqualStrings("tcp-1", collector.messageAt(0));
    try std.testing.expectEqualStrings("tcp-2", collector.messageAt(1));
}
