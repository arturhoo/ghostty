import SwiftUI
import GhosttyKit

extension Ghostty.Action {
    /// The full set of tmux control mode windows for a session. This deep
    /// copies the C payload since it is only valid for the duration of the
    /// action callback.
    struct TmuxWindows {
        let windows: [Window]

        /// A single tmux window and its flattened layout tree. Node index 0
        /// is the root of the tree.
        struct Window {
            let id: Int

            /// The window's tmux name. Copied out of the C payload like
            /// everything else here, since that payload dies with the
            /// action callback.
            let name: String

            /// Whether tmux is currently on this window. At most one
            /// window in a set has it.
            let active: Bool

            let width: Int
            let height: Int
            let nodes: [Node]

            /// The first pane in tree order. Children of a split are
            /// contiguous in `nodes` so array order is a pre-order-ish
            /// traversal; the first PANE node is the top-left-most pane.
            var firstPaneId: Int? {
                nodes.first(where: { $0.kind == .pane })?.paneId
            }
        }

        /// A node in a window's flattened layout tree. `paneId` is
        /// meaningful only when kind is pane; `children` is meaningful only
        /// for a split and indexes into the owning window's `nodes`.
        struct Node {
            enum Kind {
                /// A terminal pane (leaf).
                case pane
                /// Children are laid out side by side (tmux `{}`).
                case horizontal
                /// Children are stacked top to bottom (tmux `[]`).
                case vertical

                init(_ c: ghostty_tmux_node_kind_e) {
                    switch c {
                    case GHOSTTY_TMUX_NODE_HORIZONTAL:
                        self = .horizontal
                    case GHOSTTY_TMUX_NODE_VERTICAL:
                        self = .vertical
                    default:
                        self = .pane
                    }
                }
            }

            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let kind: Kind
            let paneId: Int
            let children: Range<Int>

            init(c: ghostty_tmux_node_s) {
                self.x = c.x
                self.y = c.y
                self.width = c.width
                self.height = c.height
                self.kind = Kind(c.kind)
                self.paneId = c.pane_id

                // The range is only meaningful for splits. Guard against a
                // malformed range so the half-open constructor can't trap.
                if c.children_start <= c.children_end {
                    self.children = c.children_start..<c.children_end
                } else {
                    self.children = 0..<0
                }
            }
        }

        init(c: ghostty_action_tmux_windows_s) {
            guard c.len > 0, let cWindows = c.windows else {
                self.windows = []
                return
            }

            self.windows = UnsafeBufferPointer(start: cWindows, count: c.len).map { cWindow in
                let nodes: [Node]
                if cWindow.nodes_len > 0, let cNodes = cWindow.nodes {
                    nodes = UnsafeBufferPointer(
                        start: cNodes,
                        count: cWindow.nodes_len
                    ).map { Node(c: $0) }
                } else {
                    nodes = []
                }

                return Window(
                    id: cWindow.id,
                    name: cWindow.name.map { String(cString: $0) } ?? "",
                    active: cWindow.active,
                    width: cWindow.width,
                    height: cWindow.height,
                    nodes: nodes)
            }
        }
    }
}
