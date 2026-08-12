import Foundation

public enum SessionClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidControlPlaneURL(ControlPlaneURLError)
    case networkUnavailable
    case requestTimedOut
    case transportFailure
    case server(statusCode: Int, message: String?)
    case invalidResponse
    case responseDecodingFailed
    case invalidViewerURL

    public var errorDescription: String? {
        switch self {
        case let .invalidControlPlaneURL(error):
            error.localizedDescription
        case .networkUnavailable:
            "The control plane could not be reached. Check the URL and network connection."
        case .requestTimedOut:
            "The control-plane request timed out."
        case .transportFailure:
            "The control-plane request failed before a response was received."
        case let .server(statusCode, message):
            if let message, !message.isEmpty {
                "The control plane returned HTTP \(statusCode): \(message)"
            } else {
                "The control plane returned HTTP \(statusCode)."
            }
        case .invalidResponse:
            "The control plane returned an invalid response."
        case .responseDecodingFailed:
            "The control plane response did not contain a valid viewer URL."
        case .invalidViewerURL:
            "The control plane returned an unsupported viewer URL."
        }
    }

    public static func mapHTTPFailure(statusCode: Int, data: Data) -> SessionClientError {
        let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
        return .server(statusCode: statusCode, message: payload?.bestMessage)
    }

    public static func mapTransportError(_ error: Error) -> SessionClientError {
        guard let urlError = error as? URLError else {
            return .transportFailure
        }

        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed:
            return .networkUnavailable
        case .timedOut:
            return .requestTimedOut
        default:
            return .transportFailure
        }
    }
}

public final class SessionClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func createSession(controlPlaneURL rawValue: String) async throws -> CreateSessionResponse {
        do {
            let baseURL = try ControlPlaneURLValidator.validate(rawValue)
            return try await createSession(at: baseURL)
        } catch let error as ControlPlaneURLError {
            throw SessionClientError.invalidControlPlaneURL(error)
        }
    }

    public func createSession(at baseURL: URL) async throws -> CreateSessionResponse {
        let validatedBaseURL: URL
        do {
            validatedBaseURL = try ControlPlaneURLValidator.validate(baseURL.absoluteString)
        } catch let error as ControlPlaneURLError {
            throw SessionClientError.invalidControlPlaneURL(error)
        }

        var request = URLRequest(
            url: validatedBaseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("sessions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CreateSessionRequest())

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SessionClientError.mapTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SessionClientError.mapHTTPFailure(statusCode: httpResponse.statusCode, data: data)
        }

        let sessionResponse: CreateSessionResponse
        do {
            sessionResponse = try decoder.decode(CreateSessionResponse.self, from: data)
        } catch {
            throw SessionClientError.responseDecodingFailed
        }

        guard (try? ControlPlaneURLValidator.validate(sessionResponse.viewerURL.absoluteString)) != nil else {
            throw SessionClientError.invalidViewerURL
        }

        return sessionResponse
    }
}
