//! Carries tmux pane operations from the host session's viewer to whatever
//! is displaying each pane, and carries input back the other way.
//!
//! The whole reason this type exists is a lock ordering problem. The viewer
//! runs inside the host surface's output processing, with the host's
//! renderer mutex held. Each pane is displayed by a different surface with
//! its own renderer mutex. Calling into a pane while holding the host's
//! lock risks a cycle, because the mailbox back pressure a blocked call
//! waits on only ever releases the *callee's* lock, never ours.
//!
//! So nothing is delivered while the host lock is held. Ops are deep
//! copied into a per-pane buffer on the way in, and `flush` hands them to
//! the pane afterwards, from a context that holds no renderer mutex at all.
//!
//! Locks, in the order they may be taken:
//!
//!   1. `delivery` ("D") — held for all of `flush`, so that a pane going
//!      away can block out a delivery that is already in progress.
//!   2. `mutex` ("S") — guards every field below and every `Channel`.
//!      A critical section under S never blocks and never calls out.
//!   3. a pane's renderer mutex — taken inside an endpoint call, which
//!      only ever happens under D with S released.
//!
//! The host is reached through a vtable behind a busy counter rather than
//! a lock, so that host teardown can wait out in-flight calls without a
//! pane thread ever holding a lock the host needs.
//!
//! Nothing here imports termio: the concrete wiring lives in the glue that
//! implements `Host` and `Endpoint`, which keeps this file testable with
//! fakes and keeps the lock discipline in one place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;

const sinkpkg = @import("sink.zig");
const Op = sinkpkg.Op;
const Sink = sinkpkg.Sink;
const KillScope = sinkpkg.KillScope;

const log = std.log.scoped(.terminal_tmux_router);

pub const Router = struct {
    io: std.Io,
    alloc: Allocator,
    refs: std.atomic.Value(u32),

    /// Guards everything below, and every `Channel`. See the lock order
    /// in the file docs.
    mutex: std.Io.Mutex = .init,

    /// Held for the whole of `flush`.
    delivery: std.Io.Mutex = .init,

    /// Signalled when `host_busy` reaches zero.
    host_idle: std.Io.Condition = .init,

    host: Host,
    host_gone: bool = false,
    host_busy: u32 = 0,

    channels: std.AutoArrayHashMapUnmanaged(usize, *Channel) = .empty,

    /// How much unread pane output we are willing to hold for a pane
    /// nothing has claimed yet. A pane the GUI never realizes would
    /// otherwise grow this without bound.
    const max_buffer_bytes: usize = 8 * 1024 * 1024;

    /// The tmux side: how we ask the host session to do something.
    ///
    /// Every method is called from a pane's thread with no locks held.
    pub const Host = struct {
        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Encoded input for a pane, headed for tmux `send-keys`.
            write: *const fn (ctx: *anyopaque, pane_id: usize, data: []const u8) void,

            /// The pane's display changed size.
            resize: *const fn (ctx: *anyopaque, pane_id: usize, cols: usize, rows: usize) void,

            /// The pane's display was closed by the user.
            kill: *const fn (ctx: *anyopaque, pane_id: usize) void,

            /// The GUI asked for a new tab, which for a tmux surface
            /// means a new tmux window.
            newWindow: *const fn (ctx: *anyopaque) void,

            /// The GUI asked to split a pane.
            split: *const fn (
                ctx: *anyopaque,
                pane_id: usize,
                horizontal: bool,
            ) void,

            /// The GUI closed a tab, which for a tmux surface means
            /// killing tmux windows.
            killWindows: *const fn (
                ctx: *anyopaque,
                pane_id: usize,
                scope: KillScope,
            ) void,

            /// The user asked to leave the session, without killing
            /// anything in it.
            detach: *const fn (ctx: *anyopaque) void,

            /// The user moved into this pane.
            selectPane: *const fn (ctx: *anyopaque, pane_id: usize) void,

            /// The user asked to zoom or unzoom this pane.
            zoomPane: *const fn (ctx: *anyopaque, pane_id: usize) void,
        };
    };

    /// The display side: how we hand a pane its operations.
    pub const Endpoint = struct {
        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Apply these ops. Called with no renderer mutex held, so it
            /// is free to take the pane's own.
            ops: *const fn (ctx: *anyopaque, ops: []const Op) void,

            /// The pane is gone. Called at most once, never at the same
            /// time as `ops`, and nothing follows it.
            close: *const fn (ctx: *anyopaque) void,
        };
    };

    const Channel = struct {
        router: *Router,
        pane_id: usize,
        buffer: std.ArrayList(Op) = .empty,
        buffer_bytes: usize = 0,
        endpoint: ?Endpoint = null,
        closed: bool = false,
        close_delivered: bool = false,

        const sink_vtable: Sink.VTable = .{
            .ops = sinkOps,
            .close = sinkClose,
        };

        fn sink(self: *Channel) Sink {
            return .{ .ctx = self, .vtable = &sink_vtable };
        }

        /// Called on the host thread with the host renderer mutex held.
        /// Copies and returns; never blocks, never calls out.
        fn sinkOps(ctx: *anyopaque, ops: []const Op) void {
            const self: *Channel = @ptrCast(@alignCast(ctx));
            const r = self.router;

            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);

            if (self.closed) return;

            if (self.buffer_bytes > max_buffer_bytes) {
                log.warn(
                    "pane id={} buffered too much with nothing reading it, closing",
                    .{self.pane_id},
                );
                self.closed = true;
                return;
            }

            self.buffer.ensureUnusedCapacity(r.alloc, ops.len) catch {
                // Dropping an op would leave the pane subtly wrong
                // forever, which is worse than losing the pane.
                log.warn("pane id={} out of memory, closing", .{self.pane_id});
                self.closed = true;
                return;
            };

            for (ops) |op| {
                const copy = op.clone(r.alloc) catch {
                    log.warn("pane id={} out of memory, closing", .{self.pane_id});
                    self.closed = true;
                    return;
                };
                if (copy == .bytes) self.buffer_bytes += copy.bytes.len;
                self.buffer.appendAssumeCapacity(copy);
            }
        }

        fn sinkClose(ctx: *anyopaque) void {
            const self: *Channel = @ptrCast(@alignCast(ctx));
            const r = self.router;

            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);

            // Idempotent: the viewer closes a sink on pane removal and
            // again on teardown.
            self.closed = true;
        }

        /// Free buffered ops. Caller holds S.
        fn clearBuffer(self: *Channel, alloc: Allocator) void {
            for (self.buffer.items) |op| op.deinit(alloc);
            self.buffer.clearRetainingCapacity();
            self.buffer_bytes = 0;
        }

        fn destroy(self: *Channel, alloc: Allocator) void {
            self.clearBuffer(alloc);
            self.buffer.deinit(alloc);
            alloc.destroy(self);
        }
    };

    pub fn create(
        alloc: Allocator,
        io: std.Io,
        host: Host,
    ) Allocator.Error!*Router {
        const self = try alloc.create(Router);
        self.* = .{
            .io = io,
            .alloc = alloc,
            .refs = .init(1),
            .host = host,
        };
        return self;
    }

    pub fn ref(self: *Router) *Router {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn unref(self: *Router) void {
        if (self.refs.fetchSub(1, .release) != 1) return;
        _ = self.refs.load(.acquire);

        for (self.channels.values()) |ch| ch.destroy(self.alloc);
        self.channels.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // ---------------------------------------------------------------
    // Host side. Called on the host thread, with the host renderer
    // mutex held, so these only ever take S.
    // ---------------------------------------------------------------

    /// Whether this pane has no channel yet, i.e. the caller should make
    /// one and attach it to the viewer.
    pub fn needsChannel(self: *Router, pane_id: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.channels.contains(pane_id);
    }

    /// Make a channel for a pane and return the sink to hand the viewer.
    pub fn createChannel(
        self: *Router,
        pane_id: usize,
    ) Allocator.Error!Sink {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const gop = try self.channels.getOrPut(self.alloc, pane_id);
        errdefer _ = self.channels.swapRemove(pane_id);
        if (gop.found_existing) return gop.value_ptr.*.sink();

        const ch = try self.alloc.create(Channel);
        ch.* = .{ .router = self, .pane_id = pane_id };
        gop.value_ptr.* = ch;
        return ch.sink();
    }

    /// Undo a `createChannel` whose `attachPane` then failed.
    pub fn destroyChannel(self: *Router, pane_id: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ch = self.channels.fetchSwapRemove(pane_id) orelse return;
        assert(ch.value.endpoint == null);
        ch.value.destroy(self.alloc);
    }

    // ---------------------------------------------------------------
    // Delivery.
    // ---------------------------------------------------------------

    /// Hand every buffered op to its pane.
    ///
    /// Must be called with no renderer mutex held: from the host thread
    /// once its output processing has released the host lock, from a pane
    /// thread just after registering, or from `detachHost`.
    pub fn flush(self: *Router) void {
        const io = self.io;

        self.delivery.lockUncancelable(io);
        defer self.delivery.unlock(io);

        // Channels are heap allocated and only freed under D, which we
        // hold, so pointers collected here stay valid after S is dropped.
        var work: std.ArrayList(*Channel) = .empty;
        defer work.deinit(self.alloc);

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            for (self.channels.values()) |ch| {
                if (ch.endpoint == null) continue;
                if (ch.buffer.items.len == 0 and
                    !(ch.closed and !ch.close_delivered)) continue;

                // On failure we simply try again next flush.
                work.append(self.alloc, ch) catch break;
            }
        }

        for (work.items) |ch| {
            var ops: std.ArrayList(Op) = .empty;
            var endpoint: ?Endpoint = null;
            var deliver_close = false;

            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);

                endpoint = ch.endpoint;
                if (endpoint != null) {
                    // Take the buffer rather than copying it, so the sink
                    // side can keep filling a fresh one while we deliver.
                    ops = ch.buffer;
                    ch.buffer = .empty;
                    ch.buffer_bytes = 0;

                    if (ch.closed and !ch.close_delivered) {
                        ch.close_delivered = true;
                        deliver_close = true;
                    }
                }
            }

            defer {
                for (ops.items) |op| op.deinit(self.alloc);
                ops.deinit(self.alloc);
            }

            const ep = endpoint orelse continue;
            if (ops.items.len > 0) ep.vtable.ops(ep.ctx, ops.items);
            if (deliver_close) ep.vtable.close(ep.ctx);
        }
    }

    // ---------------------------------------------------------------
    // Pane side. Called on a pane's own thread.
    // ---------------------------------------------------------------

    /// Claim a pane's channel. Follow with `flush` to pick up whatever
    /// was buffered before this: an idle session produces no host output
    /// to trigger one.
    ///
    /// If the pane is already gone, the endpoint is closed immediately.
    pub fn register(self: *Router, pane_id: usize, endpoint: Endpoint) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.channels.get(pane_id)) |ch| {
                assert(ch.endpoint == null);
                ch.endpoint = endpoint;
                return;
            }
        }

        endpoint.vtable.close(endpoint.ctx);
    }

    /// Give up a pane's channel.
    ///
    /// Takes the delivery lock, so once this returns the endpoint will
    /// never be called again and the pane may be torn down.
    ///
    /// Returns true if the pane was still open, which means the display
    /// closed first and the caller should ask tmux to kill the pane.
    pub fn deregister(self: *Router, pane_id: usize) bool {
        self.delivery.lockUncancelable(self.io);
        defer self.delivery.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ch = self.channels.get(pane_id) orelse return false;
        ch.endpoint = null;
        return !ch.closed;
    }

    pub fn writeInput(self: *Router, pane_id: usize, data: []const u8) void {
        if (!self.paneOpen(pane_id)) return;
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.write(self.host.ctx, pane_id, data);
    }

    pub fn requestResize(
        self: *Router,
        pane_id: usize,
        cols: usize,
        rows: usize,
    ) void {
        if (!self.paneOpen(pane_id)) return;
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.resize(self.host.ctx, pane_id, cols, rows);
    }

    /// Ask the session for a new window. Not tied to a pane: a new tab
    /// belongs to the session, and the pane the user happened to be in
    /// does not narrow it.
    pub fn newWindow(self: *Router) void {
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.newWindow(self.host.ctx);
    }

    /// Ask the session to toggle zoom on this pane.
    pub fn zoomPane(self: *Router, pane_id: usize) void {
        if (!self.paneOpen(pane_id)) return;
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.zoomPane(self.host.ctx, pane_id);
    }

    /// Tell the session the user has moved into this pane.
    pub fn selectPane(self: *Router, pane_id: usize) void {
        if (!self.paneOpen(pane_id)) return;
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.selectPane(self.host.ctx, pane_id);
    }

    /// Leave the session, leaving everything in it running.
    ///
    /// Not tied to a pane, and deliberately the whole session: detaching
    /// is a statement about this client, not about whichever pane the
    /// user was looking at when they asked.
    pub fn detach(self: *Router) void {
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.detach(self.host.ctx);
    }

    /// Ask tmux to split a pane. `horizontal` is tmux's sense of the
    /// word: a new pane to the right, side by side.
    pub fn splitPane(
        self: *Router,
        pane_id: usize,
        horizontal: bool,
    ) void {
        if (!self.paneOpen(pane_id)) return;
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.split(self.host.ctx, pane_id, horizontal);
    }

    /// Ask tmux to close windows. `pane_id` names the window the user
    /// acted on; `scope` says which windows go.
    pub fn killWindows(
        self: *Router,
        pane_id: usize,
        scope: KillScope,
    ) void {
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.killWindows(self.host.ctx, pane_id, scope);
    }

    pub fn killPane(self: *Router, pane_id: usize) void {
        if (!self.hostAcquire()) return;
        defer self.hostRelease();
        self.host.vtable.kill(self.host.ctx, pane_id);
    }

    // ---------------------------------------------------------------
    // Host teardown.
    // ---------------------------------------------------------------

    /// The host session is going away.
    ///
    /// Refuses further host calls, waits out any already running, closes
    /// every channel and delivers those closes, so each pane learns its
    /// session died. Must be called with no locks held.
    pub fn detachHost(self: *Router) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.host_gone) return;
            self.host_gone = true;

            while (self.host_busy > 0) {
                self.host_idle.waitUncancelable(self.io, &self.mutex);
            }

            for (self.channels.values()) |ch| ch.closed = true;
        }

        self.flush();
    }

    fn paneOpen(self: *Router, pane_id: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const ch = self.channels.get(pane_id) orelse return false;
        return !ch.closed;
    }

    fn hostAcquire(self: *Router) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.host_gone) return false;
        self.host_busy += 1;
        return true;
    }

    fn hostRelease(self: *Router) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(self.host_busy > 0);
        self.host_busy -= 1;
        if (self.host_busy == 0) self.host_idle.signal(self.io);
    }
};

const TestHost = struct {
    alloc: Allocator,
    writes: std.ArrayList([]u8) = .empty,
    resizes: std.ArrayList(struct {
        pane_id: usize,
        cols: usize,
        rows: usize,
    }) = .empty,
    kills: std.ArrayList(usize) = .empty,
    new_windows: usize = 0,
    detaches: usize = 0,
    selected_panes: std.ArrayList(usize) = .empty,
    zoomed_panes: std.ArrayList(usize) = .empty,
    splits: std.ArrayList(struct {
        pane_id: usize,
        horizontal: bool,
    }) = .empty,
    window_kills: std.ArrayList(struct {
        pane_id: usize,
        scope: KillScope,
    }) = .empty,

    const vtable: Router.Host.VTable = .{
        .write = write,
        .resize = resize,
        .kill = kill,
        .newWindow = newWindow,
        .split = split,
        .killWindows = killWindows,
        .detach = detach,
        .selectPane = selectPane,
        .zoomPane = zoomPane,
    };

    fn killWindows(
        ctx: *anyopaque,
        pane_id: usize,
        scope: KillScope,
    ) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.window_kills.append(self.alloc, .{
            .pane_id = pane_id,
            .scope = scope,
        }) catch @panic("oom");
    }

    fn newWindow(ctx: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.new_windows += 1;
    }

    fn detach(ctx: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.detaches += 1;
    }

    fn selectPane(ctx: *anyopaque, pane_id: usize) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.selected_panes.append(self.alloc, pane_id) catch @panic("oom");
    }

    fn zoomPane(ctx: *anyopaque, pane_id: usize) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.zoomed_panes.append(self.alloc, pane_id) catch @panic("oom");
    }

    fn split(ctx: *anyopaque, pane_id: usize, horizontal: bool) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.splits.append(self.alloc, .{
            .pane_id = pane_id,
            .horizontal = horizontal,
        }) catch @panic("oom");
    }

    fn host(self: *TestHost) Router.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn deinit(self: *TestHost) void {
        for (self.writes.items) |w| self.alloc.free(w);
        self.writes.deinit(self.alloc);
        self.resizes.deinit(self.alloc);
        self.kills.deinit(self.alloc);
        self.splits.deinit(self.alloc);
        self.window_kills.deinit(self.alloc);
        self.selected_panes.deinit(self.alloc);
        self.zoomed_panes.deinit(self.alloc);
    }

    fn write(ctx: *anyopaque, pane_id: usize, data: []const u8) void {
        _ = pane_id;
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, data) catch return;
        self.writes.append(self.alloc, copy) catch self.alloc.free(copy);
    }

    fn resize(ctx: *anyopaque, pane_id: usize, cols: usize, rows: usize) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.resizes.append(self.alloc, .{
            .pane_id = pane_id,
            .cols = cols,
            .rows = rows,
        }) catch {};
    }

    fn kill(ctx: *anyopaque, pane_id: usize) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.kills.append(self.alloc, pane_id) catch {};
    }
};

const TestEndpoint = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    op_count: usize = 0,
    closes: usize = 0,

    /// Ops seen after a close, which the contract forbids.
    ops_after_close: usize = 0,

    /// When set, any call at all is a contract violation.
    poisoned: bool = false,
    poison_hits: usize = 0,

    const vtable: Router.Endpoint.VTable = .{ .ops = ops, .close = close };

    fn endpoint(self: *TestEndpoint) Router.Endpoint {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn deinit(self: *TestEndpoint) void {
        self.bytes.deinit(self.alloc);
    }

    fn ops(ctx: *anyopaque, list: []const Op) void {
        const self: *TestEndpoint = @ptrCast(@alignCast(ctx));
        if (self.poisoned) {
            self.poison_hits += 1;
            return;
        }
        if (self.closes > 0) self.ops_after_close += list.len;
        for (list) |op| {
            self.op_count += 1;
            if (op == .bytes) self.bytes.appendSlice(
                self.alloc,
                op.bytes,
            ) catch {};
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *TestEndpoint = @ptrCast(@alignCast(ctx));
        if (self.poisoned) {
            self.poison_hits += 1;
            return;
        }
        self.closes += 1;
    }
};

/// A router plus its fake host, torn down in the right order.
const TestRouter = struct {
    host: TestHost,
    router: *Router,

    fn init(self: *TestRouter, alloc: Allocator) !void {
        self.host = .{ .alloc = alloc };
        self.router = try Router.create(alloc, testing.io, self.host.host());
    }

    fn deinit(self: *TestRouter) void {
        self.router.unref();
        self.host.deinit();
    }
};

test "ops buffered on the host side are delivered on flush" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    const sink = try tr.router.createChannel(7);
    sink.send(&.{ .{ .bytes = "hello " }, .{ .bytes = "world" } });

    // Nothing is delivered until something claims the pane.
    tr.router.flush();
    try testing.expectEqual(0, ep.op_count);

    tr.router.register(7, ep.endpoint());
    tr.router.flush();

    try testing.expectEqual(2, ep.op_count);
    try testing.expectEqualStrings("hello world", ep.bytes.items);
}

test "buffered ops outlive the memory they were sent from" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    const sink = try tr.router.createChannel(1);
    tr.router.register(1, ep.endpoint());

    {
        // Gone by the time we flush.
        const scratch = try alloc.dupe(u8, "transient");
        defer alloc.free(scratch);
        sink.send(&.{.{ .bytes = scratch }});
    }

    tr.router.flush();
    try testing.expectEqualStrings("transient", ep.bytes.items);
}

test "close is delivered once, after the ops before it" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    const sink = try tr.router.createChannel(2);
    tr.router.register(2, ep.endpoint());

    sink.send(&.{.{ .bytes = "tail" }});
    sink.close();
    // The viewer closes twice on some teardown paths.
    sink.close();

    tr.router.flush();
    tr.router.flush();

    try testing.expectEqualStrings("tail", ep.bytes.items);
    try testing.expectEqual(1, ep.closes);
    try testing.expectEqual(0, ep.ops_after_close);
}

test "nothing reaches an endpoint after deregister" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    const sink = try tr.router.createChannel(3);
    tr.router.register(3, ep.endpoint());

    // Still open, so the display closed first: the user did this.
    try testing.expect(tr.router.deregister(3));

    ep.poisoned = true;
    sink.send(&.{.{ .bytes = "ignored" }});
    sink.close();
    tr.router.flush();

    try testing.expectEqual(0, ep.poison_hits);
}

test "deregister reports a pane tmux already closed" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    const sink = try tr.router.createChannel(4);
    tr.router.register(4, ep.endpoint());

    sink.close();
    try testing.expect(!tr.router.deregister(4));
}

test "registering an unknown pane closes it immediately" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    tr.router.register(99, ep.endpoint());
    try testing.expectEqual(1, ep.closes);
}

test "input reaches the host and stops when the pane does" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    const sink = try tr.router.createChannel(5);

    tr.router.writeInput(5, "abc");
    tr.router.requestResize(5, 80, 24);
    try testing.expectEqual(1, tr.host.writes.items.len);
    try testing.expectEqualStrings("abc", tr.host.writes.items[0]);
    try testing.expectEqual(1, tr.host.resizes.items.len);

    // Unknown panes never reach the host.
    tr.router.writeInput(1234, "nope");
    try testing.expectEqual(1, tr.host.writes.items.len);

    // Neither do closed ones.
    sink.close();
    tr.router.writeInput(5, "nope");
    try testing.expectEqual(1, tr.host.writes.items.len);
}

test "detachHost closes every pane and blocks further host calls" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();

    _ = try tr.router.createChannel(6);
    tr.router.register(6, ep.endpoint());

    tr.router.detachHost();
    try testing.expectEqual(1, ep.closes);

    // Refused now, including kill, which has no pane check of its own.
    tr.router.writeInput(6, "x");
    tr.router.killPane(6);
    try testing.expectEqual(0, tr.host.writes.items.len);
    try testing.expectEqual(0, tr.host.kills.items.len);

    // Idempotent.
    tr.router.detachHost();
    try testing.expectEqual(1, ep.closes);
}

test "kill reaches the host while it is alive" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    _ = try tr.router.createChannel(8);
    tr.router.killPane(8);
    try testing.expectEqual(1, tr.host.kills.items.len);
    try testing.expectEqual(8, tr.host.kills.items[0]);
}

test "a pane nothing claims stops buffering rather than growing forever" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    const sink = try tr.router.createChannel(9);

    const big = try alloc.alloc(u8, Router.max_buffer_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    // The cap is checked against what we already hold, so the oversized
    // op is taken and the one after it is refused.
    sink.send(&.{.{ .bytes = big }});
    sink.send(&.{.{ .bytes = "after" }});

    var ep: TestEndpoint = .{ .alloc = alloc };
    defer ep.deinit();
    tr.router.register(9, ep.endpoint());
    tr.router.flush();

    try testing.expectEqual(1, ep.op_count);
    try testing.expectEqual(1, ep.closes);
}

test "unclaimed buffers are freed on destroy" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    // Never registered, never flushed: the testing allocator catches the
    // cloned ops if unref does not free them.
    const sink = try tr.router.createChannel(10);
    sink.send(&.{ .{ .bytes = "leaked?" }, .scroll_into_history });
}

test "destroyChannel rolls back an attach that failed" {
    const alloc = testing.allocator;
    var tr: TestRouter = undefined;
    try tr.init(alloc);
    defer tr.deinit();

    _ = try tr.router.createChannel(11);
    try testing.expect(!tr.router.needsChannel(11));
    tr.router.destroyChannel(11);
    try testing.expect(tr.router.needsChannel(11));
}
