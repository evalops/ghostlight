import SwiftUI
import WebKit

struct ViewerWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        context.coordinator.loadedURL = url
        context.coordinator.reloadToken = reloadToken
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }

        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            webView.reload()
        }
    }

    final class Coordinator {
        var loadedURL: URL?
        var reloadToken = 0
    }
}
