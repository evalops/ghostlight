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
    let detail: String?
    let error: APIErrorDetail?

    var bestMessage: String? {
        message ?? error?.message ?? detail
    }
}

struct APIErrorDetail: Decodable {
    let code: String?
    let message: String?
}
