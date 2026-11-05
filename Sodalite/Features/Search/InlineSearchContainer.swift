#if os(tvOS)
import SwiftUI
import UIKit

/// tvOS search with the system's inline keyboard on top and the results live underneath, instead of
/// the full-screen keyboard a focused UITextField opens, which hides every hit until the query is
/// committed. A UISearchContainerViewController rather than `.searchable()`, which rebuilt the tab on
/// every switch.
struct InlineSearchContainer<Results: View>: UIViewControllerRepresentable {
    @Binding var text: String
    var placeholder: String
    @ViewBuilder var results: () -> Results
    /// Handed to the results host whole: a UIHostingController starts from an empty environment, and
    /// the cards read the session, the theme and the shell bar out of it.
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> KeyboardEntrySearchContainer {
        let host = UIHostingController(rootView: hostedResults)
        host.view.backgroundColor = .clear

        let search = UISearchController(searchResultsController: host)
        search.searchResultsUpdater = context.coordinator
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = placeholder
        search.searchBar.text = text
        search.searchBar.autocorrectionType = .no
        search.searchBar.autocapitalizationType = .none
        search.view.backgroundColor = .clear

        let container = KeyboardEntrySearchContainer(searchController: search)
        container.view.backgroundColor = .clear
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private var hostedResults: AnyView {
        AnyView(results().environment(\.self, environment))
    }

    final class Coordinator: NSObject, UISearchResultsUpdating {
        var parent: InlineSearchContainer
        var host: UIHostingController<AnyView>?

        init(_ parent: InlineSearchContainer) {
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

    var catchesEntryFromBar = false {
        didSet { entryGuide.isEnabled = catchesEntryFromBar }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        entryGuide.isEnabled = catchesEntryFromBar
        entryGuide.preferredFocusEnvironments = [searchController]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachGuide()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        entryGuide.owningView?.removeLayoutGuide(entryGuide)
        guideConstraints = []
    }

    /// Spans this container, so the guide lies between the bar and everything the page shows.
    private func attachGuide() {
        guard let window = view.window else { return }
        if entryGuide.owningView === window, guideConstraints.allSatisfy(\.isActive) {
            return
        }
        entryGuide.owningView?.removeLayoutGuide(entryGuide)
        window.addLayoutGuide(entryGuide)
        guideConstraints = [
            entryGuide.topAnchor.constraint(equalTo: view.topAnchor),
            entryGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            entryGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            entryGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(guideConstraints)
    }
}
#endif
