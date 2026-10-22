#if !os(tvOS)
import SwiftUI
import WebKit

/// Plays a remote trailer through the official IFrame Player in a web view, the one way YouTube's
/// terms allow: the player is YouTube's, with its own controls and nothing drawn over it. tvOS has
/// no WebKit, so this does not exist there and the Trailer button stays local-only.
///
/// When the embed refuses (the owner disabled embedding, the video is gone, or no network), the
/// sheet says so and offers the watch page, which opens the YouTube app or the browser.
struct YouTubeTrailerSheet: View {
    let trailer: YouTubeTrailer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if failed {
                    ContentUnavailableView {
                        Label("detail.trailer.unavailable", systemImage: "play.slash")
                    } description: {
                        Text("detail.trailer.unavailable.message")
                    } actions: {
                        Button("detail.trailer.openInYouTube") { openURL(trailer.watchURL) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    YouTubeEmbedView(
                        videoID: trailer.videoID,
                        onFailure: { failed = true },
                        openExternally: { openURL($0) }
                    )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(trailer.title ?? String(localized: "detail.trailer"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("detail.trailer.openInYouTube", systemImage: "arrow.up.forward.app") {
                        openURL(trailer.watchURL)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }
}

/// The web view itself. The page is a local string, loaded against `https://<bundle id>` as its
/// base URL: YouTube's Required Minimum Functionality names that as the Referer a WebView app must
/// send, and without one the player answers error 153.
private struct YouTubeEmbedView {
    let videoID: String
    let onFailure: @MainActor () -> Void
    let openExternally: @MainActor (URL) -> Void

    static let origin: String = "https://\((Bundle.main.bundleIdentifier ?? "de.superuser404.Sodalite").lowercased())"

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, openExternally: openExternally)
    }

    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        #else
        webView.underPageBackgroundColor = .black
        #endif
        webView.loadHTMLString(Self.page(videoID: videoID), baseURL: URL(string: Self.origin))
        return webView
    }

    static func dismantle(_ webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.stopLoading()
        // Without this the audio of a playing trailer outlives the sheet until the view is freed.
        webView.loadHTMLString("", baseURL: nil)
    }

    /// `videoID` is validated to the 11-character id alphabet before it gets here, so the
    /// interpolation cannot break out of the string literal.
    static func page(videoID: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{width:100%;height:100%}</style>
        </head><body>
        <div id="player"></div>
        <script>
        function report(code){window.webkit.messageHandlers.\(Coordinator.messageName).postMessage(String(code))}
        function onYouTubeIframeAPIReady(){
          new YT.Player('player',{
            videoId:'\(videoID)',
            playerVars:{playsinline:1,autoplay:1,rel:0,origin:'\(origin)'},
            events:{onError:function(e){report(e.data)}}
          })
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="report('api')"></script>
        </body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        static let messageName = "trailer"
        let onFailure: @MainActor () -> Void
        let openExternally: @MainActor (URL) -> Void

        init(onFailure: @escaping @MainActor () -> Void, openExternally: @escaping @MainActor (URL) -> Void) {
            self.onFailure = onFailure
            self.openExternally = openExternally
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            LogTap.shared.note("[Trailer] embed refused: \(message.body)")
            onFailure()
        }

        /// The player's own links (the YouTube logo, the title, "Watch on YouTube") leave the embed;
        /// they belong in the YouTube app or the browser, not in this sheet.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let isTopFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if isTopFrame, navigationAction.navigationType == .linkActivated
                || navigationAction.targetFrame == nil,
               let url = navigationAction.request.url {
                openExternally(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LogTap.shared.note("[Trailer] embed page failed: \(error.localizedDescription)")
            onFailure()
        }
    }
}

#if os(iOS)
extension YouTubeEmbedView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
}
#else
extension YouTubeEmbedView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) {}
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
}
#endif
#endif
