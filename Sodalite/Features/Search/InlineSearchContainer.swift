#if os(tvOS)
import SwiftUI
import UIKit

/// tvOS search with the system's inline keyboard on top and the results live underneath, instead of
/// the full-screen keyboard a focused UITextField opens, which hides every hit until the query is
/// committed. A UISearchContainerViewController rather than `.searchable()`, which rebuilt the tab on
/// every switch.
///
/// The controller runs the full height of the screen and gets the page's top and bottom room as
/// safe area instead. Before focus moves, UIKit checks whether the view about to take it lies outside
/// the search view, and scrolls the keyboard off towards it if so. The top bar's focus view is the
/// whole SwiftUI host, so from a search view that started under the bar every press up to the bar
/// counted as leaving upwards: the field slid behind the bar and the keys came to rest across it
/// (measured in the tvOS 27 simulator, field at y=-22, keys at y=82, the bar at 46 to 114).
struct InlineSearchContainer<Results: View>: View {
    @Binding var text: String
    var placeholder: String
    @ViewBuilder var results: () -> Results

    /// The room the page gives the search, in window space.
    @State private var pageFrame: CGRect = .zero

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pageFrame = $0 }
            .overlay {
                InlineSearchRepresentable(
                    text: $text,
                    placeholder: placeholder,
                    pageFrame: pageFrame,
                    results: results
                )
                .ignoresSafeArea(edges: .vertical)
            }
    }
}

private struct InlineSearchRepresentable<Results: View>: UIViewControllerRepresentable {
    @Binding var text: String
    var placeholder: String
    var pageFrame: CGRect
    var results: () -> Results
    /// Handed to the results host whole: a UIHostingController starts from an empty environment, and
    /// the cards read the session, the theme and the shell bar out of it.
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> KeyboardEntrySearchContainer {
        let host = UIHostingController(rootView: hostedResults)
        host.view.backgroundColor = .clear

        let search = LoggingSearchController(searchResultsController: host)
        search.searchResultsUpdater = context.coordinator
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = placeholder
        search.searchBar.text = text
        search.searchBar.autocorrectionType = .no
        search.searchBar.autocapitalizationType = .none
        search.view.backgroundColor = .clear

        let container = KeyboardEntrySearchContainer(searchController: search)
        container.view.backgroundColor = .clear
        container.pageFrame = pageFrame
        context.coordinator.host = host
        return container
    }

    func updateUIViewController(_ container: KeyboardEntrySearchContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = hostedResults
        let bar = container.searchController.searchBar
        if bar.text != text {
            bar.text = text
        }
        bar.placeholder = placeholder
        container.catchesEntryFromBar = environment.shellBarHoldsFocus
        container.pageFrame = pageFrame
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private var hostedResults: AnyView {
        AnyView(results().environment(\.self, environment))
    }

    final class Coordinator: NSObject, UISearchResultsUpdating {
        var parent: InlineSearchRepresentable
        var host: UIHostingController<AnyView>?

        init(_ parent: InlineSearchRepresentable) {
            self.parent = parent
        }

        func updateSearchResults(for searchController: UISearchController) {
            let query = searchController.searchBar.text ?? ""
            if parent.text != query {
                parent.text = query
            }
        }
    }
}

/// Notes every focus change that touches the search, and every move that fails while focus is in
/// it, in the diagnostic log. Some viewers report focus stuck on the first key with nothing moving
/// it, on remotes we cannot reproduce with (the simulator only presses, it cannot swipe), so their
/// log has to show whether a move arrives at all, fails, or is pulled back.
final class LoggingSearchController: UISearchController {
    private var failureObserver: NSObjectProtocol?
    private var failureLine: String?
    private var failureRun = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        failureObserver = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.movementDidFailNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            MainActor.assumeIsolated { self?.noteFailure(context) }
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let from = place(of: context.previouslyFocusedItem)
        let to = place(of: context.nextFocusedItem)
        guard from != "outside" || to != "outside" else { return }
        failureLine = nil
        LogTap.shared.note("[Search] focus \(from) -> \(to) \(heading(context.focusHeading)) \(fieldState)")
    }

    /// The linear keyboard moves between its keys by itself, so every press or swipe along the row
    /// reaches the focus system as a failed move. A run of the same one is noted at its first, then
    /// at every tenth, so a swipe does not push the rest of the log out of its 300 lines.
    private func noteFailure(_ context: UIFocusUpdateContext?) {
        guard let context, viewIfLoaded?.window != nil else { return }
        let from = place(of: context.previouslyFocusedItem)
        guard from != "outside" else { return }
        let line = "[Search] move failed from \(from) \(heading(context.focusHeading)) \(fieldState)"
        failureRun = line == failureLine ? failureRun + 1 : 1
        failureLine = line
        guard failureRun == 1 || failureRun.isMultiple(of: 10) else { return }
        LogTap.shared.note(failureRun == 1 ? line : "\(line) (x\(failureRun))")
    }

    private var fieldState: String {
        "field=\(searchBar.isFirstResponder ? "editing" : "idle") query=\(searchBar.text?.count ?? 0)ch"
    }

    private func place(of item: UIFocusItem?) -> String {
        guard let item else { return "none" }
        guard let itemView = item as? UIView ?? (item as? UIFocusEnvironment).flatMap(Self.view(of:)),
              let root = viewIfLoaded, itemView.isDescendant(of: root) else {
            return "outside"
        }
        if let results = searchResultsController?.viewIfLoaded, itemView.isDescendant(of: results) {
            return "results"
        }
        return itemView.isDescendant(of: searchBar) ? "field" : "keys"
    }

    private static func view(of environment: UIFocusEnvironment) -> UIView? {
        var current: UIFocusEnvironment? = environment
        while let env = current {
            if let view = env as? UIView { return view }
            if let controller = env as? UIViewController { return controller.viewIfLoaded }
            current = env.parentFocusEnvironment
        }
        return nil
    }

    private func heading(_ heading: UIFocusHeading) -> String {
        let names: [(UIFocusHeading, String)] = [
            (.up, "up"), (.down, "down"), (.left, "left"), (.right, "right"),
            (.next, "next"), (.previous, "previous"),
        ]
        let parts = names.filter { heading.contains($0.0) }.map(\.1)
        return "heading=" + (parts.isEmpty ? "none" : parts.joined(separator: "+"))
    }

    isolated deinit {
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
    }
}

/// A press down from the top bar lands on the keyboard. That move is geometric, and the grid keyboard
/// fills only the leading third, so from the Search tab it met nothing but the empty results area and
/// focus stayed on the tab (Sodalite#227).
///
/// The guide belongs to the window: inside the representable SwiftUI never offers it to the focus
/// engine (measured in the tvOS 27 simulator, the move failed with the guide in place). At window
/// level it would also catch moves meant for other pages or for a cover above this one, so it is on
/// only while the bar holds focus over this page, the one moment a press down has to come here.
final class KeyboardEntrySearchContainer: UISearchContainerViewController {
    private let entryGuide = UIFocusGuide()
    private var guideConstraints: [NSLayoutConstraint] = []
    private var guideTop: NSLayoutConstraint?

    var catchesEntryFromBar = false {
        didSet { entryGuide.isEnabled = catchesEntryFromBar }
    }

    /// The page's room for the search, in window space, which the full-height search takes as safe
    /// area (see `InlineSearchContainer`). The search controller is presented, so its safe area comes
    /// from the window and not from this container. Only the window's own part is subtracted, never
    /// the view's current insets: early in a presentation those read zero, and subtracting them fed
    /// each pass back into the next (157, 314, 471), and UIKit pinned the keys at the 471.
    var pageFrame: CGRect = .zero {
        didSet { applyPageInsets() }
    }

    private func applyPageInsets() {
        guideTop?.constant = pageTop
        let search = searchController
        guard let window = view.window, search.isViewLoaded, !pageFrame.isEmpty else { return }
        let frame = search.view.convert(search.view.bounds, to: window)
        let windowTop = max(0, window.safeAreaInsets.top - frame.minY)
        let windowBottom = max(0, window.safeAreaInsets.bottom - (window.bounds.maxY - frame.maxY))
        let top = max(0, pageFrame.minY - frame.minY - windowTop)
        let bottom = max(0, frame.maxY - pageFrame.maxY - windowBottom)
        let current = search.additionalSafeAreaInsets
        guard current.top != top || current.bottom != bottom else { return }
        search.additionalSafeAreaInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }

    /// Where the page begins below this view's top edge, the bar's room under the top bar.
    private var pageTop: CGFloat {
        guard let window = view.window, !pageFrame.isEmpty else { return 0 }
        return max(0, pageFrame.minY - view.convert(view.bounds, to: window).minY)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        entryGuide.isEnabled = catchesEntryFromBar
        entryGuide.preferredFocusEnvironments = [searchController]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPageInsets()
        attachGuide()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        entryGuide.owningView?.removeLayoutGuide(entryGuide)
        guideConstraints = []
        guideTop = nil
    }

    /// Spans the page below the bar, so the guide lies between the bar and everything the page shows.
    private func attachGuide() {
        guard let window = view.window else { return }
        if entryGuide.owningView === window, guideConstraints.allSatisfy(\.isActive) {
            return
        }
        entryGuide.owningView?.removeLayoutGuide(entryGuide)
        window.addLayoutGuide(entryGuide)
        let top = entryGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: pageTop)
        guideTop = top
        guideConstraints = [
            top,
            entryGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            entryGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            entryGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(guideConstraints)
    }
}
#endif
