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

    func viewerNavigationFinished(at _: URL?) {
        guard let viewerEntryURL, case .loadingViewer = state else {
            return
        }
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
            reloadViewer()
            return
        }
        state = .viewerFailed(viewerEntryURL, message: message)
        automaticRetryEnabled = false
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
        connectionID = nil
        viewerEntryURL = nil
        defaults.removeObject(forKey: Self.controlPlaneDefaultsKey)
        automaticRetryEnabled = false
        viewerRetryAttempt = 0
        state = .disconnected
        reloadToken = 0
    }
}
