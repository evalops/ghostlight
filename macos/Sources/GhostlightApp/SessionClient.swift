import Foundation

public enum SessionClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidControlPlaneURL(ControlPlaneURLError)
    case networkUnavailable
    case requestTimedOut
    case transportFailure
    case server(statusCode: Int, message: String?)
    case invalidResponse
    case responseDecodingFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidControlPlaneURL(error): error.localizedDescription
        case .networkUnavailable: "The control plane could not be reached."
        case .requestTimedOut: "The control-plane request timed out."
        case .transportFailure: "The control-plane request failed."
        case let .server(statusCode, message):
            message.map { "HTTP \(statusCode): \($0)" } ?? "HTTP \(statusCode)."
        case .invalidResponse: "The control plane returned an invalid response."
        case .responseDecodingFailed: "The control plane returned an unsupported response."
        }
    }

    public var statusCode: Int? {
        guard case let .server(statusCode, _) = self else { return nil }
        return statusCode
    }

    static func mapHTTPFailure(statusCode: Int, data: Data) -> SessionClientError {
        let payload = try? SessionJSON.decoder.decode(APIErrorPayload.self, from: data)
        return .server(statusCode: statusCode, message: payload?.bestMessage)
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
    func getSession(at origin: URL, apiToken: String, sessionID: String) async throws -> BrowserSession
    func createSession(at origin: URL, apiToken: String, idempotencyKey: String) async throws -> BrowserSession
    func sessionEvents(at origin: URL, apiToken: String, sessionID: String, afterRevision: Int) async throws -> BrowserSession?
    func acquireLease(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> ControllerLease
    func renewLease(at origin: URL, apiToken: String, sessionID: String, leaseID: String, token: String) async throws -> ControllerLease
    func releaseLease(at origin: URL, apiToken: String, sessionID: String, leaseID: String, token: String) async throws
    func sendCommand(at origin: URL, apiToken: String, sessionID: String, token: String, idempotencyKey: String, command: BrowserCommand) async throws -> CommandReceipt
    func uploadAttachment(at origin: URL, apiToken: String, sessionID: String, token: String, fileURL: URL) async throws -> Attachment
    func createStream(at origin: URL, apiToken: String, sessionID: String) async throws -> StreamConnection
}

public final class SessionClient: SessionServicing, @unchecked Sendable {
    static let requestTimeout: TimeInterval = 15
    static let maximumResponseBytes = 1024 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func listWorkspaces(at origin: URL, apiToken: String) async throws -> [Workspace] {
        try await send(.get, origin: origin, path: ["v1", "workspaces"], headers: Self.apiBearer(apiToken))
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

    public func sessionEvents(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        afterRevision: Int
    ) async throws -> BrowserSession? {
        try await sendOptional(
            .get,
            origin: origin,
            path: ["v1", "sessions", sessionID, "events"],
            queryItems: [URLQueryItem(name: "after_revision", value: String(afterRevision))],
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

    public func createStream(at origin: URL, apiToken: String, sessionID: String) async throws -> StreamConnection {
        try await send(.post, origin: origin, path: ["v1", "sessions", sessionID, "stream"], headers: Self.apiBearer(apiToken))
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
}

private enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }
private struct CreateSessionRequest: Encodable { let workspaceID: String; enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" } }
private struct AcquireLeaseRequest: Encodable { let clientID: String; enum CodingKeys: String, CodingKey { case clientID = "client_id" } }
private struct EmptyResponse: Decodable {}
