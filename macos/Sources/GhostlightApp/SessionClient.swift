import Foundation

public enum SessionClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidControlPlaneURL(ControlPlaneURLError)
    case networkUnavailable
    case requestTimedOut
    case transportFailure
    case server(statusCode: Int, code: String?, message: String?)
    case invalidResponse
    case responseDecodingFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidControlPlaneURL(error): error.localizedDescription
        case .networkUnavailable: "The control plane could not be reached."
        case .requestTimedOut: "The control-plane request timed out."
        case .transportFailure: "The control-plane request failed."
        case let .server(statusCode, _, message):
            message.map { "HTTP \(statusCode): \($0)" } ?? "HTTP \(statusCode)."
        case .invalidResponse: "The control plane returned an invalid response."
        case .responseDecodingFailed: "The control plane returned an unsupported response."
        }
    }

    public var statusCode: Int? {
        guard case let .server(statusCode, _, _) = self else { return nil }
        return statusCode
    }

    public var apiCode: String? {
        guard case let .server(_, code, _) = self else { return nil }
        return code
    }

    static func mapHTTPFailure(statusCode: Int, data: Data) -> SessionClientError {
        let payload = try? SessionJSON.decoder.decode(APIErrorPayload.self, from: data)
        return .server(statusCode: statusCode, code: payload?.error?.code, message: payload?.bestMessage)
    }

    static func mapTransportError(_ error: Error) throws -> SessionClientError {
        guard let urlError = error as? URLError else { return .transportFailure }
        switch urlError.code {
        case .cancelled: throw CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
            return .networkUnavailable
        case .timedOut: return .requestTimedOut
        default: return .transportFailure
        }
    }
}

protocol SessionServicing: Sendable {
    func createNativeClientEnrollment(at origin: URL, operatorToken: String, clientName: String) async throws -> NativeClientEnrollment
    func redeemNativeClientEnrollment(at origin: URL, pairingCapability: String, clientName: String) async throws -> NativeClientCredential
    func revokeNativeClient(at origin: URL, operatorToken: String, clientID: String) async throws
    func revokeCurrentNativeClient(at origin: URL, clientToken: String) async throws
    func getWorkspacePreferences(at origin: URL, apiToken: String, workspaceID: String) async throws -> WorkspacePreferences
    func putWorkspacePreferences(_ preferences: WorkspacePreferences, at origin: URL, apiToken: String, workspaceID: String) async throws -> WorkspacePreferences
    func createChromePairing(at origin: URL, apiToken: String, workspaceID: String, deviceName: String) async throws -> ChromePairing
    func listChromeHandoffs(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ChromeHandoff]
    func listChromeLibrary(at origin: URL, apiToken: String, workspaceID: String, kind: String) async throws -> [ChromeLibraryItem]
    func updateChromeHandoff(at origin: URL, apiToken: String, workspaceID: String, handoffID: String, state: String) async throws -> ChromeHandoff
    func listChromeDevices(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ChromeDevice]
    func revokeChromeDevice(at origin: URL, apiToken: String, workspaceID: String, deviceID: String) async throws
    func listActivitySpaces(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ActivitySpace]
    func createActivitySpace(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, name: String, expectedRevision: Int) async throws -> ActivitySpace
    func parkActivitySpace(at origin: URL, apiToken: String, workspaceID: String, spaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, expectedRevision: Int) async throws -> ActivitySpace
    func activateActivitySpace(at origin: URL, apiToken: String, workspaceID: String, spaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, expectedRevision: Int) async throws -> ActivitySpaceActivation
    func getContinuity(at origin: URL, apiToken: String, workspaceID: String) async throws -> ContinuityOverview
    func submitContinuity(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, verb: ContinuityVerb, adapter: ContinuityAdapter, expiresAt: Date, expectedRevision: Int, spaceID: String?, url: String?) async throws -> ContinuityIntentReceipt
    func listPeripheralGrants(at origin: URL, apiToken: String, workspaceID: String) async throws -> [PeripheralGrant]
    func createPeripheralGrant(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, capability: PeripheralCapability, peripheralOrigin: String, expiresAt: Date) async throws -> PeripheralGrant
    func revokePeripheralGrant(at origin: URL, apiToken: String, workspaceID: String, grantID: String) async throws -> PeripheralGrant
    func authorizePeripheral(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, capability: PeripheralCapability, peripheralOrigin: String) async throws -> PeripheralAuthorization
    func listPeripheralAudit(at origin: URL, apiToken: String, workspaceID: String) async throws -> [PeripheralAuditEvent]
    func getSession(at origin: URL, apiToken: String, sessionID: String) async throws -> BrowserSession
    func createSession(at origin: URL, apiToken: String, idempotencyKey: String) async throws -> BrowserSession
    func sessionEvents(at origin: URL, apiToken: String, sessionID: String, afterRevision: Int, waitMilliseconds: Int) async throws -> BrowserSession?
    func acquireLease(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> ControllerLease
    func renewLease(at origin: URL, apiToken: String, sessionID: String, leaseID: String, token: String) async throws -> ControllerLease
    func releaseLease(at origin: URL, apiToken: String, sessionID: String, leaseID: String, token: String) async throws
    func sendCommand(at origin: URL, apiToken: String, sessionID: String, token: String, idempotencyKey: String, command: BrowserCommand) async throws -> CommandReceipt
    func uploadAttachment(at origin: URL, apiToken: String, sessionID: String, token: String, fileURL: URL) async throws -> Attachment
    func createStream(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> StreamConnection
    func redeemViewerCapability(at origin: URL, capability: String, clientID: String) async throws -> ViewerBootstrap
}

extension SessionServicing {
    func listPeripheralGrants(at origin: URL, apiToken: String, workspaceID: String) async throws -> [PeripheralGrant] { [] }
    func createPeripheralGrant(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, capability: PeripheralCapability, peripheralOrigin: String, expiresAt: Date) async throws -> PeripheralGrant { throw SessionClientError.invalidResponse }
    func revokePeripheralGrant(at origin: URL, apiToken: String, workspaceID: String, grantID: String) async throws -> PeripheralGrant { throw SessionClientError.invalidResponse }
    func authorizePeripheral(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, capability: PeripheralCapability, peripheralOrigin: String) async throws -> PeripheralAuthorization { PeripheralAuthorization(allowed: false, grantID: nil, expiresAt: nil) }
    func listPeripheralAudit(at origin: URL, apiToken: String, workspaceID: String) async throws -> [PeripheralAuditEvent] { [] }
    func listActivitySpaces(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ActivitySpace] { [] }
    func createActivitySpace(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, name: String, expectedRevision: Int) async throws -> ActivitySpace { throw SessionClientError.invalidResponse }
    func parkActivitySpace(at origin: URL, apiToken: String, workspaceID: String, spaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, expectedRevision: Int) async throws -> ActivitySpace { throw SessionClientError.invalidResponse }
    func activateActivitySpace(at origin: URL, apiToken: String, workspaceID: String, spaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, expectedRevision: Int) async throws -> ActivitySpaceActivation { throw SessionClientError.invalidResponse }
    func getContinuity(at origin: URL, apiToken: String, workspaceID: String) async throws -> ContinuityOverview {
        async let spaces = listActivitySpaces(at: origin, apiToken: apiToken, workspaceID: workspaceID)
        async let handoffs = listChromeHandoffs(at: origin, apiToken: apiToken, workspaceID: workspaceID)
        async let bookmarks = listChromeLibrary(at: origin, apiToken: apiToken, workspaceID: workspaceID, kind: "bookmark")
        async let readingList = listChromeLibrary(at: origin, apiToken: apiToken, workspaceID: workspaceID, kind: "reading_list")
        let (spaceValues, handoffValues, bookmarkValues, readingValues) = try await (spaces, handoffs, bookmarks, readingList)
        return ContinuityOverview(
            resume: spaceValues,
            browse: ContinuityBrowse(authority: "chrome_snapshot", bookmarks: bookmarkValues, readingList: readingValues),
            send: handoffValues,
            generatedAt: Date()
        )
    }
    func submitContinuity(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, verb: ContinuityVerb, adapter: ContinuityAdapter, expiresAt: Date, expectedRevision: Int, spaceID: String?, url: String?) async throws -> ContinuityIntentReceipt {
        switch verb {
        case .resume:
            guard let spaceID else { throw SessionClientError.invalidResponse }
            let activation = try await activateActivitySpace(at: origin, apiToken: apiToken, workspaceID: workspaceID, spaceID: spaceID, sessionID: sessionID, leaseToken: leaseToken, idempotencyKey: idempotencyKey, expectedRevision: expectedRevision)
            return ContinuityIntentReceipt(verb: verb, adapter: adapter, authority: "ghostlight_session", expiresAt: expiresAt, space: activation.space, command: activation.command)
        case .send:
            guard let url else { throw SessionClientError.invalidResponse }
            let command = try await sendCommand(at: origin, apiToken: apiToken, sessionID: sessionID, token: leaseToken, idempotencyKey: idempotencyKey, command: BrowserCommand(type: .newTab, url: url, expectedRevision: expectedRevision))
            return ContinuityIntentReceipt(verb: verb, adapter: adapter, authority: "ghostlight_session", expiresAt: expiresAt, space: nil, command: command)
        }
    }
}

public final class SessionClient: SessionServicing, @unchecked Sendable {
    static let requestTimeout: TimeInterval = 15
    static let maximumResponseBytes = 1024 * 1024

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func listWorkspaces(at origin: URL, apiToken: String) async throws -> [Workspace] {
        try await send(.get, origin: origin, path: ["v1", "workspaces"], headers: Self.apiBearer(apiToken))
    }

    public func createNativeClientEnrollment(
        at origin: URL,
        operatorToken: String,
        clientName: String
    ) async throws -> NativeClientEnrollment {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "native-client-enrollments"],
            headers: Self.apiBearer(operatorToken),
            body: try SessionJSON.encoder.encode(NativeClientEnrollmentRequest(clientName: clientName))
        )
    }

    public func redeemNativeClientEnrollment(
        at origin: URL,
        pairingCapability: String,
        clientName: String
    ) async throws -> NativeClientCredential {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "native-client-enrollments", "redeem"],
            headers: Self.apiBearer(pairingCapability),
            body: try SessionJSON.encoder.encode(NativeClientEnrollmentRequest(clientName: clientName))
        )
    }

    public func revokeNativeClient(
        at origin: URL,
        operatorToken: String,
        clientID: String
    ) async throws {
        let _: EmptyResponse? = try await sendOptional(
            .delete,
            origin: origin,
            path: ["v1", "native-clients", clientID],
            headers: Self.apiBearer(operatorToken)
        )
    }

    public func revokeCurrentNativeClient(at origin: URL, clientToken: String) async throws {
        let _: EmptyResponse? = try await sendOptional(
            .delete,
            origin: origin,
            path: ["v1", "native-client"],
            headers: Self.apiBearer(clientToken)
        )
    }

    public func getWorkspacePreferences(at origin: URL, apiToken: String, workspaceID: String) async throws -> WorkspacePreferences {
        try await send(
            .get,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "preferences"],
            headers: Self.apiBearer(apiToken)
        )
    }

    public func putWorkspacePreferences(
        _ preferences: WorkspacePreferences,
        at origin: URL,
        apiToken: String,
        workspaceID: String
    ) async throws -> WorkspacePreferences {
        try await send(
            .put,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "preferences"],
            headers: Self.apiBearer(apiToken),
            body: try SessionJSON.encoder.encode(WorkspacePreferencesUpdate(preferences))
        )
    }

    public func createChromePairing(
        at origin: URL,
        apiToken: String,
        workspaceID: String,
        deviceName: String
    ) async throws -> ChromePairing {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "chrome-pairings"],
            headers: Self.apiBearer(apiToken),
            body: try SessionJSON.encoder.encode(ChromePairingRequest(deviceName: deviceName))
        )
    }

    public func listChromeHandoffs(
        at origin: URL,
        apiToken: String,
        workspaceID: String
    ) async throws -> [ChromeHandoff] {
        try await send(
            .get,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "chrome-handoffs"],
            headers: Self.apiBearer(apiToken)
        )
    }

    public func updateChromeHandoff(
        at origin: URL,
        apiToken: String,
        workspaceID: String,
        handoffID: String,
        state: String
    ) async throws -> ChromeHandoff {
        try await send(
            .put,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "chrome-handoffs", handoffID],
            headers: Self.apiBearer(apiToken),
            body: try SessionJSON.encoder.encode(ChromeHandoffUpdate(state: state))
        )
    }

    public func listChromeLibrary(
        at origin: URL,
        apiToken: String,
        workspaceID: String,
        kind: String
    ) async throws -> [ChromeLibraryItem] {
        try await send(
            .get,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "chrome-library"],
            queryItems: [URLQueryItem(name: "kind", value: kind)],
            headers: Self.apiBearer(apiToken)
        )
    }

    public func listChromeDevices(
        at origin: URL,
        apiToken: String,
        workspaceID: String
    ) async throws -> [ChromeDevice] {
        try await send(
            .get,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "chrome-devices"],
            headers: Self.apiBearer(apiToken)
        )
    }

    public func revokeChromeDevice(
        at origin: URL,
        apiToken: String,
        workspaceID: String,
        deviceID: String
    ) async throws {
        let _: EmptyResponse? = try await sendOptional(
            .delete,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "chrome-devices", deviceID],
            headers: Self.apiBearer(apiToken)
        )
    }

    public func getSession(at origin: URL, apiToken: String, sessionID: String) async throws -> BrowserSession {
        try await send(.get, origin: origin, path: ["v1", "sessions", sessionID], headers: Self.apiBearer(apiToken))
    }

    public func createSession(at origin: URL, apiToken: String, idempotencyKey: String) async throws -> BrowserSession {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "sessions"],
            headers: Self.apiBearer(apiToken).merging(["Idempotency-Key": idempotencyKey]) { _, new in new },
            body: try SessionJSON.encoder.encode(CreateSessionRequest(workspaceID: "default"))
        )
    }

    public func listActivitySpaces(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ActivitySpace] {
        try await send(.get, origin: origin, path: ["v1", "workspaces", workspaceID, "spaces"], headers: Self.apiBearer(apiToken))
    }

    public func createActivitySpace(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, name: String, expectedRevision: Int) async throws -> ActivitySpace {
        try await send(
            .post, origin: origin, path: ["v1", "workspaces", workspaceID, "spaces"],
            headers: Self.spaceHeaders(apiToken: apiToken, leaseToken: leaseToken, idempotencyKey: idempotencyKey),
            body: try SessionJSON.encoder.encode(ActivitySpaceCaptureRequest(name: name, sessionID: sessionID, expectedRevision: expectedRevision))
        )
    }

    public func parkActivitySpace(at origin: URL, apiToken: String, workspaceID: String, spaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, expectedRevision: Int) async throws -> ActivitySpace {
        try await send(
            .post, origin: origin, path: ["v1", "workspaces", workspaceID, "spaces", spaceID, "park"],
            headers: Self.spaceHeaders(apiToken: apiToken, leaseToken: leaseToken, idempotencyKey: idempotencyKey),
            body: try SessionJSON.encoder.encode(ActivitySpaceActionRequest(sessionID: sessionID, expectedRevision: expectedRevision))
        )
    }

    public func activateActivitySpace(at origin: URL, apiToken: String, workspaceID: String, spaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, expectedRevision: Int) async throws -> ActivitySpaceActivation {
        try await send(
            .post, origin: origin, path: ["v1", "workspaces", workspaceID, "spaces", spaceID, "activate"],
            headers: Self.spaceHeaders(apiToken: apiToken, leaseToken: leaseToken, idempotencyKey: idempotencyKey),
            body: try SessionJSON.encoder.encode(ActivitySpaceActionRequest(sessionID: sessionID, expectedRevision: expectedRevision))
        )
    }

    public func getContinuity(at origin: URL, apiToken: String, workspaceID: String) async throws -> ContinuityOverview {
        try await send(.get, origin: origin, path: ["v1", "workspaces", workspaceID, "continuity"], headers: Self.apiBearer(apiToken))
    }

    public func submitContinuity(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, verb: ContinuityVerb, adapter: ContinuityAdapter, expiresAt: Date, expectedRevision: Int, spaceID: String?, url: String?) async throws -> ContinuityIntentReceipt {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "workspaces", workspaceID, "continuity"],
            headers: Self.spaceHeaders(apiToken: apiToken, leaseToken: leaseToken, idempotencyKey: idempotencyKey),
            body: try SessionJSON.encoder.encode(ContinuityIntentRequest(verb: verb, adapter: adapter, sessionID: sessionID, expectedRevision: expectedRevision, expiresAt: expiresAt, spaceID: spaceID, url: url))
        )
    }

    public func listPeripheralGrants(at origin: URL, apiToken: String, workspaceID: String) async throws -> [PeripheralGrant] {
        try await send(.get, origin: origin, path: ["v1", "workspaces", workspaceID, "peripheral-grants"], headers: Self.apiBearer(apiToken))
    }

    public func createPeripheralGrant(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, leaseToken: String, idempotencyKey: String, capability: PeripheralCapability, peripheralOrigin: String, expiresAt: Date) async throws -> PeripheralGrant {
        try await send(
            .post, origin: origin, path: ["v1", "workspaces", workspaceID, "peripheral-grants"],
            headers: Self.spaceHeaders(apiToken: apiToken, leaseToken: leaseToken, idempotencyKey: idempotencyKey),
            body: try SessionJSON.encoder.encode(PeripheralGrantRequest(sessionID: sessionID, capability: capability, direction: capability.direction, origin: peripheralOrigin, expiresAt: expiresAt))
        )
    }

    public func revokePeripheralGrant(at origin: URL, apiToken: String, workspaceID: String, grantID: String) async throws -> PeripheralGrant {
        try await send(.delete, origin: origin, path: ["v1", "workspaces", workspaceID, "peripheral-grants", grantID], headers: Self.apiBearer(apiToken))
    }

    public func authorizePeripheral(at origin: URL, apiToken: String, workspaceID: String, sessionID: String, capability: PeripheralCapability, peripheralOrigin: String) async throws -> PeripheralAuthorization {
        try await send(
            .post, origin: origin, path: ["v1", "workspaces", workspaceID, "peripheral-authorizations"], headers: Self.apiBearer(apiToken),
            body: try SessionJSON.encoder.encode(PeripheralAuthorizationRequest(sessionID: sessionID, capability: capability, direction: capability.direction, origin: peripheralOrigin))
        )
    }

    public func listPeripheralAudit(at origin: URL, apiToken: String, workspaceID: String) async throws -> [PeripheralAuditEvent] {
        try await send(.get, origin: origin, path: ["v1", "workspaces", workspaceID, "peripheral-audit"], headers: Self.apiBearer(apiToken))
    }

    public func sessionEvents(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        afterRevision: Int,
        waitMilliseconds: Int
    ) async throws -> BrowserSession? {
        try await sendOptional(
            .get,
            origin: origin,
            path: ["v1", "sessions", sessionID, "events"],
            queryItems: [
                URLQueryItem(name: "after_revision", value: String(afterRevision)),
                URLQueryItem(name: "wait_ms", value: String(waitMilliseconds)),
            ],
            headers: Self.apiBearer(apiToken)
        )
    }

    public func acquireLease(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> ControllerLease {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "sessions", sessionID, "leases"],
            headers: Self.apiBearer(apiToken),
            body: try SessionJSON.encoder.encode(AcquireLeaseRequest(clientID: clientID))
        )
    }

    public func renewLease(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        leaseID: String,
        token: String
    ) async throws -> ControllerLease {
        try await send(
            .put,
            origin: origin,
            path: ["v1", "sessions", sessionID, "leases", leaseID],
            headers: Self.authorized(apiToken: apiToken, leaseToken: token),
            body: Data("{}".utf8)
        )
    }

    public func releaseLease(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        leaseID: String,
        token: String
    ) async throws {
        let _: EmptyResponse? = try await sendOptional(
            .delete,
            origin: origin,
            path: ["v1", "sessions", sessionID, "leases", leaseID],
            headers: Self.authorized(apiToken: apiToken, leaseToken: token)
        )
    }

    public func sendCommand(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        token: String,
        idempotencyKey: String,
        command: BrowserCommand
    ) async throws -> CommandReceipt {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "sessions", sessionID, "commands"],
            headers: [
                "Authorization": "Bearer \(apiToken)",
                "X-Ghostlight-Lease-Token": token,
                "Idempotency-Key": idempotencyKey,
            ],
            body: try SessionJSON.encoder.encode(command)
        )
    }

    public func uploadAttachment(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        token: String,
        fileURL: URL
    ) async throws -> Attachment {
        let boundary = "Ghostlight-\(UUID().uuidString)"
        let filename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await send(
            .post,
            origin: origin,
            path: ["v1", "sessions", sessionID, "attachments"],
            headers: [
                "Authorization": "Bearer \(apiToken)",
                "X-Ghostlight-Lease-Token": token,
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
            ],
            body: body,
            setJSONContentType: false
        )
    }

    public func createStream(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> StreamConnection {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "sessions", sessionID, "stream"],
            headers: Self.apiBearer(apiToken),
            body: try SessionJSON.encoder.encode(AcquireLeaseRequest(clientID: clientID))
        )
    }

    public func redeemViewerCapability(at origin: URL, capability: String, clientID: String) async throws -> ViewerBootstrap {
        try await send(
            .post,
            origin: origin,
            path: ["v1", "viewer-capabilities", "redeem"],
            headers: Self.apiBearer(capability),
            body: try SessionJSON.encoder.encode(AcquireLeaseRequest(clientID: clientID))
        )
    }

    private func send<T: Decodable>(
        _ method: HTTPMethod,
        origin: URL,
        path: [String],
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        setJSONContentType: Bool = true
    ) async throws -> T {
        guard let value: T = try await sendOptional(
            method,
            origin: origin,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body,
            setJSONContentType: setJSONContentType
        ) else {
            throw SessionClientError.invalidResponse
        }
        return value
    }

    private func sendOptional<T: Decodable>(
        _ method: HTTPMethod,
        origin: URL,
        path: [String],
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        setJSONContentType: Bool = true
    ) async throws -> T? {
        let validatedOrigin: URL
        do {
            validatedOrigin = try ControlPlaneURLValidator.validate(origin.absoluteString)
        } catch let error as ControlPlaneURLError {
            throw SessionClientError.invalidControlPlaneURL(error)
        }

        var endpoint = path.reduce(validatedOrigin) { $0.appendingPathComponent($1) }
        if !queryItems.isEmpty, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + queryItems
            endpoint = components.url ?? endpoint
        }
        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil, setJSONContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try SessionClientError.mapTransportError(error)
        }
        guard data.count <= Self.maximumResponseBytes,
              let http = response as? HTTPURLResponse else {
            throw SessionClientError.invalidResponse
        }
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionClientError.mapHTTPFailure(statusCode: http.statusCode, data: data)
        }
        do {
            return try SessionJSON.decoder.decode(T.self, from: data)
        } catch {
            throw SessionClientError.responseDecodingFailed
        }
    }

    private static func apiBearer(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    private static func authorized(apiToken: String, leaseToken: String) -> [String: String] {
        ["Authorization": "Bearer \(apiToken)", "X-Ghostlight-Lease-Token": leaseToken]
    }

    private static func spaceHeaders(apiToken: String, leaseToken: String, idempotencyKey: String) -> [String: String] {
        authorized(apiToken: apiToken, leaseToken: leaseToken).merging(["Idempotency-Key": idempotencyKey]) { _, new in new }
    }
}

private enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }
private struct NativeClientEnrollmentRequest: Encodable {
    let clientName: String
    enum CodingKeys: String, CodingKey { case clientName = "client_name" }
}
private struct CreateSessionRequest: Encodable { let workspaceID: String; enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" } }
private struct ActivitySpaceCaptureRequest: Encodable {
    let name: String
    let sessionID: String
    let expectedRevision: Int
    enum CodingKeys: String, CodingKey { case name; case sessionID = "session_id"; case expectedRevision = "expected_revision" }
}
private struct ActivitySpaceActionRequest: Encodable {
    let sessionID: String
    let expectedRevision: Int
    enum CodingKeys: String, CodingKey { case sessionID = "session_id"; case expectedRevision = "expected_revision" }
}
private struct ContinuityIntentRequest: Encodable {
    let verb: ContinuityVerb
    let adapter: ContinuityAdapter
    let sessionID: String
    let expectedRevision: Int
    let expiresAt: Date
    let spaceID: String?
    let url: String?
    enum CodingKeys: String, CodingKey {
        case verb, adapter, url
        case sessionID = "session_id"
        case expectedRevision = "expected_revision"
        case expiresAt = "expires_at"
        case spaceID = "space_id"
    }
}
private struct PeripheralGrantRequest: Encodable {
    let sessionID: String
    let capability: PeripheralCapability
    let direction: PeripheralDirection
    let origin: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case capability, direction, origin; case sessionID = "session_id"; case expiresAt = "expires_at" }
}
private struct PeripheralAuthorizationRequest: Encodable {
    let sessionID: String
    let capability: PeripheralCapability
    let direction: PeripheralDirection
    let origin: String
    enum CodingKeys: String, CodingKey { case capability, direction, origin; case sessionID = "session_id" }
}
private struct AcquireLeaseRequest: Encodable { let clientID: String; enum CodingKeys: String, CodingKey { case clientID = "client_id" } }
private struct ChromePairingRequest: Encodable { let deviceName: String; enum CodingKeys: String, CodingKey { case deviceName = "device_name" } }
private struct ChromeHandoffUpdate: Encodable { let state: String }
private struct WorkspacePreferencesUpdate: Encodable {
    let searchURL: String
    let shortcuts: [WorkspaceShortcut]
    let recentURLs: [String]

    init(_ preferences: WorkspacePreferences) {
        searchURL = preferences.searchURL
        shortcuts = preferences.shortcuts
        recentURLs = preferences.recentURLs
    }

    enum CodingKeys: String, CodingKey {
        case shortcuts
        case searchURL = "search_url"
        case recentURLs = "recent_urls"
    }
}
private struct EmptyResponse: Decodable {}
