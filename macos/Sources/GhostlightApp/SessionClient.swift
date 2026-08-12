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

    public static func mapTransportError(_ error: Error) throws -> SessionClientError {
        guard let urlError = error as? URLError else {
            return .transportFailure
        }

        switch urlError.code {
        case .cancelled:
            throw CancellationError()
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

protocol ViewerDiscovering {
    func discoverViewer(controlPlaneURL: String) async throws -> ViewerDiscoveryResponse
}

public final class SessionClient: ViewerDiscovering {
    static let discoveryRequestTimeout: TimeInterval = 10
    static let maxDiscoveryResponseBytes = 16 * 1024

    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func discoverViewer(controlPlaneURL rawValue: String) async throws -> ViewerDiscoveryResponse {
        do {
            let baseURL = try ControlPlaneURLValidator.validate(rawValue)
            return try await discoverViewer(atValidatedBaseURL: baseURL)
        } catch let error as ControlPlaneURLError {
            throw SessionClientError.invalidControlPlaneURL(error)
        }
    }

    public func discoverViewer(at baseURL: URL) async throws -> ViewerDiscoveryResponse {
        let validatedBaseURL: URL
        do {
            validatedBaseURL = try ControlPlaneURLValidator.validate(baseURL.absoluteString)
        } catch let error as ControlPlaneURLError {
            throw SessionClientError.invalidControlPlaneURL(error)
        }

        return try await discoverViewer(atValidatedBaseURL: validatedBaseURL)
    }

    private func discoverViewer(atValidatedBaseURL validatedBaseURL: URL) async throws -> ViewerDiscoveryResponse {
        var request = URLRequest(
            url: validatedBaseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("viewer")
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.discoveryRequestTimeout

        let data: Data
        let response: URLResponse
        do {
            // Read the body with a hard cap so a misbehaving control plane
            // cannot buffer an unbounded response in memory; the cap covers
            // both the success payload and any error body fed to the decoder.
            let (bytes, urlResponse) = try await session.bytes(for: request)
            response = urlResponse
            data = try await Self.readBoundedBody(from: bytes, limit: Self.maxDiscoveryResponseBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SessionClientError {
            throw error
        } catch {
            throw try SessionClientError.mapTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SessionClientError.mapHTTPFailure(statusCode: httpResponse.statusCode, data: data)
        }

        let discoveryResponse: ViewerDiscoveryResponse
        do {
            discoveryResponse = try decoder.decode(ViewerDiscoveryResponse.self, from: data)
        } catch {
            throw SessionClientError.responseDecodingFailed
        }

        guard (try? ControlPlaneURLValidator.validate(discoveryResponse.viewerURL.absoluteString)) != nil else {
            throw SessionClientError.invalidViewerURL
        }

        return discoveryResponse
    }

    private static func readBoundedBody(
        from bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else {
                throw SessionClientError.invalidResponse
            }
        }
        return data
    }
}
