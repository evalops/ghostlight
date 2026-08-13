import Foundation

enum SessionJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct Workspace: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

public struct BrowserTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var url: String
    public var active: Bool
    public var loading: Bool
    public var faviconURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, url, active, loading
        case faviconURL = "favicon_url"
    }
}

public struct StreamConnection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let state: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, url, state
        case expiresAt = "expires_at"
    }
}

public struct BrowserSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var workspaceID: String
    public var name: String
    public var revision: Int
    public var runtimeState: String
    public var tabs: [BrowserTab]
    public var activeTabID: String?
    public var controller: ControllerLease?
    public var stream: StreamConnection?
    public var commandReceipts: [CommandReceipt]
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, revision, tabs, controller, stream
        case workspaceID = "workspace_id"
        case runtimeState = "runtime_state"
        case activeTabID = "active_tab_id"
        case commandReceipts = "command_receipts"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        name = try container.decode(String.self, forKey: .name)
        revision = try container.decode(Int.self, forKey: .revision)
        runtimeState = try container.decode(String.self, forKey: .runtimeState)
        tabs = try container.decode([BrowserTab].self, forKey: .tabs)
        activeTabID = try container.decodeIfPresent(String.self, forKey: .activeTabID)
        controller = try container.decodeIfPresent(ControllerLease.self, forKey: .controller)
        stream = try container.decodeIfPresent(StreamConnection.self, forKey: .stream)
        commandReceipts = try container.decodeIfPresent([CommandReceipt].self, forKey: .commandReceipts) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct ControllerLease: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let clientID: String
    public let token: String?
    public let epoch: Int
    public let expiresAt: Date
    public let renewAfter: Date

    enum CodingKeys: String, CodingKey {
        case id, token, epoch
        case sessionID = "session_id"
        case clientID = "client_id"
        case expiresAt = "expires_at"
        case renewAfter = "renew_after"
    }
}

public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let contentType: String?
    public let size: Int?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, filename, size
        case contentType = "content_type"
        case createdAt = "created_at"
    }
}

public enum BrowserCommandType: String, Codable, Sendable {
    case navigate
    case goBack = "back"
    case goForward = "forward"
    case reload
    case newTab = "create_tab"
    case closeTab = "close_tab"
    case activateTab = "activate_tab"
    case attach = "stage_attachment"
}

public struct BrowserCommand: Codable, Equatable, Sendable {
    public let type: BrowserCommandType
    public let tabID: String?
    public let url: String?
    public let attachmentID: String?
    public let expectedRevision: Int

    public init(
        type: BrowserCommandType,
        tabID: String? = nil,
        url: String? = nil,
        attachmentID: String? = nil,
        expectedRevision: Int
    ) {
        self.type = type
        self.tabID = tabID
        self.url = url
        self.attachmentID = attachmentID
        self.expectedRevision = expectedRevision
    }

    enum CodingKeys: String, CodingKey {
        case type, url
        case tabID = "tab_id"
        case attachmentID = "attachment_id"
        case expectedRevision = "expected_revision"
    }
}

public enum CommandReceiptState: String, Codable, Equatable, Sendable {
    case queued
    case applied
    case failed
}

public struct CommandReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sequence: Int
    public let sessionID: String
    public let type: BrowserCommandType
    public let url: String?
    public let tabID: String?
    public let attachmentID: String?
    public let expectedRevision: Int
    public let leaseEpoch: Int
    public let state: CommandReceiptState
    public let errorCode: String?
    public let error: String?
    public let result: JSONValue?
    public let resultingRevision: Int?
    public let acknowledgedAt: Date?
    public let completedAt: Date?
    public let createdAt: Date

    public init(
        id: String,
        sequence: Int,
        sessionID: String,
        type: BrowserCommandType,
        url: String?,
        tabID: String?,
        attachmentID: String?,
        expectedRevision: Int,
        leaseEpoch: Int,
        state: CommandReceiptState,
        errorCode: String?,
        error: String?,
        result: JSONValue?,
        resultingRevision: Int?,
        acknowledgedAt: Date?,
        completedAt: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.sequence = sequence
        self.sessionID = sessionID
        self.type = type
        self.url = url
        self.tabID = tabID
        self.attachmentID = attachmentID
        self.expectedRevision = expectedRevision
        self.leaseEpoch = leaseEpoch
        self.state = state
        self.errorCode = errorCode
        self.error = error
        self.result = result
        self.resultingRevision = resultingRevision
        self.acknowledgedAt = acknowledgedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, sequence, type, url, state, error, result
        case sessionID = "session_id"
        case tabID = "tab_id"
        case attachmentID = "attachment_id"
        case expectedRevision = "expected_revision"
        case leaseEpoch = "lease_epoch"
        case errorCode = "error_code"
        case resultingRevision = "resulting_revision"
        case acknowledgedAt = "acknowledged_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct APIErrorPayload: Decodable {
    let message: String?
    let detail: String?
    let error: APIErrorDetail?

    var bestMessage: String? { message ?? error?.message ?? detail }
}

struct APIErrorDetail: Decodable {
    let code: String?
    let message: String?
}
