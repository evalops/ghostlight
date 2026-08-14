import Foundation
import Security

struct NativeClientCredentialKey: Equatable, Hashable, Sendable {
    static let serviceName = "org.evalops.Ghostlight.native-client"

    let service: String
    let account: String

    init(origin: URL, clientID: String) {
        service = Self.serviceName
        account = "\(Self.canonicalOrigin(origin))\n\(clientID)"
    }

    private static func canonicalOrigin(_ origin: URL) -> String {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return origin.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? origin.absoluteString
    }
}

enum NativeClientCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidToken
    case invalidStoredCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The native client credential is empty."
        case .invalidStoredCredential:
            "The saved native client credential is invalid."
        case .keychain:
            "The native client credential could not be accessed in Keychain."
        }
    }
}

protocol NativeClientCredentialStoring: Sendable {
    func clientToken(for origin: URL, clientID: String) throws -> String?
    func storeClientToken(_ token: String, for origin: URL, clientID: String) throws
    func removeClientToken(for origin: URL, clientID: String) throws
}

final class KeychainNativeClientCredentialStore: NativeClientCredentialStoring, @unchecked Sendable {
    func clientToken(for origin: URL, clientID: String) throws -> String? {
        let key = NativeClientCredentialKey(origin: origin, clientID: clientID)
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NativeClientCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw NativeClientCredentialStoreError.invalidStoredCredential
        }
        return token
    }

    func storeClientToken(_ token: String, for origin: URL, clientID: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw NativeClientCredentialStoreError.invalidToken }
        let key = NativeClientCredentialKey(origin: origin, clientID: clientID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NativeClientCredentialStoreError.keychain(updateStatus)
        }
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NativeClientCredentialStoreError.keychain(addStatus)
        }
    }

    func removeClientToken(for origin: URL, clientID: String) throws {
        let key = NativeClientCredentialKey(origin: origin, clientID: clientID)
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeClientCredentialStoreError.keychain(status)
        }
    }
}
