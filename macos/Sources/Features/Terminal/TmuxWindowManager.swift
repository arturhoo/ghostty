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
        let panesBefore = Set(panes.keys)
        var liveWindows: Set<Key> = []
        var livePanes: Set<Key> = []

        for window in action.windows {
            liveWindows.insert(Key(host: host, id: window.id))
            for node in window.nodes where node.kind == .pane {
                livePanes.insert(Key(host: host, id: node.paneId))
            }
        }

        for (index, window) in action.windows.enumerated() {
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

            // Zoom renders one pane in place of the whole tree. Every
            // other pane is still in `root` and still alive: this picks
            // which node is drawn, it does not prune anything.
            let zoomed: SplitTree<Ghostty.SurfaceView>.Node? = {
                guard let paneId = window.zoomedPaneId,
                      let view = panes[Key(host: host, id: paneId)]?.value
                else { return nil }

                // Against the tree being built, not the one on screen.
                return root.node(view: view)
            }()

            let tree = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: zoomed)
            let key = Key(host: host, id: window.id)

            if let controller = windows[key]?.value {
                // Only touch the window if the arrangement actually
                // changed. tmux reports the layout on every notification,
                // including ones that changed nothing, and reassigning the
                // tree tears views out of the hierarchy and puts them back.
                // SplitTree is not Equatable, but its nodes are.
                //
                // Zoom has to be part of that comparison. tmux's
                // window_layout does not change when a pane zooms -- that
                // is the whole point of it -- so the roots compare equal
                // and a zoom toggle would never reach the screen.
                if controller.surfaceTree.root != tree.root ||
                    controller.surfaceTree.zoomed != tree.zoomed {
                    controller.surfaceTree = tree
                    keepFocusInWindow(window, of: controller, host: host)
                }
                setTitle(controller, window.name)
                focusNewPane(in: window, of: controller, host: host, seen: panesBefore)
                continue
            }

            // The first tmux window for a host gets a window of its own;
            // every one after it opens as a tab beside it.
            //
            // Both halves matter. A control mode session is its own
            // thing, so `tmux -CC` should not drop more tabs onto
            // whatever window happened to launch it. But a tmux window
            // *is* what tmux calls a tab, so the second one onwards
            // belongs beside the first rather than scattered across the
            // desktop -- which is also how the GTK side shows them.
            //
            // Opened as a tab rather than opened as a window and then
            // joined: `newWindow` sizes the window to the tree, cascades
            // it and shows it, so joining afterwards meant watching a
            // window appear offset down and to the right and then get
            // absorbed. `newTab` puts it in the group before anything is
            // presented, and handles the fullscreen rules while it is
            // there.
            let controller = newController(
                ghostty: ghostty,
                tree: tree,
                parent: tabParent(action.windows, before: index, host: host))
            setTitle(controller, window.name)
            windows[key] = .init(value: controller)
        }

        prune(liveWindows: liveWindows, livePanes: livePanes, host: host)
        selectActiveWindow(action.windows, host: host)
    }

    /// Bring forward the tab for the window tmux is currently on.
    ///
    /// tmux tracks a current window per session, and it moves when
    /// anyone moves it -- another client, a script, a binding typed in a
    /// pane. When it moves for a reason that did not come from us, the
    /// tab on screen and the window tmux thinks the user is on have come
    /// apart, and tmux's answer is the right one.
    ///
    /// Only when the group is already frontmost. tmux says nothing about
    /// whether ghostty should come forward, and a background session
    /// changing windows is not a reason to interrupt whatever the user
    /// is doing in another app -- or another window of this one.
    ///
    /// Selecting a tab that is already selected is not free: AppKit
    /// still runs the tab switch, so the check matters.
    private func selectActiveWindow(
        _ windows: [Ghostty.Action.TmuxWindows.Window],
        host: ObjectIdentifier
    ) {
        guard let active = windows.first(where: { $0.active }) else { return }
        guard let controller = self.windows[Key(host: host, id: active.id)]?.value,
              let window = controller.window else { return }
        guard let group = window.tabGroup else { return }
        guard group.selectedWindow !== window else { return }
        guard group.windows.contains(where: { $0.isKeyWindow }) else { return }

        group.selectedWindow = window
    }

    /// Put focus back on a surviving pane when the focused one is gone.
    ///
    /// Closing a split locally hands focus to a neighbour, but a tmux
    /// pane does not close: the layout it was in is replaced wholesale,
    /// so nothing runs that logic and the window is left focused on a
    /// view that is no longer in it.
    ///
    /// Which survivor gets it is the first pane tmux lists, not the
    /// neighbour of the one that went. tmux knows which pane is active
    /// and we do not ask yet; until we do, the distinction only shows up
    /// with three panes or more, and having focus somewhere in the window
    /// beats having it nowhere.
    ///
    /// Only for the key window, so a pane closing somewhere in the
    /// background cannot pull the user out of what they are typing into.
    private func keepFocusInWindow(
        _ window: Ghostty.Action.TmuxWindows.Window,
        of controller: TerminalController,
        host: ObjectIdentifier
    ) {
        guard controller.window?.isKeyWindow ?? false else { return }
        if let focused = controller.focusedSurface,
           controller.surfaceTree.contains(focused) { return }

        for node in window.nodes where node.kind == .pane {
            guard let view = panes[Key(host: host, id: node.paneId)]?.value else { continue }
            controller.focusSurface(view)
            return
        }
    }

    /// The controller for a tmux window: a tab going in after `parent`,
    /// or a window of its own when the host has nothing to sit beside.
    ///
    /// `newTab` returns nil only when it has told the user why it cannot
    /// make one, which is non-native fullscreen. The tmux window exists
    /// either way and has to go somewhere, so it gets a window.
    private func newController(
        ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        parent: NSWindow?
    ) -> TerminalController {
        if let parent,
           let controller = TerminalController.newTab(
               ghostty,
               from: parent,
               withSurfaceTree: tree) {
            return controller
        }

        return TerminalController.newWindow(ghostty, tree: tree)
    }

    /// The window a new tab for `windows[index]` should go in after, or
    /// nil if this host has nothing on screen yet.
    ///
    /// Asked rather than remembered, because a remembered one goes stale:
    /// the tmux window holding it can close while others stay open, and
    /// the next window to arrive would then have nothing to join and
    /// would come up on its own.
    ///
    /// Found by walking tmux's order rather than by taking any window of
    /// this host. Any of them finds the right tab group, but `newTab`
    /// puts the tab in *after the one it is given*, and `windows` is a
    /// dictionary -- so picking whichever came out first dropped new tabs
    /// at an arbitrary position in the bar.
    private func tabParent(
        _ windows: [Ghostty.Action.TmuxWindows.Window],
        before index: Int,
        host: ObjectIdentifier
    ) -> NSWindow? {
        // The nearest window before this one that is already on screen.
        // Going in after it is what lines our tabs up with tmux's order.
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let window = liveWindow(id: windows[i].id, host: host) { return window }
        }

        // Nothing before it, so settle for finding the group: the tab
        // lands one place later than tmux has it. Only reachable when a
        // window appears before ones already on screen, which needs a
        // lower index to be freed up and reused.
        for i in stride(from: index + 1, to: windows.count, by: 1) {
            if let window = liveWindow(id: windows[i].id, host: host) { return window }
        }

        return nil
    }

    private func liveWindow(id: Int, host: ObjectIdentifier) -> NSWindow? {
        guard let window = windows[Key(host: host, id: id)]?.value?.window,
              window.isVisible else { return nil }
        return window
    }

    /// Move focus to a pane that has just appeared in a window that was
    /// already on screen.
    ///
    /// That is what a split is from here: tmux answers `split-window`
    /// with a layout, and the pane arrives with everything else. A local
    /// split leaves the new surface focused, so this one should too.
    ///
    /// Only when the window is the key one. tmux tells every client about
    /// every change, so without that a split someone else made in another
    /// window would pull the user out of what they were typing into.
    private func focusNewPane(
        in window: Ghostty.Action.TmuxWindows.Window,
        of controller: TerminalController,
        host: ObjectIdentifier,
        seen: Set<Key>
    ) {
        guard controller.window?.isKeyWindow ?? false else { return }

        for node in window.nodes where node.kind == .pane {
            let key = Key(host: host, id: node.paneId)
            guard !seen.contains(key) else { continue }
            guard let view = panes[key]?.value else { continue }
            controller.focusSurface(view)
            return
        }
    }

    /// Show the tmux window's name as the window title.
    ///
    /// tmux owns what a tmux window is called, so this goes in as the
    /// override: the surface titles underneath are the shell's idea of a
    /// title, which is a different thing. Assigning only on a change
    /// keeps this off the main thread's work list for the common case
    /// where tmux re-reports a layout that did not move.
    private func setTitle(_ controller: TerminalController, _ name: String) {
        let wanted = name.isEmpty ? nil : name
        if controller.titleOverride != wanted {
            controller.titleOverride = wanted
        }
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

            if let controller = entry.value {
                // Just this tab. closeWindowImmediately takes the whole
                // tab group with it, and these windows are tabs of one
                // another, so closing one tmux window would have closed
                // every other one along with it.
                //
                // Undo is off because there is nothing to undo: the
                // window is gone on the tmux side, and putting a native
                // one back would show a window that no longer exists.
                if let undoManager = controller.undoManager {
                    undoManager.disableUndoRegistration {
                        controller.closeTabImmediately()
                    }
                } else {
                    controller.closeTabImmediately()
                }
            }
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
