import SwiftUI
import WebKit

struct ViewerWebView: NSViewRepresentable {
    typealias RevealDownload = () -> Void

    let url: URL
    let username: String
    let password: String?
    let reloadToken: Int
    let onNavigationStarted: () -> Void
    let onNavigationFinished: (URL?) -> Void
    let onNavigationFailed: (String) -> Void
    let onMediaReady: () -> Void
    let findRequest: FindRequest?
    let onFindResult: (FindResult) -> Void
    let onDownloadStarted: (URL) -> Void
    let onDownloadFinished: (URL, RevealDownload) -> Void
    let onDownloadFailed: (String) -> Void
    let onWebContentProcessTerminated: (() -> Void) -> Void
    let onFullscreenStateChanged: (WKWebView.FullscreenState) -> Void
    let onCapabilitiesChanged: (Capabilities) -> Void

    init(
        url: URL,
        username: String,
        password: String?,
        reloadToken: Int,
        onNavigationStarted: @escaping () -> Void,
        onNavigationFinished: @escaping (URL?) -> Void,
        onNavigationFailed: @escaping (String) -> Void,
        onMediaReady: @escaping () -> Void,
        findRequest: FindRequest? = nil,
        onFindResult: @escaping (FindResult) -> Void = { _ in },
        onDownloadStarted: @escaping (URL) -> Void = { _ in },
        onDownloadFinished: @escaping (URL, RevealDownload) -> Void = { _, _ in },
        onDownloadFailed: @escaping (String) -> Void = { _ in },
        onWebContentProcessTerminated: @escaping (() -> Void) -> Void = { _ in },
        onFullscreenStateChanged: @escaping (WKWebView.FullscreenState) -> Void = { _ in },
        onCapabilitiesChanged: @escaping (Capabilities) -> Void = { _ in }
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.reloadToken = reloadToken
        self.onNavigationStarted = onNavigationStarted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onMediaReady = onMediaReady
        self.findRequest = findRequest
        self.onFindResult = onFindResult
        self.onDownloadStarted = onDownloadStarted
        self.onDownloadFinished = onDownloadFinished
        self.onDownloadFailed = onDownloadFailed
        self.onWebContentProcessTerminated = onWebContentProcessTerminated
        self.onFullscreenStateChanged = onFullscreenStateChanged
        self.onCapabilitiesChanged = onCapabilitiesChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationStarted: onNavigationStarted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMediaReady: onMediaReady,
            onFindResult: onFindResult,
            onDownloadStarted: onDownloadStarted,
            onDownloadFinished: onDownloadFinished,
            onDownloadFailed: onDownloadFailed,
            onWebContentProcessTerminated: onWebContentProcessTerminated,
            onFullscreenStateChanged: onFullscreenStateChanged,
            onCapabilitiesChanged: onCapabilitiesChanged
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let capabilities = Capabilities.current
        configuration.preferences.isElementFullscreenEnabled = capabilities.elementFullscreen
        if let password {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.viewerLoginScript(username: username, password: password),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        context.coordinator.configureMediaReadiness(configuration)
        context.coordinator.configureNativePerformance(configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.loadedURL = url
        context.coordinator.reloadToken = reloadToken
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observeFullscreenState(of: webView)
        context.coordinator.onCapabilitiesChanged(capabilities)
        context.coordinator.performFind(findRequest, in: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    static func viewerLoginScript(username: String, password: String) -> String {
        let payload = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let json = payload.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return #"""
        (() => {
          if (sessionStorage.getItem("ghostlight.viewer.authenticated") === "1") return;
          document.documentElement.style.visibility = "hidden";
          fetch("/api/login", {
            method: "POST",
            credentials: "same-origin",
            headers: { "Accept": "application/json", "Content-Type": "application/json" },
            body: JSON.stringify(\#(json))
          }).then((response) => {
            if (!response.ok) throw new Error(`viewer login failed (${response.status})`);
            sessionStorage.setItem("ghostlight.viewer.authenticated", "1");
            location.replace("/?embed=1");
          }).catch(() => {
            document.documentElement.style.visibility = "visible";
          });
        })();
        """#
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            onNavigationStarted: onNavigationStarted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onMediaReady: onMediaReady,
            onFindResult: onFindResult,
            onDownloadStarted: onDownloadStarted,
            onDownloadFinished: onDownloadFinished,
            onDownloadFailed: onDownloadFailed,
            onWebContentProcessTerminated: onWebContentProcessTerminated,
            onFullscreenStateChanged: onFullscreenStateChanged,
            onCapabilitiesChanged: onCapabilitiesChanged
        )
        context.coordinator.onCapabilitiesChanged(.current)
        context.coordinator.performFind(findRequest, in: webView)
        if context.coordinator.loadedURL != url || context.coordinator.reloadToken != reloadToken {
            context.coordinator.loadedURL = url
            context.coordinator.reloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    struct FindRequest: Equatable {
        let query: String
        let sequence: Int
        var backwards = false
        var caseSensitive = false
        var wraps = true

        var configuration: WKFindConfiguration {
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = caseSensitive
            configuration.wraps = wraps
            return configuration
        }
    }

    struct FindResult: Equatable {
        let request: FindRequest
        let matchFound: Bool
    }

    struct Capabilities: Equatable {
        let downloads: Bool
        let findInPage: Bool
        let nativeContextMenus: Bool
        let elementFullscreen: Bool
        let pageAudioMute: Bool
        let pointerLockControl: Bool
        let cursorControl: Bool

        static let macOS14 = Capabilities(
            downloads: true,
            findInPage: true,
            nativeContextMenus: true,
            elementFullscreen: true,
            pageAudioMute: false,
            pointerLockControl: false,
            cursorControl: false
        )

        static var current: Capabilities {
            let downloads: Bool
            if #available(macOS 11.3, *) {
                downloads = true
            } else {
                downloads = false
            }

            let findInPage: Bool
            if #available(macOS 11.0, *) {
                findInPage = true
            } else {
                findInPage = false
            }

            let elementFullscreen: Bool
            if #available(macOS 12.3, *) {
                elementFullscreen = true
            } else {
                elementFullscreen = false
            }

            return Capabilities(
                downloads: downloads,
                findInPage: findInPage,
                nativeContextMenus: true,
                elementFullscreen: elementFullscreen,
                pageAudioMute: false,
                pointerLockControl: false,
                cursorControl: false
            )
        }
    }

    enum PermissionPolicy {
        static let mediaCaptureDecision = WKPermissionDecision.deny
    }

    enum DownloadDestination {
        static func downloadsDirectory(fileManager: FileManager = .default) -> URL? {
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }

        static func safeFilename(_ suggestedFilename: String) -> String {
            let withoutControls = String(
                suggestedFilename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            )
            let component = withoutControls
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let component, !component.isEmpty, component != ".", component != ".." else {
                return "download"
            }
            return component
        }

        static func destination(
            in directory: URL,
            suggestedFilename: String,
            fileExists: (URL) -> Bool
        ) -> URL {
            let filename = safeFilename(suggestedFilename)
            let initial = directory.appendingPathComponent(filename, isDirectory: false)
            guard fileExists(initial) else {
                return initial
            }

            let path = filename as NSString
            let pathExtension = path.pathExtension
            let stem = path.deletingPathExtension.isEmpty ? "download" : path.deletingPathExtension
            var suffix = 1
            while true {
                let candidateName = pathExtension.isEmpty
                    ? "\(stem)-\(suffix)"
                    : "\(stem)-\(suffix).\(pathExtension)"
                let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
                if !fileExists(candidate) {
                    return candidate
                }
                suffix += 1
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var reloadToken = 0
        private var activeNavigation: WKNavigation?
        var onNavigationStarted: () -> Void
        var onNavigationFinished: (URL?) -> Void
        var onNavigationFailed: (String) -> Void
        var onMediaReady: () -> Void
        var onFindResult: (FindResult) -> Void
        var onDownloadStarted: (URL) -> Void
        var onDownloadFinished: (URL, RevealDownload) -> Void
        var onDownloadFailed: (String) -> Void
        var onWebContentProcessTerminated: (() -> Void) -> Void
        var onFullscreenStateChanged: (WKWebView.FullscreenState) -> Void
        var onCapabilitiesChanged: (Capabilities) -> Void
        private var nativePerformanceRecorder: NativePerformanceRecorder?
        private var findSequence: Int?
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        private var fullscreenObservation: NSKeyValueObservation?

        init(
            onNavigationStarted: @escaping () -> Void,
            onNavigationFinished: @escaping (URL?) -> Void,
            onNavigationFailed: @escaping (String) -> Void,
            onMediaReady: @escaping () -> Void,
            onFindResult: @escaping (FindResult) -> Void,
            onDownloadStarted: @escaping (URL) -> Void,
            onDownloadFinished: @escaping (URL, RevealDownload) -> Void,
            onDownloadFailed: @escaping (String) -> Void,
            onWebContentProcessTerminated: @escaping (() -> Void) -> Void,
            onFullscreenStateChanged: @escaping (WKWebView.FullscreenState) -> Void,
            onCapabilitiesChanged: @escaping (Capabilities) -> Void
        ) {
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMediaReady = onMediaReady
            self.onFindResult = onFindResult
            self.onDownloadStarted = onDownloadStarted
            self.onDownloadFinished = onDownloadFinished
            self.onDownloadFailed = onDownloadFailed
            self.onWebContentProcessTerminated = onWebContentProcessTerminated
            self.onFullscreenStateChanged = onFullscreenStateChanged
            self.onCapabilitiesChanged = onCapabilitiesChanged
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
            onMediaReady: @escaping () -> Void,
            onFindResult: @escaping (FindResult) -> Void,
            onDownloadStarted: @escaping (URL) -> Void,
            onDownloadFinished: @escaping (URL, RevealDownload) -> Void,
            onDownloadFailed: @escaping (String) -> Void,
            onWebContentProcessTerminated: @escaping (() -> Void) -> Void,
            onFullscreenStateChanged: @escaping (WKWebView.FullscreenState) -> Void,
            onCapabilitiesChanged: @escaping (Capabilities) -> Void
        ) {
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onNavigationFailed = onNavigationFailed
            self.onMediaReady = onMediaReady
            self.onFindResult = onFindResult
            self.onDownloadStarted = onDownloadStarted
            self.onDownloadFinished = onDownloadFinished
            self.onDownloadFailed = onDownloadFailed
            self.onWebContentProcessTerminated = onWebContentProcessTerminated
            self.onFullscreenStateChanged = onFullscreenStateChanged
            self.onCapabilitiesChanged = onCapabilitiesChanged
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MediaReadinessSignal.messageHandlerName,
                  (message.body as? String) == "mediaReady" else { return }
            onMediaReady()
        }

        func observeFullscreenState(of webView: WKWebView) {
            fullscreenObservation = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] webView, change in
                self?.onFullscreenStateChanged(change.newValue ?? webView.fullscreenState)
            }
        }

        func performFind(_ request: FindRequest?, in webView: WKWebView) {
            guard let request, findSequence != request.sequence else {
                return
            }
            findSequence = request.sequence
            guard !request.query.isEmpty else {
                onFindResult(FindResult(request: request, matchFound: false))
                return
            }
            webView.find(request.query, configuration: request.configuration) { [weak self] result in
                self?.onFindResult(FindResult(request: request, matchFound: result.matchFound))
            }
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
            guard Self.isSameOrigin(url, as: origin) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
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
            guard Self.isSameOrigin(url, as: origin) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            guard let directory = DownloadDestination.downloadsDirectory() else {
                onDownloadFailed("The Downloads folder is unavailable.")
                completionHandler(nil)
                return
            }

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = DownloadDestination.destination(
                    in: directory,
                    suggestedFilename: suggestedFilename,
                    fileExists: { [self] candidate in
                        FileManager.default.fileExists(atPath: candidate.path)
                            || downloadDestinations.values.contains(candidate)
                    }
                )
                downloadDestinations[ObjectIdentifier(download)] = destination
                onDownloadStarted(destination)
                completionHandler(destination)
            } catch {
                onDownloadFailed(error.localizedDescription)
                completionHandler(nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else {
                return
            }
            onDownloadFinished(destination) {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            onDownloadFailed(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(PermissionPolicy.mediaCaptureDecision)
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
            onWebContentProcessTerminated { [weak webView] in
                webView?.reload()
            }
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
                && effectivePort(for: url) == effectivePort(for: origin)
        }

        private static func effectivePort(for url: URL) -> Int? {
            if let port = url.port {
                return port
            }
            return switch url.scheme?.lowercased() {
            case "http": 80
            case "https": 443
            default: nil
            }
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
