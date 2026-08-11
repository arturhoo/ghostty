//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const oni = @import("oniguruma");

const log = std.log.scoped(.terminal_tmux);

/// A tmux control mode parser. This takes in output from tmux control
/// mode and parses it into a structured notifications.
///
/// It is up to the caller to establish the connection to the tmux
/// control mode session in some way (e.g. via exec, a network socket,
/// whatever). This is fully agnostic to how the data is received and sent.
pub const Parser = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress notifications, output, etc.
    buffer: std.Io.Writer.Allocating,

    /// The maximum size in bytes of the buffer. This is used to limit
    /// memory usage. If the buffer exceeds this size, the client will
    /// enter a broken state (the control mode session will be forcibly
    /// exited and future data dropped).
    max_bytes: usize = 1024 * 1024,

    const State = enum {
        /// Outside of any active notifications. This should drop any output
        /// unless it is '%' on the first byte of a line. The buffer will be
        /// cleared when it sees '%', this is so that the previous notification
        /// data is valid until we receive/process new data.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing. When this state is set,
        /// the buffer has been deinited and must not be accessed.
        broken,

        /// Inside an active notification (started with '%').
        notification,

        /// Inside a begin/end block.
        block,

        /// Discarding a line that could not have been a notification.
        /// See the `.idle` arm of `put` for how we get here.
        skip_line,
    };

    pub fn deinit(self: *Parser) void {
        // If we're in a broken state, we already deinited
        // the buffer, so we don't need to do anything.
        if (self.state == .broken) return;

        self.buffer.deinit();
    }

    // Handle a byte of input.
    //
    // If we reach our byte limit this will return OutOfMemory. It only
    // does this on the first time we exceed the limit; subsequent calls
    // will return null as we drop all input in a broken state.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        // If we're in a broken state, just do nothing.
        //
        // We have to do this check here before we check the buffer, because if
        // we're in a broken state then we'd have already deinited the buffer.
        if (self.state == .broken) return null;

        if (self.buffer.written().len >= self.max_bytes) {
            self.broken();
            return error.OutOfMemory;
        }

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Every line tmux sends should begin with '%'. One that does
            // not is the tail of the line before it: tmux does not escape
            // names or command output, and both can contain a newline, so
            // `rename-window $'a\nb'` is enough to produce one. Ending
            // the session over that is a very large consequence for a very
            // small provocation, so drop the line instead.
            .idle => if (byte == '%') {
                self.buffer.clearRetainingCapacity();
                self.state = .notification;
            } else if (byte != '\n') {
                self.buffer.clearRetainingCapacity();
                self.state = .skip_line;
            },

            // Discarding a line we could not have understood.
            .skip_line => if (byte == '\n') {
                log.warn("discarded a stray control mode line", .{});
                self.state = .idle;
            },

            // If we're in a notification and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete notification we need to parse.
            .notification => if (byte == '\n') {
                // We have a complete notification, parse it.
                return self.parseNotification() catch {
                    // If parsing failed, then we do not mark the state
                    // as broken because we may be able to continue parsing
                    // other types of notifications.
                    //
                    // In the future we may want to emit a notification
                    // here about unknown or unsupported notifications.
                    return null;
                };
            },

            // If we're in a block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    written,
                    '\n',
                )) |v| v + 1 else 0;
                const line = written[idx..];

                if (parseBlockTerminator(line)) |terminator| {
                    const output = std.mem.trimEnd(
                        u8,
                        written[0..idx],
                        "\r\n",
                    );

                    // Important: do not clear buffer since the notification
                    // contains it.
                    self.state = .idle;
                    switch (terminator) {
                        .end => return .{ .block_end = output },
                        .err => {
                            log.warn("tmux control mode error={s}", .{output});
                            return .{ .block_err = output };
                        },
                    }
                }

                // Didn't end the block, continue accumulating.
            },
        }

        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return null;
    }

    const ParseError = error{RegexError};

    const BlockTerminator = enum { end, err };

    /// Block payload is raw data, so a line only terminates a block if it
    /// exactly matches tmux's `%end`/`%error` guard-line shape.
    fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminator {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
            .end
        else if (std.mem.eql(u8, cmd, "%error"))
            .err
        else
            return null;

        const time = fields.next() orelse return null;
        const command_id = fields.next() orelse return null;
        const flags = fields.next() orelse return null;
        const extra = fields.next();

        // In the future, we should compare these to the %begin block
        // because the tmux source guarantees that these always match and
        // that is a more robust way to match.
        _ = std.fmt.parseInt(usize, time, 10) catch return null;
        _ = std.fmt.parseInt(usize, command_id, 10) catch return null;
        _ = std.fmt.parseInt(usize, flags, 10) catch return null;
        if (extra != null) return null;

        return terminator;
    }

    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const cmd = cmd: {
            const idx = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            break :cmd line[0..idx];
        };

        // The notification MUST exist because we guard entering the notification
        // state on seeing at least a '%'.
        if (std.mem.eql(u8, cmd, "%begin")) {
            // We don't use the rest of the tokens for now because tmux
            // claims to guarantee that begin/end are always in order and
            // never intermixed. In the future, we should probably validate
            // this.
            // TODO(tmuxcc): do this before merge?

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            var re = oni.Regex.init(
                "^%output %([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const data = data: {
                const raw = line[@intCast(starts[2])..@intCast(ends[2])];
                break :data unescape(raw, raw);
            };

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .output = .{ .pane_id = id, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-changed \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_changed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) cmd: {
            if (!std.mem.eql(u8, line, "%sessions-changed")) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            var re = oni.Regex.init(
                "^%layout-change @([0-9]+) (.+) (.+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const layout = line[@intCast(starts[2])..@intCast(ends[2])];
            const visible_layout = line[@intCast(starts[3])..@intCast(ends[3])];
            const raw_flags = line[@intCast(starts[4])..@intCast(ends[4])];

            // Important: do not clear buffer here since layout strings point to it
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id,
                .layout = layout,
                .visible_layout = visible_layout,
                .raw_flags = raw_flags,
            } };
        } else if (std.mem.eql(u8, cmd, "%exit")) {
            // `%exit`, or `%exit <reason>`. tmux follows this with the
            // string terminator that ends the DCS, so the viewer would
            // find out either way; this is how it finds out *why*.
            const reason: ?[]const u8 = if (line.len > cmd.len + 1)
                line[cmd.len + 1 ..]
            else
                null;

            // Important: do not clear the buffer, reason points into it.
            self.state = .idle;
            return .{ .exit = reason };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            var re = oni.Regex.init(
                "^%window-add @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%window-close") or
            std.mem.eql(u8, cmd, "%unlinked-window-close"))
        cmd: {
            var re = oni.Regex.init(
                "^%(?:unlinked-)?window-close @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_close = .{ .id = id } };
        } else if (std.mem.startsWith(u8, cmd, "%unlinked-window-")) {
            // A window appearing or being renamed somewhere else in the
            // server. Nothing to show for a window we are not attached
            // to. Parsed rather than left to the unknown fall-through so
            // the log stays quiet and the omission reads as deliberate.
            //
            // Note this does NOT cover `%unlinked-window-close`, which is
            // handled above: see the comment on the `window_close`
            // notification for why that one is ours.
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return null;
        } else if (std.mem.eql(u8, cmd, "%window-renamed")) cmd: {
            var re = oni.Regex.init(
                "^%window-renamed @([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            var re = oni.Regex.init(
                "^%window-pane-changed @([0-9]+) %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const pane_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = window_id, .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            var re = oni.Regex.init(
                "^%client-detached (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];

            // Important: do not clear buffer here since client points to it
            self.state = .idle;
            return .{ .client_detached = .{ .client = client } };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%client-session-changed (.+) \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];
            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[3])..@intCast(ends[3])];

            // Important: do not clear buffer here since client/name point to it
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client, .session_id = session_id, .name = name } };
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        // Unknown command. Clear the buffer and return to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};

/// Decode the escaping tmux applies to text it can't send raw.
///
/// Two places need this and they use slightly different dialects of the
/// same encoding:
///
///   * `%output` payloads, where `control_write_pane_output` in tmux's
///     control.c writes any byte below a space, and the backslash itself,
///     as a backslash and three octal digits.
///   * `capture-pane -C` replies, where `grid_string_cells` in grid.c
///     writes escape sequences the same way (`\033[`, `\016`, `\017`) but
///     writes a literal backslash as a doubled backslash.
///
/// Decoding both here means neither caller has to care which it has. The
/// dialects can't collide: %output never emits a doubled backslash
/// because it octal-escapes that byte too.
///
/// Everything else passes through, so UTF-8 and other high bytes are
/// untouched.
///
/// The decoded form is never longer than what came in, so `dst` may alias
/// `src` to decode in place. Callers holding a mutable slice do exactly
/// that, which keeps the data pointing into the parser's own buffer.
pub fn unescape(dst: []u8, src: []const u8) []u8 {
    assert(dst.len >= src.len);

    var w: usize = 0;
    var r: usize = 0;

    while (r < src.len) {
        // Anything that cannot begin an escape is just a byte.
        if (src[r] != '\\' or r + 2 > src.len) {
            dst[w] = src[r];
            w += 1;
            r += 1;
            continue;
        }

        // A doubled backslash is one backslash.
        if (src[r + 1] == '\\') {
            dst[w] = '\\';
            w += 1;
            r += 2;
            continue;
        }

        const decoded: ?u8 = decoded: {
            if (r + 4 > src.len) break :decoded null;
            var value: u16 = 0;
            for (src[r + 1 ..][0..3]) |c| {
                if (c < '0' or c > '7') break :decoded null;
                value = value * 8 + (c - '0');
            }
            break :decoded std.math.cast(u8, value);
        };

        // Not an escape tmux would have written, so leave the backslash
        // alone rather than swallowing what follows it.
        const byte = decoded orelse {
            dst[w] = src[r];
            w += 1;
            r += 1;
            continue;
        };

        dst[w] = byte;
        w += 1;
        r += 4;
    }

    return dst[0..w];
}

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1). A lot of the simple documentation was copied from that man
/// page here.
pub const Notification = union(enum) {
    /// Entering tmux control mode. This isn't an actual event sent by
    /// tmux but is one sent by us to indicate that we have detected that
    /// tmux control mode is starting.
    enter,

    /// Control mode ended.
    ///
    /// Carries tmux's reason when it gave one. Nothing acts on it, but it
    /// is the only explanation we ever get for a session ending, and
    /// "too far behind" reads very differently from a clean detach when
    /// something has gone wrong. It points into the parser's buffer and
    /// so is bounded by `max_bytes` like every other line.
    exit: ?[]const u8,

    /// Dispatched at the end of a begin/end block with the raw data.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: []const u8,
    block_err: []const u8,

    /// Raw output from a pane.
    output: struct {
        pane_id: usize,
        data: []const u8, // unescaped
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    session_changed: struct {
        id: usize,
        name: []const u8,
    },

    /// A session was created or destroyed.
    sessions_changed,

    /// The layout of the window with ID window-id changed.
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },

    /// The window with ID window-id was linked to the current session.
    window_add: struct {
        id: usize,
    },

    /// The window with ID window-id closed, or left our session. tmux
    /// suppresses the dying window's `%layout-change`, so this is the
    /// only word we get that it is gone.
    ///
    /// Carries `%unlinked-window-close` as well as `%window-close`.
    /// `control_window_unlinked_cb` in tmux's control-notify.c picks
    /// between them by whether the window is still in the client's
    /// session, and by the time it runs for a window of ours it usually
    /// is not — killing a window in our own session is observed to send
    /// the unlinked form. Both mean the same thing to us, and re-listing
    /// for a window that was never ours is harmless.
    window_close: struct {
        id: usize,
    },

    /// The window with ID window-id was renamed to name.
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The active pane in the window with ID window-id changed to the pane
    /// with ID pane-id.
    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },

    /// The client has detached.
    client_detached: struct {
        client: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
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

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err);
}

test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end);
}

test "tmux block payload may start with %end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end not really\nhello", n.block_end);
}

test "tmux block payload may start with %error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%error not really\nhello", n.block_end);
}

test "tmux block may terminate with real %error after misleading payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("%error not really\nhello", n.block_err);
}

test "tmux block terminator requires exact token count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1 trailing\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end);
}

test "tmux block terminator requires numeric metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end foo bar baz\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end);
}

test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output unescapes control bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // How tmux writes a prompt redraw: carriage return, then an erase to
    // end of line. Every byte below a space arrives as three octal digits.
    for ("%output %0 a\\015\\033[Kb") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqualStrings("a\r\x1b[Kb", n.output.data);
}

test "tmux output unescapes a literal backslash" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // A backslash is itself escaped, so it is not mistaken for one.
    for ("%output %0 a\\134b") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("a\\b", n.output.data);
}

test "tmux output leaves a stray backslash alone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Not something tmux emits, but decoding must not eat bytes or run
    // off the end when it sees one.
    for ("%output %0 a\\9z b\\01") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("a\\9z b\\01", n.output.data);
}

test "tmux output passes utf8 through" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // tmux only escapes bytes below a space, so high bytes arrive raw.
    for ("%output %0 caf\u{00e9}") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("caf\u{00e9}", n.output.data);
}

test "tmux unescape decodes a doubled backslash" {
    const testing = std.testing;

    // `capture-pane -C` writes a literal backslash as a doubled backslash
    // rather than the `\134` that %output uses.
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a\\b", unescape(&buf, "a\\\\b"));
}

test "tmux unescape decodes into a separate buffer" {
    const testing = std.testing;

    // Block payloads are const, so they decode out of place.
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("\x1b[31mX", unescape(&buf, "\\033[31mX"));
}

test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}

test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}

test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}

test "tmux exit without a reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%exit") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .exit);
    try testing.expectEqual(null, n.exit);
}

test "tmux exit with a reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // The reason tmux gives when it decides a control client is not
    // draining fast enough, and the only explanation we would ever get.
    for ("%exit too far behind") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("too far behind", n.exit.?);
}

test "tmux survives a name containing a newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // `rename-window $'a\nb'` is enough to produce this. tmux does not
    // escape names, so the tail arrives as its own line starting with a
    // byte that cannot begin a notification.
    for ("%window-renamed @1 a") |byte| try testing.expect(try c.put(byte) == null);
    const renamed = (try c.put('\n')).?;
    try testing.expectEqualStrings("a", renamed.window_renamed.name);

    for ("b") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);

    // Still alive, and still parsing.
    for ("%window-add @7") |byte| try testing.expect(try c.put(byte) == null);
    const added = (try c.put('\n')).?;
    try testing.expectEqual(7, added.window_add.id);
}

test "tmux window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-close @2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(2, n.window_close.id);
}

test "tmux unlinked window notifications are ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Not ours to care about, but the parser must stay healthy across
    // them: a live session gets these whenever anyone else's window
    // changes.
    for ("%unlinked-window-add @9") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);
    for ("%unlinked-window-renamed @9 other") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);

    for ("%window-close @3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqual(3, n.window_close.id);
}

test "tmux unlinked-window-close is a window close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // What tmux actually sends when a window in our own session is
    // killed, because it has already been unlinked by the time the
    // notification callback runs.
    for ("%unlinked-window-close @1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(1, n.window_close.id);
}

test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}

test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}

test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}

test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}
