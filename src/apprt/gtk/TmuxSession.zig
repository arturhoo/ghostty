//! What a host surface running `tmux -CC` knows about the tabs and panes
//! it has put on screen.
//!
//! tmux hands us the whole window list every time anything changes, not a
//! delta, so the job here is to diff that against what already exists:
//! make tabs and pane surfaces that are new, reuse the ones that are not,
//! and close the ones tmux no longer mentions.
//!
//! Reuse is what makes this work at all. Rebuilding a pane's surface on
//! every layout change would throw away its terminal and reattach from
//! scratch, so panes are looked up by tmux pane ID and only their
//! arrangement is rebuilt.
const TmuxSession = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const terminal = @import("../../terminal/main.zig");
const termio = @import("../../termio.zig");
const CoreSurface = @import("../../Surface.zig");

const ext = @import("ext.zig");
const Surface = @import("class/surface.zig").Surface;
const Tab = @import("class/tab.zig").Tab;
const Window = @import("class/window.zig").Window;
const WeakRef = @import("weak_ref.zig").WeakRef;

const Router = terminal.tmux.Router;
const WindowSet = terminal.tmux.WindowSet;
const layout_plan = terminal.tmux.layout_plan;

const log = std.log.scoped(.gtk_tmux_session);

alloc: Allocator,

/// The session's router, held so pane surfaces can be created for it.
router: *Router,

/// tmux window ID to the tab showing it.
windows: std.AutoHashMapUnmanaged(usize, WeakRef(Tab)) = .empty,

/// tmux pane ID to the surface showing it.
panes: std.AutoHashMapUnmanaged(usize, WeakRef(Surface)) = .empty,

pub fn create(
    alloc: Allocator,
    router: *Router,
) Allocator.Error!*TmuxSession {
    const self = try alloc.create(TmuxSession);
    self.* = .{ .alloc = alloc, .router = router };
    return self;
}

pub fn destroy(self: *TmuxSession) void {
    // Close whatever is still on screen: the session is over.
    var it = self.windows.valueIterator();
    while (it.next()) |ref| {
        const tab = ref.get() orelse continue;
        defer tab.unref();
        closeTab(tab);
    }

    self.windows.deinit(self.alloc);
    self.panes.deinit(self.alloc);
    self.router.unref();
    self.alloc.destroy(self);
}

/// Bring the tabs and panes on screen into line with what tmux says.
///
/// `host` is the surface running the control mode client; new tabs are
/// created in its window.
pub fn sync(
    self: *TmuxSession,
    host: *Surface,
    windows: []const WindowSet.Window,
) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    // Remember what tmux still knows about, so anything left over can be
    // closed afterwards.
    var live_windows: std.AutoHashMapUnmanaged(usize, void) = .empty;
    var live_panes: std.AutoHashMapUnmanaged(usize, void) = .empty;

    for (windows) |window| {
        live_windows.put(arena.allocator(), window.id, {}) catch return;
        for (window.nodeSlice()) |node| {
            if (node.content() == .pane) {
                live_panes.put(
                    arena.allocator(),
                    node.pane_id,
                    {},
                ) catch return;
            }
        }

        self.syncWindow(&arena, host, window) catch |err| {
            log.warn(
                "failed to lay out tmux window id={} err={}",
                .{ window.id, err },
            );
        };
    }

    self.pruneWindows(&live_windows);
    self.prunePanes(&live_panes);
    self.selectActiveWindow(windows);
}

/// Bring forward the tab for the window tmux is currently on.
///
/// tmux tracks a current window per session and it moves when anyone
/// moves it -- another client, a script, a binding typed in a pane. When
/// that happens for a reason that did not come from here, the tab on
/// screen and the window tmux believes the user is on have come apart,
/// and tmux is the one that is right.
///
/// Selecting the page that is already selected is not free, so it is
/// checked first.
fn selectActiveWindow(self: *TmuxSession, windows: []const WindowSet.Window) void {
    const active = for (windows) |window| {
        if (window.active) break window;
    } else return;

    const ref = self.windows.getPtr(active.id) orelse return;
    const tab = ref.get() orelse return;
    defer tab.unref();

    const tab_view = ext.getAncestor(
        adw.TabView,
        tab.as(gtk.Widget),
    ) orelse return;

    const page = tab_view.getPage(tab.as(gtk.Widget));
    if (tab_view.getSelectedPage() == page) return;
    tab_view.setSelectedPage(page);
}

fn syncWindow(
    self: *TmuxSession,
    arena: *std.heap.ArenaAllocator,
    host: *Surface,
    window: WindowSet.Window,
) !void {
    const tab = try self.tabFor(host, window.id);

    // tmux owns the name of a tmux window, so it goes in as the tab's
    // override: the surface titles underneath are the shell's idea of a
    // title, which is not what this tab is.
    tab.setTitleOverride(std.mem.span(window.name));

    const plan = try layout_plan.plan(arena.allocator(), window.nodeSlice());

    var tree = try self.buildTree(plan);
    defer tree.deinit();

    // Zoom is a property of the tree we are about to hand over, not
    // something applied afterwards: `buildTree` always produces an
    // unzoomed one, so a window that stays zoomed across a layout change
    // would silently unzoom on every sync without this.
    //
    // Every pane is still in the tree and still alive. Zoom only decides
    // which node the widget renders from.
    if (window.zoomed) zoom: {
        const surface = self.panes.getPtr(window.zoomed_pane_id) orelse
            break :zoom;
        const view = surface.get() orelse break :zoom;
        defer view.unref();

        // Pointer equality against the tree we just built, so this has to
        // be the same surface `buildTree` put in it -- which it is, both
        // coming from the panes map.
        tree.zoom(tree.locate(view) orelse break :zoom);
    }

    // One call: an intermediate empty tree would close the tab.
    tab.getSplitTree().setTree(&tree);
}

/// The tab showing a tmux window, made if it does not exist yet.
fn tabFor(
    self: *TmuxSession,
    host: *Surface,
    window_id: usize,
) !*Tab {
    // Borrowed, not owned: a tab that exists is owned by the tab view,
    // and one we make below is owned by it as soon as it is inserted.
    if (self.windows.getPtr(window_id)) |ref| {
        if (ref.get()) |tab| {
            tab.unref();
            return tab;
        }
    }

    const gtk_window = ext.getAncestor(
        Window,
        host.as(gtk.Widget),
    ) orelse return error.NoWindow;

    const tab = gtk_window.newTabForTree(host.core());

    var ref: WeakRef(Tab) = .empty;
    ref.set(tab);
    try self.windows.put(self.alloc, window_id, ref);

    return tab;
}

/// Build a split tree for a plan, reusing surfaces we already have.
fn buildTree(
    self: *TmuxSession,
    plan: *const layout_plan.Plan,
) !Surface.Tree {
    switch (plan.*) {
        .pane => |pane_id| {
            const surface = try self.surfaceFor(pane_id);
            // The tree takes its own reference; ours was only to carry
            // the surface this far.
            defer surface.unref();
            return try Surface.Tree.init(self.alloc, surface);
        },

        .split => |split| {
            var first = try self.buildTree(split.first);
            defer first.deinit();
            var second = try self.buildTree(split.second);
            defer second.deinit();

            // `first` keeps `ratio` of the space, so the second subtree
            // goes to its right or below it. tmux's `{}` is a row of
            // side by side panes, which is a horizontal paned in GTK.
            const direction: Surface.Tree.Split.Direction = switch (split.axis) {
                .columns => .right,
                .rows => .down,
            };

            return try first.split(
                self.alloc,
                .root,
                direction,
                split.ratio,
                &second,
            );
        },
    }
}

/// The surface showing a pane, made if it does not exist yet.
///
/// The caller is handed a reference and must release it. Returning a
/// borrowed pointer would be a trap: a freshly made surface is owned by
/// nothing until it is put in a tree.
fn surfaceFor(self: *TmuxSession, pane_id: usize) !*Surface {
    if (self.panes.getPtr(pane_id)) |ref| {
        // `get` already took a reference for us.
        if (ref.get()) |surface| return surface;
    }

    const surface: *Surface = .new(.{ .tmux = .{
        .router = self.router,
        .pane_id = pane_id,
    } });

    // Turn the floating reference into the one we hand back.
    _ = surface.refSink();
    errdefer surface.unref();

    var ref: WeakRef(Surface) = .empty;
    ref.set(surface);
    try self.panes.put(self.alloc, pane_id, ref);

    return surface;
}

fn pruneWindows(
    self: *TmuxSession,
    live: *const std.AutoHashMapUnmanaged(usize, void),
) void {
    var dead: std.ArrayList(usize) = .empty;
    defer dead.deinit(self.alloc);

    var it = self.windows.iterator();
    while (it.next()) |entry| {
        if (live.contains(entry.key_ptr.*)) continue;
        dead.append(self.alloc, entry.key_ptr.*) catch continue;
    }

    for (dead.items) |id| {
        if (self.windows.fetchRemove(id)) |kv| {
            var ref = kv.value;
            const tab = ref.get() orelse continue;
            defer tab.unref();
            closeTab(tab);
        }
    }
}

fn prunePanes(
    self: *TmuxSession,
    live: *const std.AutoHashMapUnmanaged(usize, void),
) void {
    var dead: std.ArrayList(usize) = .empty;
    defer dead.deinit(self.alloc);

    var it = self.panes.iterator();
    while (it.next()) |entry| {
        if (live.contains(entry.key_ptr.*)) continue;
        dead.append(self.alloc, entry.key_ptr.*) catch continue;
    }

    for (dead.items) |id| {
        // The surface is removed from its tree by the layout we just
        // installed, which drops the last reference to it. All we owe
        // is forgetting it.
        _ = self.panes.remove(id);
    }
}

fn closeTab(tab: *Tab) void {
    // Emptying a tab's tree is how a tab asks to be closed.
    tab.getSplitTree().setTree(null);
}
