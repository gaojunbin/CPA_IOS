import Combine
import Foundation
import Security

/// A fully-resolved connection to a single CLIProxyAPI service ("号池"), including the
/// management key read from the Keychain. This is the runtime value the dashboard,
/// view model, background refresh and quota alerts operate on.
struct SavedConnection: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let baseURL: URL
    let managementKey: String
    let refreshIntervalSeconds: TimeInterval
    let quotaAlertsEnabled: Bool
    let quotaAlertThreshold: Double
    let quotaAlertShowsAccountNames: Bool

    /// Stable host label used in the dashboard header.
    var displayHost: String {
        baseURL.host ?? baseURL.absoluteString
    }

    static let preview = SavedConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000DE") ?? UUID(),
        name: "演示服务",
        baseURL: URL(string: "https://demo.cpa.local") ?? URL(fileURLWithPath: "/"),
        managementKey: "",
        refreshIntervalSeconds: 300,
        quotaAlertsEnabled: false,
        quotaAlertThreshold: 15,
        quotaAlertShowsAccountNames: false
    )
}

/// Persisted metadata for one service. The management key is stored separately in the
/// Keychain, keyed by `id`, and is never part of this struct (so the profile list can be
/// JSON-encoded into UserDefaults without leaking secrets).
struct ServiceProfile: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var baseURLString: String
    var refreshIntervalSeconds: TimeInterval
    var quotaAlertsEnabled: Bool
    var quotaAlertThreshold: Double
    var quotaAlertShowsAccountNames: Bool

    init(
        id: UUID = UUID(),
        name: String,
        baseURLString: String,
        refreshIntervalSeconds: TimeInterval = 300,
        quotaAlertsEnabled: Bool = false,
        quotaAlertThreshold: Double = 15,
        quotaAlertShowsAccountNames: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.quotaAlertsEnabled = quotaAlertsEnabled
        self.quotaAlertThreshold = quotaAlertThreshold
        self.quotaAlertShowsAccountNames = quotaAlertShowsAccountNames
    }

    var displayHost: String {
        (try? CPABaseURLNormalizer.normalize(baseURLString))?.host ?? baseURLString
    }
}

/// Persistence layer for the service list. Nonisolated so the background refresh task can
/// read the selected service without hopping to the main actor.
enum ConnectionStorage {
    static let servicesKey = "cpa.services.v1"
    static let selectedIDKey = "cpa.services.selectedID"
    static let keychainService = "com.rootclaw.cpa-ios.management"

    // Legacy single-connection storage, migrated into a profile on first launch.
    static let legacyBaseURLKey = "cpa.baseURL"
    static let legacyRefreshIntervalKey = "cpa.refreshIntervalSeconds"
    static let legacyQuotaAlertsEnabledKey = "cpa.quotaAlertsEnabled"
    static let legacyQuotaAlertThresholdKey = "cpa.quotaAlertThreshold"
    static let legacyQuotaAlertShowsAccountNamesKey = "cpa.quotaAlertShowsAccountNames"
    static let legacyKeychainAccount = "management-key"

    static func normalizedRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        max(60, min(value, 86_400))
    }

    static func normalizedQuotaAlertThreshold(_ value: Double) -> Double {
        max(1, min(value.rounded(), 50))
    }

    // MARK: Profiles

    static func loadProfiles(defaults: UserDefaults = .standard) -> [ServiceProfile] {
        migrateLegacyIfNeeded(defaults: defaults)
        guard let data = defaults.data(forKey: servicesKey),
              let profiles = try? JSONDecoder().decode([ServiceProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func saveProfiles(_ profiles: [ServiceProfile], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        defaults.set(data, forKey: servicesKey)
    }

    static func selectedID(defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: selectedIDKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func setSelectedID(_ id: UUID?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id.uuidString, forKey: selectedIDKey)
        } else {
            defaults.removeObject(forKey: selectedIDKey)
        }
    }

    // MARK: Keychain (one entry per profile)

    static func managementKey(for id: UUID) -> String? {
        KeychainStore.read(service: keychainService, account: id.uuidString)
    }

    static func saveManagementKey(_ value: String, for id: UUID) throws {
        try KeychainStore.save(value, service: keychainService, account: id.uuidString)
    }

    static func deleteManagementKey(for id: UUID) {
        KeychainStore.delete(service: keychainService, account: id.uuidString)
    }

    // MARK: Resolve

    static func connection(for profile: ServiceProfile, defaults: UserDefaults = .standard) -> SavedConnection? {
        guard let url = try? CPABaseURLNormalizer.normalize(profile.baseURLString),
              let key = managementKey(for: profile.id), !key.isEmpty else {
            return nil
        }
        return SavedConnection(
            id: profile.id,
            name: profile.name,
            baseURL: url,
            managementKey: key,
            refreshIntervalSeconds: normalizedRefreshInterval(profile.refreshIntervalSeconds),
            quotaAlertsEnabled: profile.quotaAlertsEnabled,
            quotaAlertThreshold: normalizedQuotaAlertThreshold(profile.quotaAlertThreshold),
            quotaAlertShowsAccountNames: profile.quotaAlertsEnabled ? profile.quotaAlertShowsAccountNames : false
        )
    }

    /// The currently-selected service, fully resolved. Used by the background refresh task.
    static func loadSelectedConnection(defaults: UserDefaults = .standard) -> SavedConnection? {
        let profiles = loadProfiles(defaults: defaults)
        let selected = selectedID(defaults: defaults)
        guard let profile = profiles.first(where: { $0.id == selected }) ?? profiles.first else {
            return nil
        }
        return connection(for: profile, defaults: defaults)
    }

    /// Disables low-quota alerts on the selected profile (called when notification
    /// permission is revoked). Active-service-only monitoring, so only the selection matters.
    static func disableQuotaAlertsForSelected(defaults: UserDefaults = .standard) {
        guard let selected = selectedID(defaults: defaults) else {
            return
        }
        var profiles = loadProfiles(defaults: defaults)
        guard let index = profiles.firstIndex(where: { $0.id == selected }) else {
            return
        }
        profiles[index].quotaAlertsEnabled = false
        profiles[index].quotaAlertShowsAccountNames = false
        saveProfiles(profiles, defaults: defaults)
    }

    // MARK: Migration

    /// Converts a pre-multi-service install (single baseURL + keychain key) into one profile.
    /// Idempotent: once `servicesKey` exists this is a no-op.
    static func migrateLegacyIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.data(forKey: servicesKey) == nil else {
            return
        }
        let legacyURL = (defaults.string(forKey: legacyBaseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyKey = KeychainStore.read(service: keychainService, account: legacyKeychainAccount) ?? ""
        guard !legacyURL.isEmpty, !legacyKey.isEmpty,
              let normalized = try? CPABaseURLNormalizer.normalize(legacyURL) else {
            // Nothing usable to migrate; mark migration done with an empty list.
            saveProfiles([], defaults: defaults)
            return
        }

        let storedInterval = defaults.double(forKey: legacyRefreshIntervalKey)
        let storedThreshold = defaults.double(forKey: legacyQuotaAlertThresholdKey)
        let profile = ServiceProfile(
            name: normalized.host ?? normalized.absoluteString,
            baseURLString: normalized.absoluteString,
            refreshIntervalSeconds: normalizedRefreshInterval(storedInterval > 0 ? storedInterval : 300),
            quotaAlertsEnabled: defaults.bool(forKey: legacyQuotaAlertsEnabledKey),
            quotaAlertThreshold: normalizedQuotaAlertThreshold(storedThreshold > 0 ? storedThreshold : 15),
            quotaAlertShowsAccountNames: defaults.bool(forKey: legacyQuotaAlertShowsAccountNamesKey)
        )

        // Persist the new layout first; only then retire the legacy entries.
        do {
            try saveManagementKey(legacyKey, for: profile.id)
        } catch {
            // If the Keychain write fails, leave legacy data intact and retry next launch.
            return
        }
        saveProfiles([profile], defaults: defaults)
        setSelectedID(profile.id, defaults: defaults)

        KeychainStore.delete(service: keychainService, account: legacyKeychainAccount)
        for key in [
            legacyBaseURLKey,
            legacyRefreshIntervalKey,
            legacyQuotaAlertsEnabledKey,
            legacyQuotaAlertThresholdKey,
            legacyQuotaAlertShowsAccountNamesKey
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var profiles: [ServiceProfile]
    @Published private(set) var selectedID: UUID?
    /// The selected service resolved with its Keychain key. Stable so SwiftUI `.task(id:)`
    /// re-fires only when the selection or its fields actually change.
    @Published private(set) var connection: SavedConnection?
    @Published private(set) var lastBaseURLString: String

    private let defaults = UserDefaults.standard

    init() {
        // Use a local `defaults` so the closures below don't capture `self` before every
        // stored property is initialized (Swift definite-initialization requirement).
        let defaults = UserDefaults.standard
        let loadedProfiles = ConnectionStorage.loadProfiles(defaults: defaults)
        var selected = ConnectionStorage.selectedID(defaults: defaults)
        if selected == nil || !loadedProfiles.contains(where: { $0.id == selected }) {
            selected = loadedProfiles.first?.id
            ConnectionStorage.setSelectedID(selected, defaults: defaults)
        }
        let resolved = loadedProfiles.first(where: { $0.id == selected }).flatMap {
            ConnectionStorage.connection(for: $0, defaults: defaults)
        }
        profiles = loadedProfiles
        selectedID = selected
        connection = resolved
        lastBaseURLString = resolved?.baseURL.absoluteString ?? ""

        QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: resolved?.quotaAlertsEnabled == true)
        Task {
            await reconcileQuotaAlertAuthorization()
        }
    }

    // MARK: Derived

    var hasProfiles: Bool {
        !profiles.isEmpty
    }

    var selectedProfile: ServiceProfile? {
        profiles.first { $0.id == selectedID }
    }

    var refreshIntervalSeconds: TimeInterval {
        connection?.refreshIntervalSeconds ?? 300
    }

    var quotaAlertsEnabled: Bool {
        connection?.quotaAlertsEnabled ?? false
    }

    var quotaAlertThreshold: Double {
        connection?.quotaAlertThreshold ?? 15
    }

    var quotaAlertShowsAccountNames: Bool {
        connection?.quotaAlertShowsAccountNames ?? false
    }

    /// Resolves any profile (not just the selected one) — used by the editor's "set current".
    func managementKey(for id: UUID) -> String? {
        ConnectionStorage.managementKey(for: id)
    }

    // MARK: Mutations

    func selectProfile(_ id: UUID) {
        guard id != selectedID, profiles.contains(where: { $0.id == id }) else {
            return
        }
        selectedID = id
        ConnectionStorage.setSelectedID(id, defaults: defaults)
        // Active-service-only monitoring: clear the previous service's alert history so the
        // newly selected service starts clean, then re-arm background refresh for it.
        QuotaAlertNotifier.resetAlertHistory()
        refreshSelectedConnection()
        afterSelectionChange()
    }

    @discardableResult
    func addProfile(
        name: String,
        baseURLString: String,
        managementKey: String,
        refreshIntervalSeconds: TimeInterval? = nil,
        quotaAlertsEnabled: Bool = false,
        quotaAlertThreshold: Double = 15,
        quotaAlertShowsAccountNames: Bool = false
    ) throws -> UUID {
        let normalizedURL = try CPABaseURLNormalizer.normalize(baseURLString)
        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ConnectionError.emptyManagementKey
        }
        let alertsEnabled = quotaAlertsEnabled
        let profile = ServiceProfile(
            name: resolvedName(name, for: normalizedURL),
            baseURLString: normalizedURL.absoluteString,
            refreshIntervalSeconds: ConnectionStorage.normalizedRefreshInterval(refreshIntervalSeconds ?? 300),
            quotaAlertsEnabled: alertsEnabled,
            quotaAlertThreshold: ConnectionStorage.normalizedQuotaAlertThreshold(quotaAlertThreshold),
            quotaAlertShowsAccountNames: alertsEnabled ? quotaAlertShowsAccountNames : false
        )
        try ConnectionStorage.saveManagementKey(trimmedKey, for: profile.id)
        profiles.append(profile)
        persistProfiles()
        lastBaseURLString = normalizedURL.absoluteString

        // The very first service becomes the active one so the dashboard opens immediately.
        if selectedID == nil {
            selectedID = profile.id
            ConnectionStorage.setSelectedID(profile.id, defaults: defaults)
            QuotaAlertNotifier.resetAlertHistory()
            refreshSelectedConnection()
            afterSelectionChange()
        }
        return profile.id
    }

    func updateProfile(
        id: UUID,
        name: String,
        baseURLString: String,
        managementKey: String?,
        refreshIntervalSeconds: TimeInterval,
        quotaAlertsEnabled: Bool,
        quotaAlertThreshold: Double,
        quotaAlertShowsAccountNames: Bool
    ) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ConnectionError.profileNotFound
        }
        let normalizedURL = try CPABaseURLNormalizer.normalize(baseURLString)
        if let provided = managementKey?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
            try ConnectionStorage.saveManagementKey(provided, for: id)
        } else if ConnectionStorage.managementKey(for: id)?.isEmpty != false {
            throw ConnectionError.emptyManagementKey
        }

        let alertsEnabled = quotaAlertsEnabled
        var profile = profiles[index]
        profile.name = resolvedName(name, for: normalizedURL)
        profile.baseURLString = normalizedURL.absoluteString
        profile.refreshIntervalSeconds = ConnectionStorage.normalizedRefreshInterval(refreshIntervalSeconds)
        profile.quotaAlertsEnabled = alertsEnabled
        profile.quotaAlertThreshold = ConnectionStorage.normalizedQuotaAlertThreshold(quotaAlertThreshold)
        profile.quotaAlertShowsAccountNames = alertsEnabled ? quotaAlertShowsAccountNames : false
        profiles[index] = profile
        persistProfiles()

        if id == selectedID {
            // Editing the active service can change its URL/key/threshold; reset alert history
            // so stale notifications don't survive across the change.
            QuotaAlertNotifier.resetAlertHistory()
            refreshSelectedConnection()
            afterSelectionChange()
        }
    }

    func removeProfile(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasSelected = (id == selectedID)
        ConnectionStorage.deleteManagementKey(for: id)
        profiles.remove(at: index)
        persistProfiles()

        if wasSelected {
            selectedID = profiles.first?.id
            ConnectionStorage.setSelectedID(selectedID, defaults: defaults)
            QuotaAlertNotifier.resetAlertHistory()
            refreshSelectedConnection()
            afterSelectionChange()
        }
    }

    func moveProfiles(fromOffsets: IndexSet, toOffset: Int) {
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistProfiles()
    }

    /// Clears every service. Kept for parity with the old single-connection "clear".
    func clear() {
        for profile in profiles {
            ConnectionStorage.deleteManagementKey(for: profile.id)
        }
        profiles = []
        selectedID = nil
        persistProfiles()
        ConnectionStorage.setSelectedID(nil, defaults: defaults)
        QuotaAlertNotifier.resetAlertHistory()
        connection = nil
        lastBaseURLString = ""
        #if os(iOS)
        BackgroundQuotaRefreshScheduler.cancel()
        #endif
    }

    // MARK: Quota alert authorization

    @discardableResult
    func reconcileQuotaAlertAuthorization() async -> Bool {
        guard let current = connection else {
            QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: false)
            #if os(iOS)
            BackgroundQuotaRefreshScheduler.cancel()
            #endif
            return false
        }
        guard current.quotaAlertsEnabled else {
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
        ConnectionStorage.loadSelectedConnection()
    }

    // MARK: Private

    private func persistProfiles() {
        ConnectionStorage.saveProfiles(profiles, defaults: defaults)
    }

    private func refreshSelectedConnection() {
        if let profile = selectedProfile {
            connection = ConnectionStorage.connection(for: profile, defaults: defaults)
        } else {
            connection = nil
        }
        if let urlString = connection?.baseURL.absoluteString {
            lastBaseURLString = urlString
        }
    }

    /// Re-arms background refresh + badge state for whatever is currently selected.
    private func afterSelectionChange() {
        let current = connection
        QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: current?.quotaAlertsEnabled == true)
        #if os(iOS)
        BackgroundQuotaRefreshScheduler.reschedule(for: current)
        #endif
        Task {
            await reconcileQuotaAlertAuthorization()
        }
    }

    private func resolvedName(_ name: String, for url: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return url.host ?? url.absoluteString
    }

    private func disableQuotaAlertsAfterPermissionLoss() {
        guard let id = selectedID,
              let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].quotaAlertsEnabled else {
            QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: false)
            #if os(iOS)
            BackgroundQuotaRefreshScheduler.cancel()
            #endif
            return
        }
        profiles[index].quotaAlertsEnabled = false
        profiles[index].quotaAlertShowsAccountNames = false
        persistProfiles()
        QuotaAlertNotifier.resetAlertHistory()
        refreshSelectedConnection()
        #if os(iOS)
        BackgroundQuotaRefreshScheduler.reschedule(for: connection)
        #endif
    }
}

enum ConnectionError: LocalizedError {
    case emptyManagementKey
    case notificationPermissionDenied
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .emptyManagementKey:
            return "请输入管理密钥"
        case .notificationPermissionDenied:
            return "请允许通知后再开启低额度提醒"
        case .profileNotFound:
            return "未找到该服务"
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
