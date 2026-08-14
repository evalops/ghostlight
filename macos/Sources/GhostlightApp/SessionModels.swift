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

public struct NativeClientEnrollment: Codable, Equatable, Sendable {
    public let pairingCapability: String
    public let clientName: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case pairingCapability = "pairing_capability"
        case clientName = "client_name"
        case expiresAt = "expires_at"
    }
}

public struct NativeClient: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let scope: String
    public let createdAt: Date
    public let lastSeenAt: Date
    public let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, scope
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at"
    }
}

public struct NativeClientCredential: Codable, Equatable, Sendable {
    public let client: NativeClient
    public let clientToken: String

    enum CodingKeys: String, CodingKey {
        case client
        case clientToken = "client_token"
    }
}

public struct WorkspaceShortcut: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var url: String
    public var position: Int

    public init(id: String, name: String, url: String, position: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.position = position
    }
}

public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public static let defaultSearchURL = "https://www.google.com/search?q={query}"
    public static let maximumRecentURLCount = 20

    public let workspaceID: String
    public var searchURL: String
    public var shortcuts: [WorkspaceShortcut]
    public var recentURLs: [String]
    public var updatedAt: Date

    public init(
        workspaceID: String,
        searchURL: String,
        shortcuts: [WorkspaceShortcut],
        recentURLs: [String],
        updatedAt: Date
    ) {
        self.workspaceID = workspaceID
        self.searchURL = searchURL
        self.shortcuts = shortcuts
        self.recentURLs = recentURLs
        self.updatedAt = updatedAt
    }

    public static func isValidSearchURLTemplate(_ value: String) -> Bool {
        guard value.count <= 500,
              value.components(separatedBy: "{query}").count == 2 else { return false }
        let target = value.replacingOccurrences(of: "{query}", with: "test")
        guard let components = URLComponents(string: target),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    static func safeRecentURL(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return nil }

        let sensitiveNames: Set<String> = [
            "accesstoken", "apikey", "auth", "authorization", "code", "cookie",
            "credential", "idtoken", "key", "password", "passwd", "secret",
            "session", "sessionid", "signature", "sig", "token",
            "xamzcredential", "xamzsecuritytoken", "xamzsignature",
            "xgoogcredential", "xgoogsecuritytoken", "xgoogsignature",
        ]
        let normalizedName: (String) -> String = {
            String($0.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let isSensitiveName: (String) -> Bool = {
            let name = normalizedName($0)
            return sensitiveNames.contains(name) || name.hasSuffix("token") || name.hasSuffix("password")
        }
        guard !(components.queryItems ?? []).contains(where: { isSensitiveName($0.name) }) else {
            return nil
        }
        return components.url?.absoluteString
    }

    static func sanitizedRecentURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap(safeRecentURL).filter { seen.insert($0).inserted }
    }

    enum CodingKeys: String, CodingKey {
        case shortcuts
        case workspaceID = "workspace_id"
        case searchURL = "search_url"
        case recentURLs = "recent_urls"
        case updatedAt = "updated_at"
    }
}

public struct ActivitySpaceTab: Codable, Equatable, Sendable {
    public let url: String
    public let position: Int
}

public struct ActivitySpace: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let name: String
    public let state: String
    public let revision: Int
    public let tabs: [ActivitySpaceTab]
    public let activePosition: Int
    public let homePreferencesWorkspaceID: String
    public let pendingHandoffIDs: [String]
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, state, revision, tabs
        case workspaceID = "workspace_id"
        case activePosition = "active_position"
        case homePreferencesWorkspaceID = "home_preferences_workspace_id"
        case pendingHandoffIDs = "pending_handoff_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct ActivitySpaceActivation: Codable, Equatable, Sendable {
    public let space: ActivitySpace
    public let command: CommandReceipt
}

public struct ContinuityBrowse: Codable, Equatable, Sendable {
    public let authority: String
    public let bookmarks: [ChromeLibraryItem]
    public let readingList: [ChromeLibraryItem]

    enum CodingKeys: String, CodingKey {
        case authority, bookmarks
        case readingList = "reading_list"
    }
}

public struct ContinuityOverview: Codable, Equatable, Sendable {
    public let resume: [ActivitySpace]
    public let browse: ContinuityBrowse
    public let send: [ChromeHandoff]
    public let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case resume, browse, send
        case generatedAt = "generated_at"
    }
}

public enum ContinuityVerb: String, Codable, Sendable {
    case resume
    case send
}

public enum ContinuityAdapter: String, Codable, Sendable {
    case nativeUI = "native_ui"
    case urlHandler = "url_handler"
    case share
    case chromeExtension = "chrome_extension"
}

public struct ContinuityIntentReceipt: Codable, Equatable, Sendable {
    public let verb: ContinuityVerb
    public let adapter: ContinuityAdapter
    public let authority: String
    public let expiresAt: Date
    public let space: ActivitySpace?
    public let command: CommandReceipt

    enum CodingKeys: String, CodingKey {
        case verb, adapter, authority, space, command
        case expiresAt = "expires_at"
    }
}

public struct ChromePairing: Codable, Equatable, Sendable {
    public let pairingCode: String
    public let workspaceID: String
    public let deviceName: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case workspaceID = "workspace_id"
        case deviceName = "device_name"
        case expiresAt = "expires_at"
    }
}

public struct ChromeHandoff: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let deviceID: String
    public let deviceName: String
    public let title: String?
    public let url: String
    public let state: String
    public let createdAt: Date
    public let updatedAt: Date
    public let groupID: String?
    public let position: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, url, state, position
        case workspaceID = "workspace_id"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case groupID = "group_id"
    }
}

public struct ChromeLibraryItem: Codable, Equatable, Sendable, Identifiable {
    public let kind: String
    public let externalID: String
    public let parentExternalID: String?
    public let title: String?
    public let url: String?
    public let position: Int
    public let read: Bool
    public let deviceID: String
    public let deviceName: String

    public var id: String { "\(deviceID):\(kind):\(externalID)" }

    enum CodingKeys: String, CodingKey {
        case kind, title, url, position, read
        case externalID = "external_id"
        case parentExternalID = "parent_external_id"
        case deviceID = "device_id"
        case deviceName = "device_name"
    }
}

public struct ChromeDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let name: String
    public let scope: String
    public let createdAt: Date
    public let lastSeenAt: Date
    public let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, scope
        case workspaceID = "workspace_id"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at"
    }
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
    public let capability: String?

    public init(id: String, url: URL, state: String, expiresAt: Date, capability: String? = nil) {
        self.id = id
        self.url = url
        self.state = state
        self.expiresAt = expiresAt
        self.capability = capability
    }

    enum CodingKeys: String, CodingKey {
        case id, url, state, capability
        case expiresAt = "expires_at"
    }
}

public struct ViewerBootstrap: Codable, Equatable, Sendable {
    public let streamID: String
    public let viewerURL: URL
    public let viewerCredential: ViewerCredential
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case viewerURL = "viewer_url"
        case viewerCredential = "viewer_credential"
        case expiresAt = "expires_at"
    }
}

public struct ViewerCredential: Codable, Equatable, Sendable {
    public let type: String
    public let name: String?
    public let value: String
    public let path: String?
    public let secure: Bool?
    public let httpOnly: Bool?
    public let sameSite: String?
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case type, name, value, path, secure
        case httpOnly = "http_only"
        case sameSite = "same_site"
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
    case restoreSpace = "restore_space"
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
    public let continuityVerb: ContinuityVerb?
    public let continuityAdapter: ContinuityAdapter?
    public let continuityExpiresAt: Date?
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
        continuityVerb: ContinuityVerb? = nil,
        continuityAdapter: ContinuityAdapter? = nil,
        continuityExpiresAt: Date? = nil,
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
        self.continuityVerb = continuityVerb
        self.continuityAdapter = continuityAdapter
        self.continuityExpiresAt = continuityExpiresAt
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
        case continuityVerb = "continuity_verb"
        case continuityAdapter = "continuity_adapter"
        case continuityExpiresAt = "continuity_expires_at"
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
