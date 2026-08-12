import SwiftUI
import WebKit

struct ViewerWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    let onNavigationStarted: () -> Void
    let onNavigationFinished: (URL?) -> Void
    let onNavigationFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationStarted: onNavigationStarted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        context.coordinator.loadedURL = url
        context.coordinator.reloadToken = reloadToken
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            onNavigationStarted: onNavigationStarted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed
        )
        if context.coordinator.loadedURL != url || context.coordinator.reloadToken != reloadToken {
            context.coordinator.loadedURL = url
            context.coordinator.reloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var reloadToken = 0
        private var activeNavigation: WKNavigation?
        var onNavigationStarted: () -> Void
        var onNavigationFinished: (URL?) -> Void
        var onNavigationFailed: (String) -> Void

        init(
            onNavigationStarted: @escaping () -> Void,
            onNavigationFinished: @escaping (URL?) -> Void,
            onNavigationFailed: @escaping (String) -> Void
        ) {
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
        }

        func update(
            onNavigationStarted: @escaping () -> Void,
            onNavigationFinished: @escaping (URL?) -> Void,
            onNavigationFailed: @escaping (String) -> Void
        ) {
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            activeNavigation = navigation
            onNavigationStarted()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive(navigation) else {
                return
            }
            activeNavigation = nil
            onNavigationFinished(webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishNavigation(navigation, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finishNavigation(navigation, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            activeNavigation = nil
            onNavigationFailed("The viewer process stopped unexpectedly.")
        }

        private func finishNavigation(_ navigation: WKNavigation?, error: Error) {
            guard isActive(navigation) else {
                return
            }
            activeNavigation = nil
            guard Self.shouldReportNavigationError(error) else {
                return
            }
            onNavigationFailed(error.localizedDescription)
        }

        private func isActive(_ navigation: WKNavigation?) -> Bool {
            guard let navigation, let activeNavigation else {
                return false
            }
            return navigation === activeNavigation
        }

        static func shouldReportNavigationError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
        }
    }
}
