import Combine
import Foundation

enum SessionViewState: Equatable {
    case disconnected
    case connecting
    case connected(URL)
    case failed(String)
}

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var controlPlaneURL = "http://localhost:8080"
    @Published private(set) var state: SessionViewState = .disconnected
    @Published private(set) var reloadToken = 0

    private static let controlPlaneDefaultsKey = "GhostlightControlPlaneURL"

    private let client: any SessionCreating
    private let defaults: UserDefaults
    private var connectTask: Task<Void, Never>?

    init(
        client: any SessionCreating = SessionClient(),
        defaults: UserDefaults = .standard,
        autoConnect: Bool = true
    ) {
        self.client = client
        self.defaults = defaults
        let environmentURL = ProcessInfo.processInfo.environment["GHOSTLIGHT_CONTROL_URL"]
        let savedURL = defaults.string(forKey: Self.controlPlaneDefaultsKey)
        self.controlPlaneURL = environmentURL ?? savedURL ?? "http://localhost:8080"

        if autoConnect, environmentURL != nil || savedURL != nil {
            connect()
        }
    }

    var viewerURL: URL? {
        guard case let .connected(url) = state else {
            return nil
        }
        return url
    }

    var isConnecting: Bool {
        if case .connecting = state {
            return true
        }
        return false
    }

    func connect() {
        connectTask?.cancel()
        state = .connecting
        let rawControlPlaneURL = controlPlaneURL

        connectTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let response = try await client.createSession(controlPlaneURL: rawControlPlaneURL)
                guard !Task.isCancelled else {
                    return
                }
                defaults.set(rawControlPlaneURL, forKey: Self.controlPlaneDefaultsKey)
                state = .connected(response.viewerURL)
            } catch is CancellationError {
                return
            } catch let error as SessionClientError {
                state = .failed(error.localizedDescription)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func reloadViewer() {
        reloadToken &+= 1
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        state = .disconnected
        reloadToken = 0
    }
}
