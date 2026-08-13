import SwiftUI
import WebKit

struct ViewerWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    let onNavigationStarted: () -> Void
    let onNavigationFinished: (URL?) -> Void
    let onNavigationFailed: (String) -> Void
    let onMediaReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationStarted: onNavigationStarted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMediaReady: onMediaReady
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        context.coordinator.configureMediaReadiness(configuration)
        context.coordinator.configureNativePerformance(configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
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
            onNavigationFailed: onNavigationFailed,
            onMediaReady: onMediaReady
        )
        if context.coordinator.loadedURL != url || context.coordinator.reloadToken != reloadToken {
            context.coordinator.loadedURL = url
            context.coordinator.reloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var reloadToken = 0
        private var activeNavigation: WKNavigation?
        var onNavigationStarted: () -> Void
        var onNavigationFinished: (URL?) -> Void
        var onNavigationFailed: (String) -> Void
        var onMediaReady: () -> Void
        private var nativePerformanceRecorder: NativePerformanceRecorder?

        init(
            onNavigationStarted: @escaping () -> Void,
            onNavigationFinished: @escaping (URL?) -> Void,
            onNavigationFailed: @escaping (String) -> Void,
            onMediaReady: @escaping () -> Void
        ) {
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMediaReady = onMediaReady
        }

        func configureMediaReadiness(_ configuration: WKWebViewConfiguration) {
            configuration.userContentController.add(self, name: MediaReadinessSignal.messageHandlerName)
            configuration.userContentController.addUserScript(
                WKUserScript(source: MediaReadinessSignal.userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        func configureNativePerformance(_ webViewConfiguration: WKWebViewConfiguration) {
            guard let performance = NativePerformanceConfiguration.fromEnvironment() else {
                return
            }
            let recorder = NativePerformanceRecorder(configuration: performance)
            nativePerformanceRecorder = recorder
            webViewConfiguration.userContentController.add(
                recorder,
                name: NativePerformanceConfiguration.messageHandlerName
            )
            webViewConfiguration.userContentController.addUserScript(
                WKUserScript(
                    source: performance.userScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        func update(
            onNavigationStarted: @escaping () -> Void,
            onNavigationFinished: @escaping (URL?) -> Void,
            onNavigationFailed: @escaping (String) -> Void,
            onMediaReady: @escaping () -> Void
        ) {
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMediaReady = onMediaReady
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MediaReadinessSignal.messageHandlerName,
                  (message.body as? String) == "mediaReady" else { return }
            onMediaReady()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only the main frame can navigate the webview away from the viewer.
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  let url = navigationAction.request.url,
                  let origin = loadedURL else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(Self.isSameOrigin(url, as: origin) ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // Server-side redirects do not produce a navigation action, so the
            // response URL must be checked against the viewer origin as well.
            guard navigationResponse.isForMainFrame,
                  let url = navigationResponse.response.url,
                  let origin = loadedURL else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(Self.isSameOrigin(url, as: origin) ? .allow : .cancel)
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

        static func isSameOrigin(_ url: URL, as origin: URL) -> Bool {
            url.scheme?.lowercased() == origin.scheme?.lowercased()
                && url.host?.lowercased() == origin.host?.lowercased()
                && url.port == origin.port
        }

        static func shouldReportNavigationError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
        }
    }
}

enum MediaReadinessSignal {
    static let messageHandlerName = "ghostlightMedia"

    static let userScript = #"""
    (() => {
      if (window.__ghostlightMediaSignalInstalled) return;
      window.__ghostlightMediaSignalInstalled = true;
      const peers = new Set();
      let sent = false;
      const NativePeerConnection = window.RTCPeerConnection;
      if (NativePeerConnection) {
        const TrackedPeerConnection = function (...args) {
          const peer = new NativePeerConnection(...args);
          peers.add(peer);
          return peer;
        };
        TrackedPeerConnection.prototype = NativePeerConnection.prototype;
        Object.setPrototypeOf(TrackedPeerConnection, NativePeerConnection);
        window.RTCPeerConnection = TrackedPeerConnection;
      }
      const connected = () => [...peers].some((peer) => peer.connectionState === "connected");
      const signal = (video) => {
        if (sent || !connected() || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || video.videoWidth < 1) return;
        sent = true;
        window.webkit.messageHandlers.ghostlightMedia.postMessage("mediaReady");
      };
      const observe = (video) => {
        if (video.__ghostlightMediaObserved) return;
        video.__ghostlightMediaObserved = true;
        if ("requestVideoFrameCallback" in video) {
          const frame = () => { signal(video); if (!sent) video.requestVideoFrameCallback(frame); };
          video.requestVideoFrameCallback(frame);
        }
      };
      const scan = () => document.querySelectorAll("video").forEach(observe);
      new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
      const timer = setInterval(() => { scan(); if (sent) clearInterval(timer); }, 250);
      window.addEventListener("pagehide", () => clearInterval(timer), { once: true });
    })();
    """#
}
