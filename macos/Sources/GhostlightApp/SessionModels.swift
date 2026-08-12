import Foundation

public struct CreateSessionRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct CreateSessionResponse: Codable, Equatable, Sendable {
    public let viewerURL: URL

    public init(viewerURL: URL) {
        self.viewerURL = viewerURL
    }

    private enum CodingKeys: String, CodingKey {
        case viewerURL = "viewer_url"
    }
}

struct APIErrorPayload: Decodable {
    let message: String?
    let error: String?
    let detail: String?

    var bestMessage: String? {
        message ?? error ?? detail
    }
}
