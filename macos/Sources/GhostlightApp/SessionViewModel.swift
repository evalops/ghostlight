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

    private let client: SessionClient
    private var connectTask: Task<Void, Never>?

    init(client: SessionClient = SessionClient()) {
        self.client = client
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
