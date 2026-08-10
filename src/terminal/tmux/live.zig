//! Integration tests that drive a real tmux server.
//!
//! Everything else in this directory tests our side of the protocol against
//! transcripts we wrote ourselves, which can only ever prove that we parse
//! our own fiction. The bugs that have actually bitten here were all the
//! other kind: tmux doing something we did not know it did. Octal-escaped
//! `%output`, raw ESC inside a `%begin` block, a per-window size that only
//! exists from tmux 3.4 — none of those are discoverable without tmux in
//! the loop.
//!
//! So this spawns one. A private server on its own socket, with no user
//! config, attached over a pty by a control client, and the bytes it sends
//! run through the same `Parser` -> `dcs.Handler` -> `Viewer` chain a real
//! surface uses. Assertions read the pane terminals the viewer maintains,
//! and anything that needs an outside opinion asks the tmux CLI on the same
//! socket.
//!
//! ## Running these
//!
//! `zig build test-tmux-live`. They are skipped by `zig build test`: they
//! need a tmux binary and they take wall-clock time waiting on another
//! process, neither of which belongs in the default suite. The gate is the
//! `GHOSTTY_TMUX_LIVE` environment variable, set by that build step.
//!
//! ## What this does not cover
//!
//! The chain stops at the viewer. `Router`, `Termio`, and the apprts are
//! above it, so nothing here says anything about throughput: tmux kills a
//! control client that falls too far behind (`%exit too far behind`), and
//! this harness drains the pty as fast as it can, so it can never provoke
//! that. Testing it needs a harness built on `Termio` with a deliberately
//! slow endpoint.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const build_options = @import("terminal_options");

const Parser = @import("../Parser.zig");
const Screen = @import("../Screen.zig");
const dcs = @import("../dcs.zig");
const ptypkg = @import("../../pty.zig");
const osfile = @import("../../os/file.zig");
const global = @import("../../global.zig");
const Viewer = @import("viewer.zig").Viewer;

const log = std.log.scoped(.tmux_live);

/// How long any single wait is allowed to take. Generous on purpose: a
/// timeout here should mean "this will never happen", not "the machine was
/// busy". A passing run does not spend it.
const timeout_ms: u64 = 10_000;

/// How long a single poll waits. Also the granularity of `waitFor`.
const poll_ms: u64 = 20;

/// Whether these tests should run at all.
///
/// They are opt-in rather than "run if tmux is installed", because a
/// developer having tmux on their PATH is not consent to spawn servers and
/// block on them during `zig build test`.
fn enabled() bool {
    if (comptime builtin.os.tag == .windows) return false;
    if (comptime !build_options.tmux_control_mode) return false;
    return global.environ().getPosix("GHOSTTY_TMUX_LIVE") != null;
}

/// A tmux server, a control client attached to it over a pty, and the
/// viewer being fed by that client.
const Session = struct {
    alloc: Allocator,
    io: std.Io,

    /// The server socket, in the system temp directory under a random
    /// name so concurrent tests cannot see each other's servers.
    socket: [:0]const u8,

    pty: ptypkg.Pty,
    pid: posix.pid_t,

    parser: Parser,
    dcs_handler: dcs.Handler,
    viewer: Viewer,

    /// Set when the viewer emits `.exit`, i.e. control mode ended. A test
    /// that did not ask for that has found a bug.
    exited: bool = false,

    /// Bytes read off the pty, for throughput assertions.
    bytes: usize = 0,

    /// Somewhere for short answers from `ask` to live so tests do not
    /// have to free every one of them.
    scratch: [64]u8 = undefined,

    /// How many `%pause` notifications tmux has sent us. A test that
    /// means to provoke one should check that it did.
    pauses: usize = 0,

    /// Start a server running `command` in its one pane, then attach.
    ///
    /// The session is created detached first so that `command` has already
    /// painted the pane by the time the control client arrives. That is the
    /// ordering that matters: it is what makes the viewer issue
    /// `capture-pane` against content rather than against a blank screen.
    fn start(
        alloc: Allocator,
        io: std.Io,
        cols: u16,
        rows: u16,
        command: []const u8,
    ) !Session {
        return startWith(alloc, io, cols, rows, command, .{});
    }

    fn startWith(
        alloc: Allocator,
        io: std.Io,
        cols: u16,
        rows: u16,
        command: []const u8,
        opts: Viewer.Options,
    ) !Session {
        const socket = socket: {
            const dir = try osfile.allocTmpDir(alloc, global.environ());
            defer osfile.freeTmpDir(alloc, dir);

            var name_buf: [osfile.random_basename_len]u8 = undefined;
            const name = try osfile.randomBasename(&name_buf);

            break :socket try std.fmt.allocPrintSentinel(
                alloc,
                "{s}/ghostty-tmux-live-{s}",
                .{ dir, name },
                0,
            );
        };
        errdefer alloc.free(socket);

        // -f /dev/null: no user config. Anything a developer has in
        // ~/.tmux.conf could change layouts, key handling or the status
        // line, and a test that depends on the machine it runs on is not
        // a test.
        {
            var x_buf: [8]u8 = undefined;
            var y_buf: [8]u8 = undefined;
            const x = try std.fmt.bufPrint(&x_buf, "{d}", .{cols});
            const y = try std.fmt.bufPrint(&y_buf, "{d}", .{rows});
            const out = try run(alloc, &.{
                "tmux",        "-f",    "/dev/null", "-S", socket,
                "new-session", "-d",    "-x",        x,    "-y",
                y,             command,
            });
            alloc.free(out);
        }

        // The status line steals a row from the client size and is one
        // more thing to differ between tmux builds. Off.
        {
            const out = try run(alloc, &.{
                "tmux", "-f", "/dev/null", "-S",  socket,
                "set",  "-g", "status",    "off",
            });
            alloc.free(out);
        }

        var pty = try ptypkg.Pty.open(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        });
        errdefer pty.deinit();

        // -CC, not -C: only the doubled form wraps the stream in the DCS
        // that this whole chain exists to parse.
        const pid = try spawn(&pty, &.{
            "tmux", "-f",  "/dev/null", "-S",
            socket, "-CC", "attach",
        });
        errdefer {
            posix.kill(pid, .KILL) catch {};
            reap(pid);
        }

        var viewer = try Viewer.init(io, alloc, opts);
        errdefer viewer.deinit();

        return .{
            .alloc = alloc,
            .io = io,
            .socket = socket,
            .pty = pty,
            .pid = pid,
            .parser = .init(),
            .dcs_handler = .{ .state = .{ .inactive = {} } },
            .viewer = viewer,
        };
    }

    fn deinit(self: *Session) void {
        self.viewer.deinit();
        self.dcs_handler.deinit();
        posix.kill(self.pid, .KILL) catch {};
        reap(self.pid);
        self.pty.deinit();

        // Take the server down with us. Otherwise it outlives the test and
        // holds the socket, and on a machine running the suite repeatedly
        // that is a slow leak of tmux processes.
        if (run(self.alloc, &.{
            "tmux", "-f", "/dev/null", "-S", self.socket, "kill-server",
        })) |out| self.alloc.free(out) else |_| {}

        self.alloc.free(self.socket);
    }

    /// Read whatever the client has sent and feed it through the chain.
    /// Returns false if nothing arrived before the poll expired.
    ///
    /// Takes several buffers per call rather than one. A harness reading
    /// 4KB per round falls behind a pane writing at full speed, which
    /// shows up as an attach handshake timing out with its replies stuck
    /// behind megabytes of pane output.
    ///
    /// Bounded rather than "drain until empty": a pane running `yes` is
    /// never empty, so an unbounded drain never returns and the caller
    /// never gets to check its predicate.
    fn pump(self: *Session) !bool {
        var fds: [1]posix.pollfd = .{.{
            .fd = self.pty.master,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if (try posix.poll(&fds, poll_ms) == 0) return false;

        var any = false;
        var buf: [4096]u8 = undefined;
        for (0..64) |_| {
            const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
                // The client is gone; the pty gives EIO rather than EOF.
                error.InputOutput => return any,
                else => return err,
            };
            if (n == 0) return any;

            any = true;
            self.bytes += n;
            for (buf[0..n]) |byte| try self.feed(byte);

            // Anything more waiting right now? A zero timeout keeps this
            // from blocking once the burst is done.
            fds[0].revents = 0;
            if (try posix.poll(&fds, 0) == 0) return any;
        }
        return any;
    }

    fn feed(self: *Session, byte: u8) !void {
        for (self.parser.next(byte)) |maybe_action| {
            const action = maybe_action orelse continue;
            const cmd: ?dcs.Command = switch (action) {
                .dcs_hook => |hook| self.dcs_handler.hook(self.alloc, hook),
                .dcs_put => |b| self.dcs_handler.put(b),
                .dcs_unhook => self.dcs_handler.unhook(),

                // Anything outside the DCS is control mode having escaped
                // onto the host surface, which is the shape of the bug
                // that started all this. Say so loudly rather than
                // silently dropping it.
                else => {
                    if (self.dcs_handler.state == .inactive) continue;
                    log.warn("action outside the tmux DCS: {}", .{action});
                    continue;
                },
            };

            var command = cmd orelse continue;
            defer command.deinit();
            switch (command) {
                .tmux => |n| try self.notify(n),
                else => {},
            }
        }
    }

    fn notify(self: *Session, n: anytype) !void {
        // `.enter` and `.exit` are the DCS handler telling us control mode
        // began and ended, not tmux notifications; the real stream handler
        // creates and destroys the viewer on them. Here the viewer outlives
        // the session struct, so entering is a no-op and exiting is just
        // recorded.
        switch (n) {
            .pause => self.pauses += 1,
            .enter => return,
            .exit => {
                self.exited = true;
                return;
            },
            else => {},
        }

        try self.dispatch(self.viewer.next(.{ .tmux = n }));
    }

    /// Hand an input to the viewer, sending anything it asks for.
    fn input(self: *Session, in: Viewer.Input) !void {
        try self.dispatch(self.viewer.next(in));
    }

    fn dispatch(self: *Session, actions: []const Viewer.Action) !void {
        for (actions) |action| switch (action) {
            .command => |c| try self.write(c),
            .exit => self.exited = true,
            else => {},
        };
    }

    fn write(self: *Session, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rest = bytes[written..];
            const rc = posix.system.write(self.pty.master, rest.ptr, rest.len);
            switch (posix.errno(rc)) {
                .SUCCESS => written += @intCast(rc),
                .INTR, .AGAIN => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    /// Pump until `pred` is true, or fail.
    fn waitFor(
        self: *Session,
        comptime pred: fn (*Session) bool,
    ) !void {
        // `pump` blocks in poll for at most `poll_ms`, so counting rounds
        // is a clock: no timer needed, and a busy machine just spends
        // longer inside poll rather than spinning.
        var rounds: usize = 0;
        while (rounds < timeout_ms / poll_ms) : (rounds += 1) {
            _ = try self.pump();
            if (pred(self)) return;
        }
        return error.TimedOutWaitingForTmux;
    }

    /// The visible text of a pane's active screen, as the viewer has it.
    fn paneText(self: *Session, pane_id: usize) ![]const u8 {
        const entry = self.viewer.panes.getEntry(pane_id) orelse
            return error.NoSuchPane;
        const screen: *Screen = entry.value_ptr.*.terminal.screens.active;
        return screen.dumpStringAlloc(self.alloc, .{ .active = .{} });
    }

    /// Pump until a pane's visible text contains `needle`, or fail.
    fn waitForPaneText(
        self: *Session,
        pane_id: usize,
        needle: []const u8,
    ) !void {
        var rounds: usize = 0;
        while (rounds < timeout_ms / poll_ms) : (rounds += 1) {
            _ = try self.pump();
            const text = self.paneText(pane_id) catch continue;
            defer self.alloc.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return;
        }
        return error.TimedOutWaitingForTmux;
    }

    /// What tmux thinks one window's size is. Returned in a fixed buffer
    /// the session owns, so callers do not have to free it.
    fn windowSize(self: *Session, window_id: usize) ![]const u8 {
        const target = try std.fmt.allocPrint(self.alloc, "@{d}", .{window_id});
        defer self.alloc.free(target);

        const out = try self.ask(&.{
            "display-message",                  "-p", "-t", target,
            "#{window_width}x#{window_height}",
        });
        defer self.alloc.free(out);

        const trimmed = std.mem.trim(u8, out, " \r\n");
        @memcpy(self.scratch[0..trimmed.len], trimmed);
        return self.scratch[0..trimmed.len];
    }

    /// Ask tmux itself something, rather than trusting our own view of it.
    fn ask(self: *Session, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{
            "tmux", "-f", "/dev/null", "-S", self.socket,
        });
        try argv.appendSlice(self.alloc, args);
        return run(self.alloc, argv.items);
    }
};

/// Wait for a killed child so it does not linger as a zombie for the rest
/// of the test run.
fn reap(pid: posix.pid_t) void {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = posix.system.waitpid(pid, &status, 0);
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => return,
        }
    }
}

/// Run a command to completion and return its stdout.
fn run(alloc: Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    );
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            log.warn(
                "tmux command failed code={d} stderr={s}",
                .{ code, result.stderr },
            );
            return error.TmuxCommandFailed;
        },
        else => return error.TmuxCommandFailed,
    }
    return result.stdout;
}

/// fork/exec `argv` with both ends of `pty` wired up as its terminal.
///
/// Only `execve` is available to us, which does not search PATH, so this
/// goes through `sh -c 'exec "$0" "$@"'`. Passing the real argv as `$0`
/// and `$@` rather than interpolating it into the script means the shell
/// never re-parses our arguments, so nothing here depends on what
/// characters a temp directory happens to contain.
fn spawn(pty: *ptypkg.Pty, argv: []const []const u8) !posix.pid_t {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prefix: []const []const u8 = &.{ "sh", "-c", "exec \"$0\" \"$@\"" };
    const argv_z = try alloc.allocSentinel(
        ?[*:0]const u8,
        prefix.len + argv.len,
        null,
    );
    for (prefix, 0..) |arg, i| argv_z[i] = try alloc.dupeZ(u8, arg);
    for (argv, 0..) |arg, i| argv_z[prefix.len + i] = try alloc.dupeZ(u8, arg);

    const rc = posix.system.fork();
    const pid: posix.pid_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return posix.unexpectedErrno(err),
    };

    if (pid == 0) {
        // Child. Nothing here may return: an error has to become an exit,
        // or we end up with two test runners.
        //
        // The slave has to be the child's std streams before
        // `childPreExec` runs, because that is what closes both ends. dup2
        // rather than dup3 so this stays the same on macOS; the fds we are
        // duplicating onto are not CLOEXEC.
        for ([_]posix.fd_t{ 0, 1, 2 }) |target| {
            if (posix.system.dup2(pty.slave, target) < 0) posix.system.exit(1);
        }
        pty.childPreExec() catch posix.system.exit(1);
        _ = std.c.execve(
            "/bin/sh",
            argv_z.ptr,
            @ptrCast(std.c.environ),
        );
        posix.system.exit(1);
    }
    return pid;
}

fn attached(self: *Session) bool {
    return self.viewer.panes.count() > 0 and
        self.viewer.command_queue.empty();
}

test "live: pane output arrives unescaped" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // `cat` rather than something that prints and exits, because this test
    // is about %output. Content already on screen when we attach comes
    // through `capture-pane` instead, which is a different path with a
    // different escaping dialect.
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();

    try session.waitFor(attached);

    // A full round trip: send-keys into the pane, the tty echoes it, cat
    // repeats it, and all of that comes back to us as %output.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "alpha\rbeta\r",
    } });
    try session.waitForPaneText(0, "beta");

    const text = try session.paneText(0);
    defer alloc.free(text);

    // tmux escapes every byte below a space in %output, so the carriage
    // returns arrive as the four characters `\015`. Undecoded they print
    // as text, nothing ever returns to column 0, and both words pile onto
    // one line -- which is exactly what the first real run of this looked
    // like.
    try testing.expect(std.mem.indexOf(u8, text, "\\015") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\\033") == null);

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var alpha_on_its_own_line = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), "alpha")) {
            alpha_on_its_own_line = true;
        }
    }
    try testing.expect(alpha_on_its_own_line);
    try testing.expect(!session.exited);
}

test "live: a styled pane survives its own capture" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // The content is already on screen when the control client attaches,
    // so the viewer's startup `capture-pane` has something styled to
    // replay. Without -C the reply carries raw ESC bytes, those end the
    // DCS carrying control mode, and the viewer goes defunct.
    var session = try Session.start(
        alloc,
        testing.io,
        80,
        24,
        "printf '\\033[31mRED\\033[0m plain\\r\\n'; sleep 60",
    );
    defer session.deinit();

    try session.waitFor(attached);

    const text = try session.paneText(0);
    defer alloc.free(text);

    try testing.expect(!session.exited);
    try testing.expect(std.mem.indexOf(u8, text, "RED plain") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\033") == null);

    // The escape was obeyed, not just swallowed: the cell is red.
    const entry = session.viewer.panes.getEntry(0).?;
    const screen: *Screen = entry.value_ptr.*.terminal.screens.active;
    const cell = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const page = cell.node.page();
    const style = page.styles.get(page.memory, cell.cell.style_id);
    try testing.expectEqual(
        @as(u8, 1),
        style.fg_color.palette,
    );
}

test "live: a window follows the size we ask for" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // A second window, untouched, as the control: a client-wide resize
    // would take it along; a per-window one must leave it exactly as it
    // was.
    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const resized = session.viewer.windows.items[0].id;
    const untouched = session.viewer.windows.items[1].id;

    try session.input(.{ .resize = .{
        .pane_id = session.viewer.windows.items[0].layout.content.pane,
        .cols = 120,
        .rows = 40,
    } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // The window we asked about took the size.
    try testing.expectEqualStrings(
        "120x40",
        try session.windowSize(resized),
    );

    // Three ways this is the per-window form and not the client-wide one,
    // which `list-windows` alone cannot tell apart because both leave the
    // target window at 120x40:
    //
    //   - the other window did not move,
    //   - the client's own size is unchanged,
    //   - and the session's is too.
    try testing.expectEqualStrings(
        "80x24",
        try session.windowSize(untouched),
    );
    {
        const w = try session.ask(&.{
            "list-clients", "-F", "#{client_width}",
        });
        defer alloc.free(w);
        try testing.expectEqualStrings("80", std.mem.trim(u8, w, " \r\n"));
    }

    try testing.expect(!session.exited);
}

test "live: a flooding pane does not break the session" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // Attach to a quiet pane and start the flood afterwards. Starting it
    // first means the attach handshake -- nine round trips -- races the
    // firehose for the same pty, which is not what this test is for and
    // loses about one run in three.
    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();

    try session.waitFor(attached);

    const pane: *Viewer.Pane = session.viewer.panes.getEntry(0).?.value_ptr.*;
    const pages_before = pane.terminal.screens.active.pages.totalPages();

    // Styled output, not plain. An escape sequence is the thing that can
    // straddle two %output notifications -- tmux splits wherever the pty
    // write landed -- so a payload with nothing to escape would say
    // nothing about reassembly.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "while :; do printf '\\033[31mflood0123456789\\033[0m\\n'; done\r",
    } });

    // Bounded by a byte target rather than a fixed number of rounds: a
    // loaded machine reads fewer bytes per round, and a test that
    // measures the machine instead of the code fails for no reason.
    const target: usize = 512 * 1024;
    const before = session.bytes;
    var rounds: usize = 0;
    while (rounds < 4000) : (rounds += 1) {
        _ = try session.pump();
        if (session.exited) break;
        if (session.bytes - before >= target) break;
    }

    // The flood was real...
    try testing.expect(session.bytes - before >= target);
    try testing.expect(!session.exited);
    try testing.expect(session.viewer.panes.contains(0));

    // ...and the viewer applied it, rather than the bytes merely
    // arriving. Counting pty bytes alone would pass with the whole
    // pane pipeline disconnected.
    try testing.expect(
        pane.terminal.screens.active.pages.totalPages() > pages_before,
    );

    // The pane is coherent rather than a pile of fragments.
    const text = try session.paneText(0);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "flood0123456789") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\033") == null);

    // And the escapes were obeyed rather than printed, across however
    // many notification boundaries they were split over.
    const screen: *Screen = pane.terminal.screens.active;
    const cell = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const page = cell.node.page();
    const style = page.styles.get(page.memory, cell.cell.style_id);
    try testing.expectEqual(@as(u8, 1), style.fg_color.palette);
}

test "live: killing a tmux window drops it here too" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expectEqual(1, session.viewer.windows.items.len);

    // A second window, so there is something left to be attached to when
    // the first one dies.
    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const doomed = session.viewer.windows.items[1].id;
    {
        const target = try std.fmt.allocPrint(alloc, "@{d}", .{doomed});
        defer alloc.free(target);
        const out = try session.ask(&.{ "kill-window", "-t", target });
        alloc.free(out);
    }

    // tmux suppresses the dying window's %layout-change, so the close
    // notification is the only word we get; without it the window would
    // sit here forever as a native window nobody can type into.
    //
    // Killing a window in our own session sends the *unlinked* spelling,
    // `%unlinked-window-close`, because the callback runs after the
    // window has already left the session. This is the case that matters
    // and the one this test covers. Plain `%window-close` arrives when a
    // window is moved out rather than killed, and is handled the same.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 1 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    for (session.viewer.windows.items) |w| {
        try testing.expect(w.id != doomed);
    }
    try testing.expect(!session.exited);
}

test "live: a stray line does not end the session" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();

    try session.waitFor(attached);

    // Feed the malformed line straight into the chain rather than asking
    // tmux to produce one.
    //
    // The obvious provocation -- `rename-window $'a\nb'`, since tmux
    // accepts any valid UTF-8 as a name -- does not work: tmux 3.5a runs
    // names through `utf8_stravis(VIS_OCTAL|VIS_CSTYLE)` in
    // `window_set_name`, so the wire carries `%window-renamed @0 a\nb`
    // with a literal backslash and 'n' on one line. A test written that
    // way passes with the recovery removed, which is worse than no test.
    //
    // Whether any tmux can put a raw newline at the start of a line is
    // not something we can prove from here, so the recovery stays as
    // defence for input we did not anticipate -- and this checks that the
    // defence works on the real chain, parser and viewer included.
    for ("stray line with no percent\n") |byte| try session.feed(byte);

    try testing.expect(!session.exited);

    // Not merely un-exited: still working. A parser left in the broken
    // state drops everything after it, so this would never arrive.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "survived\r",
    } });
    try session.waitForPaneText(0, "survived");
    try testing.expect(!session.exited);
}

test "live: a paused pane is resumed and re-read" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();

    try session.waitFor(attached);

    // Put something on screen first. It has to still be there afterwards:
    // the recovery re-reads the pane, and a re-read that dropped the
    // scrollback would be its own bug.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "echo before-pause\r",
    } });
    try session.waitForPaneText(0, "before-pause");

    // Pause the pane outright rather than provoking tmux's own
    // pause-after timer. Falling behind on purpose does reach the same
    // code, but whether tmux decides we are late enough is a race, and it
    // fired about half the time. `control_pause_pane` is the same
    // function the timer calls (cmd-refresh-client.c), so this exercises
    // the identical path with none of the timing.
    //
    // We never enable pause-after ourselves; this is here because any
    // other client can, and a paused pane is indistinguishable from a
    // frozen one.
    {
        const clients = try session.ask(&.{
            "list-clients", "-F", "#{client_name}",
        });
        defer alloc.free(clients);
        const name = std.mem.trim(u8, clients, " \r\n");

        const out = try session.ask(&.{
            "refresh-client", "-t", name, "-A", "%0:pause",
        });
        alloc.free(out);
    }

    // While the pane is paused, make it print something. tmux discards a
    // paused pane's output rather than buffering it, so this can only
    // ever reach us through a capture -- which makes it the thing that
    // tells a real recovery apart from a bare resume. Sent through the
    // tmux CLI rather than the viewer so it does not queue behind the
    // recovery commands.
    {
        const out = try session.ask(&.{
            "send-keys", "-t", "%0", "echo during-pause", "Enter",
        });
        alloc.free(out);
    }

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.pauses > 0;
        }
    }.pred);

    // The recovery is a resume plus a full re-read of the pane, because
    // tmux discards a paused pane's output rather than buffering it. It
    // has landed once the queue drains.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expect(!session.exited);
    try testing.expect(session.viewer.panes.contains(0));

    // The re-read half of the recovery. What the pane printed while it
    // was paused never came to us as %output -- tmux threw it away -- so
    // it is on screen only if we read the pane again afterwards. A
    // recovery that merely resumed would leave a permanent hole here.
    try session.waitForPaneText(0, "during-pause");

    // And the re-read did not cost us what was already there.
    {
        const text = try session.paneText(0);
        defer alloc.free(text);
        try testing.expect(
            std.mem.indexOf(u8, text, "before-pause") != null,
        );
    }

    // Output reaches us again, which it would not if the pane were still
    // paused: tmux would be dropping it server side.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "echo resumed-ok\r",
    } });
    try session.waitForPaneText(0, "resumed-ok");
    try testing.expect(!session.exited);
}

test "live: window names arrive and follow renames" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // A name with spaces in it, because that is the case the format
    // cannot handle by splitting: `list-windows` separates its fields
    // with spaces, so the name has to be the rest of the line.
    {
        const out = try session.ask(&.{ "rename-window", "my long name" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len > 0 and
                std.mem.eql(u8, v.viewer.windows.items[0].name, "my long name");
        }
    }.pred);

    // And a name arriving through `list-windows` rather than through the
    // rename notification, which is the other half of the plumbing: a new
    // window forces a re-list.
    {
        const out = try session.ask(&.{
            "new-window", "-d", "-n", "second window", "sleep 60",
        });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            if (v.viewer.windows.items.len != 2) return false;
            if (!v.viewer.command_queue.empty()) return false;
            for (v.viewer.windows.items) |w| {
                if (std.mem.eql(u8, w.name, "second window")) return true;
            }
            return false;
        }
    }.pred);

    // The first window kept its name across the re-list.
    var found = false;
    for (session.viewer.windows.items) |w| {
        if (std.mem.eql(u8, w.name, "my long name")) found = true;
    }
    try testing.expect(found);
    try testing.expect(!session.exited);
}

test "live: a new tab is a new tmux window" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expectEqual(1, session.viewer.windows.items.len);

    try session.input(.new_window);

    // tmux answers with %window-add, which re-lists, which is what makes
    // the window appear here. Nothing is remembered in between.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // And tmux agrees, rather than us having invented a window.
    const count = try session.ask(&.{
        "display-message", "-p", "#{session_windows}",
    });
    defer alloc.free(count);
    try testing.expectEqualStrings("2", std.mem.trim(u8, count, " \r\n"));
    try testing.expect(!session.exited);
}

test "live: zooming a pane round-trips through tmux" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try session.input(.{ .zoom_pane = .{ .pane_id = 1 } });

    // tmux answers with a layout, and that is what makes it true here.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items[0].zoomed_pane_id != null and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expectEqual(1, session.viewer.windows.items[0].zoomed_pane_id.?);

    // tmux's own opinion, not ours.
    {
        const zoomed = try session.ask(&.{
            "display-message", "-p", "#{window_zoomed_flag}",
        });
        defer alloc.free(zoomed);
        try testing.expectEqualStrings("1", std.mem.trim(u8, zoomed, " \r\n"));
    }

    // Both panes are still here. A zoomed window's visible layout names
    // only the zoomed pane, and this is what would break if that ever
    // drove the pane diff.
    try testing.expectEqual(2, session.viewer.panes.count());

    // And it toggles back.
    try session.input(.{ .zoom_pane = .{ .pane_id = 1 } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items[0].zoomed_pane_id == null and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expectEqual(2, session.viewer.panes.count());
    try testing.expect(!session.exited);
}

test "live: tmux changing window tells us, and settles" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // We learned which window is current from `list-windows`, without
    // being told: %session-window-changed only fires on a change.
    try testing.expect(session.viewer.current_window_id != null);
    const first = session.viewer.windows.items[0].id;
    const second = session.viewer.windows.items[1].id;
    try testing.expectEqual(first, session.viewer.current_window_id.?);

    // Somebody else moves the session to the other window.
    {
        const target = try std.fmt.allocPrint(alloc, "@{d}", .{second});
        defer alloc.free(target);
        const out = try session.ask(&.{ "select-window", "-t", target });
        alloc.free(out);
    }

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.current_window_id != null and
                v.viewer.current_window_id.? != v.viewer.windows.items[0].id and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expectEqual(second, session.viewer.current_window_id.?);
    for (session.viewer.windows.items) |w| {
        try testing.expectEqual(w.id == second, w.active);
    }

    // And it settled: the notification did not send a command back, so
    // there is nothing in flight and nothing more coming.
    try testing.expect(session.viewer.command_queue.empty());
    try testing.expect(!session.exited);
}

test "live: focusing a pane moves tmux's active pane" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // tmux makes the pane it just created the active one, so asking for
    // the *other* one is a real change and not a no-op that would pass
    // whatever we sent.
    const active_after_split = try session.ask(&.{
        "display-message", "-p", "#{pane_id}",
    });
    defer alloc.free(active_after_split);
    try testing.expectEqualStrings(
        "%1",
        std.mem.trim(u8, active_after_split, " \r\n"),
    );

    try session.input(.{ .select_pane = .{ .pane_id = 0 } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    const active = try session.ask(&.{
        "display-message", "-p", "#{pane_id}",
    });
    defer alloc.free(active);
    try testing.expectEqualStrings("%0", std.mem.trim(u8, active, " \r\n"));
    try testing.expect(!session.exited);
}

test "live: tmux accepts the pause-after flag we send it" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "sleep 60",
        .{ .pause_after = 30 },
    );
    defer session.deinit();

    try session.waitFor(attached);
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // The point of the test. `refresh-client -f` answers an unknown flag
    // with an error block, and an error block is not something the
    // startup sequence survives quietly -- so a session that is still
    // alive and idle here is tmux having accepted it.
    try testing.expect(!session.exited);

    // And tmux says so itself rather than us inferring it from silence.
    const flags = try session.ask(&.{
        "list-clients", "-F", "#{client_flags}",
    });
    defer alloc.free(flags);
    try testing.expect(
        std.mem.indexOf(u8, flags, "pause-after") != null,
    );
}

test "live: detaching ends control mode and leaves the session running" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expect(!session.exited);

    try session.input(.detach);

    // tmux ends control mode, which is how the GUI learns to close the
    // windows this client was showing.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.exited;
        }
    }.pred);

    // The half that makes this detach and not kill: the server is still
    // up and the session is still in it, with its window still running.
    // Without this the test passes just as well for `kill-session`.
    const sessions = try session.ask(&.{
        "list-sessions", "-F", "#{session_windows}",
    });
    defer alloc.free(sessions);
    try testing.expectEqualStrings("1", std.mem.trim(u8, sessions, " \r\n"));
}

test "live: a split makes a second pane in the same window" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expectEqual(1, session.viewer.panes.count());

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .right } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // Still one window: a split is a pane, not a tab.
    try testing.expectEqual(1, session.viewer.windows.items.len);

    // Side by side, as asked. tmux reports the layout, so this is its
    // opinion and not ours: two panes at the same y, different x.
    const layout = session.viewer.windows.items[0].layout;
    try testing.expect(layout.content == .horizontal);
    try testing.expect(!session.exited);
}

test "live: a downward split stacks the panes" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const layout = session.viewer.windows.items[0].layout;
    try testing.expect(layout.content == .vertical);
    try testing.expect(!session.exited);
}
