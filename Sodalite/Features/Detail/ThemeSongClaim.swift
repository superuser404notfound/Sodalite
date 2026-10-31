import SwiftUI

/// Sodalite#219: holds the page's claim on the theme song for as long as the page is on screen.
struct ThemeSongClaim: ViewModifier {
    @Environment(\.dependencies) private var dependencies
    let itemID: String?
    let session: ServerSession
    @State private var claim: ThemeSongPlayer.Claim?

    func body(content: Content) -> some View {
        content
            .onAppear { take() }
            .onDisappear { drop() }
            .onChange(of: itemID) {
                drop()
                take()
            }
    }

    private func take() {
        guard claim == nil, let itemID else { return }
        let client = session.client
        let userID = session.userID
        claim = dependencies.themeSongPlayer.claim(key: "\(session.server?.id ?? ""):\(itemID)") {
            try await JellyfinThemeSongService(client: client).themeSong(userID: userID, itemID: itemID)
        }
    }

    private func drop() {
        guard let claim else { return }
        dependencies.themeSongPlayer.release(claim)
        self.claim = nil
    }
}
