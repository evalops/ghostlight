import SwiftUI
import WebKit

struct ViewerWebView: NSViewRepresentable {
    typealias RevealDownload = () -> Void
    typealias AuthorizePeripheral = (PeripheralCapability, URL) async -> Bool

    let url: URL
    let credential: ViewerCredential?
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
    let onWebContentProcessTerminated: (@escaping () -> Void) -> Void
    let onFullscreenStateChanged: (WKWebView.FullscreenState) -> Void
    let onCapabilitiesChanged: (Capabilities) -> Void
    let command: Command?
    let onAudioStateChanged: (Bool) -> Void
    let onStreamTelemetry: (StreamTelemetry) -> Void
    let authorizePeripheral: AuthorizePeripheral

    init(
        url: URL,
        credential: ViewerCredential?,
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
        onWebContentProcessTerminated: @escaping (@escaping () -> Void) -> Void = { _ in },
        onFullscreenStateChanged: @escaping (WKWebView.FullscreenState) -> Void = { _ in },
        onCapabilitiesChanged: @escaping (Capabilities) -> Void = { _ in },
        command: Command? = nil,
        onAudioStateChanged: @escaping (Bool) -> Void = { _ in },
        onStreamTelemetry: @escaping (StreamTelemetry) -> Void = { _ in },
        authorizePeripheral: @escaping AuthorizePeripheral = { _, _ in false }
    ) {
        self.url = url
        self.credential = credential
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
        self.command = command
        self.onAudioStateChanged = onAudioStateChanged
        self.onStreamTelemetry = onStreamTelemetry
        self.authorizePeripheral = authorizePeripheral
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
            onCapabilitiesChanged: onCapabilitiesChanged,
            onAudioStateChanged: onAudioStateChanged,
            onStreamTelemetry: onStreamTelemetry,
            authorizePeripheral: authorizePeripheral
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let capabilities = Capabilities.current
        configuration.preferences.isElementFullscreenEnabled = capabilities.elementFullscreen
        context.coordinator.configureMediaReadiness(configuration)
        context.coordinator.configureEmbeddedExperience(configuration)
        context.coordinator.configureNativePerformance(configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let embeddedURL = Self.embeddedViewerURL(url)
        context.coordinator.loadedURL = embeddedURL
        context.coordinator.reloadToken = reloadToken
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observeFullscreenState(of: webView)
        context.coordinator.onCapabilitiesChanged(capabilities)
        context.coordinator.performFind(findRequest, in: webView)
        context.coordinator.perform(command, in: webView)
        Self.load(embeddedURL, credential: credential, in: webView)
        return webView
    }

    static func embeddedViewerURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "embed" }
        items.append(URLQueryItem(name: "embed", value: "1"))
        components.queryItems = items
        return components.url ?? url
    }

    static func load(_ url: URL, credential: ViewerCredential?, in webView: WKWebView) {
        guard let credential else {
            webView.load(URLRequest(url: url))
            return
        }
        guard credential.type == "cookie", let cookie = viewerCookie(credential, for: url) else {
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            DispatchQueue.main.async { webView.load(URLRequest(url: url)) }
        }
    }

    static func viewerCookie(_ credential: ViewerCredential, for url: URL) -> HTTPCookie? {
        guard credential.type == "cookie",
              let name = credential.name,
              !name.isEmpty,
              !credential.value.isEmpty,
              let host = url.host,
              credential.expiresAt > Date() else {
            return nil
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: credential.value,
            .domain: host,
            .path: credential.path ?? "/",
            .expires: credential.expiresAt,
            .secure: credential.secure == true ? "TRUE" : "FALSE",
        ]
        if credential.httpOnly == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = credential.sameSite, !sameSite.isEmpty {
            properties[HTTPCookiePropertyKey("SameSite")] = sameSite.capitalized
        }
        return HTTPCookie(properties: properties)
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
            onCapabilitiesChanged: onCapabilitiesChanged,
            onAudioStateChanged: onAudioStateChanged,
            onStreamTelemetry: onStreamTelemetry,
            authorizePeripheral: authorizePeripheral
        )
        context.coordinator.onCapabilitiesChanged(.current)
        context.coordinator.performFind(findRequest, in: webView)
        context.coordinator.perform(command, in: webView)
        let embeddedURL = Self.embeddedViewerURL(url)
        if context.coordinator.loadedURL != embeddedURL || context.coordinator.reloadToken != reloadToken {
            context.coordinator.loadedURL = embeddedURL
            context.coordinator.reloadToken = reloadToken
            Self.load(embeddedURL, credential: credential, in: webView)
        }
    }

    struct Command: Equatable {
        enum Kind: Equatable { case toggleAudio, focusKeyboard }
        let kind: Kind
        let sequence: Int

        var javaScript: String {
            switch kind {
            case .toggleAudio: "window.__ghostlightBridge?.toggleAudio()"
            case .focusKeyboard: "window.__ghostlightBridge?.focusKeyboard()"
            }
        }
    }

    struct StreamTelemetry: Equatable {
        let connectionState: String
        let framesDecoded: Int
        let framesDropped: Int
        let packetsReceived: Int
        let packetsLost: Int
        let roundTripTimeMilliseconds: Int?
        let jitterMilliseconds: Int?
        let frozen: Bool

        var degradationReason: String? {
            if connectionState != "connected" { return "Connection interrupted" }
            if frozen { return "Video stopped updating" }
            if let roundTripTimeMilliseconds, roundTripTimeMilliseconds >= 250 { return "High latency" }
            let packets = packetsReceived + packetsLost
            if packets > 0, Double(packetsLost) / Double(packets) >= 0.03 { return "Packet loss" }
            let frames = framesDecoded + framesDropped
            if frames > 0, Double(framesDropped) / Double(frames) >= 0.03 { return "Dropped frames" }
            return nil
        }

        var isDegraded: Bool { degradationReason != nil }

        static func decode(_ body: Any) -> StreamTelemetry? {
            guard let payload = body as? [String: Any], payload["kind"] as? String == "telemetry",
                  let connectionState = payload["connection_state"] as? String,
                  let framesDecoded = payload["frames_decoded"] as? Int,
                  let framesDropped = payload["frames_dropped"] as? Int,
                  let packetsReceived = payload["packets_received"] as? Int,
                  let packetsLost = payload["packets_lost"] as? Int,
                  let frozen = payload["frozen"] as? Bool else { return nil }
            return StreamTelemetry(
                connectionState: connectionState,
                framesDecoded: framesDecoded,
                framesDropped: framesDropped,
                packetsReceived: packetsReceived,
                packetsLost: packetsLost,
                roundTripTimeMilliseconds: payload["round_trip_time_ms"] as? Int,
                jitterMilliseconds: payload["jitter_ms"] as? Int,
                frozen: frozen
            )
        }
    }

    enum TelemetryVisibility {
        static func isVisible(_ telemetry: StreamTelemetry?, inspected: Bool) -> Bool {
            inspected || telemetry?.isDegraded == true
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

        static func capabilities(for type: WKMediaCaptureType) -> [PeripheralCapability] {
            switch type {
            case .camera: [.camera]
            case .microphone: [.microphone]
            case .cameraAndMicrophone: [.camera, .microphone]
            @unknown default: []
            }
        }

        static func url(for origin: WKSecurityOrigin) -> URL? {
            var components = URLComponents()
            components.scheme = origin.protocol
            components.host = origin.host
            if origin.port > 0 {
                components.port = origin.port
            }
            return components.url
        }
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
        var onWebContentProcessTerminated: (@escaping () -> Void) -> Void
        var onFullscreenStateChanged: (WKWebView.FullscreenState) -> Void
        var onCapabilitiesChanged: (Capabilities) -> Void
        var onAudioStateChanged: (Bool) -> Void
        var onStreamTelemetry: (StreamTelemetry) -> Void
        var authorizePeripheral: AuthorizePeripheral
        private var nativePerformanceRecorder: NativePerformanceRecorder?
        private var findSequence: Int?
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        private var fullscreenObservation: NSKeyValueObservation?
        private var commandSequence: Int?

        init(
            onNavigationStarted: @escaping () -> Void,
            onNavigationFinished: @escaping (URL?) -> Void,
            onNavigationFailed: @escaping (String) -> Void,
            onMediaReady: @escaping () -> Void,
            onFindResult: @escaping (FindResult) -> Void,
            onDownloadStarted: @escaping (URL) -> Void,
            onDownloadFinished: @escaping (URL, RevealDownload) -> Void,
            onDownloadFailed: @escaping (String) -> Void,
            onWebContentProcessTerminated: @escaping (@escaping () -> Void) -> Void,
            onFullscreenStateChanged: @escaping (WKWebView.FullscreenState) -> Void,
            onCapabilitiesChanged: @escaping (Capabilities) -> Void,
            onAudioStateChanged: @escaping (Bool) -> Void,
            onStreamTelemetry: @escaping (StreamTelemetry) -> Void,
            authorizePeripheral: @escaping AuthorizePeripheral
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
            self.onAudioStateChanged = onAudioStateChanged
            self.onStreamTelemetry = onStreamTelemetry
            self.authorizePeripheral = authorizePeripheral
        }

        func configureMediaReadiness(_ configuration: WKWebViewConfiguration) {
            configuration.userContentController.add(self, name: MediaReadinessSignal.messageHandlerName)
            configuration.userContentController.addUserScript(
                WKUserScript(source: MediaReadinessSignal.userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        func configureEmbeddedExperience(_ configuration: WKWebViewConfiguration) {
            configuration.userContentController.add(self, name: EmbeddedViewerSignal.messageHandlerName)
            configuration.userContentController.addUserScript(
                WKUserScript(source: EmbeddedViewerSignal.userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
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
            onWebContentProcessTerminated: @escaping (@escaping () -> Void) -> Void,
            onFullscreenStateChanged: @escaping (WKWebView.FullscreenState) -> Void,
            onCapabilitiesChanged: @escaping (Capabilities) -> Void,
            onAudioStateChanged: @escaping (Bool) -> Void,
            onStreamTelemetry: @escaping (StreamTelemetry) -> Void,
            authorizePeripheral: @escaping AuthorizePeripheral
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
            self.onAudioStateChanged = onAudioStateChanged
            self.onStreamTelemetry = onStreamTelemetry
            self.authorizePeripheral = authorizePeripheral
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == MediaReadinessSignal.messageHandlerName,
               (message.body as? String) == "mediaReady" {
                onMediaReady()
                return
            }
            guard message.name == EmbeddedViewerSignal.messageHandlerName,
                  let payload = message.body as? [String: Any], let kind = payload["kind"] as? String else { return }
            if kind == "audio", let muted = payload["muted"] as? Bool {
                onAudioStateChanged(muted)
            } else if let telemetry = StreamTelemetry.decode(payload) {
                onStreamTelemetry(telemetry)
            }
        }

        func perform(_ command: Command?, in webView: WKWebView) {
            guard let command, command.sequence != commandSequence else { return }
            commandSequence = command.sequence
            webView.evaluateJavaScript(command.javaScript)
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
            guard let origin = loadedURL else {
                onDownloadFailed("Download access was denied because the viewer origin is unavailable.")
                completionHandler(nil)
                return
            }
            Task { @MainActor [weak self] in
                guard let self, await authorizePeripheral(.download, origin) else {
                    self?.onDownloadFailed("Download access is not granted for this viewer.")
                    completionHandler(nil)
                    return
                }
                finishDownloadDestination(download, suggestedFilename: suggestedFilename, completionHandler: completionHandler)
            }
        }

        private func finishDownloadDestination(
            _ download: WKDownload,
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
            guard let viewerOrigin = loadedURL,
                  let requestingOrigin = PermissionPolicy.url(for: origin),
                  Self.isSameOrigin(requestingOrigin, as: viewerOrigin) else {
                decisionHandler(.deny)
                return
            }
            let capabilities = PermissionPolicy.capabilities(for: type)
            Task { @MainActor [weak self] in
                guard let self, !capabilities.isEmpty else {
                    decisionHandler(.deny)
                    return
                }
                for capability in capabilities where !(await authorizePeripheral(capability, requestingOrigin)) {
                    decisionHandler(.deny)
                    return
                }
                decisionHandler(.grant)
            }
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

enum EmbeddedViewerSignal {
    static let messageHandlerName = "ghostlightViewer"

    static let userScript = #"""
    (() => {
      if (window.__ghostlightViewerInstalled) return;
      window.__ghostlightViewerInstalled = true;
      const post = (payload) => window.webkit.messageHandlers.ghostlightViewer.postMessage(payload);
      const peers = new Set();
      const previous = new WeakMap();
      const NativePeerConnection = window.RTCPeerConnection;
      if (NativePeerConnection) {
        const TrackedPeerConnection = function (...args) {
          const peer = new NativePeerConnection(...args);
          peers.add(peer);
          peer.addEventListener("connectionstatechange", () => sample(peer));
          return peer;
        };
        TrackedPeerConnection.prototype = NativePeerConnection.prototype;
        Object.setPrototypeOf(TrackedPeerConnection, NativePeerConnection);
        window.RTCPeerConnection = TrackedPeerConnection;
      }

      const videos = () => [...document.querySelectorAll("video")];
      const publishAudio = () => {
        const video = videos()[0];
        if (video) post({ kind: "audio", muted: video.muted || video.volume === 0 });
      };
      const observeVideos = () => videos().forEach((video) => {
        if (video.__ghostlightAudioObserved) return;
        video.__ghostlightAudioObserved = true;
        video.addEventListener("volumechange", publishAudio);
        publishAudio();
      });

      window.__ghostlightBridge = {
        toggleAudio() {
          const video = videos()[0];
          if (!video) return false;
          video.muted = !video.muted;
          publishAudio();
          return true;
        },
        focusKeyboard() {
          const overlay = document.querySelector("textarea.overlay");
          if (!overlay) return false;
          overlay.focus();
          return document.activeElement === overlay;
        },
      };

      const sample = async (peer) => {
        try {
          const reports = await peer.getStats();
          let decoded = 0, dropped = 0, received = 0, lost = 0, rtt = null, jitter = null;
          reports.forEach((report) => {
            if (report.type === "inbound-rtp" && report.kind === "video" && !report.isRemote) {
              decoded += Number(report.framesDecoded || 0);
              dropped += Number(report.framesDropped || 0);
              received += Number(report.packetsReceived || 0);
              lost += Number(report.packetsLost || 0);
              if (Number.isFinite(report.jitter)) jitter = Math.round(report.jitter * 1000);
            }
            if (report.type === "candidate-pair" && report.state === "succeeded" && (report.nominated || report.selected) && Number.isFinite(report.currentRoundTripTime)) {
              rtt = Math.round(report.currentRoundTripTime * 1000);
            }
          });
          const prior = previous.get(peer);
          previous.set(peer, { decoded, dropped, received, lost });
          if (!prior) return;
          const delta = {
            decoded: Math.max(0, decoded - prior.decoded),
            dropped: Math.max(0, dropped - prior.dropped),
            received: Math.max(0, received - prior.received),
            lost: Math.max(0, lost - prior.lost),
          };
          post({
            kind: "telemetry",
            connection_state: peer.connectionState,
            frames_decoded: delta.decoded,
            frames_dropped: delta.dropped,
            packets_received: delta.received,
            packets_lost: delta.lost,
            round_trip_time_ms: rtt,
            jitter_ms: jitter,
            frozen: peer.connectionState === "connected" && received > 0 && delta.decoded === 0,
          });
        } catch {}
      };

      const style = document.createElement("style");
      style.textContent = ".header-container,.room-container,.video-menu{display:none!important}";
      (document.head || document.documentElement).appendChild(style);
      const observer = new MutationObserver(observeVideos);
      observer.observe(document.documentElement, { childList: true, subtree: true });
      observeVideos();
      const timer = setInterval(() => {
        observeVideos();
        peers.forEach(sample);
      }, 2000);
      window.addEventListener("pagehide", () => {
        clearInterval(timer);
        observer.disconnect();
      }, { once: true });
    })();
    """#
}
