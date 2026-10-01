#if os(tvOS)
import SwiftUI
import UIKit

/// The multiview grid's modal. Holds its coordinator, so the session lives exactly as long as the grid is presented.
final class MultiviewHostController: UIHostingController<MultiviewView> {
    let coordinator: LiveMultiviewCoordinator

    init(coordinator: LiveMultiviewCoordinator) {
        self.coordinator = coordinator
        super.init(rootView: MultiviewView(coordinator: coordinator))
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        coordinator.gridDidAppear()
        PlayerModalPresence.notifyDidChange()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        PlayerModalPresence.notifyDidChange()
    }
}
#endif
