import SwiftUI

extension View {
    /// Presents a full-screen detail as a cover (over the tab bar) instead of a NavigationStack push. The cover covers the tab bar WITHOUT ever removing it, so tvOS never re-templates the bar's icons gray on return (the tvOS 26 system bug that a `.toolbar(.hidden)` push triggers). Each cover hosts its own NavigationStack so the detail's deeper navigation (detail -> detail, -> person) still pushes normally.
    ///
    /// A static themed background sits behind the stack. Detail views draw their own full-screen backdrop over it, while backdrop-less pages show the selected theme.
    func detailCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(DetailCoverPresenter(item: item, coverContent: content))
    }
}

/// Presents one detail cover, and owns its claim on the fullscreen music player.
///
/// The claim is released from the item binding here rather than from the cover's own lifecycle: a
/// cover cannot tell being closed from being covered by the player it just put up, and this side
/// can (Sodalite#140, see NowPlayingPresentation).
private struct DetailCoverPresenter<Item: Identifiable, CoverContent: View>: ViewModifier {
    @Environment(\.dependencies) private var dependencies
    @Binding var item: Item?
    @ViewBuilder let coverContent: (Item) -> CoverContent

    @State private var nowPlayingHost = NowPlayingPresentation.HostToken()

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item) { value in
                DetailCoverHost(dismiss: { item = nil }) {
                    coverContent(value)
                }
                .nowPlayingCoverHost(nowPlayingHost)
            }
            .onChange(of: item == nil) { _, coverIsGone in
                if coverIsGone {
                    dependencies.musicPlaybackCoordinator.nowPlayingPresentation.popHost(nowPlayingHost)
                }
            }
    }
}

/// One cover's NavigationStack plus the close button that belongs to it.
///
/// Split out of the modifier because the button's visibility is state: it stands down while a page is
/// pushed above the root, where the stack's own back arrow already means "one step back" and the X
/// would silently mean "leave the whole cover" (Sodalite discussion #98, point 5).
private struct DetailCoverHost<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    /// Owned here, one per presented cover, so a second cover opened over the first cannot inherit
    /// the first's pushed pages.
    @State private var stack = DetailCoverStack()

    var body: some View {
        NavigationStack {
            content()
                #if os(iOS)
                .themedStaticBackground(pausesMotion: false)
                #endif
        }
        .environment(\.detailCoverStack, stack)
        #if os(iOS)
        .pausesAppBackgroundMotion()
        #else
        .themedStaticBackground()
        #endif
        #if os(iOS)
        // tvOS dismisses via the Menu button; iOS needs a touch close (a fullScreenCover
        // has no swipe-to-dismiss), else detail / program-info covers are a dead end.
        // Top-trailing glass circle (matching the settings gear) so it never sits on the
        // leading page title.
        .overlay(alignment: .topTrailing) {
            GlassCloseButton(action: dismiss)
            .padding(.trailing, 16)
            .padding(.top, 8)
            // Hidden, not removed: the stack's own back arrow is the way out of a pushed page,
            // and two buttons that mean different amounts of "back" is the confusion this ends.
            .opacity(stack.isPushed ? 0 : 1)
            .allowsHitTesting(!stack.isPushed)
            .animation(.easeInOut(duration: 0.2), value: stack.isPushed)
        }
        #endif
    }
}
