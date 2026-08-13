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

struct ViewerProcessRecoveryBudget {
    let maximumAttempts: Int
    let window: TimeInterval
    private var attempts: [Date] = []

    init(maximumAttempts: Int = 3, window: TimeInterval = 60) {
        self.maximumAttempts = maximumAttempts
        self.window = window
    }

    mutating func consume(at date: Date) -> Bool {
        attempts.removeAll { date.timeIntervalSince($0) >= window }
        guard attempts.count < maximumAttempts else { return false }
        attempts.append(date)
        return true
    }

    mutating func reset() {
        attempts.removeAll()
    }
}

enum StreamHandoff {
    static func resolve(
        connection: StreamConnection,
        redeem: (String) async throws -> ViewerBootstrap
    ) async throws -> ViewerBootstrap? {
        guard let capability = connection.capability else { return nil }
        do {
            let bootstrap = try await redeem(capability)
            guard bootstrap.streamID == connection.id else { throw SessionClientError.invalidResponse }
            return bootstrap
        } catch let error as SessionClientError where error.statusCode == 404 || error.statusCode == 405 {
            return nil
        } catch is DecodingError {
            return nil
        }
    }
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
    @Published private(set) var viewerBootstrap: ViewerBootstrap?
    @Published private(set) var workspacePreferences: WorkspacePreferences?
    @Published private(set) var chromeHandoffs: [ChromeHandoff] = []
    @Published private(set) var chromeDevices: [ChromeDevice] = []
    @Published private(set) var chromePairing: ChromePairing?
    @Published private(set) var chromeSyncError: String?
    @Published private(set) var preferencesError: String?
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
    private var failedSubmissionIsTerminal = false
    private var preferenceWriteTail: Task<WorkspacePreferences?, Never>?
    private var viewerProcessRecoveryBudget = ViewerProcessRecoveryBudget()

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
        preferenceWriteTail?.cancel()
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

    var streamURL: URL? { viewerBootstrap?.viewerURL ?? stream?.url }

    var shortcuts: [WorkspaceShortcut] { workspacePreferences?.shortcuts ?? [] }

    var recentURLs: [String] { workspacePreferences?.recentURLs ?? [] }

    func connect() {
        cancelLifecycle()
        let runID = UUID()
        lifecycleID = runID
        controlState = .connecting
        surfaceState = .idle
        viewerBootstrap = nil
        workspacePreferences = nil
        chromeHandoffs = []
        chromeDevices = []
        chromePairing = nil
        chromeSyncError = nil
        preferencesError = nil
        commandError = nil
        clearCommandTracking()
        viewerProcessRecoveryBudget.reset()

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
                await loadWorkspacePreferences(at: origin, apiToken: apiToken, workspaceID: browser.workspaceID)
                await loadChromeHandoffs(at: origin, apiToken: apiToken, workspaceID: browser.workspaceID)
                await loadChromeDevices(at: origin, apiToken: apiToken, workspaceID: browser.workspaceID)
                guard owns(runID) else { return }
                startEvents(at: origin, sessionID: browser.id, runID: runID)

                do {
                    let connection = try await client.createStream(at: origin, apiToken: apiToken, sessionID: browser.id, clientID: clientID)
                    guard owns(runID) else { return }
                    let bootstrap = try await StreamHandoff.resolve(connection: connection) { capability in
                        try await self.client.redeemViewerCapability(
                            at: origin,
                            capability: capability,
                            clientID: self.clientID
                        )
                    }
                    guard owns(runID) else { return }
                    stream = connection
                    viewerBootstrap = bootstrap
                    // Legacy and rolling old servers have no capability redemption
                    // endpoint; their stream URL remains the compatible fallback.
                    surfaceState = .loadingPage(bootstrap?.viewerURL ?? connection.url)
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
        viewerBootstrap = nil
        workspacePreferences = nil
        chromeHandoffs = []
        chromeDevices = []
        chromePairing = nil
        chromeSyncError = nil
        preferencesError = nil
        lease = nil
        addressDraft = ""
        controlState = .disconnected
        surfaceState = .idle
        clearCommandTracking()
        viewerProcessRecoveryBudget.reset()
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
        if !failedSubmissionIsTerminal {
            submit(failedSubmission)
            return
        }
        let failedCommand = failedSubmission.command
        let retry = BrowserCommand(
            type: failedCommand.type,
            tabID: failedCommand.tabID,
            url: failedCommand.url,
            attachmentID: failedCommand.attachmentID,
            expectedRevision: session?.revision ?? failedCommand.expectedRevision
        )
        submit(CommandSubmission(
            idempotencyKey: UUID().uuidString.lowercased(),
            command: retry,
            handoffID: failedSubmission.handoffID
        ))
    }

    func navigate() {
        navigate(to: addressDraft)
    }

    func navigate(to value: String) {
        guard let target = Self.navigationTarget(
            for: value,
            searchURL: workspacePreferences?.searchURL ?? WorkspacePreferences.defaultSearchURL
        ) else { return }
        addressDraft = target
        send(.init(type: .navigate, tabID: activeTab?.id, url: target, expectedRevision: session?.revision ?? 0))
    }

    func createChromePairing(deviceName: String) async -> Bool {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, let session,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else { return false }
        do {
            chromePairing = try await client.createChromePairing(
                at: origin,
                apiToken: apiToken,
                workspaceID: session.workspaceID,
                deviceName: name
            )
            chromeSyncError = nil
            return true
        } catch {
            chromeSyncError = error.localizedDescription
            return false
        }
    }

    func openChromeHandoff(_ handoff: ChromeHandoff) {
        guard handoff.state == "pending",
              WorkspacePreferences.safeRecentURL(handoff.url) != nil else { return }
        let command = BrowserCommand(
            type: .newTab,
            url: handoff.url,
            expectedRevision: session?.revision ?? 0
        )
        submit(CommandSubmission(
            idempotencyKey: "chrome-handoff-\(handoff.id)",
            command: command,
            handoffID: handoff.id
        ))
    }

    func dismissChromeHandoff(_ handoff: ChromeHandoff) {
        resolveChromeHandoff(handoff.id, state: "dismissed")
    }

    func refreshChromeDevices() async {
        guard let session,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else { return }
        await loadChromeDevices(at: origin, apiToken: apiToken, workspaceID: session.workspaceID)
    }

    func revokeChromeDevice(_ device: ChromeDevice) async {
        guard let session,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else { return }
        do {
            try await client.revokeChromeDevice(
                at: origin,
                apiToken: apiToken,
                workspaceID: session.workspaceID,
                deviceID: device.id
            )
            chromeDevices.removeAll { $0.id == device.id }
            chromeSyncError = nil
        } catch {
            chromeSyncError = error.localizedDescription
        }
    }

    nonisolated static func navigationTarget(
        for input: String,
        searchURL: String = WorkspacePreferences.defaultSearchURL
    ) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("://") { return value }
        if !value.contains(where: \.isWhitespace), value.contains(".") || value.contains(":") {
            return "https://\(value)"
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard WorkspacePreferences.isValidSearchURLTemplate(searchURL),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let target = searchURL.replacingOccurrences(of: "{query}", with: encoded)
        guard let components = URLComponents(string: target),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url?.absoluteString
    }

    func loadWorkspacePreferences() async {
        guard let session,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else { return }
        await loadWorkspacePreferences(at: origin, apiToken: apiToken, workspaceID: session.workspaceID)
    }

    func replaceShortcuts(_ shortcuts: [WorkspaceShortcut]) async -> Bool {
        guard let searchURL = workspacePreferences?.searchURL else { return false }
        return await replaceHomePreferences(searchURL: searchURL, shortcuts: shortcuts)
    }

    func replaceHomePreferences(searchURL: String, shortcuts: [WorkspaceShortcut]) async -> Bool {
        guard var preferences = workspacePreferences else { return false }
        let searchURL = searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkspacePreferences.isValidSearchURLTemplate(searchURL) else { return false }
        preferences.searchURL = searchURL
        preferences.shortcuts = shortcuts.enumerated().map { position, shortcut in
            WorkspaceShortcut(
                id: shortcut.id,
                name: shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines),
                url: shortcut.url.trimmingCharacters(in: .whitespacesAndNewlines),
                position: position
            )
        }
        return await persistWorkspacePreferences(preferences)
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
        guard let url = streamURL else { return }
        surfaceState = .loadingPage(url)
    }

    func viewerNavigationFinished(at url: URL?) {
        guard let entry = streamURL else { return }
        guard url.map({ ViewerWebView.Coordinator.isSameOrigin($0, as: entry) }) ?? true else {
            surfaceState = .failed("The stream navigated to an unexpected origin.")
            return
        }
        surfaceState = .pageReady(entry)
    }

    func viewerMediaReady() {
        guard let url = streamURL else { return }
        viewerProcessRecoveryBudget.reset()
        surfaceState = .mediaReady(url)
    }

    func viewerNavigationFailed(_ message: String) {
        surfaceState = .failed(message)
    }

    func viewerProcessTerminated(reload: @escaping () -> Void) {
        guard let url = streamURL else { return }
        guard viewerProcessRecoveryBudget.consume(at: now()) else {
            surfaceState = .failed("The viewer process stopped repeatedly. Reconnect to continue.")
            return
        }
        surfaceState = .loadingPage(url)
        guard let session,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else {
            reload()
            return
        }
        let runID = lifecycleID
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await client.createStream(
                    at: origin, apiToken: apiToken, sessionID: session.id, clientID: clientID
                )
                let bootstrap = try await StreamHandoff.resolve(connection: connection) { capability in
                    try await self.client.redeemViewerCapability(at: origin, capability: capability, clientID: self.clientID)
                }
                guard owns(runID) else { return }
                stream = connection
                viewerBootstrap = bootstrap
                surfaceState = .loadingPage(bootstrap?.viewerURL ?? connection.url)
                if bootstrap == nil { reload() }
            } catch {
                guard owns(runID) else { return }
                surfaceState = .failed("The viewer could not recover: \(error.localizedDescription)")
            }
        }
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
        failedSubmissionIsTerminal = false
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
                failedSubmissionIsTerminal = false
                commandError = error.localizedDescription
                commandStatus = .failed(code: "request_failed", message: error.localizedDescription)
            }
        }
    }

    private func accept(_ receipt: CommandReceipt, submission: CommandSubmission?) {
        let previousState = receiptsByID[receipt.id]?.state
        let resolvedSubmission = submission ?? submissionsByReceiptID[receipt.id]
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
            if failedSubmission?.idempotencyKey == resolvedSubmission?.idempotencyKey { failedSubmission = nil }
            if previousState != .applied,
               resolvedSubmission?.command.type == .navigate,
               let url = receipt.url ?? resolvedSubmission?.command.url {
                recordRecentURL(url)
            }
            if previousState != .applied, let handoffID = resolvedSubmission?.handoffID {
                resolveChromeHandoff(handoffID, state: "opened")
            }
        case .failed:
            failedSubmission = submission ?? submissionsByReceiptID[receipt.id]
            failedSubmissionIsTerminal = true
        }
        updateCommandStatus()
    }

    private func updateCommandStatus() {
        let pending = submissionsByKey.count + receiptsByID.values.filter { $0.state == .queued }.count
        if pending > 0 {
            commandStatus = .pending(pending)
            return
        }
        if let latest = receiptsByID.values
            .filter({ $0.state != .queued })
            .max(by: { $0.sequence < $1.sequence }), latest.state == .failed {
            commandStatus = .failed(
                code: latest.errorCode ?? "command_failed",
                message: latest.error ?? latest.errorCode ?? "The browser command failed."
            )
            return
        }
        commandStatus = .idle
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
        failedSubmissionIsTerminal = false
        commandStatus = .idle
    }

    private func loadWorkspacePreferences(at origin: URL, apiToken: String, workspaceID: String) async {
        do {
            var preferences = try await client.getWorkspacePreferences(
                at: origin,
                apiToken: apiToken,
                workspaceID: workspaceID
            )
            guard session?.workspaceID == workspaceID else { return }
            preferences.recentURLs = WorkspacePreferences.sanitizedRecentURLs(preferences.recentURLs)
            workspacePreferences = preferences
            preferencesError = nil
        } catch is CancellationError {
            return
        } catch {
            guard session?.workspaceID == workspaceID else { return }
            preferencesError = error.localizedDescription
        }
    }

    private func loadChromeHandoffs(at origin: URL, apiToken: String, workspaceID: String) async {
        do {
            let values = try await client.listChromeHandoffs(
                at: origin,
                apiToken: apiToken,
                workspaceID: workspaceID
            )
            guard session?.workspaceID == workspaceID else { return }
            chromeHandoffs = values
            chromeSyncError = nil
        } catch is CancellationError {
            return
        } catch {
            guard session?.workspaceID == workspaceID else { return }
            chromeSyncError = error.localizedDescription
        }
    }

    private func loadChromeDevices(at origin: URL, apiToken: String, workspaceID: String) async {
        do {
            let values = try await client.listChromeDevices(
                at: origin,
                apiToken: apiToken,
                workspaceID: workspaceID
            )
            guard session?.workspaceID == workspaceID else { return }
            chromeDevices = values.filter { $0.revokedAt == nil }
            chromeSyncError = nil
        } catch is CancellationError {
            return
        } catch {
            guard session?.workspaceID == workspaceID else { return }
            chromeSyncError = error.localizedDescription
        }
    }

    private func resolveChromeHandoff(_ handoffID: String, state: String) {
        guard let session,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.updateChromeHandoff(
                    at: origin,
                    apiToken: apiToken,
                    workspaceID: session.workspaceID,
                    handoffID: handoffID,
                    state: state
                )
                chromeHandoffs.removeAll { $0.id == handoffID }
                chromeSyncError = nil
            } catch let error as SessionClientError where error.statusCode == 409 {
                chromeHandoffs.removeAll { $0.id == handoffID }
            } catch {
                chromeSyncError = error.localizedDescription
            }
        }
    }

    private func persistWorkspacePreferences(_ input: WorkspacePreferences) async -> Bool {
        var preferences = input
        preferences.recentURLs = WorkspacePreferences.sanitizedRecentURLs(preferences.recentURLs)
        guard let session,
              session.workspaceID == preferences.workspaceID,
              let origin = try? ControlPlaneURLValidator.validate(controlOrigin) else { return false }
        let apiToken = apiToken
        let workspaceID = session.workspaceID
        let previousWrite = preferenceWriteTail
        workspacePreferences = preferences
        preferencesError = nil

        let write = Task<WorkspacePreferences?, Never> { [client] in
            _ = await previousWrite?.value
            guard !Task.isCancelled else { return nil }
            return try? await client.putWorkspacePreferences(
                preferences,
                at: origin,
                apiToken: apiToken,
                workspaceID: workspaceID
            )
        }
        preferenceWriteTail = write
        guard let saved = await write.value else {
            if workspacePreferences == preferences {
                preferencesError = "Workspace preferences could not be saved."
            }
            return false
        }
        if workspacePreferences == preferences {
            workspacePreferences = saved
        }
        return true
    }

    private func recordRecentURL(_ url: String) {
        guard var preferences = workspacePreferences,
              let safeURL = WorkspacePreferences.safeRecentURL(url) else { return }
        preferences.recentURLs.removeAll { $0 == safeURL }
        preferences.recentURLs.insert(safeURL, at: 0)
        preferences.recentURLs = Array(
            preferences.recentURLs.prefix(WorkspacePreferences.maximumRecentURLCount)
        )
        workspacePreferences = preferences
        Task { [weak self] in
            _ = await self?.persistWorkspacePreferences(preferences)
        }
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
            var pollCount = 0
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
                    pollCount += 1
                    if pollCount.isMultiple(of: 8), let workspaceID = session?.workspaceID {
                        await loadChromeHandoffs(at: origin, apiToken: apiToken, workspaceID: workspaceID)
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
        preferenceWriteTail?.cancel()
        preferenceWriteTail = nil
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
    let handoffID: String?

    init(idempotencyKey: String, command: BrowserCommand, handoffID: String? = nil) {
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.handoffID = handoffID
    }
}
