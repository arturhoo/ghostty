//! A termio backend for a single tmux control mode pane.
//!
//! There is no subprocess and no pty. The pane's output arrives from the
//! host surface's tmux session by way of the router, and input goes back
//! out the same way to become `send-keys`. Everything above us — the
//! terminal, the renderer, the surface — works exactly as it does for a
//! real process.
//!
//! tmux owns the pane's grid, so our `resize` asks tmux to resize the pane
//! and the answer comes back later as an op. See `Termio.resize`.
pub const Tmux = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

// By file path rather than through `terminal.tmux`, which is an empty
// struct when tmux control mode is compiled out. The backend only exists
// in builds that have it, but the import must still resolve.
const Router = @import("../terminal/tmux/router.zig").Router;

const log = std.log.scoped(.io_tmux);

/// Which pane of which session this backend displays. This is what the
/// app runtime hands us when it creates the surface.
pub const Pane = struct {
    router: *Router,
    pane_id: usize,
};

/// Our reference to the router, released in `deinit`.
router: *Router,
pane_id: usize,

pub const Config = Pane;

/// We have no per-thread state: there is no pty to poll and no write
/// queue to own, because input is handed straight to the router.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub fn init(config: Config) Tmux {
    return .{
        .router = config.router.ref(),
        .pane_id = config.pane_id,
    };
}

pub fn deinit(self: *Tmux) void {
    self.router.unref();
}

pub fn initTerminal(self: *Tmux, t: *terminal.Terminal) void {
    _ = self;
    _ = t;

    // Nothing to do: the pane's size and contents both come from tmux,
    // as ops, once we are registered.
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // The thread data union is undefined until we set it.
    td.backend = .{ .tmux = .{} };

    self.router.register(self.pane_id, io.tmuxEndpoint());

    // Pick up whatever was buffered before we existed: our initial size
    // and the capture replay. An idle session produces no host output, so
    // nothing else would trigger a delivery.
    //
    // Safe to receive ops already: our surface creates the renderer and
    // its wakeup before it spawns this thread, so the render scheduling
    // inside cannot fail.
    self.router.flush();
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .tmux);

    // Blocks out any delivery already in progress, so once this returns
    // our terminal can be torn down.
    if (self.router.deregister(self.pane_id)) {
        // The channel was still open, which means the display was closed
        // first rather than the pane going away. Make that mean something
        // on the tmux side.
        self.router.killPane(self.pane_id);
    }
}

pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;

    // Exec uses this to poll the pty's termios for password prompts,
    // which needs a pty. The focus escape sequences themselves are
    // emitted above the backend.
}

pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;

    // We ask; tmux decides. The new size comes back as an op if it is
    // granted, so we never resize our own grid here.
    self.router.requestResize(
        self.pane_id,
        grid_size.columns,
        grid_size.rows,
    );
}

pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;

    if (!linefeed) {
        self.router.writeInput(self.pane_id, data);
        return;
    }

    // Chunked through a stack buffer so a large paste needs no allocation.
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) {
        const chunk = expandLinefeed(data, i, &buf);
        assert(chunk.next > i); // buffer big enough to always progress
        i = chunk.next;
        self.router.writeInput(self.pane_id, buf[0..chunk.len]);
    }
}

/// Copy from `data[start]` into `out`, turning each carriage return into
/// a carriage return and newline, which is what a pty would have done.
///
/// Stops when `out` cannot hold another expanded byte, so the caller can
/// send what it has and come back for the rest.
fn expandLinefeed(data: []const u8, start: usize, out: []u8) struct {
    len: usize,
    next: usize,
} {
    assert(out.len >= 2);

    var i = start;
    var o: usize = 0;
    while (i < data.len and o + 2 <= out.len) {
        const ch = data[i];
        i += 1;

        out[o] = ch;
        o += 1;
        if (ch == '\r') {
            out[o] = '\n';
            o += 1;
        }
    }

    return .{ .len = o, .next = i };
}

pub fn childExitedAbnormally(
    self: *Tmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;

    // We have no child, so nothing can exit abnormally. A pane going away
    // arrives as a router close instead.
}

pub fn getProcessInfo(
    self: *Tmux,
    comptime info: ProcessInfo,
) ?ProcessInfo.Type(info) {
    _ = self;

    // There is no local process: the pane's program runs under the tmux
    // server, which may not even be on this machine.
    return null;
}

test "linefeed expansion turns carriage returns into CRLF" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    const out = expandLinefeed("a\rb\r", 0, &buf);
    try testing.expectEqual(4, out.next);
    try testing.expectEqualStrings("a\r\nb\r\n", buf[0..out.len]);
}

test "linefeed expansion resumes where it ran out of room" {
    const testing = std.testing;

    // Three bytes of room: "a" then a carriage return expanding to two
    // is exactly full, so the second pair has to come next time.
    var buf: [3]u8 = undefined;
    const first = expandLinefeed("a\rb\r", 0, &buf);
    try testing.expectEqualStrings("a\r\n", buf[0..first.len]);
    try testing.expectEqual(2, first.next);

    const second = expandLinefeed("a\rb\r", first.next, &buf);
    try testing.expectEqualStrings("b\r\n", buf[0..second.len]);
    try testing.expectEqual(4, second.next);
}

test "linefeed expansion leaves other bytes alone" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    const out = expandLinefeed("plain\ntext", 0, &buf);
    try testing.expectEqualStrings("plain\ntext", buf[0..out.len]);
}
