import AppKit
import SwiftUI

/// Puts the sidebar toggle back beside the traffic lights when the window opens with the sidebar
/// collapsed.
///
/// The window restores the collapsed sidebar, and a toolbar first laid out that way never places the
/// sidebar's toggle: it goes into the overflow menu at the far right and stays there. Measured in a
/// bare `TabView` with `.sidebarAdaptable` on macOS 26, 2026-10-07. Resizing the window, re-adding
/// the toolbar or the item, and collapsing again in the same pass all leave it there. Showing the
/// sidebar does place it, and collapsing after that keeps it placed, so that is what this does,
/// without animation, and only when the toggle is actually missing.
struct MacSidebarToggleRepair: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RepairView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class RepairView: NSView {
        private enum Phase {
            case watching
            case expanded(NSSplitViewItem)
            case done
        }

        private var phase = Phase.watching
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window, case .watching = phase else { return }
            // The toolbar fills in over the first few updates of a window that is just opening. A
            // shell mounted into a window already on screen gets no update to wait for, hence the
            // check of its own.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            DispatchQueue.main.async { [weak self] in self?.check() }
        }

        private func check() {
            guard let window, window.isVisible,
                  let toggle = window.toolbar?.items.first(where: {
                      $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar")
                  })
            else { return }
            let isPlaced = toggle.view?.window != nil

            switch phase {
            case .done:
                return
            case .expanded(let sidebar):
                guard isPlaced else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0; sidebar.isCollapsed = true }
                finish()
            case .watching:
                guard !isPlaced,
                      let sidebar = window.contentView.flatMap(Self.splitViewController)?
                          .splitViewItems.first(where: { $0.behavior == .sidebar }),
                      sidebar.isCollapsed
                else { return finish() }
                phase = .expanded(sidebar)
                NSAnimationContext.runAnimationGroup { $0.duration = 0; sidebar.isCollapsed = false }
                DispatchQueue.main.async { [weak self] in self?.check() }
            }
        }

        private func finish() {
            phase = .done
            stopObserving()
        }

        private func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private static func splitViewController(in view: NSView) -> NSSplitViewController? {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController {
                return controller
            }
            return view.subviews.lazy.compactMap(splitViewController).first
        }
    }
}
