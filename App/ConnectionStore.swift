import Combine
import Foundation
import Security

struct SavedConnection: Equatable, Sendable {
    let baseURL: URL
    let managementKey: String
    let refreshIntervalSeconds: TimeInterval
    let quotaAlertsEnabled: Bool
    let quotaAlertThreshold: Double
    let quotaAlertShowsAccountNames: Bool

    static let preview = SavedConnection(
        baseURL: URL(string: "https://demo.cpa.local") ?? URL(fileURLWithPath: "/"),
        managementKey: "",
        refreshIntervalSeconds: 300,
        quotaAlertsEnabled: false,
        quotaAlertThreshold: 15,
        quotaAlertShowsAccountNames: false
    )
}

enum ConnectionStorage {
    static let baseURLKey = "cpa.baseURL"
    static let refreshIntervalKey = "cpa.refreshIntervalSeconds"
    static let quotaAlertsEnabledKey = "cpa.quotaAlertsEnabled"
    static let quotaAlertThresholdKey = "cpa.quotaAlertThreshold"
    static let quotaAlertShowsAccountNamesKey = "cpa.quotaAlertShowsAccountNames"
    static let keychainService = "com.rootclaw.cpa-ios.management"
    static let keychainAccount = "management-key"

    static func loadSavedConnection(defaults: UserDefaults = .standard) -> SavedConnection? {
        let baseURLString = defaults.string(forKey: baseURLKey) ?? ""
        let key = KeychainStore.read(service: keychainService, account: keychainAccount) ?? ""
        guard let url = try? CPABaseURLNormalizer.normalize(baseURLString), !key.isEmpty else {
            return nil
        }
        return SavedConnection(
            baseURL: url,
            managementKey: key,
            refreshIntervalSeconds: storedRefreshInterval(defaults: defaults),
            quotaAlertsEnabled: storedQuotaAlertsEnabled(defaults: defaults),
            quotaAlertThreshold: storedQuotaAlertThreshold(defaults: defaults),
            quotaAlertShowsAccountNames: storedQuotaAlertShowsAccountNames(defaults: defaults)
        )
    }

    static func normalizedRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        max(60, min(value, 86_400))
    }

    static func normalizedQuotaAlertThreshold(_ value: Double) -> Double {
        max(1, min(value.rounded(), 50))
    }

    static func storedRefreshInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: refreshIntervalKey)
        return normalizedRefreshInterval(value > 0 ? value : 300)
    }

    static func storedQuotaAlertsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: quotaAlertsEnabledKey)
    }

    static func storedQuotaAlertThreshold(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: quotaAlertThresholdKey)
        return normalizedQuotaAlertThreshold(value > 0 ? value : 15)
    }

    static func storedQuotaAlertShowsAccountNames(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: quotaAlertShowsAccountNamesKey)
    }

    static func disableQuotaAlerts(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: quotaAlertsEnabledKey)
        defaults.set(false, forKey: quotaAlertShowsAccountNamesKey)
    }
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connection: SavedConnection?
    @Published private(set) var lastBaseURLString: String

    private let defaults = UserDefaults.standard

    init() {
        lastBaseURLString = defaults.string(forKey: ConnectionStorage.baseURLKey) ?? ""
        if let savedConnection = Self.loadSavedConnectionFromStorage() {
            connection = savedConnection
            lastBaseURLString = savedConnection.baseURL.absoluteString
        }
        QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: connection?.quotaAlertsEnabled == true)
        Task {
            await reconcileQuotaAlertAuthorization()
        }
    }

    var refreshIntervalSeconds: TimeInterval {
        connection?.refreshIntervalSeconds ?? storedRefreshInterval
    }

    var quotaAlertsEnabled: Bool {
        connection?.quotaAlertsEnabled ?? storedQuotaAlertsEnabled
    }

    var quotaAlertThreshold: Double {
        connection?.quotaAlertThreshold ?? storedQuotaAlertThreshold
    }

    var quotaAlertShowsAccountNames: Bool {
        connection?.quotaAlertShowsAccountNames ?? storedQuotaAlertShowsAccountNames
    }

    func save(
        baseURLString: String,
        managementKey: String,
        refreshIntervalSeconds: TimeInterval? = nil,
        quotaAlertsEnabled: Bool? = nil,
        quotaAlertThreshold: Double? = nil,
        quotaAlertShowsAccountNames: Bool? = nil
    ) throws {
        let normalizedURL = try CPABaseURLNormalizer.normalize(baseURLString)
        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ConnectionError.emptyManagementKey
        }
        let previousConnection = connection
        let previousAlertSettings = (
            enabled: self.quotaAlertsEnabled,
            threshold: self.quotaAlertThreshold,
            showsAccountNames: self.quotaAlertShowsAccountNames
        )
        let hasExistingConnection = connection != nil
        let interval = ConnectionStorage.normalizedRefreshInterval(refreshIntervalSeconds ?? self.refreshIntervalSeconds)
        let alertsEnabled = quotaAlertsEnabled ?? (hasExistingConnection ? self.quotaAlertsEnabled : false)
        let alertThreshold = ConnectionStorage.normalizedQuotaAlertThreshold(quotaAlertThreshold ?? self.quotaAlertThreshold)
        let requestedShowAccountNames = quotaAlertShowsAccountNames ?? (hasExistingConnection ? self.quotaAlertShowsAccountNames : false)
        let showAccountNames = alertsEnabled ? requestedShowAccountNames : false
        try KeychainStore.save(trimmedKey, service: ConnectionStorage.keychainService, account: ConnectionStorage.keychainAccount)
        defaults.set(normalizedURL.absoluteString, forKey: ConnectionStorage.baseURLKey)
        defaults.set(interval, forKey: ConnectionStorage.refreshIntervalKey)
        defaults.set(alertsEnabled, forKey: ConnectionStorage.quotaAlertsEnabledKey)
        defaults.set(alertThreshold, forKey: ConnectionStorage.quotaAlertThresholdKey)
        defaults.set(showAccountNames, forKey: ConnectionStorage.quotaAlertShowsAccountNamesKey)
        if shouldResetAlertHistory(
            previousConnection: previousConnection,
            previousAlertSettings: previousAlertSettings,
            newBaseURL: normalizedURL,
            newManagementKey: trimmedKey,
            newAlertsEnabled: alertsEnabled,
            newAlertThreshold: alertThreshold,
            newShowsAccountNames: showAccountNames
        ) {
            QuotaAlertNotifier.resetAlertHistory()
        }
        lastBaseURLString = normalizedURL.absoluteString
        let savedConnection = SavedConnection(
            baseURL: normalizedURL,
            managementKey: trimmedKey,
            refreshIntervalSeconds: interval,
            quotaAlertsEnabled: alertsEnabled,
            quotaAlertThreshold: alertThreshold,
            quotaAlertShowsAccountNames: showAccountNames
        )
        connection = savedConnection
        #if os(iOS)
        BackgroundQuotaRefreshScheduler.reschedule(for: savedConnection)
        #endif
    }

    func clear() {
        KeychainStore.delete(service: ConnectionStorage.keychainService, account: ConnectionStorage.keychainAccount)
        defaults.removeObject(forKey: ConnectionStorage.baseURLKey)
        defaults.removeObject(forKey: ConnectionStorage.refreshIntervalKey)
        defaults.removeObject(forKey: ConnectionStorage.quotaAlertsEnabledKey)
        defaults.removeObject(forKey: ConnectionStorage.quotaAlertThresholdKey)
        defaults.removeObject(forKey: ConnectionStorage.quotaAlertShowsAccountNamesKey)
        QuotaAlertNotifier.resetAlertHistory()
        lastBaseURLString = ""
        connection = nil
        #if os(iOS)
        BackgroundQuotaRefreshScheduler.cancel()
        #endif
    }

    @discardableResult
    func reconcileQuotaAlertAuthorization() async -> Bool {
        guard connection != nil else {
            if quotaAlertsEnabled {
                disableQuotaAlertsAfterPermissionLoss()
                return true
            }
            QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: false)
            #if os(iOS)
            BackgroundQuotaRefreshScheduler.cancel()
            #endif
            return false
        }
        guard quotaAlertsEnabled else {
            QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: false)
            #if os(iOS)
            BackgroundQuotaRefreshScheduler.cancel()
            #endif
            return false
        }
        guard await QuotaAlertNotifier.canSendAlerts() else {
            disableQuotaAlertsAfterPermissionLoss()
            return true
        }
        QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: true)
        return false
    }

    func makeClient() -> CPAClient? {
        guard let connection else {
            return nil
        }
        return CPAClient(baseURL: connection.baseURL, managementKey: connection.managementKey)
    }

    nonisolated static func loadSavedConnectionFromStorage() -> SavedConnection? {
        ConnectionStorage.loadSavedConnection()
    }

    private var storedRefreshInterval: TimeInterval {
        ConnectionStorage.storedRefreshInterval(defaults: defaults)
    }

    private var storedQuotaAlertsEnabled: Bool {
        ConnectionStorage.storedQuotaAlertsEnabled(defaults: defaults)
    }

    private var storedQuotaAlertThreshold: Double {
        ConnectionStorage.storedQuotaAlertThreshold(defaults: defaults)
    }

    private var storedQuotaAlertShowsAccountNames: Bool {
        ConnectionStorage.storedQuotaAlertShowsAccountNames(defaults: defaults)
    }

    private func shouldResetAlertHistory(
        previousConnection: SavedConnection?,
        previousAlertSettings: (enabled: Bool, threshold: Double, showsAccountNames: Bool),
        newBaseURL: URL,
        newManagementKey: String,
        newAlertsEnabled: Bool,
        newAlertThreshold: Double,
        newShowsAccountNames: Bool
    ) -> Bool {
        if !newAlertsEnabled {
            return true
        }
        guard let previousConnection else {
            return true
        }
        return previousConnection.baseURL != newBaseURL ||
            previousConnection.managementKey != newManagementKey ||
            previousAlertSettings.enabled != newAlertsEnabled ||
            previousAlertSettings.threshold != newAlertThreshold ||
            previousAlertSettings.showsAccountNames != newShowsAccountNames
    }

    private func disableQuotaAlertsAfterPermissionLoss() {
        guard quotaAlertsEnabled else {
            return
        }
        ConnectionStorage.disableQuotaAlerts(defaults: defaults)
        QuotaAlertNotifier.resetAlertHistory()
        guard let current = connection else {
            #if os(iOS)
            BackgroundQuotaRefreshScheduler.cancel()
            #endif
            return
        }
        let savedConnection = SavedConnection(
            baseURL: current.baseURL,
            managementKey: current.managementKey,
            refreshIntervalSeconds: current.refreshIntervalSeconds,
            quotaAlertsEnabled: false,
            quotaAlertThreshold: current.quotaAlertThreshold,
            quotaAlertShowsAccountNames: false
        )
        connection = savedConnection
        #if os(iOS)
        BackgroundQuotaRefreshScheduler.reschedule(for: savedConnection)
        #endif
    }
}

enum ConnectionError: LocalizedError {
    case emptyManagementKey
    case notificationPermissionDenied

    var errorDescription: String? {
        switch self {
        case .emptyManagementKey:
            return "请输入管理密钥"
        case .notificationPermissionDenied:
            return "请允许通知后再开启低额度提醒"
        }
    }
}

enum KeychainStore {
    static func save(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(updateStatus)
        }

        var addQuery = query
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(addStatus)
        }
    }

    static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
