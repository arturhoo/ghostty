//! Structured replay of a tmux pane onto a terminal the viewer does not own.
//!
//! The viewer keeps a shadow `Terminal` per pane. To render a pane in a real
//! surface, that surface's own terminal has to end up in the same state. The
//! obvious way to do that is to tee the pane's VT bytes, but the viewer's
//! replay is not only bytes: it also calls `switchScreen`, scrolls the active
//! area into history, erases the display, and writes cursor state onto the
//! *inactive* screen. Two of those have no escape sequence that reproduces
//! them:
//!
//!   * `Terminal.switchScreen` is the bare flip. Every mode-driven switch
//!     (DECSET 47, 1047, 1049) additionally copies the cursor, and 1049 also
//!     saves the cursor and erases the alternate screen. The viewer wants
//!     none of that.
//!
//!   * `applyPaneState` writes the alternate screen's cursor while the
//!     primary screen may be active. A byte stream only ever reaches the
//!     active screen.
//!
//! So the sink carries operations rather than bytes, with raw VT as one of
//! them. The viewer applies each op to its shadow terminal through the same
//! `applyOp` it hands to the sink, which is what keeps the two from drifting:
//! there is one implementation, not two.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Terminal = @import("../Terminal.zig");
const ScreenSet = @import("../ScreenSet.zig");
const size = @import("../size.zig");
const viewer = @import("viewer.zig");

const log = std.log.scoped(.terminal_tmux_sink);

/// The parsed `list-panes` line for one pane.
pub const PaneStateData = viewer.PaneStateData;

/// A single operation on a pane's terminal.
///
/// Slices are only valid for the duration of the sink call: they point into
/// the viewer's notification and arena memory, the same contract the viewer's
/// actions carry. Copy anything you need to keep.
pub const Op = union(enum) {
    /// Raw VT bytes: `%output` data, or capture-pane replay content.
    ///
    /// These must go through a stream whose parser state persists across
    /// ops, because a sequence can be split across notifications.
    bytes: []const u8,

    /// Make the given screen active, without any of the side effects that
    /// the DECSET alternate-screen modes carry.
    switch_screen: ScreenSet.Key,

    /// Push the whole active area into scrollback and home the cursor. This
    /// is the tail of a history replay, and uses the applying terminal's own
    /// row count.
    scroll_into_history,

    /// Clear the display and home the cursor, ahead of a visible replay.
    erase_and_home,

    /// Cursor position, modes, scroll region and tab stops, as tmux
    /// reported them.
    pane_state: PaneStateData,

    /// The pane's grid was resized by a layout change.
    ///
    /// A consumer that owns a surface should route this through its surface
    /// resize path rather than letting `applyOp` resize the terminal alone,
    /// otherwise the renderer keeps a stale cell geometry.
    resize: struct {
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    },
};

/// A consumer of a pane's operations.
///
/// `ops` is called while the viewer's caller holds its renderer lock, so an
/// implementation must not block, and must not call into another terminal's
/// I/O: copy or enqueue and return.
pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ops: *const fn (ctx: *anyopaque, ops: []const Op) void,

        /// The pane is gone, or was detached. Never called concurrently
        /// with `ops`, and nothing is delivered afterwards.
        close: *const fn (ctx: *anyopaque) void,
    };

    pub inline fn send(self: Sink, ops: []const Op) void {
        self.vtable.ops(self.ctx, ops);
    }

    pub inline fn close(self: Sink) void {
        self.vtable.close(self.ctx);
    }
};

/// Apply an op to a terminal.
///
/// `.bytes` is not handled here: the caller owns the stream, because parser
/// state has to persist across calls.
pub fn applyOp(
    alloc: Allocator,
    t: *Terminal,
    op: Op,
) !void {
    switch (op) {
        .bytes => unreachable,

        .switch_screen => |key| _ = try t.switchScreen(key),

        .scroll_into_history => {
            t.carriageReturn();
            for (0..t.rows) |_| try t.index();
            t.setCursorPos(1, 1);
        },

        .erase_and_home => {
            t.eraseDisplay(.complete, false);
            t.setCursorPos(1, 1);
        },

        .pane_state => |data| applyPaneState(t, data),

        .resize => |v| try t.resize(alloc, .{
            .cols = v.cols,
            .rows = v.rows,
        }),
    }
}

/// Apply tmux's reported pane state to a terminal.
///
/// This is a merge, not a snapshot: an unrecognized cursor shape leaves the
/// shape alone, and out-of-range coordinates are skipped, because tmux sends
/// MAX_INT for "no saved cursor".
pub fn applyPaneState(t: *Terminal, data: PaneStateData) void {
    // tmux reports which screen the pane is on; the cursor it reports
    // belongs to that screen, which is not necessarily the active one.
    const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

    // Set cursor position on the appropriate screen (tmux uses 0-based)
    if (t.screens.get(screen_key)) |screen| {
        cursor: {
            const cursor_x = std.math.cast(
                size.CellCountInt,
                data.cursor_x,
            ) orelse break :cursor;
            const cursor_y = std.math.cast(
                size.CellCountInt,
                data.cursor_y,
            ) orelse break :cursor;
            if (cursor_x >= screen.pages.cols or
                cursor_y >= screen.pages.rows) break :cursor;
            screen.cursorAbsolute(cursor_x, cursor_y);
        }

        // Set cursor shape on this screen
        if (data.cursor_shape.len > 0) {
            if (std.mem.eql(u8, data.cursor_shape, "block")) {
                screen.cursor.cursor_style = .block;
            } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                screen.cursor.cursor_style = .underline;
            } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                screen.cursor.cursor_style = .bar;
            }
        }
        // "default" or unknown: leave as-is
    }

    // Set alternate screen saved cursor position
    if (t.screens.get(.alternate)) |alt_screen| cursor: {
        const alt_x = std.math.cast(
            size.CellCountInt,
            data.alternate_saved_x,
        ) orelse break :cursor;
        const alt_y = std.math.cast(
            size.CellCountInt,
            data.alternate_saved_y,
        ) orelse break :cursor;

        // If our coordinates are outside our screen we ignore it.
        // tmux actually sends MAX_INT for when there isn't a set
        // cursor position, so this isn't theoretical.
        if (alt_x >= alt_screen.pages.cols or
            alt_y >= alt_screen.pages.rows) break :cursor;

        alt_screen.cursorAbsolute(alt_x, alt_y);
    }

    // Set cursor visibility
    t.modes.set(.cursor_visible, data.cursor_flag);

    // Set cursor blinking
    t.modes.set(.cursor_blinking, data.cursor_blinking);

    // Terminal modes
    t.modes.set(.insert, data.insert_flag);
    t.modes.set(.wraparound, data.wrap_flag);
    t.modes.set(.keypad_keys, data.keypad_flag);
    t.modes.set(.cursor_keys, data.keypad_cursor_flag);
    t.modes.set(.origin, data.origin_flag);

    // Mouse tracking modes. tmux names these after its internal
    // MODE_MOUSE_* flags, which do not line up with the DECSET numbers
    // by name: MODE_MOUSE_STANDARD is 1000, MODE_MOUSE_BUTTON is 1002,
    // MODE_MOUSE_ALL is 1003 (tmux input.c).
    t.modes.set(.mouse_event_normal, data.mouse_standard_flag);
    t.modes.set(.mouse_event_button, data.mouse_button_flag);
    t.modes.set(.mouse_event_any, data.mouse_all_flag);

    // `mouse_any_flag` is deliberately unused: it is a roll-up of the
    // three modes above, not a mode of its own. tmux has no DECSET 9
    // either, so nothing here can set mouse_event_x10.

    t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
    t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);

    // Focus and bracketed paste
    t.modes.set(.focus_event, data.focus_flag);
    t.modes.set(.bracketed_paste, data.bracketed_paste);

    // Scroll region (tmux uses 0-based values)
    scroll: {
        const scroll_top = std.math.cast(
            size.CellCountInt,
            data.scroll_region_upper,
        ) orelse break :scroll;
        const scroll_bottom = std.math.cast(
            size.CellCountInt,
            data.scroll_region_lower,
        ) orelse break :scroll;
        t.scrolling_region.top = scroll_top;
        t.scrolling_region.bottom = scroll_bottom;
    }

    // Tab stops - parse comma-separated list and set
    t.tabstops.reset(0); // Clear all tabstops first
    if (data.pane_tabs.len > 0) {
        var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
        while (tabs_it.next()) |tab_str| {
            const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
            const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
            if (col_cell >= t.cols) continue;
            t.tabstops.set(col_cell);
        }
    }

    // Everything above addresses screens by key, so the pane is still on
    // whichever screen the last capture replay left active: the alternate
    // one, since that is the last capture we queue. tmux just told us
    // which screen the pane is really on, so put it back.
    _ = t.switchScreen(screen_key) catch |err| {
        log.warn(
            "failed to restore active screen pane id={}: {}",
            .{ data.pane_id, err },
        );
    };
}
