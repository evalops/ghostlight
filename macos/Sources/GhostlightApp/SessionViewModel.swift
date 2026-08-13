import Combine
import Foundation

enum ControlState: Equatable {
    case disconnected
    case connecting
    case controller(expiresAt: Date)
    case observer
    case expired
    case failed(String)
}

enum SurfaceState: Equatable {
    case idle
    case loadingPage(URL)
    case pageReady(URL)
    case mediaReady(URL)
    case failed(String)
}

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var controlOrigin: String
    @Published var addressDraft = ""
    @Published private(set) var controlState: ControlState = .disconnected
    @Published private(set) var surfaceState: SurfaceState = .idle
    @Published private(set) var session: BrowserSession?
    @Published private(set) var stream: StreamConnection?
    @Published private(set) var commandError: String?

    static let originKey = "GhostlightControlOrigin"
    static let sessionIDKey = "GhostlightSessionID"
    static let clientIDKey = "GhostlightClientID"
    static let legacyOriginKey = "GhostlightControlPlaneURL"

    private let client: any SessionServicing
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private(set) var clientID: String
    private var lease: ControllerLease?
    private var isAddressFocused = false
    private var lifecycleTask: Task<Void, Never>?
    private var leaseTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var lifecycleID = UUID()

    init(
        client: any SessionServicing = SessionClient(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init,
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = SessionViewModel.defaultSleepUntil,
        autoConnect: Bool = true
    ) {
        self.client = client
        self.defaults = defaults
        self.now = now
        self.sleepUntil = sleepUntil

        let migrated = defaults.string(forKey: Self.originKey)
            ?? defaults.string(forKey: Self.legacyOriginKey)
        let environmentOrigin = environment["GHOSTLIGHT_CONTROL_URL"]
        self.controlOrigin = environmentOrigin ?? migrated ?? "http://localhost:8080"

        if defaults.string(forKey: Self.originKey) == nil, let migrated {
            defaults.set(migrated, forKey: Self.originKey)
        }
        defaults.removeObject(forKey: Self.legacyOriginKey)

        let savedClientID = defaults.string(forKey: Self.clientIDKey)
        let resolvedClientID = savedClientID ?? UUID().uuidString.lowercased()
        self.clientID = resolvedClientID
        defaults.set(resolvedClientID, forKey: Self.clientIDKey)

        if autoConnect, environmentOrigin != nil || migrated != nil {
            connect()
        }
    }

    deinit {
        lifecycleTask?.cancel()
        leaseTask?.cancel()
        eventsTask?.cancel()
    }

    var activeTab: BrowserTab? {
        guard let session else { return nil }
        return session.tabs.first(where: { $0.id == session.activeTabID })
            ?? session.tabs.first(where: \.active)
    }

    var canControl: Bool {
        guard case .controller = controlState, let lease else { return false }
        return now() < lease.expiresAt
    }

    var streamURL: URL? { stream?.url }

    func connect() {
        cancelLifecycle()
        let runID = UUID()
        lifecycleID = runID
        controlState = .connecting
        surfaceState = .idle
        commandError = nil

        let origin: URL
        do {
            origin = try ControlPlaneURLValidator.validate(controlOrigin)
        } catch {
            controlState = .failed(error.localizedDescription)
            return
        }

        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = try await resumeOrCreate(at: origin)
                guard owns(runID) else { return }
                defaults.set(origin.absoluteString, forKey: Self.originKey)
                defaults.set(browser.id, forKey: Self.sessionIDKey)
                apply(browser)
                startEvents(at: origin, sessionID: browser.id, runID: runID)

                do {
                    let connection = try await client.createStream(at: origin, sessionID: browser.id)
                    guard owns(runID) else { return }
                    stream = connection
                    surfaceState = .loadingPage(connection.url)
                } catch {
                    guard owns(runID) else { return }
                    surfaceState = .failed(error.localizedDescription)
                }

                do {
                    let acquired = try await client.acquireLease(at: origin, sessionID: browser.id, clientID: clientID)
                    guard owns(runID) else { return }
                    installLease(acquired)
                    startLeaseRenewal(at: origin, sessionID: browser.id, runID: runID)
                } catch let error as SessionClientError where error.statusCode == 409 || error.statusCode == 423 {
                    guard owns(runID) else { return }
                    becomeObserver()
                } catch {
                    guard owns(runID) else { return }
                    controlState = .failed(error.localizedDescription)
                }
            } catch is CancellationError {
                return
            } catch {
                guard owns(runID) else { return }
                controlState = .failed(error.localizedDescription)
            }
        }
    }

    func resetSession() {
        cancelLifecycle()
        defaults.removeObject(forKey: Self.sessionIDKey)
        session = nil
        stream = nil
        lease = nil
        addressDraft = ""
        controlState = .disconnected
        surfaceState = .idle
    }

    func apply(_ incoming: BrowserSession) {
        if let current = session, incoming.revision <= current.revision { return }
        session = incoming
        if !isAddressFocused { syncAddressDraft() }
    }

    func setAddressFocused(_ focused: Bool) {
        isAddressFocused = focused
        if !focused { syncAddressDraft() }
    }

    func installLease(_ lease: ControllerLease) {
        self.lease = lease
        controlState = now() < lease.expiresAt ? .controller(expiresAt: lease.expiresAt) : .expired
    }

    func becomeObserver() {
        lease = nil
        controlState = .observer
    }

    func goBack() { send(.init(type: .goBack, tabID: activeTab?.id, expectedRevision: session?.revision ?? 0)) }
    func goForward() { send(.init(type: .goForward, tabID: activeTab?.id, expectedRevision: session?.revision ?? 0)) }
    func reload() { send(.init(type: .reload, tabID: activeTab?.id, expectedRevision: session?.revision ?? 0)) }
    func newTab() { send(.init(type: .newTab, expectedRevision: session?.revision ?? 0)) }
    func closeTab(_ id: String) { send(.init(type: .closeTab, tabID: id, expectedRevision: session?.revision ?? 0)) }
    func activateTab(_ id: String) { send(.init(type: .activateTab, tabID: id, expectedRevision: session?.revision ?? 0)) }

    func navigate() {
        let value = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let target = value.contains("://") ? value : "https://\(value)"
        send(.init(type: .navigate, tabID: activeTab?.id, url: target, expectedRevision: session?.revision ?? 0))
    }

    func attach(_ fileURL: URL) {
        guard let context = commandContext else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let attachment = try await client.uploadAttachment(
                    at: context.origin,
                    sessionID: context.sessionID,
                    token: context.token,
                    fileURL: fileURL
                )
                send(.init(type: .attach, tabID: activeTab?.id, attachmentID: attachment.id, expectedRevision: session?.revision ?? 0))
            } catch {
                commandError = error.localizedDescription
            }
        }
    }

    func viewerNavigationStarted() {
        guard let url = stream?.url else { return }
        surfaceState = .loadingPage(url)
    }

    func viewerNavigationFinished(at url: URL?) {
        guard let entry = stream?.url else { return }
        guard url.map({ ViewerWebView.Coordinator.isSameOrigin($0, as: entry) }) ?? true else {
            surfaceState = .failed("The stream navigated to an unexpected origin.")
            return
        }
        surfaceState = .pageReady(entry)
    }

    func viewerMediaReady() {
        guard let url = stream?.url else { return }
        surfaceState = .mediaReady(url)
    }

    func viewerNavigationFailed(_ message: String) {
        surfaceState = .failed(message)
    }

    private func resumeOrCreate(at origin: URL) async throws -> BrowserSession {
        if let sessionID = defaults.string(forKey: Self.sessionIDKey) {
            do {
                return try await client.getSession(at: origin, sessionID: sessionID)
            } catch let error as SessionClientError where error.statusCode == 404 {
                defaults.removeObject(forKey: Self.sessionIDKey)
            }
        }
        return try await client.createSession(
            at: origin,
            idempotencyKey: "ghostlight-macos-\(clientID)-browser"
        )
    }

    private func send(_ command: BrowserCommand) {
        guard let context = commandContext else { return }
        commandError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await client.sendCommand(
                    at: context.origin,
                    sessionID: context.sessionID,
                    token: context.token,
                    idempotencyKey: UUID().uuidString.lowercased(),
                    command: command
                )
                apply(updated)
            } catch {
                commandError = error.localizedDescription
            }
        }
    }

    private var commandContext: (origin: URL, sessionID: String, token: String)? {
        guard canControl,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin),
              let session,
              let lease else { return nil }
        return (origin, session.id, lease.token)
    }

    private func startEvents(at origin: URL, sessionID: String, runID: UUID) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            guard let self else { return }
            while owns(runID), !Task.isCancelled {
                do {
                    let revision = session?.revision ?? 0
                    if let updated = try await client.sessionEvents(
                        at: origin,
                        sessionID: sessionID,
                        afterRevision: revision
                    ) {
                        apply(updated)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } catch is CancellationError {
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func startLeaseRenewal(at origin: URL, sessionID: String, runID: UUID) {
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            guard let self else { return }
            while owns(runID), let current = lease, !Task.isCancelled {
                do {
                    try await sleepUntil(current.renewAfter)
                    guard owns(runID), now() < current.expiresAt else {
                        controlState = .expired
                        lease = nil
                        return
                    }
                    let renewed = try await client.renewLease(
                        at: origin,
                        sessionID: sessionID,
                        leaseID: current.id,
                        token: current.token
                    )
                    installLease(renewed)
                } catch is CancellationError {
                    return
                } catch {
                    guard owns(runID) else { return }
                    if now() >= current.expiresAt {
                        lease = nil
                        controlState = .expired
                    } else {
                        becomeObserver()
                    }
                    return
                }
            }
        }
    }

    private func syncAddressDraft() {
        addressDraft = activeTab?.url ?? ""
    }

    private func owns(_ id: UUID) -> Bool { lifecycleID == id && !Task.isCancelled }

    private func cancelLifecycle() {
        lifecycleTask?.cancel()
        leaseTask?.cancel()
        eventsTask?.cancel()
        lifecycleTask = nil
        leaseTask = nil
        eventsTask = nil
        lease = nil
    }

    nonisolated private static func defaultSleepUntil(_ date: Date) async throws {
        let interval = max(0, date.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(interval))
    }
}
