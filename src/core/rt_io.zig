//! Process-wide default `std.Io`.
//!
//! Zig 0.16's `std.Io.Threaded.global_single_threaded` is initialized with
//! `Allocator.failing` (see Threaded.init_single_threaded), which is only safe
//! for operations that never allocate through the Io. `std.process.spawn`
//! DOES allocate (argv/env null-termination arenas come from the Io's
//! allocator), so spawning through the single-threaded global Io fails with
//! `error.OutOfMemory` in both production and tests.
//!
//! This module provides one shared Io backed by a real, thread-safe allocator
//! (`std.heap.smp_allocator`, process lifetime, no deinit needed) so that
//! every `defaultIo()` shim across the codebase can allocate when required.
//! `std.Io.Threaded.init` performs runtime work (CPU-count probe, sigaction),
//! so the instance is initialized lazily on first use.
const std = @import("std");

var instance: std.Io.Threaded = undefined;

const state_uninit = 0;
const state_initing = 1;
const state_ready = 2;

var init_state = std.atomic.Value(u8).init(state_uninit);

/// The process-wide default Io. Safe for both allocating (spawn) and
/// non-allocating operations.
pub fn default() std.Io {
    while (true) {
        switch (init_state.load(.acquire)) {
            state_ready => return instance.io(),
            state_uninit => {
                if (init_state.cmpxchgStrong(state_uninit, state_initing, .acq_rel, .acquire) == null) {
                    instance = std.Io.Threaded.init(std.heap.smp_allocator, .{});
                    init_state.store(state_ready, .release);
                    return instance.io();
                }
            },
            state_initing => std.atomic.spinLoopHint(),
            else => unreachable,
        }
    }
}
