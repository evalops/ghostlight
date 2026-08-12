import Combine
import Foundation

enum SessionViewState: Equatable {
    case disconnected
    case discoveringControl
    case loadingViewer(URL, retryAttempt: Int)
    case viewerLoaded(URL)
    case viewerFailed(URL, message: String)
    case controlFailed(String)
}

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var controlPlaneURL = "http://localhost:8080"
    @Published private(set) var state: SessionViewState = .disconnected
    @Published private(set) var reloadToken = 0

    private static let controlPlaneDefaultsKey = "GhostlightControlPlaneURL"

    private let client: any ViewerDiscovering
    private let defaults: UserDefaults
    private var connectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var viewerEntryURL: URL?
    private var automaticRetryEnabled = false
    private var viewerRetryAttempt = 0

    static let automaticRetryLimit = 2

    init(
        client: any ViewerDiscovering = SessionClient(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        autoConnect: Bool = true
    ) {
        self.client = client
        self.defaults = defaults
        let environmentURL = environment["GHOSTLIGHT_CONTROL_URL"]
        let savedURL = defaults.string(forKey: Self.controlPlaneDefaultsKey)
        self.controlPlaneURL = environmentURL ?? savedURL ?? "http://localhost:8080"

        if autoConnect, environmentURL != nil || savedURL != nil {
            connect(automatic: true)
        }
    }

    var viewerURL: URL? {
        viewerEntryURL
    }

    var isConnecting: Bool {
        switch state {
        case .discoveringControl, .loadingViewer:
            return true
        case .disconnected, .viewerLoaded, .viewerFailed, .controlFailed:
            return false
        }
    }

    func connect() {
        connect(automatic: false)
    }

    private func connect(automatic: Bool) {
        connectTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        let requestID = UUID()
        connectionID = requestID
        viewerEntryURL = nil
        automaticRetryEnabled = automatic
        viewerRetryAttempt = 0
        state = .discoveringControl
        let rawControlPlaneURL = controlPlaneURL

        connectTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let response = try await client.discoverViewer(controlPlaneURL: rawControlPlaneURL)
                guard !Task.isCancelled, connectionID == requestID else {
                    return
                }
                defaults.set(rawControlPlaneURL, forKey: Self.controlPlaneDefaultsKey)
                viewerEntryURL = response.viewerURL
                state = .loadingViewer(response.viewerURL, retryAttempt: 0)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, connectionID == requestID else {
                    return
                }
                state = .controlFailed(error.localizedDescription)
            }
        }
    }

    func viewerNavigationStarted() {
        guard let viewerEntryURL else {
            return
        }

        switch state {
        case .loadingViewer:
            break
        case .viewerLoaded, .viewerFailed:
            state = .loadingViewer(viewerEntryURL, retryAttempt: viewerRetryAttempt)
        case .disconnected, .discoveringControl, .controlFailed:
            break
        }
    }

    func viewerNavigationFinished(at url: URL?) {
        guard let viewerEntryURL, case .loadingViewer = state else {
            return
        }
        if let url, !ViewerWebView.Coordinator.isSameOrigin(url, as: viewerEntryURL) {
            viewerNavigationFailed("The viewer navigated to an unexpected origin.")
            return
        }
        retryTask?.cancel()
        retryTask = nil
        state = .viewerLoaded(viewerEntryURL)
        viewerRetryAttempt = 0
        automaticRetryEnabled = false
    }

    func viewerNavigationFailed(_ message: String) {
        guard let viewerEntryURL else {
            return
        }

        switch state {
        case .loadingViewer, .viewerLoaded:
            break
        case .disconnected, .discoveringControl, .viewerFailed, .controlFailed:
            return
        }

        if automaticRetryEnabled, viewerRetryAttempt < Self.automaticRetryLimit {
            viewerRetryAttempt += 1
            state = .loadingViewer(viewerEntryURL, retryAttempt: viewerRetryAttempt)
            scheduleAutomaticRetry()
            return
        }
        state = .viewerFailed(viewerEntryURL, message: message)
        automaticRetryEnabled = false
    }

    private func scheduleAutomaticRetry() {
        retryTask?.cancel()
        let attempt = viewerRetryAttempt
        let requestID = connectionID
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.automaticRetryDelay(forAttempt: attempt))
            guard !Task.isCancelled, let self else {
                return
            }
            guard self.connectionID == requestID,
                  self.viewerRetryAttempt == attempt,
                  case .loadingViewer = self.state else {
                return
            }
            self.reloadViewer()
        }
    }

    private static func automaticRetryDelay(forAttempt attempt: Int) -> Duration {
        // Exponential backoff: 1s after the first failure, 2s after the second.
        .seconds(1 << (attempt - 1))
    }

    func reloadViewer() {
        reloadToken &+= 1
    }

    func retryViewer() {
        guard let viewerEntryURL, case .viewerFailed = state else {
            return
        }
        automaticRetryEnabled = false
        viewerRetryAttempt = 0
        state = .loadingViewer(viewerEntryURL, retryAttempt: 0)
        reloadViewer()
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
        connectionID = nil
        viewerEntryURL = nil
        defaults.removeObject(forKey: Self.controlPlaneDefaultsKey)
        automaticRetryEnabled = false
        viewerRetryAttempt = 0
        state = .disconnected
        reloadToken = 0
    }
}
