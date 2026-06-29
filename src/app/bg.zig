//! Background job management: spawn, track, and reap child processes.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("../core.zig");
const event_loop = @import("../core/event_loop.zig");
const EventLoop = event_loop.EventLoop;
const journal_mod = @import("job_journal.zig");
const sandbox = @import("../core/sandbox.zig");
const shell = @import("../core/shell.zig");
const syslog_mock = @import("../test/syslog_mock.zig");

fn defaultIo() std.Io {
    return @import("../core/rt_io.zig").default();
}

fn currentEnvMap(alloc: std.mem.Allocator) !std.process.Environ.Map {
    var env_len: usize = 0;
    while (std.c.environ[env_len] != null) : (env_len += 1) {}
    return std.process.Environ.createMap(.{
        .block = .{ .slice = std.c.environ[0..env_len :null] },
    }, alloc);
}

const Mutex = struct {
    inner: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(defaultIo());
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock(defaultIo());
    }
};

pub const State = enum {
    running,
    exited,
    signaled,
    stopped,
    unknown,
    wait_err,
};

pub fn stateName(st: State) []const u8 {
    return switch (st) {
        .running => "running",
        .exited => "exited",
        .signaled => "signaled",
        .stopped => "stopped",
        .unknown => "unknown",
        .wait_err => "wait_err",
    };
}

pub const StopResult = enum {
    sent,
    already_done,
    not_found,
};

pub const View = struct {
    id: u64,
    pid: i32,
    cmd: []u8,
    log_path: []u8,
    state: State,
    code: ?i32,
    started_at_ms: i64,
    ended_at_ms: ?i64,
    err_name: ?[]const u8,
};

pub fn deinitViews(alloc: std.mem.Allocator, views: []View) void {
    for (views) |v| {
        alloc.free(v.cmd);
        alloc.free(v.log_path);
    }
    alloc.free(views);
}

pub fn deinitView(alloc: std.mem.Allocator, v: View) void {
    alloc.free(v.cmd);
    alloc.free(v.log_path);
}

const WaitCtx = struct {
    mgr: *Manager,
    job_id: u64,
    child: std.process.Child,
};

const Job = struct {
    id: u64,
    pid: i32,
    cmd: []u8,
    log_path: []u8,
    state: State = .running,
    code: ?i32 = null,
    started_at_ms: i64,
    ended_at_ms: ?i64 = null,
    err_name: ?[]const u8 = null,
    thr: ?std.Thread = null,
    ctx: *WaitCtx,
};

pub const Manager = struct {
    pub const Opts = struct {
        state_dir: ?[]const u8 = null,
        home: ?[]const u8 = null,
        tmp_dir: []const u8 = "/tmp",
        pz_state_dir: ?[]const u8 = null,
        xdg_state_home: ?[]const u8 = null,
        recover: bool = true,
        audit_emitter: ?*core.audit.Emitter = null,
        now_ms: *const fn () i64 = nowMs,
        policy: ?core.policy.Policy = null,
    };

    alloc: std.mem.Allocator,
    mu: Mutex = .{},
    audit_mu: Mutex = .{},
    jobs: std.ArrayListUnmanaged(Job) = .empty,
    done: std.ArrayListUnmanaged(u64) = .empty,
    next_id: u64 = 1,
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,
    journal: journal_mod.Journal,
    tmp_dir: []const u8 = "/tmp",
    home: ?[]const u8 = null,
    audit_emitter: ?*core.audit.Emitter = null,
    now_ms: *const fn () i64 = nowMs,
    policy: ?core.policy.Policy = null,
    audit_seq: u64 = 1,

    pub fn init(alloc: std.mem.Allocator) !Manager {
        return initWithOpts(alloc, .{});
    }

    pub fn initWithOpts(alloc: std.mem.Allocator, opts: Opts) !Manager {
        const pipe = try makePipe(true);
        errdefer {
            closeFd(pipe[0]);
            closeFd(pipe[1]);
        }

        var out: Manager = .{
            .alloc = alloc,
            .wake_r = pipe[0],
            .wake_w = pipe[1],
            .journal = try journal_mod.Journal.init(alloc, .{
                .state_dir = opts.state_dir,
                .home = opts.home,
                .pz_state_dir = opts.pz_state_dir,
                .xdg_state_home = opts.xdg_state_home,
            }),
            .tmp_dir = opts.tmp_dir,
            .home = opts.home,
            .audit_emitter = opts.audit_emitter,
            .now_ms = opts.now_ms,
            .policy = opts.policy,
        };
        errdefer out.journal.deinit();

        if (opts.recover) {
            try out.recoverStale();
        }
        return out;
    }

    pub fn deinit(self: *Manager) void {
        self.mu.lock();
        for (self.jobs.items) |job| {
            if (job.state == .running) {
                const p: std.posix.pid_t = @intCast(job.pid);
                const tgt: std.posix.pid_t = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) -p else p;
                _ = std.posix.kill(tgt, std.posix.SIG.KILL) catch {}; // cleanup: propagation impossible
                self.journal.appendCleanup(job.id, "shutdown_kill") catch {}; // cleanup: propagation impossible
            }
        }
        self.mu.unlock();

        var i: usize = 0;
        while (true) : (i += 1) {
            var thr: ?std.Thread = null;

            self.mu.lock();
            if (i >= self.jobs.items.len) {
                self.mu.unlock();
                break;
            }
            thr = self.jobs.items[i].thr;
            self.jobs.items[i].thr = null;
            self.mu.unlock();

            if (thr) |t| t.join();
        }

        self.mu.lock();
        for (self.jobs.items) |job| {
            self.alloc.destroy(job.ctx);
            self.alloc.free(job.cmd);
            self.alloc.free(job.log_path);
        }
        self.jobs.deinit(self.alloc);
        self.done.deinit(self.alloc);
        self.mu.unlock();

        closeFd(self.wake_r);
        closeFd(self.wake_w);
        self.journal.deinit();
        self.* = undefined;
    }

    pub fn wakeFd(self: *const Manager) std.posix.fd_t {
        return self.wake_r;
    }

    pub fn start(self: *Manager, cmd_raw: []const u8, cwd: ?[]const u8) !u64 {
        const cmd = std.mem.trim(u8, cmd_raw, " \t");
        const cwd_txt = cwd orelse "";
        const start_attrs = [_]core.audit.Attribute{
            .{ .key = "cwd", .vis = .mask, .val = .{ .str = cwd_txt } },
        };
        try self.emitControlAudit(.{
            .op = "start",
            .msg = .{ .text = "bg control start", .vis = .@"pub" },
            .argv = .{ .text = cmd, .vis = .mask },
            .attrs = &start_attrs,
        });
        if (cmd.len == 0) {
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = "InvalidArgs", .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return error.InvalidArgs;
        }
        if (try shell.touchesProtectedPath(self.alloc, cmd) or
            (if (self.policy) |pol| try shell.deniedByPolicy(self.alloc, cmd, pol) else false))
        {
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = "Denied", .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return error.AccessDenied;
        }

        const id = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            const out = self.next_id;
            self.next_id +%= 1;
            break :blk out;
        };

        const log_path = try self.mkLogPath(id);
        errdefer self.alloc.free(log_path);

        const cmd_dup = try self.alloc.dupe(u8, cmd);
        errdefer self.alloc.free(cmd_dup);

        var env = try currentEnvMap(self.alloc);
        defer env.deinit();
        sandbox.scrubEnv(&env);
        try env.put("PZ_BG_LOG", log_path);

        const wrapped = try std.fmt.allocPrint(self.alloc, "({s}) >\"${{PZ_BG_LOG}}\" 2>&1", .{cmd});
        defer self.alloc.free(wrapped);

        const argv = [_][]const u8{
            "/bin/bash",
            "-lc",
            wrapped,
        };

        const is_posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;
        var child = std.process.spawn(defaultIo(), .{
            .argv = argv[0..],
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env,
            .pgid = if (is_posix) 0 else null,
        }) catch |err| {
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(err), .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return err;
        };

        const ctx = try self.alloc.create(WaitCtx);
        errdefer self.alloc.destroy(ctx);
        ctx.* = .{
            .mgr = self,
            .job_id = id,
            .child = child,
        };

        const pid: i32 = @intCast(child.id.?);
        const started_at_ms = core.time.milliTimestamp();

        self.journal.appendLaunch(id, pid, cmd_dup, log_path, started_at_ms) catch |err| {
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(err), .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return err;
        };

        self.mu.lock();
        const idx = self.jobs.items.len;
        self.jobs.append(self.alloc, .{
            .id = id,
            .pid = pid,
            .cmd = cmd_dup,
            .log_path = log_path,
            .state = .running,
            .code = null,
            .started_at_ms = started_at_ms,
            .ended_at_ms = null,
            .err_name = null,
            .thr = null,
            .ctx = ctx,
        }) catch |append_err| {
            self.mu.unlock();
            child.kill(defaultIo()); // cleanup: propagation impossible
            self.journal.appendCleanup(id, "start_append_fail") catch {}; // cleanup: propagation impossible
            self.alloc.destroy(ctx);
            self.alloc.free(cmd_dup);
            self.alloc.free(log_path);
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(append_err), .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return append_err;
        };
        self.mu.unlock();

        const thr = std.Thread.spawn(.{}, waitThread, .{ctx}) catch |spawn_err| {
            child.kill(defaultIo()); // cleanup: propagation impossible
            self.journal.appendCleanup(id, "start_spawn_fail") catch {}; // cleanup: propagation impossible

            self.mu.lock();
            if (idx < self.jobs.items.len and self.jobs.items[idx].id == id) {
                const removed = self.jobs.orderedRemove(idx);
                self.mu.unlock();
                self.alloc.destroy(removed.ctx);
                self.alloc.free(removed.cmd);
                self.alloc.free(removed.log_path);
            } else {
                self.mu.unlock();
            }
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(spawn_err), .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return spawn_err;
        };

        self.mu.lock();
        if (idx < self.jobs.items.len and self.jobs.items[idx].id == id) {
            self.jobs.items[idx].thr = thr;
        } else {
            self.mu.unlock();
            thr.join();
            self.journal.appendCleanup(id, "start_internal_error") catch {}; // cleanup: propagation impossible
            try self.emitControlAudit(.{
                .op = "start",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = "InternalError", .vis = .mask },
                .argv = .{ .text = cmd, .vis = .mask },
                .attrs = &start_attrs,
            });
            return error.InternalError;
        }
        self.mu.unlock();

        const ok_attrs = [_]core.audit.Attribute{
            .{ .key = "job_id", .val = .{ .uint = id } },
            .{ .key = "pid", .val = .{ .uint = @intCast(pid) } },
            .{ .key = "cwd", .vis = .mask, .val = .{ .str = cwd_txt } },
            .{ .key = "log_path", .vis = .mask, .val = .{ .str = log_path } },
        };
        try self.emitControlAudit(.{
            .op = "start",
            .msg = .{ .text = "bg control success", .vis = .@"pub" },
            .argv = .{ .text = cmd, .vis = .mask },
            .attrs = &ok_attrs,
        });
        return id;
    }

    pub fn stop(self: *Manager, id: u64) !StopResult {
        const start_attrs = [_]core.audit.Attribute{
            .{ .key = "job_id", .val = .{ .uint = id } },
        };
        try self.emitControlAudit(.{
            .op = "stop",
            .msg = .{ .text = "bg control start", .vis = .@"pub" },
            .attrs = &start_attrs,
        });
        self.mu.lock();
        const idx = self.findIdxLocked(id) orelse {
            self.mu.unlock();
            const fail_attrs = [_]core.audit.Attribute{
                .{ .key = "job_id", .val = .{ .uint = id } },
                .{ .key = "status", .val = .{ .str = "not_found" } },
            };
            try self.emitControlAudit(.{
                .op = "stop",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = "bg not found", .vis = .@"pub" },
                .attrs = &fail_attrs,
            });
            return .not_found;
        };
        const job = self.jobs.items[idx];
        if (job.state != .running) {
            self.mu.unlock();
            const done_attrs = [_]core.audit.Attribute{
                .{ .key = "job_id", .val = .{ .uint = id } },
                .{ .key = "status", .val = .{ .str = "already_done" } },
            };
            try self.emitControlAudit(.{
                .op = "stop",
                .msg = .{ .text = "bg control success", .vis = .@"pub" },
                .attrs = &done_attrs,
            });
            return .already_done;
        }
        const pid: std.posix.pid_t = @intCast(job.pid);
        self.mu.unlock();

        // Signal the entire process group (negative pid).
        const sig_target: std.posix.pid_t = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) -pid else pid;
        std.posix.kill(sig_target, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => {
                try self.emitStopAlreadyDone(id);
                return .already_done;
            },
            error.PermissionDenied => {
                if (self.waitForStopRaceDone(id)) {
                    try self.emitStopAlreadyDone(id);
                    return .already_done;
                }
                try self.emitControlAudit(.{
                    .op = "stop",
                    .outcome = .fail,
                    .severity = .err,
                    .msg = .{ .text = @errorName(err), .vis = .mask },
                    .attrs = &start_attrs,
                });
                return err;
            },
            else => {
                try self.emitControlAudit(.{
                    .op = "stop",
                    .outcome = .fail,
                    .severity = .err,
                    .msg = .{ .text = @errorName(err), .vis = .mask },
                    .attrs = &start_attrs,
                });
                return err;
            },
        };
        const ok_attrs = [_]core.audit.Attribute{
            .{ .key = "job_id", .val = .{ .uint = id } },
            .{ .key = "status", .val = .{ .str = "sent" } },
        };
        try self.emitControlAudit(.{
            .op = "stop",
            .msg = .{ .text = "bg control success", .vis = .@"pub" },
            .attrs = &ok_attrs,
        });
        return .sent;
    }

    fn emitStopAlreadyDone(self: *Manager, id: u64) !void {
        const done_attrs = [_]core.audit.Attribute{
            .{ .key = "job_id", .val = .{ .uint = id } },
            .{ .key = "status", .val = .{ .str = "already_done" } },
        };
        try self.emitControlAudit(.{
            .op = "stop",
            .msg = .{ .text = "bg control success", .vis = .@"pub" },
            .attrs = &done_attrs,
        });
    }

    fn waitForStopRaceDone(self: *Manager, id: u64) bool {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            if (self.isDone(id)) return true;
            std.Io.sleep(defaultIo(), .fromMilliseconds(10), .awake) catch return false;
        }
        return self.isDone(id);
    }

    fn isDone(self: *Manager, id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.findIdxLocked(id) orelse return true;
        return self.jobs.items[idx].state != .running;
    }

    pub fn list(self: *Manager, alloc: std.mem.Allocator) ![]View {
        try self.emitControlAudit(.{
            .op = "list",
            .msg = .{ .text = "bg control start", .vis = .@"pub" },
        });
        self.mu.lock();
        defer self.mu.unlock();

        const out = alloc.alloc(View, self.jobs.items.len) catch |err| {
            try self.emitControlAudit(.{
                .op = "list",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(err), .vis = .mask },
            });
            return err;
        };
        errdefer alloc.free(out);

        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                alloc.free(out[j].cmd);
                alloc.free(out[j].log_path);
            }
            alloc.free(out);
        }

        for (self.jobs.items) |job| {
            out[i] = copyJob(alloc, job) catch |err| {
                try self.emitControlAudit(.{
                    .op = "list",
                    .outcome = .fail,
                    .severity = .err,
                    .msg = .{ .text = @errorName(err), .vis = .mask },
                });
                return err;
            };
            i += 1;
        }
        const ok_attrs = [_]core.audit.Attribute{
            .{ .key = "count", .val = .{ .uint = @intCast(out.len) } },
        };
        try self.emitControlAudit(.{
            .op = "list",
            .msg = .{ .text = "bg control success", .vis = .@"pub" },
            .attrs = &ok_attrs,
        });
        return out;
    }

    pub fn view(self: *Manager, alloc: std.mem.Allocator, id: u64) !?View {
        self.mu.lock();
        defer self.mu.unlock();

        const idx = self.findIdxLocked(id) orelse return null;
        return try copyJob(alloc, self.jobs.items[idx]);
    }

    pub fn drainDone(self: *Manager, alloc: std.mem.Allocator) ![]View {
        try self.emitControlAudit(.{
            .op = "drain",
            .msg = .{ .text = "bg control start", .vis = .@"pub" },
        });
        self.mu.lock();
        const ids = alloc.alloc(u64, self.done.items.len) catch |err| {
            self.mu.unlock();
            try self.emitControlAudit(.{
                .op = "drain",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(err), .vis = .mask },
            });
            return err;
        };
        for (self.done.items, 0..) |id, i| ids[i] = id;
        self.done.clearRetainingCapacity();
        self.mu.unlock();
        defer alloc.free(ids);

        const out = alloc.alloc(View, ids.len) catch |err| {
            try self.emitControlAudit(.{
                .op = "drain",
                .outcome = .fail,
                .severity = .err,
                .msg = .{ .text = @errorName(err), .vis = .mask },
            });
            return err;
        };
        errdefer alloc.free(out);

        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                alloc.free(out[j].cmd);
                alloc.free(out[j].log_path);
            }
            alloc.free(out);
        }

        for (ids) |id| {
            const v = (self.view(alloc, id) catch |err| {
                try self.emitControlAudit(.{
                    .op = "drain",
                    .outcome = .fail,
                    .severity = .err,
                    .msg = .{ .text = @errorName(err), .vis = .mask },
                });
                return err;
            }) orelse {
                try self.emitControlAudit(.{
                    .op = "drain",
                    .outcome = .fail,
                    .severity = .err,
                    .msg = .{ .text = "InternalError", .vis = .mask },
                });
                return error.InternalError;
            };
            out[i] = v;
            i += 1;
        }
        const ok_attrs = [_]core.audit.Attribute{
            .{ .key = "count", .val = .{ .uint = @intCast(out.len) } },
        };
        try self.emitControlAudit(.{
            .op = "drain",
            .msg = .{ .text = "bg control success", .vis = .@"pub" },
            .attrs = &ok_attrs,
        });
        return out;
    }

    fn waitThread(ctx: *WaitCtx) void {
        const wait_term = ctx.child.wait(defaultIo());
        const ended_at_ms = core.time.milliTimestamp();
        ctx.mgr.onExit(ctx.job_id, ended_at_ms, wait_term);
    }

    fn childTermCode(value: anytype) i32 {
        return switch (@typeInfo(@TypeOf(value))) {
            .@"enum" => @intCast(@intFromEnum(value)),
            .int, .comptime_int => @intCast(value),
            else => @compileError("unsupported child wait term payload"),
        };
    }

    fn onExit(self: *Manager, id: u64, ended_at_ms: i64, wait_term: std.process.Child.WaitError!std.process.Child.Term) void {
        self.mu.lock();
        defer self.mu.unlock();

        const idx = self.findIdxLocked(id) orelse return;
        var job = &self.jobs.items[idx];
        job.ended_at_ms = ended_at_ms;

        if (wait_term) |term| {
            switch (term) {
                .exited => |code| {
                    job.state = .exited;
                    job.code = @as(i32, code);
                    job.err_name = null;
                },
                .signal => |sig| {
                    job.state = .signaled;
                    job.code = childTermCode(sig);
                    job.err_name = null;
                },
                .stopped => |sig| {
                    job.state = .stopped;
                    job.code = childTermCode(sig);
                    job.err_name = null;
                },
                .unknown => |sig| {
                    job.state = .unknown;
                    job.code = childTermCode(sig);
                    job.err_name = null;
                },
            }
        } else |wait_err| {
            job.state = .wait_err;
            job.code = null;
            job.err_name = @errorName(wait_err);
        }

        self.journal.appendExit(
            id,
            stateName(job.state),
            job.code,
            ended_at_ms,
            job.err_name,
        ) catch |err| {
            std.log.warn("bg: journal appendExit failed for job {}: {}", .{ id, err });
        };

        self.done.append(self.alloc, job.id) catch |err| {
            std.log.warn("bg: done tracking append failed for job {}: {}", .{ id, err });
        };
        const b = [_]u8{1};
        _ = fdWrite(self.wake_w, &b) catch {}; // cleanup: propagation impossible
    }

    fn recoverStale(self: *Manager) !void {
        const active = try self.journal.replayActive(self.alloc);
        defer journal_mod.deinitActives(self.alloc, active);

        if (active.len == 0) return;

        // Create a temporary event loop to wait for SIGCHLD instead of polling.
        var el = try EventLoop.init();
        defer el.deinit();

        // Dummy handler — we only use el.wait() for the timeout/wake, not callbacks.
        const DummyHandler = struct {
            handler: event_loop.Handler = .{ .vt = &event_loop.Handler.Bind(@This(), onReady).vt },
            fn onReady(_: *@This(), _: std.posix.fd_t, _: bool, _: bool) void {}
        };
        var dummy_handler = DummyHandler{};
        try el.watchSigchld(&dummy_handler.handler);

        for (active) |job| {
            const pid: std.posix.pid_t = @intCast(job.pid);
            // Send TERM, then wait for SIGCHLD with 150ms timeout.
            std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
                error.ProcessNotFound => {
                    try self.journal.appendCleanup(job.id, "startup_reap");
                    continue;
                },
                else => {
                    std.log.warn("bg: TERM signal failed for pid {}: {}", .{ pid, err });
                },
            };

            const reaped = reapAfterSignal(&el, pid);

            if (!reaped) {
                std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
                    error.ProcessNotFound => {},
                    else => {
                        std.log.warn("bg: KILL signal failed for pid {}: {}", .{ pid, err });
                    },
                };
                // Final blocking reap after KILL.
                _ = waitPid(pid, 0) catch {};
            }
            try self.journal.appendCleanup(job.id, "startup_reap");
        }
    }

    /// Wait for a child to exit using SIGCHLD via the event loop (150ms timeout).
    /// Returns true if the child was reaped, false if it's still alive.
    fn reapAfterSignal(el: *EventLoop, pid: std.posix.pid_t) bool {
        var remaining_ms: i32 = 150;
        while (remaining_ms > 0) {
            // Try non-blocking reap first.
            const res = waitPid(pid, std.c.W.NOHANG) catch return false;
            if (res.pid != 0) return true;

            // Wait for SIGCHLD or timeout.
            var ev_buf: [event_loop.max_events]event_loop.Event = undefined;
            _ = el.wait(remaining_ms, &ev_buf) catch return false;

            // After wake, try reaping again. Reduce timeout for next iteration
            // in case SIGCHLD was for a different child.
            remaining_ms -= 50;
        }
        // Final WNOHANG attempt after timeout.
        const res = waitPid(pid, std.c.W.NOHANG) catch return false;
        return res.pid != 0;
    }

    fn findIdxLocked(self: *Manager, id: u64) ?usize {
        for (self.jobs.items, 0..) |job, i| {
            if (job.id == id) return i;
        }
        return null;
    }

    fn mkLogPath(self: *Manager, id: u64) ![]u8 {
        const log_dir = if (self.home) |h|
            try std.fmt.allocPrint(self.alloc, "{s}/.pz/bg", .{h})
        else
            try self.alloc.dupe(u8, self.tmp_dir);
        defer self.alloc.free(log_dir);

        core.fs_secure.ensureDirPath(log_dir) catch {
            // Fall through: createFileAbsolute will fail with a clear error.
        };

        var n: u32 = 0;
        while (n < 64) : (n += 1) {
            const ts = core.time.milliTimestamp();
            const path = try std.fmt.allocPrint(self.alloc, "{s}/pz-bg-{d}-{d}.log", .{
                log_dir,
                id,
                ts + @as(i64, n),
            });

            const f = std.Io.Dir.createFileAbsolute(defaultIo(), path, .{
                .read = true,
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    self.alloc.free(path);
                    continue;
                },
                else => {
                    self.alloc.free(path);
                    return err;
                },
            };
            f.close(defaultIo());
            return path;
        }
        return error.PathAlreadyExists;
    }

    fn emitControlAudit(self: *Manager, req: ControlAudit) !void {
        const e = self.audit_emitter orelse return;
        self.audit_mu.lock();
        const seq = self.audit_seq;
        self.audit_seq +%= 1;
        self.audit_mu.unlock();

        try e.emit(self.alloc, .{
            .ts_ms = self.now_ms(),
            .sid = "bg",
            .seq = seq,
            .severity = req.severity,
            .outcome = req.outcome,
            .actor = .{ .kind = .sys },
            .res = .{
                .kind = .cmd,
                .name = .{ .text = "bg", .vis = .@"pub" },
                .op = req.op,
            },
            .msg = req.msg,
            .data = .{
                .tool = .{
                    .name = .{ .text = "bg", .vis = .@"pub" },
                    .call_id = req.op,
                    .argv = req.argv,
                },
            },
            .attrs = req.attrs,
        });
    }
};

const ControlAudit = struct {
    op: []const u8,
    outcome: core.audit.Outcome = .ok,
    severity: core.audit.Severity = .info,
    msg: ?core.audit.Str,
    argv: ?core.audit.Str = null,
    attrs: []const core.audit.Attribute = &.{},
};

const nowMs = core.time.milliTimestamp;

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn makePipe(nonblocking: bool) ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
    errdefer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    try setCloexec(fds[0]);
    try setCloexec(fds[1]);
    if (nonblocking) {
        try setNonblockFd(fds[0]);
        try setNonblockFd(fds[1]);
    }
    return fds;
}

fn setCloexec(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, @as(c_int, std.posix.F.GETFD), @as(c_int, 0));
    if (flags == -1) return std.posix.unexpectedErrno(std.posix.errno(-1));
    if (std.c.fcntl(fd, @as(c_int, std.posix.F.SETFD), flags | @as(c_int, std.posix.FD_CLOEXEC)) == -1) {
        return std.posix.unexpectedErrno(std.posix.errno(-1));
    }
}

fn setNonblockFd(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, @as(c_int, std.posix.F.GETFL), @as(c_int, 0));
    if (flags == -1) return std.posix.unexpectedErrno(std.posix.errno(-1));
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (std.c.fcntl(fd, @as(c_int, std.posix.F.SETFL), flags | nonblock) == -1) {
        return std.posix.unexpectedErrno(std.posix.errno(-1));
    }
}

fn fdWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

const WaitPidResult = struct {
    pid: std.posix.pid_t,
    status: u32,
};

fn waitPid(pid: std.posix.pid_t, options: c_int) !WaitPidResult {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, options);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{
                .pid = rc,
                .status = @as(u32, @bitCast(status)),
            },
            .INTR => continue,
            .CHILD => return error.ProcessNotFound,
            .INVAL => unreachable,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn copyJob(alloc: std.mem.Allocator, job: Job) !View {
    return .{
        .id = job.id,
        .pid = job.pid,
        .cmd = try alloc.dupe(u8, job.cmd),
        .log_path = try alloc.dupe(u8, job.log_path),
        .state = job.state,
        .code = job.code,
        .started_at_ms = job.started_at_ms,
        .ended_at_ms = job.ended_at_ms,
        .err_name = job.err_name,
    };
}

fn waitWake(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var fds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = try std.posix.poll(&fds, timeout_ms);
    if (n <= 0) return false;
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

const DoneSnap = struct {
    id: u64,
    state: []const u8,
    code: ?i32,
    cmd: []const u8,
    has_log: bool,
    has_out: bool,
    has_err: bool,
};

const JobSnap = struct {
    id: u64,
    state: []const u8,
    code: ?i32,
    cmd: []const u8,
    has_log: bool,
};

fn toJobSnap(v: View) JobSnap {
    return .{
        .id = v.id,
        .state = stateName(v.state),
        .code = v.code,
        .cmd = v.cmd,
        .has_log = v.log_path.len > 0,
    };
}

const ChainSnap = struct {
    lines: u64,
    last_key_id: ?u32,
    has_last_mac: bool,
};

fn toChainSnap(ok: anytype) ChainSnap {
    return .{
        .lines = ok.lines,
        .last_key_id = ok.last_key_id,
        .has_last_mac = ok.last_mac != null,
    };
}

const AuditCap = struct {
    emitter: core.audit.Emitter = .{ .vt = &core.audit.Emitter.Bind(@This(), emitAudit).vt },
    rows: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.rows.items) |row| alloc.free(row);
        self.rows.deinit(alloc);
    }

    fn emitAudit(self: *@This(), alloc: std.mem.Allocator, ent: core.audit.Entry) !void {
        const raw = try core.audit.encodeAlloc(alloc, ent);
        try self.rows.append(alloc, raw);
    }
};

fn scrubBgAudit(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try alloc.dupe(u8, raw);

    const log_pat = "\"key\":\"log_path\",\"vis\":\"mask\",\"ty\":\"str\",\"val\":\"/tmp/pz-bg-";
    if (std.mem.indexOf(u8, out, log_pat)) |log_idx| {
        const start = log_idx + log_pat.len;
        const end_rel = std.mem.indexOfScalar(u8, out[start..], '"') orelse return out;
        const end = start + end_rel;
        const repl = try std.mem.concat(alloc, u8, &.{ out[0..start], "LOG", out[end..] });
        alloc.free(out);
        out = repl;
    }

    const redacted_log_pat = "\"key\":\"log_path\",\"vis\":\"mask\",\"ty\":\"str\",\"val\":\"";
    if (std.mem.indexOf(u8, out, redacted_log_pat)) |log_idx| {
        const start = log_idx + redacted_log_pat.len;
        const end_rel = std.mem.indexOfScalar(u8, out[start..], '"') orelse return out;
        const end = start + end_rel;
        const repl = try std.mem.concat(alloc, u8, &.{ out[0..start], "[mask:LOG]", out[end..] });
        alloc.free(out);
        out = repl;
    }

    const pid_pat = "\"key\":\"pid\",\"vis\":\"pub\",\"ty\":\"uint\",\"val\":";
    if (std.mem.indexOf(u8, out, pid_pat)) |pid_idx| {
        const start = pid_idx + pid_pat.len;
        const end_rel = std.mem.indexOfAny(u8, out[start..], "},") orelse return out;
        const end = start + end_rel;
        const repl = try std.mem.concat(alloc, u8, &.{ out[0..start], "0", out[end..] });
        alloc.free(out);
        out = repl;
    }

    const sent = "\"key\":\"status\",\"vis\":\"pub\",\"ty\":\"str\",\"val\":\"sent\"";
    const done = "\"key\":\"status\",\"vis\":\"pub\",\"ty\":\"str\",\"val\":\"already_done\"";
    if (std.mem.indexOf(u8, out, sent) != null) {
        const repl = try std.mem.replaceOwned(
            u8,
            alloc,
            out,
            sent,
            "\"key\":\"status\",\"vis\":\"pub\",\"ty\":\"str\",\"val\":\"OUTCOME\"",
        );
        alloc.free(out);
        out = repl;
    } else if (std.mem.indexOf(u8, out, done) != null) {
        const repl = try std.mem.replaceOwned(
            u8,
            alloc,
            out,
            done,
            "\"key\":\"status\",\"vis\":\"pub\",\"ty\":\"str\",\"val\":\"OUTCOME\"",
        );
        alloc.free(out);
        out = repl;
    }

    return out;
}

const AuditHdrDoc = struct {
    ts_ms: i64,
    sid: []const u8,
    seq: u64,
    sev: core.audit.Severity,
};

const AuditSealDoc = struct {
    mac: []const u8,
    body: []const u8,
};

fn e2eAuditKey() core.audit_integrity.Key {
    return .{
        .id = 7,
        .bytes = [_]u8{0x37} ** core.audit_integrity.mac_len,
    };
}

fn e2eFrameOpts() core.audit.FrameOpts {
    return .{
        .hostname = "pz-host",
        .app_name = "pz",
        .procid = "17",
        .msgid = "audit",
    };
}

fn shipAuditRows(alloc: std.mem.Allocator, sender: *core.syslog.Sender, rows: []const []const u8) !void {
    var tracker = core.audit_integrity.SeqTracker.init(alloc, std.Io.failing, null);
    return shipAuditRowsWithTracker(alloc, sender, rows, &tracker);
}

fn shipAuditRowsWithTracker(alloc: std.mem.Allocator, sender: *core.syslog.Sender, rows: []const []const u8, seq_tracker: *core.audit_integrity.SeqTracker) !void {
    const key = e2eAuditKey();
    var prev: ?core.audit_integrity.Mac = null;

    for (rows) |row| {
        const hdr = try std.json.parseFromSlice(AuditHdrDoc, alloc, row, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer hdr.deinit();

        const seq = try seq_tracker.next();
        const sealed = try core.audit_integrity.sealAllocSeq(alloc, key, prev, row, seq);
        defer alloc.free(sealed);

        const doc = try std.json.parseFromSlice(AuditSealDoc, alloc, sealed, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer doc.deinit();

        var next: core.audit_integrity.Mac = undefined;
        _ = try std.fmt.hexToBytes(next[0..], doc.value.mac);

        const frame = try core.audit.encodeFrameBodyAlloc(alloc, e2eFrameOpts(), .{
            .ts_ms = hdr.value.ts_ms,
            .sid = hdr.value.sid,
            .seq = hdr.value.seq,
            .severity = hdr.value.sev,
        }, sealed);
        defer alloc.free(frame);

        try sender.sendRaw(frame);
        prev = next;
    }
}

fn extractSyslogMsg(raw: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, raw, "] {") orelse return error.InvalidFrame;
    return raw[idx + 2 ..];
}

fn joinShippedLinesAlloc(alloc: std.mem.Allocator, collector: anytype) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (0..collector.msgCount()) |i| {
        try out.appendSlice(alloc, try extractSyslogMsg(collector.messageAt(i)));
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

fn joinShippedBodiesAlloc(alloc: std.mem.Allocator, collector: anytype) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (0..collector.msgCount()) |i| {
        const raw = try extractSyslogMsg(collector.messageAt(i));
        const doc = try std.json.parseFromSlice(AuditSealDoc, alloc, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer doc.deinit();

        if (i > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, doc.value.body);
    }
    return try out.toOwnedSlice(alloc);
}

test "bg manager rejects empty command" {
    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();
    try std.testing.expectError(error.InvalidArgs, mgr.start("", null));
    try std.testing.expectError(error.InvalidArgs, mgr.start("   ", null));
}

test "bg manager rejects protected commands" {
    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();
    try std.testing.expectError(error.AccessDenied, mgr.start("env FOO=1 bash -c 'cat ~/.pz/settings.json'", null));
}

test "bg manager captures stdout+stderr and reports completion" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("printf 'out'; printf 'err' 1>&2", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);

    try std.testing.expectEqual(@as(usize, 1), done.len);

    const f = try std.Io.Dir.openFileAbsolute(std.testing.io, done[0].log_path, .{ .mode = .read_only });
    defer f.close(std.testing.io);
    var read_buf: [1024]u8 = undefined;
    var reader = f.readerStreaming(std.testing.io, &read_buf);
    const out = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(out);

    const snap = DoneSnap{
        .id = done[0].id,
        .state = stateName(done[0].state),
        .code = done[0].code,
        .cmd = done[0].cmd,
        .has_log = done[0].log_path.len > 0,
        .has_out = std.mem.indexOf(u8, out, "out") != null,
        .has_err = std.mem.indexOf(u8, out, "err") != null,
    };
    try oh.snap(@src(),
        \\app.bg.DoneSnap
        \\  .id: u64 = 1
        \\  .state: []const u8
        \\    "exited"
        \\  .code: ?i32
        \\    0
        \\  .cmd: []const u8
        \\    "printf 'out'; printf 'err' 1>&2"
        \\  .has_log: bool = true
        \\  .has_out: bool = true
        \\  .has_err: bool = true
    ).expectEqual(snap);
}

test "bg manager supports multiple concurrent jobs" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("sleep 1", null);
    _ = try mgr.start("sleep 1", null);

    const jobs = try mgr.list(std.testing.allocator);
    defer deinitViews(std.testing.allocator, jobs);

    try std.testing.expectEqual(@as(usize, 2), jobs.len);
    const snaps = [_]JobSnap{
        toJobSnap(jobs[0]),
        toJobSnap(jobs[1]),
    };
    try oh.snap(@src(),
        \\[2]app.bg.JobSnap
        \\  [0]: app.bg.JobSnap
        \\    .id: u64 = 1
        \\    .state: []const u8
        \\      "running"
        \\    .code: ?i32
        \\      null
        \\    .cmd: []const u8
        \\      "sleep 1"
        \\    .has_log: bool = true
        \\  [1]: app.bg.JobSnap
        \\    .id: u64 = 2
        \\    .state: []const u8
        \\      "running"
        \\    .code: ?i32
        \\      null
        \\    .cmd: []const u8
        \\      "sleep 1"
        \\    .has_log: bool = true
    ).expectEqual(snaps);
}

test "bg manager records non-zero exit code" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("printf 'bad'; exit 7", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);

    const snap = toJobSnap(done[0]);
    try oh.snap(@src(),
        \\app.bg.JobSnap
        \\  .id: u64 = 1
        \\  .state: []const u8
        \\    "exited"
        \\  .code: ?i32
        \\    7
        \\  .cmd: []const u8
        \\    "printf 'bad'; exit 7"
        \\  .has_log: bool = true
    ).expectEqual(snap);
}

test "bg manager view handles missing ids" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect((try mgr.view(std.testing.allocator, 1)) == null);

    const id = try mgr.start("sleep 1", null);
    const view = (try mgr.view(std.testing.allocator, id)) orelse return error.TestUnexpectedResult;
    defer deinitView(std.testing.allocator, view);
    try oh.snap(@src(),
        \\app.bg.JobSnap
        \\  .id: u64 = 1
        \\  .state: []const u8
        \\    "running"
        \\  .code: ?i32
        \\    null
        \\  .cmd: []const u8
        \\    "sleep 1"
        \\  .has_log: bool = true
    ).expectEqual(toJobSnap(view));

    try std.testing.expect((try mgr.view(std.testing.allocator, id + 9999)) == null);
}

test "bg manager drainDone is empty after first drain" {
    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("printf x", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const first = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.len);

    const second = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "bg manager stop reports already_done after completion" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.start("printf done", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);
    try oh.snap(@src(),
        \\app.bg.JobSnap
        \\  .id: u64 = 1
        \\  .state: []const u8
        \\    "exited"
        \\  .code: ?i32
        \\    0
        \\  .cmd: []const u8
        \\    "printf done"
        \\  .has_log: bool = true
    ).expectEqual(toJobSnap(done[0]));

    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .already_done);
}

test "bg manager stop tolerates short-lived command race" {
    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.start("printf done", null);
    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .sent or stop == .already_done);

    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);
}

test "bg manager stop sends termination signal" {
    var mgr = try Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.start("sleep 5", null);
    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .sent or stop == .already_done);

    try std.testing.expect((try mgr.stop(999999)) == .not_found);
}

test "bg manager recovers and clears stale journal launch entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(state_dir);

    var j = try journal_mod.Journal.init(std.testing.allocator, .{
        .state_dir = state_dir,
        .enabled = true,
    });
    try j.appendLaunch(99, 999_999, "sleep 30", "/tmp/none.log", 1);
    j.deinit();

    var mgr = try Manager.initWithOpts(std.testing.allocator, .{
        .state_dir = state_dir,
        .recover = true,
    });
    defer mgr.deinit();

    const active = try mgr.journal.replayActive(std.testing.allocator);
    defer journal_mod.deinitActives(std.testing.allocator, active);
    try std.testing.expectEqual(@as(usize, 0), active.len);
}

test "bg manager audit emits start and success entries for control ops" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var cap = AuditCap{};
    defer cap.deinit(std.testing.allocator);

    var mgr = try Manager.initWithOpts(std.testing.allocator, .{
        .audit_emitter = &cap.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 123;
            }
        }.f,
    });
    defer mgr.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "tmp/secret");
    const secret_cwd = try tmp.dir.realPathFileAlloc(std.testing.io, "tmp/secret", std.testing.allocator);
    defer std.testing.allocator.free(secret_cwd);

    const id = try mgr.start("printf done", secret_cwd);
    const listed = try mgr.list(std.testing.allocator);
    defer deinitViews(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .sent or stop == .already_done);

    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);

    const joined = try std.mem.join(std.testing.allocator, "\n", cap.rows.items);
    defer std.testing.allocator.free(joined);
    const scrubbed = try scrubBgAudit(std.testing.allocator, joined);
    defer std.testing.allocator.free(scrubbed);

    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":123,"sid":"bg","seq":1,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"start"},"msg":{"text":"bg control start","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"start","argv":{"text":"[mask:<^[0-9a-f]{16}$>]","vis":"mask"}},"attrs":[{"key":"cwd","vis":"mask","ty":"str","val":"[mask:<^[0-9a-f]{16}$>]"}]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":2,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"start"},"msg":{"text":"bg control success","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"start","argv":{"text":"[mask:<^[0-9a-f]{16}$>]","vis":"mask"}},"attrs":[{"key":"job_id","vis":"pub","ty":"uint","val":1},{"key":"pid","vis":"pub","ty":"uint","val":0},{"key":"cwd","vis":"mask","ty":"str","val":"[mask:<^[0-9a-f]{16}$>]"},{"key":"log_path","vis":"mask","ty":"str","val":"[mask:LOG]"}]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":3,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"list"},"msg":{"text":"bg control start","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"list"},"attrs":[]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":4,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"list"},"msg":{"text":"bg control success","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"list"},"attrs":[{"key":"count","vis":"pub","ty":"uint","val":1}]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":5,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"stop"},"msg":{"text":"bg control start","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"stop"},"attrs":[{"key":"job_id","vis":"pub","ty":"uint","val":1}]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":6,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"stop"},"msg":{"text":"bg control success","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"stop"},"attrs":[{"key":"job_id","vis":"pub","ty":"uint","val":1},{"key":"status","vis":"pub","ty":"str","val":"OUTCOME"}]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":7,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"drain"},"msg":{"text":"bg control start","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"drain"},"attrs":[]}
        \\{"v":1,"ts_ms":123,"sid":"bg","seq":8,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"drain"},"msg":{"text":"bg control success","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"drain"},"attrs":[{"key":"count","vis":"pub","ty":"uint","val":1}]}"
    ).expectEqual(scrubbed);
}

test "bg manager audit emits failure entries for invalid start and missing stop" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var cap = AuditCap{};
    defer cap.deinit(std.testing.allocator);

    var mgr = try Manager.initWithOpts(std.testing.allocator, .{
        .audit_emitter = &cap.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 456;
            }
        }.f,
    });
    defer mgr.deinit();

    try std.testing.expectError(error.InvalidArgs, mgr.start("   ", null));
    try std.testing.expectEqual(StopResult.not_found, try mgr.stop(42));

    const joined = try std.mem.join(std.testing.allocator, "\n", cap.rows.items);
    defer std.testing.allocator.free(joined);

    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":456,"sid":"bg","seq":1,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"start"},"msg":{"text":"bg control start","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"start","argv":{"text":"[mask:<^[0-9a-f]{16}$>]","vis":"mask"}},"attrs":[{"key":"cwd","vis":"mask","ty":"str","val":"[mask:<^[0-9a-f]{16}$>]"}]}
        \\{"v":1,"ts_ms":456,"sid":"bg","seq":2,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"start"},"msg":{"text":"[mask:<^[0-9a-f]{16}$>]","vis":"mask"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"start","argv":{"text":"[mask:<^[0-9a-f]{16}$>]","vis":"mask"}},"attrs":[{"key":"cwd","vis":"mask","ty":"str","val":"[mask:<^[0-9a-f]{16}$>]"}]}
        \\{"v":1,"ts_ms":456,"sid":"bg","seq":3,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"stop"},"msg":{"text":"bg control start","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"stop"},"attrs":[{"key":"job_id","vis":"pub","ty":"uint","val":42}]}
        \\{"v":1,"ts_ms":456,"sid":"bg","seq":4,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"bg","vis":"pub"},"op":"stop"},"msg":{"text":"bg not found","vis":"pub"},"data":{"name":{"text":"bg","vis":"pub"},"call_id":"stop"},"attrs":[{"key":"job_id","vis":"pub","ty":"uint","val":42},{"key":"status","vis":"pub","ty":"str","val":"not_found"}]}"
    ).expectEqual(joined);
}

test "bg manager syslog e2e ships redacted chained success audit over udp" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var cap = AuditCap{};
    defer cap.deinit(std.testing.allocator);

    var mgr = try Manager.initWithOpts(std.testing.allocator, .{
        .audit_emitter = &cap.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 123;
            }
        }.f,
    });
    defer mgr.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "tmp/secret");
    const secret_cwd = try tmp.dir.realPathFileAlloc(std.testing.io, "tmp/secret", std.testing.allocator);
    defer std.testing.allocator.free(secret_cwd);

    const id = try mgr.start("printf done", secret_cwd);
    const listed = try mgr.list(std.testing.allocator);
    defer deinitViews(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .sent or stop == .already_done);

    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);

    var collector = try syslog_mock.UdpCollector.init();
    defer collector.deinit();
    const t = try collector.spawnCount(cap.rows.items.len);

    var sender = try core.syslog.Sender.init(std.testing.allocator, .{
        .io = defaultIo(),
        .transport = .udp,
        .host = "127.0.0.1",
        .port = collector.port(),
        .allow_private = true,
    });
    defer sender.deinit();

    try shipAuditRows(std.testing.allocator, &sender, cap.rows.items);
    t.join();

    try std.testing.expectEqual(cap.rows.items.len, collector.msgCount());

    const shipped_lines = try joinShippedLinesAlloc(std.testing.allocator, &collector);
    defer std.testing.allocator.free(shipped_lines);
    const got_chain = try core.audit_integrity.verifyLogAlloc(std.testing.allocator, shipped_lines, &.{e2eAuditKey()});
    switch (got_chain) {
        .ok => |ok| try oh.snap(@src(),
            \\app.bg.ChainSnap
            \\  .lines: u64 = 8
            \\  .last_key_id: ?u32
            \\    7
            \\  .has_last_mac: bool = true
        ).expectEqual(toChainSnap(ok)),
        .fail => return error.InvalidAuditChain,
    }

    for (0..collector.msgCount()) |i| {
        const raw = collector.messageAt(i);
        try std.testing.expect(std.mem.indexOf(u8, raw, "printf done") == null);
        try std.testing.expect(std.mem.indexOf(u8, raw, secret_cwd) == null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "[pz@32473 sid=\"bg\" seq=\"") != null);
    }

    const shipped_bodies = try joinShippedBodiesAlloc(std.testing.allocator, &collector);
    defer std.testing.allocator.free(shipped_bodies);
    const scrubbed = try scrubBgAudit(std.testing.allocator, shipped_bodies);
    defer std.testing.allocator.free(scrubbed);

    const joined = try std.mem.join(std.testing.allocator, "\n", cap.rows.items);
    defer std.testing.allocator.free(joined);
    const expected = try scrubBgAudit(std.testing.allocator, joined);
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, scrubbed);
}

test "bg manager syslog e2e ships redacted chained failure audit over tcp" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var cap = AuditCap{};
    defer cap.deinit(std.testing.allocator);

    var mgr = try Manager.initWithOpts(std.testing.allocator, .{
        .audit_emitter = &cap.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 456;
            }
        }.f,
    });
    defer mgr.deinit();

    try std.testing.expectError(error.InvalidArgs, mgr.start("   ", null));
    try std.testing.expectEqual(StopResult.not_found, try mgr.stop(42));

    var collector = try syslog_mock.TcpCollector.init();
    defer collector.deinit();
    const t = try collector.spawnCount(cap.rows.items.len);

    var sender = try core.syslog.Sender.init(std.testing.allocator, .{
        .io = defaultIo(),
        .transport = .tcp,
        .host = "127.0.0.1",
        .port = collector.port(),
        .allow_private = true,
    });
    defer sender.deinit();

    try shipAuditRows(std.testing.allocator, &sender, cap.rows.items);
    t.join();

    try std.testing.expectEqual(cap.rows.items.len, collector.msgCount());

    const shipped_lines = try joinShippedLinesAlloc(std.testing.allocator, &collector);
    defer std.testing.allocator.free(shipped_lines);
    const got_chain = try core.audit_integrity.verifyLogAlloc(std.testing.allocator, shipped_lines, &.{e2eAuditKey()});
    switch (got_chain) {
        .ok => |ok| try oh.snap(@src(),
            \\app.bg.ChainSnap
            \\  .lines: u64 = 4
            \\  .last_key_id: ?u32
            \\    7
            \\  .has_last_mac: bool = true
        ).expectEqual(toChainSnap(ok)),
        .fail => return error.InvalidAuditChain,
    }

    for (0..collector.msgCount()) |i| {
        const raw = collector.messageAt(i);
        try std.testing.expect(std.mem.indexOf(u8, raw, "InvalidArgs") == null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "[pz@32473 sid=\"bg\" seq=\"") != null);
    }

    const shipped_bodies = try joinShippedBodiesAlloc(std.testing.allocator, &collector);
    defer std.testing.allocator.free(shipped_bodies);
    const scrubbed = try scrubBgAudit(std.testing.allocator, shipped_bodies);
    defer std.testing.allocator.free(scrubbed);

    const joined = try std.mem.join(std.testing.allocator, "\n", cap.rows.items);
    defer std.testing.allocator.free(joined);
    const expected = try scrubBgAudit(std.testing.allocator, joined);
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, scrubbed);
}
