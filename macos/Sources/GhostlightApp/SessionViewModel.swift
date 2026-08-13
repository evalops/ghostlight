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

enum CommandStatus: Equatable {
    case idle
    case pending(Int)
    case failed(code: String, message: String)
}

enum NativeBrowserAction: CaseIterable, Equatable {
    case focusLocation
    case newTab
    case closeTab
    case reload
    case goBack
    case goForward
    case nextTab
    case previousTab
}

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var controlOrigin: String
    @Published var apiToken: String
    @Published var addressDraft = ""
    @Published private(set) var controlState: ControlState = .disconnected
    @Published private(set) var surfaceState: SurfaceState = .idle
    @Published private(set) var session: BrowserSession?
    @Published private(set) var stream: StreamConnection?
    @Published private(set) var commandError: String?
    @Published private(set) var commandStatus: CommandStatus = .idle
    @Published private(set) var addressFocusRequest = 0

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
    private var submissionsByKey: [String: CommandSubmission] = [:]
    private var submissionsByReceiptID: [String: CommandSubmission] = [:]
    private var receiptsByID: [String: CommandReceipt] = [:]
    private var failedSubmission: CommandSubmission?

    init(
        client: any SessionServicing = SessionClient(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { date in
            try await SessionViewModel.defaultSleepUntil(date)
        },
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
        self.apiToken = environment["GHOSTLIGHT_API_TOKEN"] ?? ""

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
        clearCommandTracking()

        let origin: URL
        do {
            origin = try ControlPlaneURLValidator.validate(controlOrigin)
        } catch {
            controlState = .failed(error.localizedDescription)
            return
        }
        let apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiToken.isEmpty else {
            controlState = .failed("Enter the control API token.")
            return
        }
        self.apiToken = apiToken

        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = try await resumeOrCreate(at: origin, apiToken: apiToken)
                guard owns(runID) else { return }
                defaults.set(origin.absoluteString, forKey: Self.originKey)
                defaults.set(browser.id, forKey: Self.sessionIDKey)
                apply(browser)
                startEvents(at: origin, sessionID: browser.id, runID: runID)

                do {
                    let connection = try await client.createStream(at: origin, apiToken: apiToken, sessionID: browser.id)
                    guard owns(runID) else { return }
                    stream = connection
                    surfaceState = .loadingPage(connection.url)
                } catch {
                    guard owns(runID) else { return }
                    surfaceState = .failed(error.localizedDescription)
                }

                do {
                    let acquired = try await client.acquireLease(at: origin, apiToken: apiToken, sessionID: browser.id, clientID: clientID)
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
        clearCommandTracking()
    }

    func apply(_ incoming: BrowserSession) {
        incoming.commandReceipts.forEach { accept($0, submission: submissionsByReceiptID[$0.id]) }
        if let current = session, incoming.revision <= current.revision { return }
        let activeTabChanged = session?.activeTabID != incoming.activeTabID
        session = incoming
        if activeTabChanged || !isAddressFocused { syncAddressDraft() }
    }

    func setAddressFocused(_ focused: Bool) {
        isAddressFocused = focused
        if !focused { syncAddressDraft() }
    }

    func installLease(_ lease: ControllerLease) {
        guard lease.token != nil else {
            becomeObserver()
            return
        }
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
    func newTab() { send(.init(type: .newTab, url: "https://www.google.com", expectedRevision: session?.revision ?? 0)) }
    func closeTab(_ id: String) { send(.init(type: .closeTab, tabID: id, expectedRevision: session?.revision ?? 0)) }
    func activateTab(_ id: String) { send(.init(type: .activateTab, tabID: id, expectedRevision: session?.revision ?? 0)) }

    func canPerform(_ action: NativeBrowserAction) -> Bool {
        guard canControl else { return false }
        switch action {
        case .focusLocation, .closeTab, .reload, .goBack, .goForward:
            return activeTab != nil
        case .nextTab, .previousTab:
            return (session?.tabs.count ?? 0) > 1
        case .newTab:
            return session != nil
        }
    }

    func perform(_ action: NativeBrowserAction) {
        guard canPerform(action) else { return }
        switch action {
        case .focusLocation:
            addressFocusRequest &+= 1
        case .newTab:
            newTab()
        case .closeTab:
            if let id = activeTab?.id { closeTab(id) }
        case .reload:
            reload()
        case .goBack:
            goBack()
        case .goForward:
            goForward()
        case .nextTab:
            cycleTab(offset: 1)
        case .previousTab:
            cycleTab(offset: -1)
        }
    }

    func retryFailedCommand() {
        guard let failedSubmission, canControl else { return }
        submit(failedSubmission)
    }

    func navigate() {
        navigate(to: addressDraft)
    }

    func navigate(to value: String) {
        guard let target = Self.navigationTarget(for: value) else { return }
        addressDraft = target
        send(.init(type: .navigate, tabID: activeTab?.id, url: target, expectedRevision: session?.revision ?? 0))
    }

    nonisolated static func navigationTarget(for input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("://") { return value }
        if !value.contains(where: \.isWhitespace), value.contains(".") || value.contains(":") {
            return "https://\(value)"
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url?.absoluteString
    }

    func attach(_ fileURL: URL) {
        guard let context = commandContext else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let attachment = try await client.uploadAttachment(
                    at: context.origin,
                    apiToken: context.apiToken,
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

    private func resumeOrCreate(at origin: URL, apiToken: String) async throws -> BrowserSession {
        if let sessionID = defaults.string(forKey: Self.sessionIDKey) {
            do {
                return try await client.getSession(at: origin, apiToken: apiToken, sessionID: sessionID)
            } catch let error as SessionClientError where error.statusCode == 404 {
                defaults.removeObject(forKey: Self.sessionIDKey)
            }
        }
        return try await client.createSession(
            at: origin,
            apiToken: apiToken,
            idempotencyKey: "ghostlight-macos-\(clientID)-browser"
        )
    }

    private func send(_ command: BrowserCommand) {
        guard let context = commandContext else { return }
        let submission = CommandSubmission(idempotencyKey: UUID().uuidString.lowercased(), command: command)
        submit(submission, context: context)
    }

    private func submit(_ submission: CommandSubmission) {
        guard let context = commandContext else { return }
        submit(submission, context: context)
    }

    private func submit(
        _ submission: CommandSubmission,
        context: (origin: URL, apiToken: String, sessionID: String, token: String)
    ) {
        commandError = nil
        failedSubmission = nil
        submissionsByKey[submission.idempotencyKey] = submission
        updateCommandStatus()
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.sendCommand(
                    at: context.origin,
                    apiToken: context.apiToken,
                    sessionID: context.sessionID,
                    token: context.token,
                    idempotencyKey: submission.idempotencyKey,
                    command: submission.command
                )
                accept(receipt, submission: submission)
            } catch {
                submissionsByKey.removeValue(forKey: submission.idempotencyKey)
                failedSubmission = submission
                commandError = error.localizedDescription
                commandStatus = .failed(code: "request_failed", message: error.localizedDescription)
            }
        }
    }

    private func accept(_ receipt: CommandReceipt, submission: CommandSubmission?) {
        if let submission {
            submissionsByKey.removeValue(forKey: submission.idempotencyKey)
            submissionsByReceiptID[receipt.id] = submission
        }
        if let existing = receiptsByID[receipt.id], existing.state != .queued, receipt.state == .queued {
            updateCommandStatus()
            return
        }
        receiptsByID[receipt.id] = receipt
        switch receipt.state {
        case .queued:
            break
        case .applied:
            submissionsByReceiptID.removeValue(forKey: receipt.id)
            if failedSubmission?.idempotencyKey == submission?.idempotencyKey { failedSubmission = nil }
        case .failed:
            failedSubmission = submission ?? submissionsByReceiptID[receipt.id]
        }
        updateCommandStatus()
    }

    private func updateCommandStatus() {
        if let failed = receiptsByID.values
            .filter({ $0.state == .failed })
            .max(by: { $0.sequence < $1.sequence }) {
            commandStatus = .failed(
                code: failed.errorCode ?? "command_failed",
                message: failed.error ?? failed.errorCode ?? "The browser command failed."
            )
            return
        }
        let pending = submissionsByKey.count + receiptsByID.values.filter { $0.state == .queued }.count
        commandStatus = pending == 0 ? .idle : .pending(pending)
    }

    private func cycleTab(offset: Int) {
        guard let tabs = session?.tabs, tabs.count > 1 else { return }
        let activeIndex = tabs.firstIndex(where: { $0.id == activeTab?.id }) ?? 0
        let nextIndex = (activeIndex + offset + tabs.count) % tabs.count
        activateTab(tabs[nextIndex].id)
    }

    private func clearCommandTracking() {
        submissionsByKey.removeAll()
        submissionsByReceiptID.removeAll()
        receiptsByID.removeAll()
        failedSubmission = nil
        commandStatus = .idle
    }

    private var commandContext: (origin: URL, apiToken: String, sessionID: String, token: String)? {
        guard canControl,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin),
              let session,
              let lease,
              let leaseToken = lease.token else { return nil }
        return (origin, apiToken, session.id, leaseToken)
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
                        apiToken: apiToken,
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
            while owns(runID), let current = lease, let token = current.token, !Task.isCancelled {
                do {
                    try await sleepUntil(current.renewAfter)
                    guard owns(runID), now() < current.expiresAt else {
                        controlState = .expired
                        lease = nil
                        return
                    }
                    let renewed = try await client.renewLease(
                        at: origin,
                        apiToken: apiToken,
                        sessionID: sessionID,
                        leaseID: current.id,
                        token: token
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

private struct CommandSubmission: Equatable {
    let idempotencyKey: String
    let command: BrowserCommand
}
