//! Turns a tmux window layout into something a binary split tree can be
//! built from.
//!
//! tmux describes a window as a tree whose split nodes may have any number
//! of children: three panes side by side is one node with three children.
//! A ghostty split tree is strictly binary, so a run of children becomes a
//! chain of two-way splits, leaning left:
//!
//!     tmux:   split(a, b, c)
//!     plan:   split(a, split(b, c))
//!
//! Ratios are computed from the children's own sizes rather than the
//! parent's, because a tmux split spends a cell on the separator between
//! each pair and the children therefore do not add up to the parent.
//!
//! This is deliberately free of any GUI type, so the arithmetic can be
//! tested on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;

const WindowSet = @import("window_set.zig").WindowSet;

/// How the two sides of a split sit next to each other.
///
/// Named for the geometry rather than borrowing tmux's or ghostty's
/// vocabulary, both of which use "horizontal" for the opposite thing
/// depending on who you ask. The caller maps these onto whatever its own
/// split type calls them.
pub const Axis = enum {
    /// Side by side, divided by a vertical line. tmux writes this `{}`.
    columns,

    /// Stacked, divided by a horizontal line. tmux writes this `[]`.
    rows,
};

pub const Plan = union(enum) {
    /// A tmux pane ID.
    pane: usize,

    split: Split,

    pub const Split = struct {
        axis: Axis,

        /// The share of the pair's span given to `first`, in (0, 1).
        ratio: f16,

        first: *const Plan,
        second: *const Plan,
    };

    /// Number of panes in this plan.
    pub fn paneCount(self: *const Plan) usize {
        return switch (self.*) {
            .pane => 1,
            .split => |s| s.first.paneCount() + s.second.paneCount(),
        };
    }
};

/// Build a plan for one window's flattened layout.
///
/// Everything is allocated from `arena`; free it all at once.
pub fn plan(
    arena: Allocator,
    nodes: []const WindowSet.Node,
) Allocator.Error!*const Plan {
    assert(nodes.len > 0);
    return build(arena, nodes, 0);
}

fn build(
    arena: Allocator,
    nodes: []const WindowSet.Node,
    index: usize,
) Allocator.Error!*const Plan {
    const node = nodes[index];
    const out = try arena.create(Plan);

    switch (node.content()) {
        .pane => |id| out.* = .{ .pane = id },

        inline .horizontal, .vertical => |children, tag| {
            const axis: Axis = switch (tag) {
                // tmux calls a left-to-right row of panes "horizontal".
                .horizontal => .columns,
                .vertical => .rows,
                else => unreachable,
            };

            out.* = try chain(
                arena,
                nodes,
                children.start,
                children.end,
                axis,
            );
        },
    }

    return out;
}

/// Turn `nodes[start..end]` into a left-leaning chain of two-way splits.
fn chain(
    arena: Allocator,
    nodes: []const WindowSet.Node,
    start: usize,
    end: usize,
    axis: Axis,
) Allocator.Error!Plan {
    assert(end > start);

    // A split with one child is not something tmux produces, but if it
    // ever did, the child alone is the honest answer.
    if (end - start == 1) return (try build(arena, nodes, start)).*;

    const first = try build(arena, nodes, start);

    const second = try arena.create(Plan);
    second.* = try chain(arena, nodes, start + 1, end, axis);

    // Against the remaining children rather than the parent: the parent
    // also spans the separators between them.
    const head = span(nodes[start], axis);
    var tail: usize = 0;
    for (nodes[start + 1 .. end]) |n| tail += span(n, axis);

    const total = head + tail;
    const ratio: f16 = if (total == 0)
        0.5
    else
        @floatCast(@as(f64, @floatFromInt(head)) / @as(f64, @floatFromInt(total)));

    return .{ .split = .{
        .axis = axis,
        .ratio = ratio,
        .first = first,
        .second = second,
    } };
}

fn span(node: WindowSet.Node, axis: Axis) usize {
    return switch (axis) {
        .columns => node.width,
        .rows => node.height,
    };
}

// -------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------

const Layout = @import("layout.zig").Layout;
const Viewer = @import("viewer.zig").Viewer;

/// Build a WindowSet from one checksum-free layout string.
fn testSet(alloc: Allocator, layout_str: []const u8) !*WindowSet {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const parsed = try Layout.parse(arena.allocator(), layout_str);

    var window: Viewer.Window = .{
        .id = 0,
        .width = parsed.width,
        .height = parsed.height,
        .layout_arena = arena.state,
        .layout = parsed,
    };
    defer window.deinit(alloc);

    return try WindowSet.create(alloc, &.{window});
}

test "a single pane is the whole plan" {
    const alloc = testing.allocator;

    const set = try testSet(alloc, "80x24,0,0,3");
    defer set.destroy();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const p = try plan(arena.allocator(), set.windows[0].nodeSlice());
    try testing.expectEqual(3, p.pane);
    try testing.expectEqual(1, p.paneCount());
}

test "two stacked panes split on their own heights" {
    const alloc = testing.allocator;

    // 22 and 21 rows with a separator between: the ratio is against
    // 43, not the window's 44.
    const set = try testSet(alloc, "83x44,0,0[83x22,0,0,0,83x21,0,23,2]");
    defer set.destroy();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const p = try plan(arena.allocator(), set.windows[0].nodeSlice());
    try testing.expectEqual(.rows, p.split.axis);
    try testing.expectEqual(0, p.split.first.pane);
    try testing.expectEqual(2, p.split.second.pane);
    try testing.expectApproxEqAbs(
        @as(f32, 22.0 / 43.0),
        @as(f32, p.split.ratio),
        0.001,
    );
}

test "side by side panes use the columns axis" {
    const alloc = testing.allocator;

    const set = try testSet(alloc, "80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    defer set.destroy();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const p = try plan(arena.allocator(), set.windows[0].nodeSlice());
    try testing.expectEqual(.columns, p.split.axis);
    try testing.expectApproxEqAbs(
        @as(f32, 40.0 / 79.0),
        @as(f32, p.split.ratio),
        0.001,
    );
}

test "three children become a left leaning chain" {
    const alloc = testing.allocator;

    // Three equal columns of 26 in an 80 wide window.
    const set = try testSet(
        alloc,
        "80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}",
    );
    defer set.destroy();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const p = try plan(arena.allocator(), set.windows[0].nodeSlice());
    try testing.expectEqual(3, p.paneCount());

    // First cut gives a third to pane 1.
    try testing.expectEqual(1, p.split.first.pane);
    try testing.expectApproxEqAbs(
        @as(f32, 26.0 / 78.0),
        @as(f32, p.split.ratio),
        0.001,
    );

    // The rest is itself a split, and its ratio is against what is left
    // rather than the original span: half, not a third.
    const rest = p.split.second;
    try testing.expectEqual(2, rest.split.first.pane);
    try testing.expectEqual(3, rest.split.second.pane);
    try testing.expectApproxEqAbs(
        @as(f32, 0.5),
        @as(f32, rest.split.ratio),
        0.001,
    );
}

test "a nested split keeps its own axis" {
    const alloc = testing.allocator;

    // A row split whose second child is a column split.
    const set = try testSet(
        alloc,
        "80x24,0,0[80x12,0,0,0,80x11,0,13{40x11,0,13,1,39x11,41,13,2}]",
    );
    defer set.destroy();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const p = try plan(arena.allocator(), set.windows[0].nodeSlice());
    try testing.expectEqual(.rows, p.split.axis);
    try testing.expectEqual(0, p.split.first.pane);

    const nested = p.split.second;
    try testing.expectEqual(.columns, nested.split.axis);
    try testing.expectEqual(1, nested.split.first.pane);
    try testing.expectEqual(2, nested.split.second.pane);
    try testing.expectEqual(3, p.paneCount());
}
