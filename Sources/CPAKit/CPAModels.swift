import Foundation

public struct ManagementDashboard: Equatable {
    public let accounts: [CPAAccount]
    public let apiKeyUsage: [APIKeyUsageRecord]
    public let quotaSwitchProject: Bool?
    public let quotaSwitchPreviewModel: Bool?
    public let serverVersion: String?
    public let serverCommit: String?
    public let fetchedAt: Date

    public init(
        accounts: [CPAAccount],
        apiKeyUsage: [APIKeyUsageRecord] = [],
        quotaSwitchProject: Bool? = nil,
        quotaSwitchPreviewModel: Bool? = nil,
        serverVersion: String? = nil,
        serverCommit: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.accounts = accounts
        self.apiKeyUsage = apiKeyUsage
        self.quotaSwitchProject = quotaSwitchProject
        self.quotaSwitchPreviewModel = quotaSwitchPreviewModel
        self.serverVersion = serverVersion
        self.serverCommit = serverCommit
        self.fetchedAt = fetchedAt
    }
}

public struct AuthFilesResponse: Decodable, Equatable {
    public let files: [CPAAccount]
}

public struct ModelsResponse: Decodable, Equatable {
    public let models: [CPAModelDefinition]
}

public struct CPAModelDefinition: Decodable, Identifiable, Equatable {
    public let id: String
    public let displayName: String?
    public let type: String?
    public let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case type
        case ownedBy = "owned_by"
    }
}

public struct CPAAccount: Decodable, Identifiable, Equatable {
    public let id: String
    public let authIndex: String?
    public let name: String
    public let type: String?
    public let provider: String?
    public let label: String?
    public let status: String?
    public let statusMessage: String?
    public let disabled: Bool
    public let unavailable: Bool
    public let runtimeOnly: Bool
    public let source: String?
    public let size: Int64?
    public let success: Int64
    public let failed: Int64
    public let recentRequests: [RecentRequestBucket]
    public let email: String?
    public let projectID: String?
    public let accountType: String?
    public let account: String?
    public let path: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let modifiedAt: Date?
    public let lastRefresh: Date?
    public let nextRetryAfter: Date?
    public let nextRefreshAfter: Date?
    public let quota: QuotaState?
    public let modelStates: [String: ModelState]
    public let lastError: ProviderError?
    public let idToken: CodexIDTokenClaims?
    public let antigravityCredits: AntigravityCredits?
    public let priority: Int?
    public let note: String?
    public let websockets: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case authIndex = "auth_index"
        case name
        case type
        case provider
        case label
        case status
        case statusMessage = "status_message"
        case disabled
        case unavailable
        case runtimeOnly = "runtime_only"
        case source
        case size
        case success
        case failed
        case recentRequests = "recent_requests"
        case email
        case projectID = "project_id"
        case accountType = "account_type"
        case account
        case path
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case modifiedAt = "modtime"
        case lastRefresh = "last_refresh"
        case nextRetryAfter = "next_retry_after"
        case nextRefreshAfter = "next_refresh_after"
        case quota
        case modelStates = "model_states"
        case lastError = "last_error"
        case idToken = "id_token"
        case antigravityCredits = "antigravity_credits"
        case priority
        case note
        case websockets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        type = try container.decodeIfPresent(String.self, forKey: .type)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try container.decodeFlexibleBoolIfPresent(forKey: .disabled) ?? false
        unavailable = try container.decodeFlexibleBoolIfPresent(forKey: .unavailable) ?? false
        runtimeOnly = try container.decodeFlexibleBoolIfPresent(forKey: .runtimeOnly) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source)
        size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
        success = try container.decodeFlexibleInt64IfPresent(forKey: .success) ?? 0
        failed = try container.decodeFlexibleInt64IfPresent(forKey: .failed) ?? 0
        recentRequests = try container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequests) ?? []
        email = try container.decodeIfPresent(String.self, forKey: .email)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        createdAt = try container.decodeFlexibleDateIfPresent(forKey: .createdAt)
        updatedAt = try container.decodeFlexibleDateIfPresent(forKey: .updatedAt)
        modifiedAt = try container.decodeFlexibleDateIfPresent(forKey: .modifiedAt)
        lastRefresh = try container.decodeFlexibleDateIfPresent(forKey: .lastRefresh)
        nextRetryAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfter)
        nextRefreshAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRefreshAfter)
        quota = try container.decodeIfPresent(QuotaState.self, forKey: .quota)
        modelStates = try container.decodeIfPresent([String: ModelState].self, forKey: .modelStates) ?? [:]
        lastError = try container.decodeIfPresent(ProviderError.self, forKey: .lastError)
        idToken = try container.decodeIfPresent(CodexIDTokenClaims.self, forKey: .idToken)
        antigravityCredits = try container.decodeIfPresent(AntigravityCredits.self, forKey: .antigravityCredits)
        priority = try container.decodeFlexibleIntIfPresent(forKey: .priority)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        websockets = try container.decodeFlexibleBoolIfPresent(forKey: .websockets)
    }
}

public struct RecentRequestBucket: Decodable, Identifiable, Equatable {
    public var id: String { time }
    public let time: String
    public let success: Int64
    public let failed: Int64

    enum CodingKeys: String, CodingKey {
        case time
        case success
        case failed
    }

    public init(time: String, success: Int64, failed: Int64) {
        self.time = time
        self.success = success
        self.failed = failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decodeIfPresent(String.self, forKey: .time) ?? ""
        success = try container.decodeFlexibleInt64IfPresent(forKey: .success) ?? 0
        failed = try container.decodeFlexibleInt64IfPresent(forKey: .failed) ?? 0
    }
}

public struct QuotaState: Decodable, Equatable {
    public let exceeded: Bool
    public let reason: String?
    public let nextRecoverAt: Date?
    public let backoffLevel: Int?

    enum CodingKeys: String, CodingKey {
        case exceeded
        case reason
        case nextRecoverAt = "next_recover_at"
        case backoffLevel = "backoff_level"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exceeded = try container.decodeFlexibleBoolIfPresent(forKey: .exceeded) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        nextRecoverAt = try container.decodeFlexibleDateIfPresent(forKey: .nextRecoverAt)
        backoffLevel = try container.decodeFlexibleIntIfPresent(forKey: .backoffLevel)
    }
}

public struct ModelState: Decodable, Equatable {
    public let status: String?
    public let statusMessage: String?
    public let unavailable: Bool
    public let nextRetryAfter: Date?
    public let lastError: ProviderError?
    public let quota: QuotaState?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case status
        case statusMessage = "status_message"
        case unavailable
        case nextRetryAfter = "next_retry_after"
        case lastError = "last_error"
        case quota
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        unavailable = try container.decodeFlexibleBoolIfPresent(forKey: .unavailable) ?? false
        nextRetryAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfter)
        lastError = try container.decodeIfPresent(ProviderError.self, forKey: .lastError)
        quota = try container.decodeIfPresent(QuotaState.self, forKey: .quota)
        updatedAt = try container.decodeFlexibleDateIfPresent(forKey: .updatedAt)
    }
}

public struct ProviderError: Decodable, Equatable {
    public let code: String?
    public let message: String
    public let retryable: Bool
    public let httpStatus: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case httpStatus = "http_status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        retryable = try container.decodeFlexibleBoolIfPresent(forKey: .retryable) ?? false
        httpStatus = try container.decodeFlexibleIntIfPresent(forKey: .httpStatus)
    }
}

public struct CodexIDTokenClaims: Decodable, Equatable {
    public let chatgptAccountID: String?
    public let planType: String?
    public let subscriptionActiveStart: Date?
    public let subscriptionActiveUntil: Date?

    enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case planType = "plan_type"
        case subscriptionActiveStart = "chatgpt_subscription_active_start"
        case subscriptionActiveUntil = "chatgpt_subscription_active_until"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatgptAccountID = try container.decodeIfPresent(String.self, forKey: .chatgptAccountID)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        subscriptionActiveStart = try container.decodeFlexibleDateIfPresent(forKey: .subscriptionActiveStart)
        subscriptionActiveUntil = try container.decodeFlexibleDateIfPresent(forKey: .subscriptionActiveUntil)
    }
}

public struct AntigravityCredits: Decodable, Equatable {
    public let known: Bool
    public let available: Bool
    public let creditAmount: Double?
    public let minCreditAmount: Double?
    public let paidTierID: String?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case known
        case available
        case creditAmount = "credit_amount"
        case minCreditAmount = "min_credit_amount"
        case paidTierID = "paid_tier_id"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        known = try container.decodeFlexibleBoolIfPresent(forKey: .known) ?? false
        available = try container.decodeFlexibleBoolIfPresent(forKey: .available) ?? false
        creditAmount = try container.decodeFlexibleDoubleIfPresent(forKey: .creditAmount)
        minCreditAmount = try container.decodeFlexibleDoubleIfPresent(forKey: .minCreditAmount)
        paidTierID = try container.decodeIfPresent(String.self, forKey: .paidTierID)
        updatedAt = try container.decodeFlexibleDateIfPresent(forKey: .updatedAt)
    }
}

public struct APIKeyUsageEntry: Decodable, Equatable {
    public let success: Int64
    public let failed: Int64
    public let recentRequests: [RecentRequestBucket]

    enum CodingKeys: String, CodingKey {
        case success
        case failed
        case recentRequests = "recent_requests"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeFlexibleInt64IfPresent(forKey: .success) ?? 0
        failed = try container.decodeFlexibleInt64IfPresent(forKey: .failed) ?? 0
        recentRequests = try container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequests) ?? []
    }
}

public struct APIKeyUsageRecord: Identifiable, Equatable {
    public let id: String
    public let provider: String
    public let baseURL: String
    public let apiKey: String
    public let success: Int64
    public let failed: Int64
    public let recentRequests: [RecentRequestBucket]

    public var maskedAPIKey: String {
        guard apiKey.count > 10 else {
            return apiKey.isEmpty ? "未命名 Key" : apiKey
        }
        return "\(apiKey.prefix(6))...\(apiKey.suffix(4))"
    }
}

public struct BooleanValueResponse: Decodable, Equatable {
    public let value: Bool?
    public let switchProject: Bool?
    public let switchPreviewModel: Bool?

    enum CodingKeys: String, CodingKey {
        case value
        case switchProject = "switch-project"
        case switchPreviewModel = "switch-preview-model"
    }
}

public extension CPAAccount {
    var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return label
        }
        if let email, !email.isEmpty {
            return email
        }
        return name
    }

    var providerName: String {
        let value = provider ?? type ?? "unknown"
        return value.isEmpty ? "unknown" : value
    }

    var totalRequests: Int64 {
        success + failed
    }

    var failedRate: Double {
        guard totalRequests > 0 else {
            return 0
        }
        return Double(failed) / Double(totalRequests)
    }

    var nextRecoveryDate: Date? {
        let candidates = [
            quota?.nextRecoverAt,
            nextRetryAfter,
            modelStates.values.compactMap(\.nextRetryAfter).min()
        ].compactMap { $0 }
        return candidates.min()
    }

    var activeModelCooldowns: [(model: String, state: ModelState)] {
        modelStates
            .filter { _, state in
                state.unavailable || state.quota?.exceeded == true || state.nextRetryAfter != nil
            }
            .sorted { lhs, rhs in lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending }
            .map { (model: $0.key, state: $0.value) }
    }

    var statusKind: CPAStatusKind {
        if disabled {
            return .disabled
        }
        if let antigravityCredits, antigravityCredits.known, !antigravityCredits.available {
            return .cooling
        }
        if quota?.exceeded == true || unavailable || nextRecoveryDate != nil {
            return .cooling
        }
        switch status?.lowercased() {
        case "active":
            return .available
        case "refreshing", "pending":
            return .pending
        case "error":
            return .error
        case "disabled":
            return .disabled
        default:
            return totalRequests == 0 ? .unknown : .available
        }
    }
}

public enum CPAStatusKind: String, CaseIterable, Identifiable {
    case all
    case available
    case cooling
    case pending
    case error
    case disabled
    case unknown

    public var id: String { rawValue }
}

public enum APIKeyUsageParser {
    public static func flatten(_ response: [String: [String: APIKeyUsageEntry]]) -> [APIKeyUsageRecord] {
        response.flatMap { provider, entries in
            entries.map { compositeKey, entry in
                let parts = compositeKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let baseURL = parts.first.map(String.init) ?? ""
                let apiKey = parts.count > 1 ? String(parts[1]) : compositeKey
                return APIKeyUsageRecord(
                    id: "\(provider)|\(compositeKey)",
                    provider: provider,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    success: entry.success,
                    failed: entry.failed,
                    recentRequests: entry.recentRequests
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.provider != rhs.provider {
                return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
            }
            return lhs.maskedAPIKey.localizedCaseInsensitiveCompare(rhs.maskedAPIKey) == .orderedAscending
        }
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(Date.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return FlexibleDateParser.parse(value)
        }
        if let value = try? decode(Double.self, forKey: key), value > 0 {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }

    func decodeFlexibleBoolIfPresent(forKey key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value != 0
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

public enum FlexibleDateParser {
    public static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0001-01-01T00:00:00Z" else {
            return nil
        }
        let iso8601WithFractionalSeconds = ISO8601DateFormatter()
        iso8601WithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601WithFractionalSeconds.date(from: trimmed) {
            return date
        }

        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: trimmed) {
            return date
        }
        if let unix = TimeInterval(trimmed) {
            return Date(timeIntervalSince1970: unix)
        }
        return nil
    }
}
