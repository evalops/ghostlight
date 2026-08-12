import Foundation

public enum ControlPlaneURLError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case malformed
    case unsupportedScheme
    case missingHost
    case credentialsNotAllowed

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a control-plane URL."
        case .malformed:
            "The control-plane URL is not valid."
        case .unsupportedScheme:
            "The control-plane URL must use HTTP or HTTPS."
        case .missingHost:
            "The control-plane URL must include a host."
        case .credentialsNotAllowed:
            "The control-plane URL cannot include embedded credentials."
        }
    }
}

public enum ControlPlaneURLValidator {
    public static func validate(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ControlPlaneURLError.empty
        }

        guard let url = URL(string: value) else {
            throw ControlPlaneURLError.malformed
        }

        guard let scheme = url.scheme?.lowercased() else {
            throw ControlPlaneURLError.malformed
        }

        guard scheme == "http" || scheme == "https" else {
            throw ControlPlaneURLError.unsupportedScheme
        }

        guard let host = url.host, !host.isEmpty else {
            throw ControlPlaneURLError.missingHost
        }

        guard url.user == nil && url.password == nil else {
            throw ControlPlaneURLError.credentialsNotAllowed
        }

        return url
    }
}
