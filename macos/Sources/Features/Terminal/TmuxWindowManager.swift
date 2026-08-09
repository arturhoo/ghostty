// The Sources folder is a file system synchronized group shared with the
// iOS target, so anything referencing AppKit or TerminalController has to
// be guarded rather than added to the project's exception list.
#if os(macOS)

import AppKit
import GhosttyKit

/// Creates and maintains native windows for tmux control mode windows.
///
/// Observes `.ghosttyDidUpdateTmuxWindows`, which the
/// `GHOSTTY_ACTION_TMUX_WINDOWS` handler posts with a deep copied payload
/// and the hosting surface as the notification object.
///
/// tmux sends the whole window list on every change rather than a delta,
/// so this diffs it against what is already on screen: windows and panes
/// that are new are created, ones that already exist are reused, and
/// anything tmux stopped mentioning is closed.
///
/// Reuse is the point. Rebuilding a pane's surface when the layout changes
/// would throw away its terminal and start it over, so panes are looked up
/// by tmux pane id and only their arrangement is rebuilt.
class TmuxWindowManager {
    /// tmux window and pane ids are only unique within one control mode
    /// session, so they are qualified by the surface hosting it.
    private struct Key: Hashable {
        let host: ObjectIdentifier
        let id: Int
    }

    /// Weakly held: the user can close one of these windows themselves,
    /// and we should not keep it alive or resurrect it.
    private struct WeakController {
        weak var value: TerminalController?
    }

    private struct WeakSurface {
        weak var value: Ghostty.SurfaceView?
    }

    private var windows: [Key: WeakController] = [:]
    private var panes: [Key: WeakSurface] = [:]

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyDidUpdateTmuxWindows(_:)),
            name: .ghosttyDidUpdateTmuxWindows,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func ghosttyDidUpdateTmuxWindows(_ notification: Notification) {
        guard let hostView = notification.object as? Ghostty.SurfaceView else { return }
        guard let action = notification.userInfo?[
            Notification.Name.TmuxWindowsKey
        ] as? Ghostty.Action.TmuxWindows else { return }
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        let ghostty = appDelegate.ghostty
        guard let app = ghostty.app else { return }
        guard let hostSurface = hostView.surface else { return }

        let host = ObjectIdentifier(hostView)
        var liveWindows: Set<Key> = []
        var livePanes: Set<Key> = []

        for window in action.windows {
            liveWindows.insert(Key(host: host, id: window.id))
            for node in window.nodes where node.kind == .pane {
                livePanes.insert(Key(host: host, id: node.paneId))
            }
        }

        for window in action.windows {
            guard !window.nodes.isEmpty else { continue }

            guard let root = node(
                for: window,
                at: 0,
                host: host,
                app: app,
                hostSurface: hostSurface
            ) else {
                Ghostty.logger.warning(
                    "could not build a layout for tmux window id=\(window.id)")
                continue
            }

            let tree = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: nil)
            let key = Key(host: host, id: window.id)

            if let controller = windows[key]?.value {
                // Only touch the window if the arrangement actually
                // changed. tmux reports the layout on every notification,
                // including ones that changed nothing, and reassigning the
                // tree tears views out of the hierarchy and puts them back.
                // SplitTree is not Equatable, but its nodes are.
                if controller.surfaceTree.root != tree.root {
                    controller.surfaceTree = tree
                }
                continue
            }

            windows[key] = .init(
                value: TerminalController.newWindow(ghostty, tree: tree))
        }

        prune(liveWindows: liveWindows, livePanes: livePanes, host: host)
    }

    /// Close the windows for tmux windows that are gone, and forget panes
    /// that are gone. Only touches state belonging to this host, so two
    /// tmux sessions in one app do not disturb each other.
    private func prune(
        liveWindows: Set<Key>,
        livePanes: Set<Key>,
        host: ObjectIdentifier
    ) {
        for (key, entry) in windows {
            guard key.host == host else { continue }
            if liveWindows.contains(key) {
                // Drop entries whose window the user closed themselves, so
                // a later layout can build a fresh one.
                if entry.value == nil { windows.removeValue(forKey: key) }
                continue
            }

            entry.value?.closeWindowImmediately()
            windows.removeValue(forKey: key)
        }

        for (key, entry) in panes {
            guard key.host == host else { continue }
            if livePanes.contains(key) && entry.value != nil { continue }

            // The surface itself is released by the tree that no longer
            // holds it; all we owe is forgetting it.
            panes.removeValue(forKey: key)
        }
    }

    /// Build the split tree for one node of a tmux layout.
    ///
    /// tmux splits can have any number of children; a split tree is binary,
    /// so a run of children becomes a chain of two way splits leaning left.
    /// Ratios come from the children's own sizes rather than the parent's,
    /// because a tmux split spends a cell on the divider between each pair
    /// and so the children do not add up to the parent.
    private func node(
        for window: Ghostty.Action.TmuxWindows.Window,
        at index: Int,
        host: ObjectIdentifier,
        app: ghostty_app_t,
        hostSurface: ghostty_surface_t
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard window.nodes.indices.contains(index) else { return nil }
        let n = window.nodes[index]

        switch n.kind {
        case .pane:
            guard let view = surface(
                paneId: n.paneId,
                host: host,
                app: app,
                hostSurface: hostSurface
            ) else { return nil }
            return .leaf(view: view)

        case .horizontal, .vertical:
            let direction: SplitTree<Ghostty.SurfaceView>.Direction =
                n.kind == .horizontal ? .horizontal : .vertical
            return chain(
                window: window,
                children: Array(n.children),
                direction: direction,
                host: host,
                app: app,
                hostSurface: hostSurface)
        }
    }

    private func chain(
        window: Ghostty.Action.TmuxWindows.Window,
        children: [Int],
        direction: SplitTree<Ghostty.SurfaceView>.Direction,
        host: ObjectIdentifier,
        app: ghostty_app_t,
        hostSurface: ghostty_surface_t
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard let first = children.first else { return nil }

        let head = node(
            for: window,
            at: first,
            host: host,
            app: app,
            hostSurface: hostSurface)
        let rest = Array(children.dropFirst())
        if rest.isEmpty { return head }

        guard let head else { return nil }
        guard let tail = chain(
            window: window,
            children: rest,
            direction: direction,
            host: host,
            app: app,
            hostSurface: hostSurface
        ) else { return head }

        // Against what is left rather than the whole span, so the second
        // cut of three equal panes is a half and not a third.
        let span = { (i: Int) -> Int in
            guard window.nodes.indices.contains(i) else { return 0 }
            let node = window.nodes[i]
            return direction == .horizontal ? node.width : node.height
        }
        let headSpan = span(first)
        let total = headSpan + rest.reduce(0) { $0 + span($1) }
        let ratio = total > 0 ? Double(headSpan) / Double(total) : 0.5

        return .split(.init(
            direction: direction,
            ratio: ratio,
            left: head,
            right: tail))
    }

    /// The surface displaying one tmux pane, made if we do not have it.
    ///
    /// Every surface consumes exactly one router reference, so a fresh one
    /// is taken per surface and ownership passes to the surface config.
    private func surface(
        paneId: Int,
        host: ObjectIdentifier,
        app: ghostty_app_t,
        hostSurface: ghostty_surface_t
    ) -> Ghostty.SurfaceView? {
        let key = Key(host: host, id: paneId)
        if let existing = panes[key]?.value { return existing }

        guard let router = ghostty_surface_tmux_router(hostSurface) else {
            Ghostty.logger.warning("no tmux router for the hosting surface")
            return nil
        }

        var config = Ghostty.SurfaceConfiguration()
        config.tmuxRouter = router
        config.tmuxPaneId = paneId

        let view = Ghostty.SurfaceView(app, baseConfig: config)
        panes[key] = .init(value: view)
        return view
    }
}

#endif
