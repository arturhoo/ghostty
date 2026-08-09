const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const CursorStyle = @import("../cursor.zig").Style;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");
const sinkpkg = @import("sink.zig");
const Sink = sinkpkg.Sink;

const log = std.log.scoped(.terminal_tmux_viewer);

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We need to ignore `output` for panes that aren't yet initialized
//   (until capture-panes are complete).
// - We should note what the active window pane is on the tmux side;
//   we can use this at least for initial focus.

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │            startup_block                    │
///                              │                                             │
///                              │  Wait for initial %begin/%end block from    │
///                              │  tmux. This is the response to the initial  │
///                              │  command (e.g., "attach -t 0").             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %end / %error
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           startup_session                   │
///                              │                                             │
///                              │  Wait for %session-changed notification     │
///                              │  to get the initial session ID.             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %session-changed
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                    ┌───────────────────────────┴───────────────────────────┐
///                    │                  For each new pane:                   │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (primary screen)     │                            │     (primary screen)     │
///     │                          │                            │                          │
///     │  Capture scrollback      │                            │  Capture visible area    │
///     │  history into terminal.  │                            │  into terminal.          │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (alternate screen)   │                            │     (alternate screen)   │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    └───────────────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///
pub const Viewer = struct {
    /// I/O implementation used for all internal state.
    io: std.Io,

    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// The last client size we reported to tmux, so we don't re-send an
    /// unchanged one. See `nextClientSize`.
    last_client_size: ?struct {
        cols: usize,
        rows: usize,
    } = null,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, *Pane);

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        switch (u_field.type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,

        /// Data to write to a pane, e.g. keyboard input encoded by the
        /// caller into the bytes a normal pty would receive.
        write: Write,

        /// Ask tmux to resize a pane, because whatever is displaying it
        /// changed size.
        resize: Resize,

        /// Tell tmux how big our control mode client is. tmux sizes the
        /// session to its smallest attached client, so without this a
        /// second attached client can pin our panes small.
        client_size: ClientSize,

        /// Ask tmux to kill a pane, because the thing displaying it was
        /// closed.
        kill_pane: KillPane,

        pub const Write = struct {
            pane_id: usize,
            data: []const u8,
        };

        pub const Resize = struct {
            pane_id: usize,
            cols: usize,
            rows: usize,
        };

        pub const ClientSize = struct {
            cols: usize,
            rows: usize,
        };

        pub const KillPane = struct {
            pane_id: usize,
        };
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,

        /// The last size we asked tmux to make this window. Like a pane's
        /// request this is what we asked for, not what tmux settled on, so
        /// that a clamped request is not re-sent forever. See
        /// `windowResizeCommand`.
        last_size_request: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            self.layout_arena.promote(alloc).deinit();
        }
    };

    /// A single tmux pane.
    ///
    /// Panes are heap allocated and referenced by pointer from `PanesMap`,
    /// so that a pane keeps one address for its whole life. That matters
    /// because `stream` contains pointers back into the pane: the parser's
    /// handler points at `terminal`, and the OSC parser's capture writer
    /// points into the parser's own buffer. A pane stored by value in a
    /// hash map would have all of those silently invalidated the first
    /// time the map grew or the pane was moved between maps, and a
    /// half-parsed OSC sequence would then write through a dangling
    /// pointer.
    pub const Pane = struct {
        terminal: Terminal,

        /// The VT parser for this pane.
        ///
        /// This is persistent because tmux splits a pane's output across
        /// `%output` notifications wherever the pty write landed, so an
        /// escape sequence can straddle two of them. A fresh parser per
        /// notification loses the prefix and prints the tail as text.
        stream: TerminalStream,

        /// Where this pane's operations are mirrored, if anything has
        /// attached. See `attachPane`.
        sink: ?Sink = null,

        /// The size this pane is asking for and has not been given.
        ///
        /// Used by `composeLayoutSize` to work out how big the window has
        /// to be. Cleared as soon as tmux answers with a layout, because
        /// from then on tmux's size is the truth about this pane and a
        /// spent request would compose a stale window for a sibling.
        last_resize_request: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        /// The last size we actually asked tmux for.
        ///
        /// Deliberately separate from `last_resize_request`, and
        /// deliberately never cleared by tmux: a resize is a request and
        /// the layout is the ruling, so tmux is free to answer with
        /// something else. When it does, the surface has not moved and
        /// asks for the same size again -- and because every resize is
        /// answered with a layout, re-sending it is not one wasted round
        /// trip but a loop with no end. This remembers the question we
        /// already had answered so we do not ask it again.
        last_resize_sent: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        pub fn create(
            io: std.Io,
            alloc: Allocator,
            cols: size.CellCountInt,
            rows: size.CellCountInt,
        ) !*Pane {
            const self = try alloc.create(Pane);
            errdefer alloc.destroy(self);

            self.terminal = try .init(io, alloc, .{
                .cols = cols,
                .rows = rows,
            });
            errdefer self.terminal.deinit(alloc);

            // Only valid because `self` never moves again.
            self.stream = self.terminal.vtStream();
            self.sink = null;

            // Field defaults do not apply here: `self` is uninitialized
            // memory and every field is assigned by hand, so anything left
            // out keeps whatever was in the allocation.
            self.last_resize_request = null;
            self.last_resize_sent = null;

            return self;
        }

        pub fn destroy(self: *Pane, alloc: Allocator) void {
            if (self.sink) |s| s.close();
            self.stream.deinit();
            self.terminal.deinit(alloc);
            alloc.destroy(self);
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(io: std.Io, alloc: Allocator) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .io = io,
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .tmux_version = "",
            .command_queue = command_queue,
            .windows = .empty,
            .panes = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.*.destroy(self.alloc);
            self.panes.deinit(self.alloc);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
            .write => self.nextWrite(input.write),
            .resize => self.nextResize(input.resize),
            .client_size => self.nextClientSize(input.client_size),
            .kill_pane => self.nextKillPane(input.kill_pane),
        };
    }

    /// Ask tmux to resize a pane.
    ///
    /// Two things can need to change, because a pane can never be larger
    /// than the tmux window holding it: the window's size, and the pane's
    /// share of that window. A pane that is alone in its window only needs
    /// the first, since it always fills whatever the window is.
    ///
    /// Deduplicated against the last size we asked for, not against the
    /// pane's current size: tmux clamps a resize to what the layout allows,
    /// so comparing against the result would make us re-send the same
    /// request forever.
    fn nextResize(self: *Viewer, r: Input.Resize) []const Action {
        if (self.state != .command_queue) return &.{};
        if (r.cols == 0 or r.rows == 0) return &.{};

        const pane: *Pane = (self.panes.getEntry(r.pane_id) orelse {
            log.info("resize of unknown pane id={}, dropping", .{r.pane_id});
            return &.{};
        }).value_ptr.*;

        // Against what we last sent, not what the pane is still asking
        // for: tmux clears the request when it answers, and the answer is
        // often not what we asked for.
        if (pane.last_resize_sent) |last| {
            if (last.cols == r.cols and last.rows == r.rows) return &.{};
        }
        pane.last_resize_sent = .{ .cols = r.cols, .rows = r.rows };
        pane.last_resize_request = .{ .cols = r.cols, .rows = r.rows };

        return self.queueResize(r) catch |err| {
            log.warn(
                "failed to queue resize for pane id={} err={}",
                .{ r.pane_id, err },
            );
            return &.{};
        };
    }

    fn queueResize(
        self: *Viewer,
        r: Input.Resize,
    ) Allocator.Error![]const Action {
        var commands: [2]Command = undefined;
        var count: usize = 0;
        errdefer for (commands[0..count]) |c| c.deinit(self.alloc);

        // The window first: growing a pane into space the window does not
        // have yet would just be clamped away.
        var pane_needed = true;
        if (try self.windowResizeCommand(r.pane_id)) |result| {
            if (result.command) |c| {
                commands[count] = c;
                count += 1;

                // A lone pane is its window, so `resize-pane` could only
                // ask for the size we just asked for.
                if (result.only_pane_in_window) pane_needed = false;
            }
        }

        if (pane_needed) {
            commands[count] = try self.userCommand(
                "resize-pane -t %{d} -x {d} -y {d}\n",
                .{ r.pane_id, r.cols, r.rows },
            );
            count += 1;
        }

        // Ownership passes to the queue, success or not.
        const n = count;
        count = 0;
        return self.queueUserCommands(commands[0..n]);
    }

    const WindowResize = struct {
        /// Null when the window is already the size we want, or when tmux
        /// is too old to be told.
        command: ?Command,
        only_pane_in_window: bool,
    };

    /// Build the command that sizes the tmux window holding `pane_id`.
    ///
    /// tmux lays every window out inside its client's size, so a control
    /// client that reports one size gets one size for all of its windows.
    /// That is wrong for us: each tmux window is its own native window and
    /// has its own size. `refresh-client -C @id:WxH` sets a per-window size
    /// that `clients_calculate_size` uses in place of the client's own for
    /// that window (see tmux's resize.c), which is exactly what we want.
    ///
    /// The size comes from the panes rather than from the apprt, because
    /// the viewer is what knows the layout: composing the panes' requested
    /// sizes the same way tmux composes a layout gives the size the native
    /// window is asking for, dividers included.
    ///
    /// Returns null if the pane is in no window we know about.
    fn windowResizeCommand(
        self: *Viewer,
        pane_id: usize,
    ) Allocator.Error!?WindowResize {
        const window: *Window = self.windowForPane(pane_id) orelse return null;
        const want = composeLayoutSize(&self.panes, window.layout);
        const only = window.layout.content == .pane;

        if (window.last_size_request) |last| {
            if (last.cols == want.cols and last.rows == want.rows) {
                return .{ .command = null, .only_pane_in_window = only };
            }
        }

        window.last_size_request = .{ .cols = want.cols, .rows = want.rows };

        // Per-window sizes through `refresh-client -C @id:WxH` landed in
        // tmux 3.4. An older server parses that argument as a plain size,
        // fails, and answers with an error, so it gets `resize-window`
        // instead -- which is what iTerm2 does, and which reaches the
        // same place by a blunter route: it pins the window's size by
        // setting `window-size` to manual for it, a server side change
        // that outlives us. Worth it, because the alternative is a window
        // stuck at whatever size the host surface happens to be.
        const command = if (self.tmuxVersionAtLeast(3, 4))
            try self.userCommand(
                "refresh-client -C @{d}:{d}x{d}\n",
                .{ window.id, want.cols, want.rows },
            )
        else
            try self.userCommand(
                "resize-window -x {d} -y {d} -t @{d}\n",
                .{ want.cols, want.rows, window.id },
            );

        return .{
            .command = command,
            .only_pane_in_window = only,
        };
    }

    /// The window containing the given pane, if any.
    fn windowForPane(self: *Viewer, pane_id: usize) ?*Window {
        for (self.windows.items) |*window| {
            if (layoutContainsPane(window.layout, pane_id)) return window;
        }
        return null;
    }

    fn layoutContainsPane(node: Layout, pane_id: usize) bool {
        return switch (node.content) {
            .pane => |id| id == pane_id,
            .horizontal, .vertical => |children| for (children) |child| {
                if (layoutContainsPane(child, pane_id)) break true;
            } else false,
        };
    }

    /// The size a layout would need to hold every pane at the size that
    /// pane last asked for, falling back to the size tmux gave it.
    ///
    /// This is tmux's own composition: a split costs one cell for the
    /// divider between each pair of children, and the other axis is the
    /// largest child. See `layout_fix_offsets` in tmux's layout.c.
    fn composeLayoutSize(
        panes: *const PanesMap,
        node: Layout,
    ) struct { cols: usize, rows: usize } {
        switch (node.content) {
            .pane => |id| {
                if (panes.get(id)) |pane| {
                    if (pane.last_resize_request) |r| {
                        return .{ .cols = r.cols, .rows = r.rows };
                    }
                }
                return .{ .cols = node.width, .rows = node.height };
            },

            .horizontal => |children| {
                var cols: usize = children.len -| 1;
                var rows: usize = 0;
                for (children) |child| {
                    const child_size = composeLayoutSize(panes, child);
                    cols += child_size.cols;
                    rows = @max(rows, child_size.rows);
                }
                return .{ .cols = cols, .rows = rows };
            },

            .vertical => |children| {
                var cols: usize = 0;
                var rows: usize = children.len -| 1;
                for (children) |child| {
                    const child_size = composeLayoutSize(panes, child);
                    cols = @max(cols, child_size.cols);
                    rows += child_size.rows;
                }
                return .{ .cols = cols, .rows = rows };
            },
        }
    }

    /// Whether the tmux we are talking to is at least the given version.
    ///
    /// tmux reports versions like `3.5a`, where the letter is a bug-fix
    /// release, so only the leading `major.minor` is compared. An
    /// unparseable version answers false: a feature we cannot confirm is
    /// a feature we do not use.
    fn tmuxVersionAtLeast(self: *const Viewer, major: usize, minor: usize) bool {
        var it = std.mem.splitScalar(u8, self.tmux_version, '.');
        const major_str = it.next() orelse return false;
        const minor_str = it.next() orelse return false;

        const got_major = std.fmt.parseInt(usize, major_str, 10) catch
            return false;

        // Trim any bug-fix letter, e.g. the `a` of `3.5a`.
        const digits = end: {
            var end: usize = 0;
            while (end < minor_str.len and std.ascii.isDigit(minor_str[end])) {
                end += 1;
            }
            break :end minor_str[0..end];
        };
        const got_minor = std.fmt.parseInt(usize, digits, 10) catch
            return false;

        if (got_major != major) return got_major > major;
        return got_minor >= minor;
    }

    /// Tell tmux the size of our control mode client.
    fn nextClientSize(self: *Viewer, c: Input.ClientSize) []const Action {
        if (self.state != .command_queue) return &.{};
        if (c.cols == 0 or c.rows == 0) return &.{};

        if (self.last_client_size) |last| {
            if (last.cols == c.cols and last.rows == c.rows) return &.{};
        }
        self.last_client_size = .{ .cols = c.cols, .rows = c.rows };

        return self.queueUserCommand("refresh-client -C {d}x{d}\n", .{
            c.cols,
            c.rows,
        }) catch {
            log.warn("failed to queue client size", .{});
            return &.{};
        };
    }

    /// Ask tmux to kill a pane.
    fn nextKillPane(self: *Viewer, k: Input.KillPane) []const Action {
        if (self.state != .command_queue) return &.{};

        if (!self.panes.contains(k.pane_id)) {
            log.info("kill of unknown pane id={}, dropping", .{k.pane_id});
            return &.{};
        }

        return self.queueUserCommand("kill-pane -t %{d}\n", .{
            k.pane_id,
        }) catch {
            log.warn("failed to queue kill for pane id={}", .{k.pane_id});
            return &.{};
        };
    }

    /// Queue a command for tmux, returning the action that sends it if
    /// nothing else is already in flight.
    ///
    /// Everything the caller can ask tmux to do goes through here, so we
    /// never have more than one command outstanding; tmux answers each
    /// with a `%begin`/`%end` block that `receivedCommandOutput` discards.
    fn queueUserCommand(
        self: *Viewer,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error![]const Action {
        // queueUserCommands takes ownership whether it succeeds or not.
        return self.queueUserCommands(&.{try self.userCommand(fmt, args)});
    }

    /// Build a user command from a format string. The caller owns it
    /// until it is handed to `queueUserCommands`.
    fn userCommand(
        self: *Viewer,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!Command {
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer builder.deinit();
        builder.writer.print(fmt, args) catch return error.OutOfMemory;
        return .{ .user = try builder.toOwnedSlice() };
    }

    /// Queue commands, returning the action that sends the first of them
    /// if nothing was already in flight. Ownership of `commands` passes to
    /// the queue whether this succeeds or not.
    fn queueUserCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state == .command_queue);
        assert(commands.len > 0);
        errdefer for (commands) |c| c.deinit(self.alloc);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);

        // If a command is already in flight then ours are sent later, as
        // each one ahead completes (see the tail of `nextCommand`).
        const was_empty = self.command_queue.empty();
        const action: ?Action = if (was_empty) action: {
            var builder: std.Io.Writer.Allocating = .init(arena.allocator());
            commands[0].formatCommand(&builder.writer) catch
                return error.OutOfMemory;
            break :action .{ .command = builder.writer.buffered() };
        } else null;

        // Must be the last fallible operation: past this point the queue
        // owns the commands and our errdefer would double free them.
        try self.queueCommands(commands);

        return if (action) |a| self.singleAction(a) else &.{};
    }

    /// Send bytes to a pane as tmux `send-keys`.
    ///
    /// This goes through the command queue like any other command so that
    /// we never have more than one command in flight; tmux replies to it
    /// with a `%begin`/`%end` block that `receivedCommandOutput` discards.
    fn nextWrite(
        self: *Viewer,
        w: Input.Write,
    ) []const Action {
        // We can only send input once we've reached steady state. Before
        // that we're still replaying startup commands and don't know the
        // pane set.
        if (self.state != .command_queue) {
            log.info(
                "write to pane id={} while not ready, dropping",
                .{w.pane_id},
            );
            return &.{};
        }

        // Drop writes to panes we don't know about rather than letting
        // tmux error on an unknown target.
        if (!self.panes.contains(w.pane_id)) {
            log.info("write to unknown pane id={}, dropping", .{w.pane_id});
            return &.{};
        }

        // Nothing to send. Avoid a `send-keys` with no keys, which tmux
        // would interpret as "send the key this command is bound to".
        if (w.data.len == 0) return &.{};

        return self.queueWrite(w) catch {
            log.warn(
                "failed to queue write for pane id={}, dropping",
                .{w.pane_id},
            );
            return &.{};
        };
    }

    fn queueWrite(
        self: *Viewer,
        w: Input.Write,
    ) Allocator.Error![]const Action {
        // `send-keys -H` takes each key as a hexadecimal number, so we can
        // pass arbitrary encoded input through byte-for-byte without tmux
        // attempting to interpret any of it as a key name.
        var hex: std.Io.Writer.Allocating = .init(self.alloc);
        defer hex.deinit();
        for (w.data) |byte| hex.writer.print(
            " {x:0>2}",
            .{byte},
        ) catch return error.OutOfMemory;

        return self.queueUserCommand("send-keys -H -t %{d}{s}\n", .{
            w.pane_id,
            hex.writer.buffered(),
        });
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => |reason| {
                if (reason) |r| log.info("tmux control mode exited: {s}", .{r});
                return self.defunct();
            },

            // Any begin and end (even error) is fine! Now we wait for
            // session-changed to get the initial session ID. session-changed
            // is guaranteed to come after the initial command output
            // since if the initial command is `attach` tmux will run that,
            // queue the notification, then do notificatins.
            .block_end, .block_err => {
                self.state = .startup_session;
                return &.{};
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => |reason| {
                if (reason) |r| log.info("tmux control mode exited: {s}", .{r});
                return self.defunct();
            },

            .session_changed => |info| {
                self.session_id = info.id;

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);

                return self.enterCommandQueue(
                    arena.allocator(),
                    &.{ .tmux_version, .list_windows },
                ) catch {
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };
            },

            else => return &.{},
        }
    }

    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .idle);

        switch (n) {
            .enter => unreachable,
            .exit => |reason| {
                if (reason) |r| log.info("tmux control mode exited: {s}", .{r});
                return self.defunct();
            },
            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // Track whether the in-flight command slot is available. Starts true
        // if queue is empty (no command in flight). Set to true when a command
        // completes (block_end/block_err) or the queue is reset (session_changed).
        var command_consumed = self.command_queue.empty();

        switch (n) {
            .enter => unreachable,
            .exit => |reason| {
                if (reason) |r| log.info("tmux control mode exited: {s}", .{r});
                return self.defunct();
            },

            inline .block_end,
            .block_err,
            => |content, tag| {
                self.receivedCommandOutput(
                    &actions,
                    content,
                    tag == .block_err,
                ) catch {
                    log.warn("failed to process command output, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed since a block end/err is the output
                // from a command.
                command_consumed = true;
            },

            .output => |out| self.receivedOutput(
                out.pane_id,
                out.data,
            ) catch |err| {
                log.warn(
                    "failed to process output for pane id={}: {}",
                    .{ out.pane_id, err },
                );
            },

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed because sessionChanged resets
                // our entire viewer.
                command_consumed = true;
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // tmux stopped sending us a pane's output. Ask for it back
            // and re-read the pane, since what it discarded meanwhile is
            // gone for good.
            .pause => |info| self.pauseRecover(info.pane_id) catch {
                log.warn("failed to resume a paused pane, becoming defunct", .{});
                return self.defunct();
            },

            // tmux acknowledging the resume we asked for above. The
            // capture commands queued alongside it do the rest.
            .@"continue" => |info| log.info(
                "tmux resumed pane id={}",
                .{info.pane_id},
            ),

            // A window left this session, by being killed, by its last
            // pane exiting, or by being moved elsewhere.
            .window_close => |info| self.windowClose(info.id) catch {
                log.warn("failed to handle window close, becoming defunct", .{});
                return self.defunct();
            },

            // The active pane changed. We don't care about this because
            // we handle our own focus.
            .window_pane_changed => {},

            // We ignore this one. It means a session was created or
            // destroyed. If it was our own session we will get an exit
            // notification very soon. If it is another session we don't
            // care.
            .sessions_changed => {},

            // We don't use window names for anything, currently.
            .window_renamed => {},

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => {},
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands. We only emit a
        // command if a prior command was consumed (or never existed).
        if (self.state == .command_queue and command_consumed) {
            if (self.command_queue.first()) |next_command| {
                // We should not have any commands, because our nextCommand
                // always queues them.
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();

                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
            }
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        // Clear our prior window arena and setup our layout
        window.layout = layout: {
            var arena = window.layout_arena.promote(self.alloc);
            defer window.layout_arena = arena.state;
            _ = arena.reset(.retain_capacity);
            break :layout Layout.parseWithChecksum(
                arena.allocator(),
                layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return err;
            };
        };

        // Reset our arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
    }

    /// When a window is added to the session, we need to refresh our window
    /// list to get the new window's information.
    /// Bring a paused pane back.
    ///
    /// tmux pauses a pane when the pause-after client flag is set and we
    /// fall behind on it. We never set that flag, but any other client
    /// can set it on us, and while a pane is paused tmux *discards* its
    /// output rather than buffering it (`control_write_output` in
    /// control.c). So resuming is not enough: everything between the
    /// pause and the resume is gone, and a shadow terminal that simply
    /// carried on would be quietly wrong from then on.
    ///
    /// Re-read the pane instead, exactly as if it were new.
    fn pauseRecover(self: *Viewer, pane_id: usize) !void {
        if (!self.panes.contains(pane_id)) {
            log.info("pause for untracked pane id={}, dropping", .{pane_id});
            return;
        }

        const resume_cmd = try self.userCommand(
            "refresh-client -A '%{d}:continue'\n",
            .{pane_id},
        );
        errdefer resume_cmd.deinit(self.alloc);

        try self.queueCommands(&.{
            resume_cmd,
            .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
            .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
            .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
            .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
            .pane_state,
        });
    }

    /// A window we were showing is gone.
    ///
    /// Refresh the whole list rather than pruning by hand: `syncLayouts`
    /// already drops the window, destroys its panes and closes their
    /// sinks, and doing that in two places is where a lifetime bug would
    /// live. The cost is one round trip.
    fn windowClose(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id;
        try self.queueCommands(&.{.list_windows});
    }

    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id; // We refresh all windows via list-windows

        // Queue list-windows to get the updated window list
        try self.queueCommands(&.{.list_windows});
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.*.destroy(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.io,
            self.alloc,
            &self.panes,
            &panes,
            window.layout,
        );

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Get our list of added panes and setup our command queue
        // to populate them.
        // TODO: errdefer cleanup
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added = true;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });
            }

            // If we added any panes, then we also want to resync the pane
            // state (terminal modes and cursor positions and so on).
            if (added) try self.queueCommands(&.{.pane_state});
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                entry_const.value.destroy(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        var replacement: Viewer = try .init(self.io, self.alloc);
        errdefer replacement.deinit();

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Setup our command queue and put ourselves in the command queue
        // state.
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and jump directly to the list
        self.session_id = session_id;

        assert(self.state == .command_queue);
    }

    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return;
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            .user => {},

            .pane_state => try self.receivedPaneState(content),

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
            ),

            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                content,
            ),

            .tmux_version => try self.receivedTmuxVersion(content),
        }
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch |err| {
            log.info("failed to parse tmux version: {s}", .{line});
            return err;
        };

        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        defer windows.deinit(self.alloc);

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch |err| {
                log.info("failed to parse list-windows line: {s}", .{line});
                return err;
            };

            // Parse the layout
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const window_alloc = arena.allocator();
            const layout: Layout = Layout.parseWithChecksum(
                window_alloc,
                data.window_layout,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                return err;
            };

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout_arena = arena.state,
                .layout = layout,
            });
        }

        // Sync up our layouts. This will populate unknown panes, prune, etc.
        // This moves the windows above into our own window list, so it must
        // happen before we build the action below.
        try self.syncLayouts(windows.items);

        // Setup our windows action so the caller can process GUI
        // window changes. This has to reference our own window list: the
        // local list above only owns the slice until we return.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse list-panes line: {s}", .{line});
                return err;
            };

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };

            try self.paneOps(entry.value_ptr.*, &.{.{ .pane_state = data }});
        }
    }

    /// Mirror a pane's operations somewhere else, typically a surface that
    /// renders the pane.
    ///
    /// Attach while the pane's initial captures are still in flight, which
    /// is what happens if you attach in response to a `.windows` action:
    /// the captures are queued before that action is emitted, so their
    /// replies reach the sink. A pane that has been alive for a while will
    /// only mirror what happens from now on; re-capturing for a late
    /// attacher is not implemented yet.
    ///
    /// The sink's first op is always a `.resize` carrying the pane's
    /// current size, so a consumer never has to guess the geometry it is
    /// about to receive content for.
    ///
    /// Fails with `PaneMidSequence` if the pane's parser is part way
    /// through an escape sequence. The sink's parser starts fresh, so it
    /// would receive the tail without the prefix and print it as text.
    /// Attaching again once the sequence completes will succeed.
    ///
    /// An existing sink for the pane is closed and replaced.
    pub fn attachPane(
        self: *Viewer,
        pane_id: usize,
        s: Sink,
    ) error{ UnknownPane, PaneMidSequence }!void {
        const entry = self.panes.getEntry(pane_id) orelse
            return error.UnknownPane;
        const pane: *Pane = entry.value_ptr.*;

        if (!pane.stream.ground()) {
            log.info(
                "attach to pane id={} while mid-sequence, refusing",
                .{pane_id},
            );
            return error.PaneMidSequence;
        }

        if (pane.sink) |old| old.close();
        pane.sink = s;

        s.send(&.{.{ .resize = .{
            .cols = pane.terminal.cols,
            .rows = pane.terminal.rows,
        } }});
    }

    /// Stop mirroring a pane. Closes the sink. Safe to call for a pane
    /// that is unknown or has nothing attached.
    pub fn detachPane(self: *Viewer, pane_id: usize) void {
        const entry = self.panes.getEntry(pane_id) orelse return;
        const pane: *Pane = entry.value_ptr.*;
        if (pane.sink) |s| {
            s.close();
            pane.sink = null;
        }
    }

    /// Apply operations to a pane's terminal and mirror them to its sink.
    ///
    /// Both sides see the same ops and, apart from the byte stream, run the
    /// same `applyOp`, which is what stops the shadow terminal and the
    /// attached one from drifting.
    fn paneOps(
        self: *Viewer,
        pane: *Pane,
        ops: []const sinkpkg.Op,
    ) !void {
        for (ops) |op| switch (op) {
            // The stream is per-pane and persistent, so it can't go
            // through applyOp.
            .bytes => |b| pane.stream.nextSlice(b),
            else => try sinkpkg.applyOp(self.alloc, &pane.terminal, op),
        };

        if (pane.sink) |s| s.send(ops);
    }

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // The replay populates the active area too, so it won't be exactly
        // correct, but scrolling it into history leaves only the scrollback
        // we were after and we'll get the active contents soon.
        //
        // The captures ask tmux to escape everything non-printable so that
        // no raw ESC ever reaches the DCS carrying control mode, so the
        // escape sequences `-e` asked for arrive as text and have to be
        // turned back into bytes here. A block payload is const, unlike an
        // %output payload, so this decodes into a scratch buffer; decoding
        // never grows the input, so the reply's own length is enough room.
        const buf = try self.alloc.alloc(u8, content.len);
        defer self.alloc.free(buf);
        try self.paneOps(pane, &.{
            .{ .switch_screen = screen_key },
            .{ .bytes = control.unescape(buf, content) },
            .scroll_into_history,
        });

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            const screen: *Screen = pane.terminal.screens.active;
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // Erase the active area and reset the cursor to the top-left
        // before writing the visible content.
        const buf = try self.alloc.alloc(u8, content.len);
        defer self.alloc.free(buf);
        try self.paneOps(pane, &.{
            .{ .switch_screen = screen_key },
            .erase_and_home,
            .{ .bytes = control.unescape(buf, content) },
        });
    }

    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;
        try self.paneOps(pane, &.{.{ .bytes = data }});
    }

    /// Convert a tmux layout dimension into a terminal cell count. tmux
    /// gives us a usize but our terminals are limited to CellCountInt, so
    /// clamp instead of failing: a layout this large is nonsense, and it
    /// isn't worth tearing down the session over.
    fn layoutCellCount(v: usize) size.CellCountInt {
        return std.math.cast(size.CellCountInt, v) orelse max: {
            log.warn("layout dimension too large, clamping value={}", .{v});
            break :max std.math.maxInt(size.CellCountInt);
        };
    }

    fn initLayout(
        io: std.Io,
        gpa_alloc: Allocator,
        panes_old: *PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        io,
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                const cols = layoutCellCount(layout.width);
                const rows = layoutCellCount(layout.height);

                // If we already have this pane, it is already initialized
                // so just copy it over. It may have been resized by the
                // layout change that brought us here, though.
                if (panes_old.get(id)) |pane| {
                    // A zero dimension can't be resized to and only shows
                    // up in a malformed layout, so leave the pane alone
                    // rather than failing the whole sync.
                    if (cols > 0 and rows > 0 and
                        (pane.terminal.cols != cols or
                            pane.terminal.rows != rows))
                    {
                        try pane.terminal.resize(gpa_alloc, .{
                            .cols = cols,
                            .rows = rows,
                        });

                        // Whatever we last asked for, this is the answer,
                        // so forget the request. Leaving it would let a
                        // stale one shrink the window back through
                        // `composeLayoutSize` if a sibling resizes before
                        // this pane's surface has caught up.
                        //
                        // `last_resize_sent` deliberately survives this.
                        // It is what stops us asking the same question
                        // again once tmux has answered it.
                        pane.last_resize_request = null;

                        // Anything mirroring this pane has to resize too.
                        // A consumer that owns a surface should route this
                        // through its surface resize path.
                        if (pane.sink) |s| s.send(&.{.{ .resize = .{
                            .cols = cols,
                            .rows = rows,
                        } }});
                    }

                    gop.value_ptr.* = pane;
                    break :pane;
                }

                gop.value_ptr.* = try Pane.create(io, gpa_alloc, cols, rows);
            },
        }
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our commands
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| self.command_queue.appendAssumeCapacity(cmd);

        // Move into the command queue state
        self.state = .command_queue;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;

        // Nothing will ever be delivered to a pane again, so say so now.
        // Waiting for the viewer to be torn down would leave anything
        // mirroring a pane believing it is still live.
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane: *Pane = kv.value_ptr.*;
            if (pane.sink) |s| {
                s.close();
                pane.sink = null;
            }
        }

        return self.singleAction(.exit);
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes.
    pane_state,

    /// Get the tmux server version.
    tmux_version,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            => {},
            .user => |v| alloc.free(v),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -C = escape non-printable bytes as octal. Mandatory
                //   alongside -e: a reply travels inside a %begin/%end
                //   block, and unlike %output tmux does not escape block
                //   payloads, so a raw ESC would terminate the DCS that
                //   carries control mode and drop us out of the session.
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S - = start at the top of history ("-")
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -C -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -C = escape non-printable bytes as octal (see above)
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -t %{d} = target a specific pane ID
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -C -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -F '{s}'\n",
                .{comptime Format.list_panes.comptimeFormat()},
            )),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            .user => |v| try writer.writeAll(v),
        }
    }
};

/// Format strings used for commands in our viewer.
/// The parsed `list-panes` line for a single pane, as carried by
/// `sink.Op.pane_state`.
pub const PaneStateData = Format.list_panes.Struct();

const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
        },
    };

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_width,
            .window_height,
            .window_layout,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "capture replay decodes escaped escape sequences" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 42,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        // One pane, so the first capture is pane_history for pane 0. The
        // captures must ask tmux to escape what it sends: a raw ESC in a
        // block payload would end the control mode DCS.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 80 24 b25d,80x24,0,0,0
                ,
            } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-C"));
                }
            }).check,
        },
        // The history response, escaped the same way. Moves us on to
        // pane_visible.
        .{
            .input = .{ .tmux = .{ .block_end = "\\033[32mOLD" } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-C"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .history = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("OLD", str);
                }
            }).check,
        },
        // The visible response, as tmux escapes it under `-e -C`.
        .{
            .input = .{ .tmux = .{ .block_end = "\\033[31mRED" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("RED", str);
                }
            }).check,
        },
    });
}

test "layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4 capture-pane + 1 pane_state)
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes.
        // This should NOT return a command action since queue was not empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // Should not contain a command action
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 0 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 4 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // Active screen starts with "prompt %" at beginning
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        // capture-pane pane 4 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;42;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "write sends keys to the target pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // One window with a single pane, id 0.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain the capture-pane commands so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // With the queue empty, a write is sent immediately as a hex-encoded
        // send-keys. "hi" is 0x68 0x69.
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "hi" } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expectEqualStrings(
                        "send-keys -H -t %0 68 69\n",
                        command,
                    );
                }
            }).check,
        },
    });
}

test "write waits for the in-flight command" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // One window with a single pane, id 0. This leaves the pane setup
        // commands queued with the first already in flight.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // A write now must not jump the queue: we only ever have one
        // command in flight, so it produces no action yet and is appended
        // behind the five pending pane setup commands.
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "x" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expectEqual(6, v.command_queue.len());
                }
            }).check,
        },
        // Drain the pane setup commands. The write is sent as the last of
        // them completes.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expectEqualStrings(
                        "send-keys -H -t %0 78\n",
                        command,
                    );
                }
            }).check,
        },
    });
}

test "write to an unknown pane is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        // Only pane 0 exists.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Pane 7 was never in a layout, so there is nothing to send to.
        // Queueing it would make tmux error on an unknown target.
        .{
            .input = .{ .write = .{ .pane_id = 7, .data = "x" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // An empty write has nothing to send either. Without this guard
        // we would emit a bare `send-keys`, which tmux reads as "send the
        // key this command is bound to".
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "write before startup completes is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // We are still in startup_block: no session, no panes.
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "x" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

/// A sink that applies everything it receives to its own terminal, which
/// is what a real consumer does. Init in place: the stream's handler points
/// at `terminal`, so this must not be moved after init.
const MirrorSink = struct {
    alloc: Allocator,
    terminal: Terminal,
    stream: TerminalStream,
    closed: bool = false,

    fn init(
        self: *MirrorSink,
        alloc: Allocator,
        io: std.Io,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) !void {
        self.* = .{
            .alloc = alloc,
            .terminal = try .init(io, alloc, .{ .cols = cols, .rows = rows }),
            .stream = undefined,
        };
        self.stream = self.terminal.vtStream();
    }

    fn deinit(self: *MirrorSink) void {
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
    }

    fn sink(self: *MirrorSink) Sink {
        return .{ .ctx = self, .vtable = &.{
            .ops = applyOps,
            .close = markClosed,
        } };
    }

    fn applyOps(ctx: *anyopaque, ops: []const sinkpkg.Op) void {
        const self: *MirrorSink = @ptrCast(@alignCast(ctx));
        for (ops) |op| switch (op) {
            .bytes => |b| self.stream.nextSlice(b),
            else => sinkpkg.applyOp(
                self.alloc,
                &self.terminal,
                op,
            ) catch |err| {
                log.warn("mirror sink failed to apply op: {}", .{err});
            },
        };
    }

    fn markClosed(ctx: *anyopaque) void {
        const self: *MirrorSink = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

/// Assert that two terminals hold the same visible state.
fn expectMirrored(expected: *Terminal, actual: *Terminal) !void {
    try testing.expectEqual(expected.screens.active_key, actual.screens.active_key);
    try testing.expectEqual(expected.cols, actual.cols);
    try testing.expectEqual(expected.rows, actual.rows);

    {
        const want = try expected.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(want);
        const got = try actual.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    {
        const want = try expected.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .history = .{} },
        );
        defer testing.allocator.free(want);
        const got = try actual.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .history = .{} },
        );
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // Both screens, not just the active one. The cursor of the screen
    // that is *not* active is the state a byte stream can never carry,
    // so it is the whole reason the sink sends operations.
    inline for (.{ .primary, .alternate }) |key| {
        const want_screen = expected.screens.get(key);
        const got_screen = actual.screens.get(key);
        try testing.expectEqual(want_screen == null, got_screen == null);

        if (want_screen) |want| {
            const got = got_screen.?;
            try testing.expectEqual(want.cursor.x, got.cursor.x);
            try testing.expectEqual(want.cursor.y, got.cursor.y);
            try testing.expectEqual(
                want.cursor.cursor_style,
                got.cursor.cursor_style,
            );
        }
    }

    try testing.expectEqual(
        expected.scrolling_region.top,
        actual.scrolling_region.top,
    );
    try testing.expectEqual(
        expected.scrolling_region.bottom,
        actual.scrolling_region.bottom,
    );

    inline for (.{
        .cursor_visible,
        .cursor_blinking,
        .insert,
        .wraparound,
        .keypad_keys,
        .cursor_keys,
        .origin,
        .mouse_event_any,
        .mouse_event_button,
        .mouse_event_normal,
        .mouse_event_x10,
        .mouse_format_utf8,
        .mouse_format_sgr,
        .focus_event,
        .bracketed_paste,
    }) |mode| {
        try testing.expectEqual(
            expected.modes.get(mode),
            actual.modes.get(mode),
        );
    }
}

/// Drive a viewer to steady state with a single 83x44 pane (id 0).
fn testSinglePaneSteps() []const TestStep {
    return &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 83 44 b7dd,83x44,0,0,0
            ,
        } } },
        // Four capture-pane replies plus pane_state.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    };
}

const two_panes_vertical = "027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]";
const two_panes_horizontal = "1c1b,83x44,0,0{41x44,0,0,0,41x44,42,0,1}";

/// Startup for a two-pane window with the given layout.
///
/// `vertical` stacks panes 0 (83x20) and 1 (83x23) top to bottom;
/// `horizontal` puts panes 0 and 1 (41x44 each) side by side. Either way
/// the divider between them makes the window 83x44.
fn testTwoPaneSteps(comptime layout: []const u8) []const TestStep {
    return &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        .{ .input = .{ .tmux = .{ .block_end = "$0 @0 83 44 " ++ layout } } },
        // Four capture-pane replies per pane.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    };
}

test "pane state maps tmux mouse flags to the right modes" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // tmux reports normal tracking only: mouse_standard_flag is set,
        // and mouse_any_flag is set because it is a roll-up of the three
        // tracking modes rather than a mode of its own.
        //
        //  ...;mouse_all;mouse_any;mouse_button;mouse_standard;utf8;sgr;...
        .{ .input = .{ .tmux = .{
            .block_end =
            \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;1;0;1;0;0;0;0;0;39;8,16
            ,
        } } },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
    const t: *Terminal = &pane.terminal;

    // MODE_MOUSE_STANDARD is DECSET 1000, which is mouse_event_normal.
    try testing.expect(t.modes.get(.mouse_event_normal));
    try testing.expect(!t.modes.get(.mouse_event_button));
    try testing.expect(!t.modes.get(.mouse_event_any));

    // tmux has no DECSET 9, so nothing can turn x10 on.
    try testing.expect(!t.modes.get(.mouse_event_x10));
}

test "attached sink mirrors the pane terminal" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    // Attach once the pane exists but before any capture reply lands,
    // which is what a caller reacting to the .windows action does.
    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try viewer.attachPane(0, mirror.sink());

    try testViewer(&viewer, &.{
        // Primary history, then primary visible, then the alternate pair.
        .{ .input = .{ .tmux = .{ .block_end = "scrollback line" } } },
        .{ .input = .{ .tmux = .{ .block_end = "visible line" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // pane_state: the pane is on the primary screen with its cursor
        // at (7,2), and the *alternate* screen has a saved cursor at
        // (5,3). That alternate cursor is the case a byte stream cannot
        // express, since bytes only ever reach the active screen.
        .{ .input = .{ .tmux = .{
            .block_end =
            \\%0;7;2;1;bar;;;0;5;3;1;1;0;0;1;0;0;0;0;0;0;;;1;40;8,16,24
            ,
        } } },
        // Then live output, including a sequence split across two
        // notifications so the mirror's parser state is exercised too.
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "hello \x1b[3",
        } } } },
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "1mred",
        } } } },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;

    // Pin the inactive screen's cursor to a distinctive value first, so
    // the mirror comparison below is not two zeroes agreeing.
    try testing.expectEqual(.primary, pane.terminal.screens.active_key);
    const alt = pane.terminal.screens.get(.alternate).?;
    try testing.expectEqual(5, alt.cursor.x);
    try testing.expectEqual(3, alt.cursor.y);

    try expectMirrored(&pane.terminal, &mirror.terminal);

    // Sanity: the replay actually did something, so the comparison above
    // is not just two blank terminals agreeing.
    const str = try mirror.terminal.screens.active.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(str);
    try testing.expect(std.mem.indexOf(u8, str, "hello red") != null);
}

test "sink is closed when its pane goes away" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testing.expect(!mirror.closed);

    // Switching session resets the viewer, which drops every pane.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 2,
            .name = "other",
        } } } },
    });

    try testing.expect(!viewer.panes.contains(0));
    try testing.expect(mirror.closed);
}

test "resizing a lone pane resizes its window" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    // A fresh pane has asked for nothing yet. `Pane.create` assigns every
    // field by hand into uninitialized memory, so this catches a field
    // that only looks initialized because it has a default.
    try testing.expectEqual(
        null,
        viewer.panes.getEntry(0).?.value_ptr.*.last_resize_request,
    );

    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the command queue is empty and
        // our command is sent immediately rather than queued behind it.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // A pane that is alone fills its window, so sizing the window is
        // the whole job: nothing is queued behind this.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .contains_command = "refresh-client -C @0:100x30\n",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Drain the reply, so the queue is empty again and a command that
        // is not deduplicated would be sent immediately. Without that,
        // "no action" would prove nothing.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The same size again is not worth a round trip.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // A different size is.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 90, .rows = 30 } },
            .contains_command = "refresh-client -C @0:90x30\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Unknown panes and degenerate sizes are dropped.
        .{
            .input = .{ .resize = .{ .pane_id = 9, .cols = 10, .rows = 10 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 0, .rows = 10 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "resizing a split pane sizes both the window and the pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 grows from 83x20 to 90x25. Pane 1 has not been heard
        // from, so it still counts as the 83x23 tmux gave it: the window
        // composes to max(90, 83) x (25 + 23 + 1).
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 90, .rows = 25 } },
            .contains_command = "refresh-client -C @0:90x49\n",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // The window command goes first, because a pane can
                    // never grow past its window. The pane command is
                    // queued behind it.
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(2, v.command_queue.len());
                }
            }).check,
        },
        // The window reply lets the queued pane resize go out.
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "resize-pane -t %0 -x 90 -y 25\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Now pane 1 catches up. The window recomposes to 90x(25+30+1).
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 90, .rows = 30 } },
            .contains_command = "refresh-client -C @0:90x56\n",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "resize-pane -t %1 -x 90 -y 30\n",
        },
    });
}

test "a side-by-side split composes across the other axis" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_horizontal));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 widens from 41 to 50. Pane 1 is still the 41 tmux gave
        // it, so the window wants 50 + 41 + the divider, and the height is
        // the taller of the two rather than their sum.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 50, .rows = 44 } },
            .contains_command = "refresh-client -C @0:92x44\n",
        },
    });
}

test "a window is only resized when its own size changes" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Each pane asks for the size it already has, which is the first
        // time either has asked for anything. The window is unchanged at
        // 83x44, but we have never told tmux that, so we do.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 20 } },
            .contains_command = "refresh-client -C @0:83x44\n",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "resize-pane -t %0 -x 83 -y 20\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 1 now asks for its own current size. That is new for the
        // pane but composes to the same 83x44, so only the pane command
        // goes out.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 83, .rows = 23 } },
            .contains_command = "resize-pane -t %1 -x 83 -y 23\n",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "tmux resizing a pane forgets what we asked for" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 25 } } },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
    try testing.expect(pane.last_resize_request != null);

    // tmux answers with a layout that sizes pane 0 differently. That is
    // the answer to our request, so the request is spent: keeping it would
    // let it compose a stale window size for a sibling's resize later.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = "19fb,83x44,0,0[83x30,0,0,0,83x13,0,31,1]",
            .visible_layout = "19fb,83x44,0,0[83x30,0,0,0,83x13,0,31,1]",
            .raw_flags = "*",
        } } } },
    });

    try testing.expectEqual(30, pane.terminal.rows);
    try testing.expectEqual(null, pane.last_resize_request);
}

test "a size tmux will not give us is not asked for twice" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Ask for a size.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .contains_command = "refresh-client -C @0:100x30\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // tmux answers with something else. It is entitled to: a resize
        // is a request, and the layout is the ruling.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "a69d,90x40,0,0,0",
                .visible_layout = "a69d,90x40,0,0,0",
                .raw_flags = "*",
            } } },
        },

        // The surface has not moved, so it asks for the same size again.
        // Asking tmux again would be asking a question we have already
        // had answered, and since tmux replies to every resize with a
        // layout, doing so is not one wasted round trip but a loop that
        // never ends.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "an old tmux sizes windows the old way" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        // Per-window sizes arrived in tmux 3.4.
        .{ .input = .{ .tmux = .{ .block_end = "3.3a" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 83 44 b7dd,83x44,0,0,0
            ,
        } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // `refresh-client -C @id:WxH` does not exist before 3.4, so the
        // window is sized with resize-window instead. It is still a lone
        // pane, so that is the whole job.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .contains_command = "resize-window -x 100 -y 30 -t @0\n",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "tmux version comparison" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    const cases = .{
        .{ "3.4", true },
        .{ "3.5a", true },
        .{ "4.0", true },
        .{ "3.10", true },
        .{ "3.3a", false },
        .{ "2.9", false },
        // Nothing we can read is nothing we can rely on.
        .{ "next", false },
        .{ "", false },
        .{ "3.x", false },
    };

    inline for (cases) |case| {
        viewer.alloc.free(viewer.tmux_version);
        viewer.tmux_version = try viewer.alloc.dupe(u8, case[0]);
        try testing.expectEqual(case[1], viewer.tmuxVersionAtLeast(3, 4));
    }
}

test "a paused pane is resumed and re-read" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 0 } } },
            .contains_command = "refresh-client -A '%0:continue'\n",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Resume, then four captures and a pane state: what
                    // tmux discarded while paused is not coming back, so
                    // the pane has to be read again from scratch.
                    try testing.expectEqual(6, v.command_queue.len());
                }
            }).check,
        },
        // A pause for a pane we do not know is not worth a round trip.
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 9 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(6, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "client size is reported to tmux once" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the command queue is empty and
        // our command is sent immediately rather than queued behind it.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .client_size = .{ .cols = 120, .rows = 40 } },
            .contains_command = "refresh-client -C 120x40\n",
        },
        // Drain the reply so the queue is empty: otherwise "no action"
        // would just mean "queued behind something".
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .client_size = .{ .cols = 120, .rows = 40 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "kill pane asks tmux to kill it" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the command queue is empty and
        // our command is sent immediately rather than queued behind it.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .kill_pane = .{ .pane_id = 0 } },
            .contains_command = "kill-pane -t %0\n",
        },
        .{
            .input = .{ .kill_pane = .{ .pane_id = 9 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "new inputs are dropped before startup completes" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 1, .rows = 1 } } },
        .{ .input = .{ .client_size = .{ .cols = 1, .rows = 1 } } },
        .{
            .input = .{ .kill_pane = .{ .pane_id = 0 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "attach sizes the sink from the pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    // Deliberately the wrong size: attaching has to correct it.
    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 10, 5);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());

    try testing.expectEqual(83, mirror.terminal.cols);
    try testing.expectEqual(44, mirror.terminal.rows);
}

test "attach is refused while the pane is mid-sequence" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    // Leave the pane's parser part way through an SGR sequence.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1b[3",
        } } } },
    });
    try testing.expectError(
        error.PaneMidSequence,
        viewer.attachPane(0, mirror.sink()),
    );

    // Once the sequence completes, attaching works.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "1m",
        } } } },
    });
    try viewer.attachPane(0, mirror.sink());
}

test "sinks are closed when the connection ends" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testing.expect(!mirror.closed);

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });

    try testing.expect(mirror.closed);
}

test "detaching a pane closes its sink" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    viewer.detachPane(0);
    try testing.expect(mirror.closed);

    // Detach is idempotent and unknown panes are fine.
    viewer.detachPane(0);
    viewer.detachPane(1234);

    try testing.expectError(error.UnknownPane, viewer.attachPane(
        1234,
        mirror.sink(),
    ));
}

test "output escape sequence split across notifications" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // pane_state, alternate_on = 0.
        .{ .input = .{ .tmux = .{
            .block_end =
            \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16
            ,
        } } },

        // A single SGR sequence delivered in two pieces, which is what a
        // pty does whenever a write lands on a buffer boundary. The
        // parser has to remember it is mid-sequence.
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1b[3",
        } } } },
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "1mX",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);

                    // With a fresh parser per notification the escape is
                    // lost and the tail is printed literally as "1mX".
                    try testing.expectEqualStrings("X", str);
                }
            }).check,
        },
    });
}

test "pane state restores the active screen" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // The last capture replayed was the alternate screen, so the
        // active screen is left on alternate. pane_state says this pane
        // is not in the alternate screen, so it has to switch back.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(
                        .primary,
                        pane.terminal.screens.active_key,
                    );
                }
            }).check,
        },
    });
}

test "layout dimensions clamp to the cell count limit" {
    const max = std.math.maxInt(size.CellCountInt);
    try testing.expectEqual(80, Viewer.layoutCellCount(80));
    try testing.expectEqual(max, Viewer.layoutCellCount(max));
    try testing.expectEqual(max, Viewer.layoutCellCount(@as(usize, max) + 1));
}

test "layout change resizes a surviving pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        // One pane filling the window.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(83, pane.terminal.cols);
                    try testing.expectEqual(44, pane.terminal.rows);
                }
            }).check,
        },
        // Drain the capture-pane commands plus pane_state.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Split the window. Pane 0 survives but is now only 22 rows tall.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(83, pane.terminal.cols);
                    try testing.expectEqual(22, pane.terminal.rows);

                    // The newly added pane is sized from the layout too.
                    const added: *Viewer.Pane = v.panes.getEntry(2).?.value_ptr.*;
                    try testing.expectEqual(83, added.terminal.cols);
                    try testing.expectEqual(21, added.terminal.rows);
                }
            }).check,
        },
    });
}

test "list-windows windows action outlives the parse" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 42,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    const windows = for (actions) |action| {
                        if (action == .windows) break action.windows;
                    } else return error.WindowsActionMissing;

                    // The action must point at our own window list. Anything
                    // else is freed by the time we return to the caller.
                    try testing.expectEqual(
                        @intFromPtr(v.windows.items.ptr),
                        @intFromPtr(windows.ptr),
                    );
                    try testing.expectEqual(v.windows.items.len, windows.len);

                    try testing.expectEqual(1, windows.len);
                    try testing.expectEqual(0, windows[0].id);
                    try testing.expectEqual(83, windows[0].width);
                    try testing.expectEqual(44, windows[0].height);
                }
            }).check,
        },
    });
}
