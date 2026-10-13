import SwiftUI

extension View {
    /// Presents a full-screen detail as a cover (over the tab bar) instead of a NavigationStack push. The cover covers the tab bar WITHOUT ever removing it, so tvOS never re-templates the bar's icons gray on return (the tvOS 26 system bug that a `.toolbar(.hidden)` push triggers). Each cover hosts its own NavigationStack so the detail's deeper navigation (detail -> detail, -> person) still pushes normally.
    ///
    /// A static themed background sits behind the stack. Detail views draw their own full-screen backdrop over it, while backdrop-less pages show the selected theme.
    ///
    /// On the Mac and on iOS it is a push onto the enclosing NavigationStack instead. A window has no
    /// tab bar to keep on screen, and a sheet there is a modal panel floating over the window, which
    /// is the wrong shape for browsing: the toolbar's back button, the back gesture and Cmd-[ all
    /// expect a stack. iOS does not have the gray-icon bug either, and a cover there takes away the
    /// edge-swipe back that every other app's detail page answers to.
    @ViewBuilder
    func detailCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS) || os(iOS)
        modifier(DetailPushPresenter(item: item, destination: content))
        #else
        detailCoverModal(item: item, content: content)
        #endif
    }

    /// Always a cover (a sheet on the Mac), for a presenter that sits above every NavigationStack and
    /// so has nothing to push onto: the router's deep links.
    func detailCoverModal<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(DetailCoverPresenter(item: item, coverContent: content))
    }
}

#if os(macOS) || os(iOS)
/// `navigationDestination(item:)` wants a Hashable item and these are only Identifiable, so the push
/// is driven by presence instead. The pushed value is held here rather than read back from the
/// binding: a pop clears the binding before the page has finished sliding out, and a destination
/// read from it would blank mid-animation.
private struct DetailPushPresenter<Item: Identifiable, Destination: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let destination: (Item) -> Destination

    @State private var pushed: Item?

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: Binding(
                get: { item != nil },
                set: { if !$0 { item = nil } }
            )) {
                if let value = item ?? pushed {
                    destination(value)
                        .themedStaticBackground()
                        .detailCoverPush()
                }
            }
            .onChange(of: item?.id, initial: true) { _, _ in
                if let item { pushed = item }
            }
    }
}
#endif

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
            .fullScreenCoverCompat(item: $item) { value in
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
        #if !os(tvOS)
        // tvOS dismisses via the Menu button; everywhere else needs a close control (a cover
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
