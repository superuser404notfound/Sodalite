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

    func makeUIViewController(context: Context) -> UISearchContainerViewController {
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

        let container = UISearchContainerViewController(searchController: search)
        container.view.backgroundColor = .clear
        context.coordinator.host = host
        return container
    }

    func updateUIViewController(_ container: UISearchContainerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = hostedResults
        let bar = container.searchController.searchBar
        if bar.text != text {
            bar.text = text
        }
        bar.placeholder = placeholder
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
#endif
