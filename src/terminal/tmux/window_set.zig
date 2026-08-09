//! A snapshot of the tmux window and pane layout, owned by the caller.
//!
//! The viewer hands out its window list as an action whose memory is only
//! valid until the next call to `next`. Anything that wants to keep that
//! information around, or hand it to another thread, needs a copy that owns
//! itself. That is what this is.
//!
//! The layout tree is flattened into a single array per window, with splits
//! referring to their children by index range rather than by pointer. The
//! stored types are `extern` so that this can be handed across the C ABI
//! without building a second representation: a `cval` conversion has no
//! allocator and returns by value, so whatever crosses the boundary has to
//! already exist in this shape. `Node.content` recovers the tagged union
//! for Zig callers.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Layout = @import("layout.zig").Layout;
const Viewer = @import("viewer.zig").Viewer;

pub const WindowSet = struct {
    /// Owns every allocation reachable from `windows`.
    arena: ArenaAllocator,

    /// The windows in the session, in the order tmux reported them.
    windows: []const Window,

    pub const Window = extern struct {
        /// The tmux window ID. Stable for the lifetime of a viewer.
        id: usize,

        /// The size of the whole window in cells.
        width: usize,
        height: usize,

        /// The layout tree, flattened. Index 0 is the root. This is never
        /// empty: a window always has at least one pane.
        nodes: [*]const Node,
        nodes_len: usize,

        pub fn nodeSlice(self: Window) []const Node {
            return self.nodes[0..self.nodes_len];
        }
    };

    pub const Node = extern struct {
        /// Offset from the top-left of the window, in cells.
        x: usize,
        y: usize,

        /// Size of this node in cells.
        width: usize,
        height: usize,

        kind: Kind,

        /// The tmux pane ID. Only meaningful when `kind` is `.pane`.
        pane_id: usize,

        /// Half-open range into the owning window's nodes. Only meaningful
        /// when `kind` is a split.
        children_start: usize,
        children_end: usize,

        /// Sync with: ghostty_tmux_node_kind_e
        pub const Kind = enum(c_int) {
            /// A leaf holding a single tmux pane.
            pane,

            /// A split. Children are contiguous in the same window's node
            /// array, so they can be addressed by range.
            horizontal,
            vertical,
        };

        /// A half-open range into the owning window's `nodes`.
        pub const Children = struct {
            start: usize,
            end: usize,

            pub fn slice(self: Children, nodes: []const Node) []const Node {
                return nodes[self.start..self.end];
            }
        };

        pub const Content = union(enum) {
            pane: usize,
            horizontal: Children,
            vertical: Children,
        };

        /// The tagged view of this node, for Zig callers. The flat fields
        /// above exist for the C ABI; this is the one to switch on.
        pub fn content(self: Node) Content {
            const children: Children = .{
                .start = self.children_start,
                .end = self.children_end,
            };
            return switch (self.kind) {
                .pane => .{ .pane = self.pane_id },
                .horizontal => .{ .horizontal = children },
                .vertical => .{ .vertical = children },
            };
        }
    };

    /// Snapshot the given windows. The result owns all of its memory and
    /// is independent of the viewer it came from.
    pub fn create(
        gpa: Allocator,
        windows: []const Viewer.Window,
    ) Allocator.Error!*WindowSet {
        const self = try gpa.create(WindowSet);
        errdefer gpa.destroy(self);

        self.* = .{
            .arena = .init(gpa),
            .windows = &.{},
        };
        errdefer self.arena.deinit();

        const alloc = self.arena.allocator();
        const copy = try alloc.alloc(Window, windows.len);
        for (windows, copy) |src, *dst| {
            var nodes: std.ArrayList(Node) = .empty;

            // Slot 0 is the root. Every node is placed by its parent, so
            // the root has to be placed by us.
            try nodes.append(alloc, undefined);
            try flatten(alloc, &nodes, 0, src.layout);

            const owned = try nodes.toOwnedSlice(alloc);
            dst.* = .{
                .id = src.id,
                .width = src.width,
                .height = src.height,
                .nodes = owned.ptr,
                .nodes_len = owned.len,
            };
        }

        self.windows = copy;
        return self;
    }

    /// Write `layout` into the already-reserved `nodes[idx]`, appending
    /// its descendants to the end of `nodes`.
    ///
    /// Direct children are reserved as one contiguous block before any of
    /// them recurses, which is what lets a split address its children as a
    /// range: a grandchild always lands after every one of its parent's
    /// siblings.
    fn flatten(
        alloc: Allocator,
        nodes: *std.ArrayList(Node),
        idx: usize,
        layout: Layout,
    ) Allocator.Error!void {
        nodes.items[idx] = .{
            .x = layout.x,
            .y = layout.y,
            .width = layout.width,
            .height = layout.height,
            .kind = undefined,
            .pane_id = 0,
            .children_start = 0,
            .children_end = 0,
        };

        switch (layout.content) {
            .pane => |id| {
                nodes.items[idx].kind = .pane;
                nodes.items[idx].pane_id = id;
            },

            inline .horizontal, .vertical => |children, tag| {
                const start = nodes.items.len;
                try nodes.appendNTimes(alloc, undefined, children.len);

                // Re-index rather than holding a pointer: the append above
                // may have reallocated.
                nodes.items[idx].kind = @field(Node.Kind, @tagName(tag));
                nodes.items[idx].children_start = start;
                nodes.items[idx].children_end = start + children.len;

                for (children, start..) |child, child_idx| {
                    try flatten(alloc, nodes, child_idx, child);
                }
            },
        }
    }

    /// Free the snapshot and the snapshot itself.
    pub fn destroy(self: *WindowSet) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Build a `Viewer.Window` from a layout string for testing. The layout
/// string has no checksum prefix; see `Layout.parse`.
fn testWindow(
    alloc: Allocator,
    id: usize,
    width: usize,
    height: usize,
    layout_str: []const u8,
) !Viewer.Window {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const layout = try Layout.parse(arena.allocator(), layout_str);
    return .{
        .id = id,
        .name = "",
        .width = width,
        .height = height,
        .layout_arena = arena.state,
        .layout = layout,
    };
}

test "single pane window" {
    const alloc = testing.allocator;

    var window = try testWindow(alloc, 0, 83, 44, "83x44,0,0,0");
    defer window.deinit(alloc);

    const set = try WindowSet.create(alloc, &.{window});
    defer set.destroy();

    try testing.expectEqual(1, set.windows.len);
    try testing.expectEqual(0, set.windows[0].id);
    try testing.expectEqual(83, set.windows[0].width);
    try testing.expectEqual(44, set.windows[0].height);

    const nodes = set.windows[0].nodeSlice();
    try testing.expectEqual(1, nodes.len);
    try testing.expectEqual(0, nodes[0].x);
    try testing.expectEqual(0, nodes[0].y);
    try testing.expectEqual(83, nodes[0].width);
    try testing.expectEqual(44, nodes[0].height);
    try testing.expectEqual(0, nodes[0].content().pane);

    // The flat fields are what crosses the C ABI, so pin them too.
    try testing.expectEqual(.pane, nodes[0].kind);
    try testing.expectEqual(0, nodes[0].pane_id);
}

test "vertical split" {
    const alloc = testing.allocator;

    var window = try testWindow(
        alloc,
        0,
        83,
        44,
        "83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
    );
    defer window.deinit(alloc);

    const set = try WindowSet.create(alloc, &.{window});
    defer set.destroy();

    const nodes = set.windows[0].nodeSlice();
    try testing.expectEqual(3, nodes.len);

    const children = nodes[0].content().vertical;
    try testing.expectEqual(1, children.start);
    try testing.expectEqual(3, children.end);

    const kids = children.slice(nodes);
    try testing.expectEqual(2, kids.len);
    try testing.expectEqual(0, kids[0].content().pane);
    try testing.expectEqual(22, kids[0].height);
    try testing.expectEqual(2, kids[1].content().pane);
    try testing.expectEqual(23, kids[1].y);
    try testing.expectEqual(21, kids[1].height);
}

test "nested split keeps siblings contiguous" {
    const alloc = testing.allocator;

    // A vertical split whose second child is itself a horizontal split.
    // The grandchildren must land after both direct children so that the
    // root's child range stays valid.
    var window = try testWindow(
        alloc,
        3,
        80,
        24,
        "80x24,0,0[80x12,0,0,0,80x11,0,13{40x11,0,13,1,39x11,41,13,2}]",
    );
    defer window.deinit(alloc);

    const set = try WindowSet.create(alloc, &.{window});
    defer set.destroy();

    try testing.expectEqual(3, set.windows[0].id);

    const nodes = set.windows[0].nodeSlice();
    try testing.expectEqual(5, nodes.len);

    // Root: vertical, two direct children at 1 and 2.
    const top = nodes[0].content().vertical;
    try testing.expectEqual(1, top.start);
    try testing.expectEqual(3, top.end);

    // First child is a plain pane.
    try testing.expectEqual(0, nodes[1].content().pane);

    // Second child is the nested horizontal split, whose own children
    // were appended after it.
    const nested = nodes[2].content().horizontal;
    try testing.expectEqual(3, nested.start);
    try testing.expectEqual(5, nested.end);
    try testing.expectEqual(1, nodes[3].content().pane);
    try testing.expectEqual(2, nodes[4].content().pane);
    try testing.expectEqual(41, nodes[4].x);
}

test "multiple windows" {
    const alloc = testing.allocator;

    var w0 = try testWindow(alloc, 0, 83, 44, "83x44,0,0,0");
    defer w0.deinit(alloc);
    var w1 = try testWindow(alloc, 7, 80, 24, "80x24,0,0,5");
    defer w1.deinit(alloc);

    const set = try WindowSet.create(alloc, &.{ w0, w1 });
    defer set.destroy();

    try testing.expectEqual(2, set.windows.len);
    try testing.expectEqual(0, set.windows[0].id);
    try testing.expectEqual(7, set.windows[1].id);
    try testing.expectEqual(5, set.windows[1].nodeSlice()[0].content().pane);
}

test "empty window list" {
    const set = try WindowSet.create(testing.allocator, &.{});
    defer set.destroy();
    try testing.expectEqual(0, set.windows.len);
}
