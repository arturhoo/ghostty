//! Types and functions related to tmux protocols.

const control = @import("tmux/control.zig");
const layout = @import("tmux/layout.zig");
pub const output = @import("tmux/output.zig");
pub const ControlParser = control.Parser;
pub const ControlNotification = control.Notification;
pub const Layout = layout.Layout;
pub const Viewer = @import("tmux/viewer.zig").Viewer;
pub const WindowSet = @import("tmux/window_set.zig").WindowSet;
pub const sink = @import("tmux/sink.zig");
pub const Router = @import("tmux/router.zig").Router;
pub const layout_plan = @import("tmux/layout_plan.zig");
pub const Op = sink.Op;
pub const Sink = sink.Sink;

test {
    @import("std").testing.refAllDecls(@This());
}
