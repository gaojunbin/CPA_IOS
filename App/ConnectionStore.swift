import Combine
import Foundation
import Security

struct SavedConnection: Equatable {
    let baseURL: URL
    let managementKey: String
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connection: SavedConnection?
    @Published private(set) var lastBaseURLString: String

    private let defaults = UserDefaults.standard
    private let baseURLKey = "cpa.baseURL"
    private let keychainService = "com.rootclaw.cpa-ios.management"
    private let keychainAccount = "management-key"

    init() {
        lastBaseURLString = defaults.string(forKey: baseURLKey) ?? ""
        let key = KeychainStore.read(service: keychainService, account: keychainAccount) ?? ""
        if let url = try? CPABaseURLNormalizer.normalize(lastBaseURLString), !key.isEmpty {
            connection = SavedConnection(baseURL: url, managementKey: key)
            lastBaseURLString = url.absoluteString
        }
    }

    func save(baseURLString: String, managementKey: String) throws {
        let normalizedURL = try CPABaseURLNormalizer.normalize(baseURLString)
        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ConnectionError.emptyManagementKey
        }
        try KeychainStore.save(trimmedKey, service: keychainService, account: keychainAccount)
        defaults.set(normalizedURL.absoluteString, forKey: baseURLKey)
        lastBaseURLString = normalizedURL.absoluteString
        connection = SavedConnection(baseURL: normalizedURL, managementKey: trimmedKey)
    }

    func clear() {
        KeychainStore.delete(service: keychainService, account: keychainAccount)
        defaults.removeObject(forKey: baseURLKey)
        lastBaseURLString = ""
        connection = nil
    }

    func makeClient() -> CPAClient? {
        guard let connection else {
            return nil
        }
        return CPAClient(baseURL: connection.baseURL, managementKey: connection.managementKey)
    }
}

enum ConnectionError: LocalizedError {
    case emptyManagementKey

    var errorDescription: String? {
        switch self {
        case .emptyManagementKey:
            return "请输入管理密钥"
        }
    }
}

enum KeychainStore {
    static func save(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error, LocalizedError {
    case invalidData
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "管理密钥无法保存"
        case let .unhandled(status):
            return "钥匙串写入失败: \(status)"
        }
    }
}
