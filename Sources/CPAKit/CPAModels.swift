import Foundation

public struct ManagementDashboard: Equatable, Sendable {
    public let accounts: [CPAAccount]
    public let accountQuotas: [AccountQuota]
    public let apiKeyUsage: [APIKeyUsageRecord]
    public let quotaSwitchProject: Bool?
    public let quotaSwitchPreviewModel: Bool?
    public let serverVersion: String?
    public let serverCommit: String?
    public let serverBuildDate: String?
    public let fetchedAt: Date

    public init(
        accounts: [CPAAccount],
        accountQuotas: [AccountQuota]? = nil,
        apiKeyUsage: [APIKeyUsageRecord] = [],
        quotaSwitchProject: Bool? = nil,
        quotaSwitchPreviewModel: Bool? = nil,
        serverVersion: String? = nil,
        serverCommit: String? = nil,
        serverBuildDate: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.accounts = accounts
        self.accountQuotas = accountQuotas ?? accounts.map { AccountQuota(account: $0, usage: nil, errorMessage: nil) }
        self.apiKeyUsage = apiKeyUsage
        self.quotaSwitchProject = quotaSwitchProject
        self.quotaSwitchPreviewModel = quotaSwitchPreviewModel
        self.serverVersion = serverVersion
        self.serverCommit = serverCommit
        self.serverBuildDate = serverBuildDate
        self.fetchedAt = fetchedAt
    }

    public func replacingAccountQuota(_ quota: AccountQuota) -> ManagementDashboard {
        var values = accountQuotas
        let replacementKey = Self.accountKey(for: quota.account)
        let keyMatches = values.indices.filter { Self.accountKey(for: values[$0].account) == replacementKey }
        if keyMatches.count == 1, let index = keyMatches.first {
            values[index] = quota
        } else if values.filter({ $0.id == quota.id }).count == 1,
                  let index = values.firstIndex(where: { $0.id == quota.id }),
                  Self.canReplaceByID(current: values[index].account, replacement: quota.account) {
            values[index] = quota
        } else {
            return self
        }
        return ManagementDashboard(
            accounts: accounts,
            accountQuotas: values,
            apiKeyUsage: apiKeyUsage,
            quotaSwitchProject: quotaSwitchProject,
            quotaSwitchPreviewModel: quotaSwitchPreviewModel,
            serverVersion: serverVersion,
            serverCommit: serverCommit,
            serverBuildDate: serverBuildDate,
            fetchedAt: fetchedAt
        )
    }

    public func preservingLiveUsage(from previous: ManagementDashboard?) -> ManagementDashboard {
        guard let previous else {
            return self
        }
        let previousQuotasByAccountKey = previous.quotaByAccountKey()
        let previousQuotas = previous.quotaByID()
        let mergedQuotas = accounts.map { account -> AccountQuota in
            let accountKey = Self.accountKey(for: account)
            let previousQuota: AccountQuota?
            if let quota = previousQuotasByAccountKey[accountKey] {
                previousQuota = quota
            } else if let quota = previousQuotas[account.id],
                      Self.canReplaceByID(current: account, replacement: quota.account) {
                previousQuota = quota
            } else {
                previousQuota = nil
            }
            guard let previousQuota,
                  previousQuota.usage != nil || (previousQuota.errorMessage ?? "").isEmpty == false
            else {
                return AccountQuota(account: account, usage: nil, errorMessage: nil)
            }
            return AccountQuota(
                account: account,
                usage: previousQuota.usage,
                errorMessage: previousQuota.errorMessage
            )
        }
        return ManagementDashboard(
            accounts: accounts,
            accountQuotas: mergedQuotas,
            apiKeyUsage: apiKeyUsage,
            quotaSwitchProject: quotaSwitchProject,
            quotaSwitchPreviewModel: quotaSwitchPreviewModel,
            serverVersion: serverVersion,
            serverCommit: serverCommit,
            serverBuildDate: serverBuildDate,
            fetchedAt: fetchedAt
        )
    }

    private func quotaByAccountKey() -> [String: AccountQuota] {
        var values: [String: AccountQuota] = [:]
        var duplicateKeys = Set<String>()
        for quota in accountQuotas {
            let key = Self.accountKey(for: quota.account)
            if values[key] != nil {
                duplicateKeys.insert(key)
            }
            values[key] = quota
        }
        for key in duplicateKeys {
            values.removeValue(forKey: key)
        }
        return values
    }

    private func quotaByID() -> [String: AccountQuota] {
        var values: [String: AccountQuota] = [:]
        var duplicateIDs = Set<String>()
        for quota in accountQuotas {
            if values[quota.id] != nil {
                duplicateIDs.insert(quota.id)
            }
            values[quota.id] = quota
        }
        for id in duplicateIDs {
            values.removeValue(forKey: id)
        }
        return values
    }

    private static func accountKey(for account: CPAAccount) -> String {
        account.stableIdentity
    }

    private static func canReplaceByID(current: CPAAccount, replacement: CPAAccount) -> Bool {
        !hasConflictingIdentity(current.authIndex, replacement.authIndex) &&
            !hasConflictingIdentity(current.name, replacement.name) &&
            !hasConflictingIdentity(current.providerName, replacement.providerName)
    }

    private static func hasConflictingIdentity(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !left.isEmpty && !right.isEmpty && left != right
    }

    public static func demo(fetchedAt: Date = Date()) -> ManagementDashboard {
        let data = Data(Self.demoAuthFilesJSON.utf8)
        guard let response = try? JSONDecoder().decode(AuthFilesResponse.self, from: data) else {
            return ManagementDashboard(accounts: [], fetchedAt: fetchedAt)
        }
        let quotas = response.files.map { account in
            AccountQuota(
                account: account,
                usage: demoUsage(for: account),
                errorMessage: nil
            )
        }
        let apiKeyUsage = APIKeyUsageParser.flatten(Self.demoAPIKeyUsage)
        return ManagementDashboard(
            accounts: response.files,
            accountQuotas: quotas,
            apiKeyUsage: apiKeyUsage,
            quotaSwitchProject: true,
            quotaSwitchPreviewModel: false,
            serverVersion: "demo",
            serverCommit: nil,
            serverBuildDate: nil,
            fetchedAt: fetchedAt
        )
    }

    public static func demoModels(for account: CPAAccount) -> [CPAModelDefinition] {
        switch ProviderCatalog.info(for: account.normalizedProvider).key {
        case "codex":
            return [
                CPAModelDefinition(id: "gpt-5-codex", displayName: "GPT-5 Codex", type: "chat", ownedBy: "OpenAI"),
                CPAModelDefinition(id: "gpt-5-mini", displayName: "GPT-5 Mini", type: "chat", ownedBy: "OpenAI"),
                CPAModelDefinition(id: "gpt-4.1", displayName: "GPT-4.1", type: "chat", ownedBy: "OpenAI")
            ]
        case "claude":
            return [
                CPAModelDefinition(id: "claude-opus-4", displayName: "Claude Opus 4", type: "chat", ownedBy: "Anthropic"),
                CPAModelDefinition(id: "claude-sonnet-4", displayName: "Claude Sonnet 4", type: "chat", ownedBy: "Anthropic"),
                CPAModelDefinition(id: "claude-haiku-3.5", displayName: "Claude Haiku 3.5", type: "chat", ownedBy: "Anthropic")
            ]
        case "antigravity":
            return [
                CPAModelDefinition(id: "gemini-3-pro", displayName: "Gemini 3 Pro", type: "chat", ownedBy: "Google"),
                CPAModelDefinition(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", type: "chat", ownedBy: "Anthropic"),
                CPAModelDefinition(id: "gpt-5", displayName: "GPT-5", type: "chat", ownedBy: "OpenAI")
            ]
        case "xai":
            return [
                CPAModelDefinition(id: "grok-4", displayName: "Grok 4", type: "chat", ownedBy: "xAI"),
                CPAModelDefinition(id: "grok-code-fast-1", displayName: "Grok Code Fast 1", type: "coding", ownedBy: "xAI")
            ]
        case "kimi":
            return [
                CPAModelDefinition(id: "kimi-k2", displayName: "Kimi K2", type: "chat", ownedBy: "Moonshot AI"),
                CPAModelDefinition(id: "kimi-k2-thinking", displayName: "Kimi K2 Thinking", type: "reasoning", ownedBy: "Moonshot AI")
            ]
        case "gemini":
            return [
                CPAModelDefinition(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", type: "chat", ownedBy: "Google"),
                CPAModelDefinition(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", type: "chat", ownedBy: "Google")
            ]
        default:
            return []
        }
    }

    private static func demoUsage(for account: CPAAccount) -> UsageSnapshot? {
        switch ProviderCatalog.info(for: account.normalizedProvider).key {
        case "codex":
            return UsageSnapshot(
                planType: "team",
                primary: QuotaWindow(
                    id: "demo-codex-5h",
                    label: "5h",
                    usedPercent: 38,
                    remainingPercent: 62,
                    resetAfterSeconds: 11_400,
                    resetAt: nil
                ),
                weekly: QuotaWindow(
                    id: "demo-codex-7d",
                    label: "7d",
                    usedPercent: 54,
                    remainingPercent: 46,
                    resetAfterSeconds: 342_000,
                    resetAt: nil
                ),
                rawStatus: "demo"
            )
        case "claude":
            return UsageSnapshot(
                planType: "Max",
                primary: nil,
                weekly: nil,
                additionalWindows: [
                    QuotaWindow(
                        id: "demo-claude-5h",
                        label: "5 小时限额",
                        usedPercent: 72,
                        remainingPercent: 28,
                        resetAfterSeconds: 5_400,
                        resetAt: nil,
                        displayValue: "28%",
                        isUsable: true
                    ),
                    QuotaWindow(
                        id: "demo-claude-7d",
                        label: "7 天 Sonnet",
                        usedPercent: 41,
                        remainingPercent: 59,
                        resetAfterSeconds: 204_000,
                        resetAt: nil,
                        displayValue: "59%",
                        isUsable: true
                    )
                ],
                rawStatus: "demo"
            )
        case "antigravity":
            return UsageSnapshot(
                planType: "Google One AI",
                primary: nil,
                weekly: nil,
                additionalWindows: [
                    QuotaWindow(
                        id: "demo-antigravity-claude",
                        label: "Claude/GPT",
                        usedPercent: 16,
                        remainingPercent: 84,
                        resetAfterSeconds: nil,
                        resetAt: nil,
                        displayValue: "84%",
                        detailText: "05-31 09:00",
                        isUsable: true
                    ),
                    QuotaWindow(
                        id: "demo-antigravity-gemini",
                        label: "Gemini 3 Pro",
                        usedPercent: 100,
                        remainingPercent: 0,
                        resetAfterSeconds: nil,
                        resetAt: nil,
                        displayValue: "0%",
                        detailText: "05-31 15:00",
                        isUsable: false
                    )
                ],
                rawStatus: "demo"
            )
        case "xai":
            return UsageSnapshot(
                planType: nil,
                primary: nil,
                weekly: nil,
                additionalWindows: [
                    QuotaWindow(
                        id: "demo-xai-monthly",
                        label: "月度积分",
                        usedPercent: 22,
                        remainingPercent: 78,
                        resetAfterSeconds: nil,
                        resetAt: nil,
                        displayValue: "78%",
                        amountText: "$11.20 / $50.00",
                        isUsable: true
                    )
                ],
                rawStatus: "demo"
            )
        case "kimi":
            return UsageSnapshot(
                planType: "coding",
                primary: nil,
                weekly: nil,
                additionalWindows: [
                    QuotaWindow(
                        id: "demo-kimi-weekly",
                        label: "周限额",
                        usedPercent: 34,
                        remainingPercent: 66,
                        resetAfterSeconds: 86_400,
                        resetAt: nil,
                        displayValue: "66%",
                        amountText: "340 / 1000",
                        detailText: "24小时后重置",
                        isUsable: true
                    )
                ],
                rawStatus: "demo"
            )
        default:
            return nil
        }
    }

    private static let demoAPIKeyUsage: [String: [String: APIKeyUsageEntry]] = [
        "openai": [
            "https://api.demo.local|sk-demo1234567890": APIKeyUsageEntry(
                success: 428,
                failed: 7,
                recentRequests: [
                    RecentRequestBucket(time: "09:00", success: 38, failed: 0),
                    RecentRequestBucket(time: "09:10", success: 42, failed: 1),
                    RecentRequestBucket(time: "09:20", success: 35, failed: 0),
                    RecentRequestBucket(time: "09:30", success: 40, failed: 2)
                ]
            )
        ]
    ]

    private static let demoAuthFilesJSON = """
    {
      "files": [
        {
          "id": "demo-codex",
          "auth_index": "demo-codex",
          "name": "codex-team.json",
          "provider": "codex",
          "label": "Codex Team",
          "status": "active",
          "success": 318,
          "failed": 4,
          "account_type": "team",
          "chatgpt_account_id": "acct-demo-team",
          "model_states": {
            "gpt-5-codex": {"status": "active"},
            "gpt-5-mini": {"status": "active"}
          },
          "recent_requests": [
            {"time": "09:00", "success": 30, "failed": 0},
            {"time": "09:10", "success": 34, "failed": 0},
            {"time": "09:20", "success": 27, "failed": 1},
            {"time": "09:30", "success": 36, "failed": 0}
          ]
        },
        {
          "id": "demo-claude",
          "auth_index": "demo-claude",
          "name": "claude-max.json",
          "provider": "claude",
          "label": "Claude Max",
          "status": "active",
          "success": 204,
          "failed": 8,
          "account_type": "max",
          "recent_requests": [
            {"time": "09:00", "success": 18, "failed": 1},
            {"time": "09:10", "success": 22, "failed": 0},
            {"time": "09:20", "success": 19, "failed": 2}
          ],
          "model_states": {
            "claude-opus-4": {
              "status": "cooling",
              "unavailable": true,
              "next_retry_after": "2026-05-31T06:30:00Z",
              "quota": {"exceeded": true, "reason": "demo cooldown"}
            }
          }
        },
        {
          "id": "demo-antigravity",
          "auth_index": "demo-antigravity",
          "name": "antigravity-google-one.json",
          "provider": "antigravity",
          "label": "Antigravity Google One",
          "status": "active",
          "success": 168,
          "failed": 12,
          "project_id": "demo-project",
          "antigravity_credits": {
            "known": true,
            "available": true,
            "credit_amount": 25000,
            "min_credit_amount": 50
          },
          "model_states": {
            "gemini-3-pro": {
              "status": "limited",
              "unavailable": true,
              "quota": {"exceeded": true, "reason": "demo shared project limit"}
            }
          }
        },
        {
          "id": "demo-xai",
          "auth_index": "demo-xai",
          "name": "grok.json",
          "provider": "xai",
          "label": "Grok",
          "status": "active",
          "success": 92,
          "failed": 3,
          "model_states": {
            "grok-code-fast-1": {
              "status": "error",
              "last_error": {"message": "demo provider returned 429", "retryable": true, "http_status": 429}
            }
          }
        },
        {
          "id": "demo-kimi",
          "auth_index": "demo-kimi",
          "name": "kimi-coding.json",
          "provider": "kimi",
          "label": "Kimi Coding",
          "status": "active",
          "success": 76,
          "failed": 2,
          "recent_requests": [
            {"time": "09:00", "success": 10, "failed": 0},
            {"time": "09:10", "success": 11, "failed": 0},
            {"time": "09:20", "success": 9, "failed": 1}
          ],
          "model_states": {
            "kimi-k2-thinking": {"status": "refreshing", "status_message": "demo refresh in progress"}
          }
        },
        {
          "id": "demo-gemini-disabled",
          "name": "gemini-disabled.json",
          "provider": "gemini",
          "label": "Gemini Backup",
          "status": "disabled",
          "disabled": true,
          "success": 0,
          "failed": 0
        }
      ]
    }
    """
}

public struct AuthFilesResponse: Decodable, Equatable, Sendable {
    public let files: [CPAAccount]
}

public struct ModelsResponse: Decodable, Equatable, Sendable {
    public let models: [CPAModelDefinition]
}

public struct CPAModelDefinition: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let type: String?
    public let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case type
        case ownedBy = "owned_by"
        case ownedByCamel = "ownedBy"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleStringIfPresent(forKey: .id) ?? "unknown"
        displayName = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .displayName),
            try container.decodeFlexibleStringIfPresent(forKey: .displayNameCamel)
        )
        type = try container.decodeFlexibleStringIfPresent(forKey: .type)
        ownedBy = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .ownedBy),
            try container.decodeFlexibleStringIfPresent(forKey: .ownedByCamel)
        )
    }

    public init(id: String, displayName: String? = nil, type: String? = nil, ownedBy: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.ownedBy = ownedBy
    }
}

public struct CPAAccount: Decodable, Identifiable, Equatable, Sendable {
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
    public let chatgptAccountID: String?
    public let planType: String?
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
        case authIndexCamel = "authIndex"
        case name
        case type
        case provider
        case label
        case status
        case statusMessage = "status_message"
        case statusMessageCamel = "statusMessage"
        case disabled
        case unavailable
        case runtimeOnly = "runtime_only"
        case runtimeOnlyCamel = "runtimeOnly"
        case source
        case size
        case success
        case failed
        case recentRequests = "recent_requests"
        case recentRequestsCamel = "recentRequests"
        case email
        case projectID = "project_id"
        case projectIDCamel = "projectId"
        case projectIDUpperCamel = "projectID"
        case accountType = "account_type"
        case accountTypeCamel = "accountType"
        case account
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptAccountIDCamel = "chatgptAccountID"
        case chatgptAccountIdCamel = "chatgptAccountId"
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case planType = "plan_type"
        case planTypeCamel = "planType"
        case plan
        case path
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case modifiedAt = "modtime"
        case modifiedAtCamel = "modifiedAt"
        case lastRefresh = "last_refresh"
        case lastRefreshCamel = "lastRefresh"
        case lastRefreshedAt = "last_refreshed_at"
        case lastRefreshedAtCamel = "lastRefreshedAt"
        case nextRetryAfter = "next_retry_after"
        case nextRetryAfterCamel = "nextRetryAfter"
        case nextRefreshAfter = "next_refresh_after"
        case nextRefreshAfterCamel = "nextRefreshAfter"
        case quota
        case modelStates = "model_states"
        case modelStatesCamel = "modelStates"
        case lastError = "last_error"
        case lastErrorCamel = "lastError"
        case idToken = "id_token"
        case idTokenCamel = "idToken"
        case antigravityCredits = "antigravity_credits"
        case antigravityCreditsCamel = "antigravityCredits"
        case priority
        case note
        case websockets
        case webSockets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decodeIfPresent(CodexIDTokenClaims.self, forKey: .idToken)
            ?? container.decodeIfPresent(CodexIDTokenClaims.self, forKey: .idTokenCamel)
        let decodedID = try container.decodeFlexibleStringIfPresent(forKey: .id)
        let decodedName = try container.decodeFlexibleStringIfPresent(forKey: .name)
        let decodedAuthIndex = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .authIndex),
            try container.decodeFlexibleStringIfPresent(forKey: .authIndexCamel)
        )
        let fallbackName = firstNonEmptyString(decodedName, decodedID, decodedAuthIndex) ?? "unknown"

        id = firstNonEmptyString(decodedID, decodedAuthIndex, decodedName) ?? fallbackName
        authIndex = decodedAuthIndex
        name = fallbackName
        type = try container.decodeFlexibleStringIfPresent(forKey: .type)
        provider = try container.decodeFlexibleStringIfPresent(forKey: .provider)
        label = try container.decodeFlexibleStringIfPresent(forKey: .label)
        status = try container.decodeFlexibleStringIfPresent(forKey: .status)
        statusMessage = firstNonEmptyString(
            try decodeCPAAccountErrorText(from: container, forKey: .statusMessage),
            try decodeCPAAccountErrorText(from: container, forKey: .statusMessageCamel)
        )
        disabled = try container.decodeFlexibleBoolIfPresent(forKey: .disabled) ?? false
        unavailable = try container.decodeFlexibleBoolIfPresent(forKey: .unavailable) ?? false
        runtimeOnly = try container.decodeFlexibleBoolIfPresent(forKey: .runtimeOnly)
            ?? container.decodeFlexibleBoolIfPresent(forKey: .runtimeOnlyCamel)
            ?? false
        source = try container.decodeFlexibleStringIfPresent(forKey: .source)
        size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
        success = try container.decodeFlexibleInt64IfPresent(forKey: .success) ?? 0
        failed = try container.decodeFlexibleInt64IfPresent(forKey: .failed) ?? 0
        recentRequests = try container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequests)
            ?? container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequestsCamel)
            ?? []
        email = try container.decodeFlexibleStringIfPresent(forKey: .email)
        projectID = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .projectID),
            try container.decodeFlexibleStringIfPresent(forKey: .projectIDCamel),
            try container.decodeFlexibleStringIfPresent(forKey: .projectIDUpperCamel)
        )
        accountType = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .accountType),
            try container.decodeFlexibleStringIfPresent(forKey: .accountTypeCamel)
        )
        account = try container.decodeFlexibleStringIfPresent(forKey: .account)
        idToken = token
        chatgptAccountID = firstNonEmptyString(
            token?.chatgptAccountID,
            try container.decodeFlexibleStringIfPresent(forKey: .chatgptAccountID),
            try container.decodeFlexibleStringIfPresent(forKey: .chatgptAccountIDCamel),
            try container.decodeFlexibleStringIfPresent(forKey: .chatgptAccountIdCamel),
            try container.decodeFlexibleStringIfPresent(forKey: .accountID),
            try container.decodeFlexibleStringIfPresent(forKey: .accountIDCamel)
        )
        planType = firstNonEmptyString(
            token?.planType,
            try container.decodeFlexibleStringIfPresent(forKey: .planType),
            try container.decodeFlexibleStringIfPresent(forKey: .planTypeCamel),
            try container.decodeFlexibleStringIfPresent(forKey: .plan)
        )
        path = try container.decodeFlexibleStringIfPresent(forKey: .path)
        createdAt = try container.decodeFlexibleDateIfPresent(forKey: .createdAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .createdAtCamel)
        updatedAt = try container.decodeFlexibleDateIfPresent(forKey: .updatedAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .updatedAtCamel)
        modifiedAt = try container.decodeFlexibleDateIfPresent(forKey: .modifiedAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .modifiedAtCamel)
        lastRefresh = try container.decodeFlexibleDateIfPresent(forKey: .lastRefresh)
            ?? container.decodeFlexibleDateIfPresent(forKey: .lastRefreshCamel)
            ?? container.decodeFlexibleDateIfPresent(forKey: .lastRefreshedAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .lastRefreshedAtCamel)
        nextRetryAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfter)
            ?? container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfterCamel)
        nextRefreshAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRefreshAfter)
            ?? container.decodeFlexibleDateIfPresent(forKey: .nextRefreshAfterCamel)
        quota = try container.decodeIfPresent(QuotaState.self, forKey: .quota)
        modelStates = try container.decodeIfPresent([String: ModelState].self, forKey: .modelStates)
            ?? container.decodeIfPresent([String: ModelState].self, forKey: .modelStatesCamel)
            ?? [:]
        lastError = try decodeCPAAccountProviderError(from: container, forKey: .lastError)
            ?? decodeCPAAccountProviderError(from: container, forKey: .lastErrorCamel)
        antigravityCredits = try container.decodeIfPresent(AntigravityCredits.self, forKey: .antigravityCredits)
            ?? container.decodeIfPresent(AntigravityCredits.self, forKey: .antigravityCreditsCamel)
        priority = try container.decodeFlexibleIntIfPresent(forKey: .priority)
        note = try container.decodeFlexibleStringIfPresent(forKey: .note)
        websockets = try container.decodeFlexibleBoolIfPresent(forKey: .websockets)
            ?? container.decodeFlexibleBoolIfPresent(forKey: .webSockets)
    }
}

public struct RecentRequestBucket: Decodable, Identifiable, Equatable, Sendable {
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
        time = try container.decodeFlexibleStringIfPresent(forKey: .time) ?? ""
        success = try container.decodeFlexibleInt64IfPresent(forKey: .success) ?? 0
        failed = try container.decodeFlexibleInt64IfPresent(forKey: .failed) ?? 0
    }
}

public struct QuotaState: Decodable, Equatable, Sendable {
    public let exceeded: Bool
    public let reason: String?
    public let nextRecoverAt: Date?
    public let backoffLevel: Int?

    enum CodingKeys: String, CodingKey {
        case exceeded
        case reason
        case nextRecoverAt = "next_recover_at"
        case nextRecoverAtCamel = "nextRecoverAt"
        case backoffLevel = "backoff_level"
        case backoffLevelCamel = "backoffLevel"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exceeded = try container.decodeFlexibleBoolIfPresent(forKey: .exceeded) ?? false
        reason = try decodeQuotaStateErrorText(from: container, forKey: .reason)
        nextRecoverAt = try container.decodeFlexibleDateIfPresent(forKey: .nextRecoverAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .nextRecoverAtCamel)
        backoffLevel = try container.decodeFlexibleIntIfPresent(forKey: .backoffLevel)
            ?? container.decodeFlexibleIntIfPresent(forKey: .backoffLevelCamel)
    }
}

public struct ModelState: Decodable, Equatable, Sendable {
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
        case statusMessageCamel = "statusMessage"
        case unavailable
        case nextRetryAfter = "next_retry_after"
        case nextRetryAfterCamel = "nextRetryAfter"
        case lastError = "last_error"
        case lastErrorCamel = "lastError"
        case quota
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeFlexibleStringIfPresent(forKey: .status)
        statusMessage = firstNonEmptyString(
            try decodeModelStateErrorText(from: container, forKey: .statusMessage),
            try decodeModelStateErrorText(from: container, forKey: .statusMessageCamel)
        )
        unavailable = try container.decodeFlexibleBoolIfPresent(forKey: .unavailable) ?? false
        nextRetryAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfter)
            ?? container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfterCamel)
        lastError = try decodeModelStateProviderError(from: container, forKey: .lastError)
            ?? decodeModelStateProviderError(from: container, forKey: .lastErrorCamel)
        quota = try container.decodeIfPresent(QuotaState.self, forKey: .quota)
        updatedAt = try container.decodeFlexibleDateIfPresent(forKey: .updatedAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .updatedAtCamel)
    }
}

public struct ProviderError: Decodable, Equatable, Sendable {
    public let code: String?
    public let message: String
    public let retryable: Bool
    public let httpStatus: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case type
        case message
        case error
        case detail
        case reason
        case description
        case status
        case statusMessage = "status_message"
        case statusMessageCamel = "statusMessage"
        case retryable
        case httpStatus = "http_status"
        case httpStatusCamel = "httpStatus"
        case statusCode = "status_code"
        case statusCodeCamel = "statusCode"
    }

    public init(code: String? = nil, message: String, retryable: Bool = false, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.httpStatus = httpStatus
    }

    public init(from decoder: Decoder) throws {
        if let message = singleValueString(from: decoder) {
            self = ProviderError(message: message)
        } else {
            self = try decodeProviderErrorPayload(from: decoder.container(keyedBy: CodingKeys.self))
        }
    }
}

private func decodeCPAAccountErrorText(
    from container: KeyedDecodingContainer<CPAAccount.CodingKeys>,
    forKey key: CPAAccount.CodingKeys
) throws -> String? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        return nil
    }
    if let value = try container.decodeFlexibleStringIfPresent(forKey: key) {
        return value
    }
    guard let nested = try? container.nestedContainer(keyedBy: ProviderError.CodingKeys.self, forKey: key) else {
        return nil
    }
    return try decodeProviderErrorText(from: nested)
}

private func decodeQuotaStateErrorText(
    from container: KeyedDecodingContainer<QuotaState.CodingKeys>,
    forKey key: QuotaState.CodingKeys
) throws -> String? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        return nil
    }
    if let value = try container.decodeFlexibleStringIfPresent(forKey: key) {
        return value
    }
    guard let nested = try? container.nestedContainer(keyedBy: ProviderError.CodingKeys.self, forKey: key) else {
        return nil
    }
    return try decodeProviderErrorText(from: nested)
}

private func decodeModelStateErrorText(
    from container: KeyedDecodingContainer<ModelState.CodingKeys>,
    forKey key: ModelState.CodingKeys
) throws -> String? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        return nil
    }
    if let value = try container.decodeFlexibleStringIfPresent(forKey: key) {
        return value
    }
    guard let nested = try? container.nestedContainer(keyedBy: ProviderError.CodingKeys.self, forKey: key) else {
        return nil
    }
    return try decodeProviderErrorText(from: nested)
}

private func decodeCPAAccountProviderError(
    from container: KeyedDecodingContainer<CPAAccount.CodingKeys>,
    forKey key: CPAAccount.CodingKeys
) throws -> ProviderError? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        return nil
    }
    if let message = try container.decodeFlexibleStringIfPresent(forKey: key) {
        return ProviderError(message: message)
    }
    guard let nested = try? container.nestedContainer(keyedBy: ProviderError.CodingKeys.self, forKey: key) else {
        return nil
    }
    return try decodeProviderErrorPayload(from: nested)
}

private func decodeModelStateProviderError(
    from container: KeyedDecodingContainer<ModelState.CodingKeys>,
    forKey key: ModelState.CodingKeys
) throws -> ProviderError? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        return nil
    }
    if let message = try container.decodeFlexibleStringIfPresent(forKey: key) {
        return ProviderError(message: message)
    }
    guard let nested = try? container.nestedContainer(keyedBy: ProviderError.CodingKeys.self, forKey: key) else {
        return nil
    }
    return try decodeProviderErrorPayload(from: nested)
}

private func decodeProviderErrorPayload(
    from container: KeyedDecodingContainer<ProviderError.CodingKeys>
) throws -> ProviderError {
    let decodedCode = firstNonEmptyString(
        try container.decodeFlexibleStringIfPresent(forKey: .code),
        try container.decodeFlexibleStringIfPresent(forKey: .type)
    )
    let decodedMessage = firstNonEmptyString(
        try decodeProviderErrorText(from: container, forKey: .message),
        try decodeProviderErrorText(from: container, forKey: .error),
        try decodeProviderErrorText(from: container, forKey: .detail),
        try decodeProviderErrorText(from: container, forKey: .reason),
        try decodeProviderErrorText(from: container, forKey: .description),
        try decodeProviderErrorText(from: container, forKey: .statusMessage),
        try decodeProviderErrorText(from: container, forKey: .statusMessageCamel),
        decodedCode
    ) ?? ""
    return ProviderError(
        code: decodedCode,
        message: decodedMessage,
        retryable: try container.decodeFlexibleBoolIfPresent(forKey: .retryable) ?? false,
        httpStatus: try container.decodeFlexibleIntIfPresent(forKey: .httpStatus)
            ?? container.decodeFlexibleIntIfPresent(forKey: .httpStatusCamel)
            ?? container.decodeFlexibleIntIfPresent(forKey: .statusCode)
            ?? container.decodeFlexibleIntIfPresent(forKey: .statusCodeCamel)
            ?? container.decodeFlexibleIntIfPresent(forKey: .status)
    )
}

private func decodeProviderErrorText(
    from container: KeyedDecodingContainer<ProviderError.CodingKeys>
) throws -> String? {
    firstNonEmptyString(
        try decodeProviderErrorText(from: container, forKey: .message),
        try decodeProviderErrorText(from: container, forKey: .error),
        try decodeProviderErrorText(from: container, forKey: .detail),
        try decodeProviderErrorText(from: container, forKey: .reason),
        try decodeProviderErrorText(from: container, forKey: .statusMessage),
        try decodeProviderErrorText(from: container, forKey: .statusMessageCamel),
        try container.decodeFlexibleStringIfPresent(forKey: .code),
        try container.decodeFlexibleStringIfPresent(forKey: .type),
        try container.decodeFlexibleStringIfPresent(forKey: .status)
    )
}

private func decodeProviderErrorText(
    from container: KeyedDecodingContainer<ProviderError.CodingKeys>,
    forKey key: ProviderError.CodingKeys
) throws -> String? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        return nil
    }
    if let value = try container.decodeFlexibleStringIfPresent(forKey: key) {
        return value
    }
    guard let nested = try? container.nestedContainer(keyedBy: ProviderError.CodingKeys.self, forKey: key) else {
        return nil
    }
    return firstNonEmptyString(
        try decodeProviderErrorText(from: nested, forKey: .message),
        try decodeProviderErrorText(from: nested, forKey: .error),
        try decodeProviderErrorText(from: nested, forKey: .detail),
        try decodeProviderErrorText(from: nested, forKey: .reason),
        try decodeProviderErrorText(from: nested, forKey: .statusMessage),
        try decodeProviderErrorText(from: nested, forKey: .statusMessageCamel),
        try nested.decodeFlexibleStringIfPresent(forKey: .code),
        try nested.decodeFlexibleStringIfPresent(forKey: .type),
        try nested.decodeFlexibleStringIfPresent(forKey: .status)
    )
}

public struct CodexIDTokenClaims: Decodable, Equatable, Sendable {
    public let chatgptAccountID: String?
    public let planType: String?
    public let subscriptionActiveStart: Date?
    public let subscriptionActiveUntil: Date?

    enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptAccountIDCamel = "chatgptAccountID"
        case chatgptAccountIdCamel = "chatgptAccountId"
        case planType = "plan_type"
        case planTypeCamel = "planType"
        case subscriptionActiveStart = "chatgpt_subscription_active_start"
        case subscriptionActiveStartCamel = "chatgptSubscriptionActiveStart"
        case subscriptionActiveUntil = "chatgpt_subscription_active_until"
        case subscriptionActiveUntilCamel = "chatgptSubscriptionActiveUntil"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatgptAccountID = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .chatgptAccountID),
            try container.decodeFlexibleStringIfPresent(forKey: .chatgptAccountIDCamel),
            try container.decodeFlexibleStringIfPresent(forKey: .chatgptAccountIdCamel)
        )
        planType = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .planType),
            try container.decodeFlexibleStringIfPresent(forKey: .planTypeCamel)
        )
        subscriptionActiveStart = try container.decodeFlexibleDateIfPresent(forKey: .subscriptionActiveStart)
            ?? container.decodeFlexibleDateIfPresent(forKey: .subscriptionActiveStartCamel)
        subscriptionActiveUntil = try container.decodeFlexibleDateIfPresent(forKey: .subscriptionActiveUntil)
            ?? container.decodeFlexibleDateIfPresent(forKey: .subscriptionActiveUntilCamel)
    }
}

public struct AntigravityCredits: Decodable, Equatable, Sendable {
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
        case creditAmountCamel = "creditAmount"
        case minCreditAmount = "min_credit_amount"
        case minCreditAmountCamel = "minCreditAmount"
        case minimumCreditAmountForUsage
        case paidTierID = "paid_tier_id"
        case paidTierIDCamel = "paidTierID"
        case paidTierIdCamel = "paidTierId"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        known = try container.decodeFlexibleBoolIfPresent(forKey: .known) ?? false
        available = try container.decodeFlexibleBoolIfPresent(forKey: .available) ?? false
        creditAmount = try container.decodeFlexibleDoubleIfPresent(forKey: .creditAmount)
            ?? container.decodeFlexibleDoubleIfPresent(forKey: .creditAmountCamel)
        minCreditAmount = try container.decodeFlexibleDoubleIfPresent(forKey: .minCreditAmount)
            ?? container.decodeFlexibleDoubleIfPresent(forKey: .minCreditAmountCamel)
            ?? container.decodeFlexibleDoubleIfPresent(forKey: .minimumCreditAmountForUsage)
        paidTierID = firstNonEmptyString(
            try container.decodeFlexibleStringIfPresent(forKey: .paidTierID),
            try container.decodeFlexibleStringIfPresent(forKey: .paidTierIDCamel),
            try container.decodeFlexibleStringIfPresent(forKey: .paidTierIdCamel)
        )
        updatedAt = try container.decodeFlexibleDateIfPresent(forKey: .updatedAt)
            ?? container.decodeFlexibleDateIfPresent(forKey: .updatedAtCamel)
    }
}

public struct APIKeyUsageEntry: Decodable, Equatable, Sendable {
    public let success: Int64
    public let failed: Int64
    public let recentRequests: [RecentRequestBucket]

    enum CodingKeys: String, CodingKey {
        case success
        case failed
        case recentRequests = "recent_requests"
        case recentRequestsCamel = "recentRequests"
    }

    public init(success: Int64, failed: Int64, recentRequests: [RecentRequestBucket]) {
        self.success = success
        self.failed = failed
        self.recentRequests = recentRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeFlexibleInt64IfPresent(forKey: .success) ?? 0
        failed = try container.decodeFlexibleInt64IfPresent(forKey: .failed) ?? 0
        recentRequests = try container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequests)
            ?? container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequestsCamel)
            ?? []
    }
}

public struct APIKeyUsageRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let baseURL: String
    fileprivate let apiKey: String
    public let success: Int64
    public let failed: Int64
    public let recentRequests: [RecentRequestBucket]

    fileprivate init(
        id: String,
        provider: String,
        baseURL: String,
        apiKey: String,
        success: Int64,
        failed: Int64,
        recentRequests: [RecentRequestBucket]
    ) {
        self.id = id
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.success = success
        self.failed = failed
        self.recentRequests = recentRequests
    }

    public var maskedAPIKey: String {
        guard !apiKey.isEmpty else {
            return "未命名 Key"
        }
        if apiKey.count <= 6 {
            return "****"
        }
        if apiKey.count <= 10 {
            return "****\(apiKey.suffix(4))"
        }
        return "\(apiKey.prefix(6))...\(apiKey.suffix(4))"
    }
}

public struct BooleanValueResponse: Decodable, Equatable, Sendable {
    public let value: Bool?
    public let switchProject: Bool?
    public let switchPreviewModel: Bool?

    enum CodingKeys: String, CodingKey {
        case value
        case switchProject = "switch-project"
        case switchProjectSnake = "switch_project"
        case switchProjectCamel = "switchProject"
        case switchPreviewModel = "switch-preview-model"
        case switchPreviewModelSnake = "switch_preview_model"
        case switchPreviewModelCamel = "switchPreviewModel"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeFlexibleBoolIfPresent(forKey: .value)
        switchProject = try container.decodeFlexibleBoolIfPresent(forKey: .switchProject)
            ?? container.decodeFlexibleBoolIfPresent(forKey: .switchProjectSnake)
            ?? container.decodeFlexibleBoolIfPresent(forKey: .switchProjectCamel)
        switchPreviewModel = try container.decodeFlexibleBoolIfPresent(forKey: .switchPreviewModel)
            ?? container.decodeFlexibleBoolIfPresent(forKey: .switchPreviewModelSnake)
            ?? container.decodeFlexibleBoolIfPresent(forKey: .switchPreviewModelCamel)
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
        if let account, !account.isEmpty {
            return account
        }
        return name
    }

    var displayNameIsSensitive: Bool {
        let displayValue = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !displayValue.isEmpty else {
            return false
        }
        let sensitiveValues = [
            email,
            account,
            chatgptAccountID,
            authIndex,
            projectID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        if sensitiveValues.contains(displayValue) {
            return true
        }
        return displayValue.contains("@")
    }

    var providerName: String {
        firstNonEmptyString(provider, type) ?? "unknown"
    }

    var normalizedProvider: String {
        providerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    var stableIdentity: String {
        [
            id,
            authIndex ?? "",
            name,
            providerName
        ].joined(separator: "\u{1F}")
    }

    var isAntigravity: Bool {
        normalizedProvider == "antigravity"
    }

    var isClaude: Bool {
        normalizedProvider == "claude" || normalizedProvider == "anthropic"
    }

    var isKimi: Bool {
        normalizedProvider == "kimi"
    }

    var isXAI: Bool {
        normalizedProvider == "xai" || normalizedProvider == "x-ai" || normalizedProvider == "grok"
    }

    /// Codex / OpenAI accounts are the only ones exposing rolling 5-hour and 7-day
    /// rate-limit windows, so the dashboard's 5h/7d headline average is scoped to them.
    var isCodexLike: Bool {
        normalizedProvider == "codex" || normalizedProvider.contains("openai")
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

    var quotaLine: String {
        switch statusKind {
        case .available:
            if let credits = antigravityCredits, credits.known {
                return credits.available ? "Credits \(displayCredits(credits.creditAmount))" : "Credits 不足"
            }
            return "额度可用"
        case .cooling:
            if let activeModelIssueLine {
                return activeModelIssueLine
            }
            if let credits = antigravityCredits, credits.known, !credits.available {
                return "Credits 不足"
            }
            if let nextRecoveryDate {
                return "冷却至 \(displayClock(nextRecoveryDate))"
            }
            return quota?.reason ?? "额度受限"
        case .pending:
            return "刷新中"
        case .error:
            return statusMessage ?? lastError?.message ?? activeModelIssueLine ?? "异常"
        case .disabled:
            return "已停用"
        case .unknown:
            return "未知"
        case .all:
            return ""
        }
    }

    var nextRecoveryDate: Date? {
        let modelRecoveryDate = modelStates.values
            .compactMap { futureDate($0.nextRetryAfter) }
            .min()
        let candidates = [
            futureDate(quota?.nextRecoverAt),
            futureDate(nextRetryAfter),
            modelRecoveryDate
        ].compactMap { $0 }
        return candidates.min()
    }

    var activeModelCooldowns: [(model: String, state: ModelState)] {
        modelStates
            .filter { _, state in
                let status = normalizedModelStatus(state)
                let hasFutureRetry = futureDate(state.nextRetryAfter) != nil
                return state.unavailable ||
                    state.quota?.exceeded == true ||
                    hasFutureRetry ||
                    modelStatusIndicatesError(status) ||
                    modelStatusIndicatesLimit(status) ||
                    (state.lastError?.message ?? "").isEmpty == false
            }
            .sorted { lhs, rhs in lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending }
            .map { (model: $0.key, state: $0.value) }
    }

    var activeModelIssueLine: String? {
        guard let item = activeModelCooldowns.first else {
            return nil
        }
        let message = firstNonEmptyString(
            item.state.statusMessage,
            item.state.lastError?.message,
            item.state.quota?.reason,
            item.state.status
        )
        if let message {
            return "\(item.model): \(message)"
        }
        return item.model
    }

    var hasActiveModelError: Bool {
        activeModelCooldowns.contains { item in
            modelStatusIndicatesError(normalizedModelStatus(item.state)) ||
                (item.state.lastError?.message ?? "").isEmpty == false
        }
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
        if let lastError, !lastError.message.isEmpty {
            return .error
        }
        if hasActiveModelError {
            return .error
        }
        if !activeModelCooldowns.isEmpty {
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

private func normalizedModelStatus(_ state: ModelState) -> String {
    state.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
}

private func modelStatusIndicatesError(_ status: String) -> Bool {
    !status.isEmpty && ["error", "failed", "failure"].contains { status.contains($0) }
}

private func modelStatusIndicatesLimit(_ status: String) -> Bool {
    !status.isEmpty && ["cool", "quota", "limit", "unavailable", "exceeded"].contains { status.contains($0) }
}

public func stableAccountIdentitySort(_ lhs: CPAAccount, _ rhs: CPAAccount) -> Bool {
    let leftValues = [
        lhs.displayName,
        lhs.authIndex ?? "",
        lhs.name,
        lhs.providerName,
        lhs.id
    ]
    let rightValues = [
        rhs.displayName,
        rhs.authIndex ?? "",
        rhs.name,
        rhs.providerName,
        rhs.id
    ]

    for (left, right) in zip(leftValues, rightValues) {
        let result = left.localizedCaseInsensitiveCompare(right)
        if result != .orderedSame {
            return result == .orderedAscending
        }
    }
    return false
}

public enum CPAStatusKind: String, CaseIterable, Identifiable, Sendable {
    case all
    case available
    case cooling
    case pending
    case error
    case disabled
    case unknown

    public var id: String { rawValue }
}

public struct QuotaWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let resetAfterSeconds: Double?
    public let resetAt: Date?
    public let displayValue: String?
    public let amountText: String?
    public let detailText: String?
    public let isUsable: Bool?

    public init(
        id: String,
        label: String,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetAfterSeconds: Double?,
        resetAt: Date?,
        displayValue: String? = nil,
        amountText: String? = nil,
        detailText: String? = nil,
        isUsable: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
        self.displayValue = displayValue
        self.amountText = amountText
        self.detailText = detailText
        self.isUsable = isUsable
    }

    public var isExhausted: Bool {
        if isUsable == false {
            return true
        }
        if let remainingPercent {
            return remainingPercent <= 0.01
        }
        if let usedPercent {
            return usedPercent >= 99.99
        }
        return false
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let planType: String?
    public let primary: QuotaWindow?
    public let weekly: QuotaWindow?
    public let additionalWindows: [QuotaWindow]
    public let rawStatus: String?
    public let fetchedAt: Date

    public init(
        planType: String?,
        primary: QuotaWindow?,
        weekly: QuotaWindow?,
        additionalWindows: [QuotaWindow] = [],
        rawStatus: String?,
        fetchedAt: Date = Date()
    ) {
        self.planType = planType
        self.primary = primary
        self.weekly = weekly
        self.additionalWindows = additionalWindows
        self.rawStatus = rawStatus
        self.fetchedAt = fetchedAt
    }

    public var hasQuotaSignal: Bool {
        primary != nil || weekly != nil || !additionalWindows.isEmpty
    }

    public var quotaWindows: [QuotaWindow] {
        [primary, weekly].compactMap { $0 } + additionalWindows
    }
}

public struct AccountQuota: Identifiable, Equatable, Sendable {
    public let id: String
    public let account: CPAAccount
    public let usage: UsageSnapshot?
    public let errorMessage: String?
    public let supportsUsage: Bool

    public init(
        account: CPAAccount,
        usage: UsageSnapshot?,
        errorMessage: String?,
        supportsUsage: Bool? = nil
    ) {
        id = account.id
        self.account = account
        self.usage = usage
        self.errorMessage = errorMessage
        self.supportsUsage = supportsUsage ?? ProviderCatalog.info(for: account.normalizedProvider).supportsUsage
    }

    public var quotaWindows: [QuotaWindow] {
        usage?.quotaWindows ?? []
    }

    public var stableIdentity: String {
        account.stableIdentity
    }

    public var dashboardQuotaWindows: [QuotaWindow] {
        let windows = quotaWindows
        guard windows.count > 4 else {
            return windows
        }

        let pinnedIDs = Set([usage?.primary?.id, usage?.weekly?.id].compactMap { $0 })
        var selected = windows.filter { pinnedIDs.contains($0.id) }
        let selectedIDs = Set(selected.map(\.id))
        let remaining = windows
            .filter { !selectedIDs.contains($0.id) }
            .sorted(by: quotaWindowAttentionSort)

        for window in remaining where selected.count < 4 {
            selected.append(window)
        }
        return selected
    }

    public var hiddenDashboardQuotaWindowCount: Int {
        max(0, quotaWindows.count - dashboardQuotaWindows.count)
    }

    public var effectivePlanType: String? {
        firstNonEmptyString(usage?.planType, account.planType, account.idToken?.planType, account.accountType)
    }

    public var primaryRemainingPercent: Double? {
        usage?.primary?.remainingPercent
    }

    public var weeklyRemainingPercent: Double? {
        usage?.weekly?.remainingPercent
    }

    public var lowestRemainingPercent: Double? {
        quotaWindows.compactMap(\.remainingPercent).min()
    }

    public var hasUnusableQuotaWindow: Bool {
        quotaWindows.contains { $0.isExhausted }
    }

    public var statusKind: CPAStatusKind {
        if account.disabled {
            return .disabled
        }
        if let errorMessage, !errorMessage.isEmpty {
            return .error
        }
        if hasUnusableQuotaWindow {
            return .cooling
        }
        switch account.statusKind {
        case .cooling, .pending, .error, .disabled:
            return account.statusKind
        case .all, .available, .unknown:
            break
        }
        if usage?.hasQuotaSignal == true {
            return .available
        }
        return account.statusKind
    }

    public var liveQuotaLine: String {
        if let errorMessage, !errorMessage.isEmpty {
            return displayErrorMessage(errorMessage, limit: 72)
        }
        if !supportsUsage {
            return "身份状态"
        }
        if let lowestRemainingPercent {
            return "最低剩余 \(displayPercent(lowestRemainingPercent))"
        }
        if usage?.hasQuotaSignal == true {
            return "额度已同步"
        }
        return account.quotaLine
    }

    public func needsQuotaAlert(threshold: Double) -> Bool {
        guard !account.disabled else {
            return false
        }
        if let errorMessage, !errorMessage.isEmpty {
            return true
        }
        if statusKind == .cooling || statusKind == .error {
            return true
        }
        if let lowestRemainingPercent, lowestRemainingPercent <= threshold {
            return true
        }
        return false
    }

    public var quotaAlertReason: String {
        if let errorMessage, !errorMessage.isEmpty {
            return displayErrorMessage(errorMessage, limit: 80)
        }
        if statusKind == .cooling {
            return account.quotaLine
        }
        if statusKind == .error {
            return account.statusMessage ?? account.lastError?.message ?? "账号异常"
        }
        if let lowestRemainingPercent {
            return "最低剩余 \(displayPercent(lowestRemainingPercent))"
        }
        return liveQuotaLine
    }
}

private func quotaWindowAttentionSort(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> Bool {
    let lhsRank = quotaWindowAttentionRank(lhs)
    let rhsRank = quotaWindowAttentionRank(rhs)
    if lhsRank != rhsRank {
        return lhsRank < rhsRank
    }
    switch (lhs.remainingPercent, rhs.remainingPercent) {
    case let (.some(left), .some(right)) where left != right:
        return left < right
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}

private func quotaWindowAttentionRank(_ window: QuotaWindow) -> Int {
    if window.isExhausted {
        return 0
    }
    guard let remaining = window.remainingPercent else {
        return 4
    }
    if remaining <= 15 {
        return 1
    }
    if remaining <= 35 {
        return 2
    }
    return 3
}

public struct PoolSummary: Equatable, Sendable {
    public let totalAccounts: Int
    public let quotaAccounts: Int
    public let errorAccounts: Int
    public let disabledAccounts: Int
    public let primaryAverage: Double?
    public let weeklyAverage: Double?
    public let fetchedAt: Date

    public init(accounts: [AccountQuota], fetchedAt: Date = Date()) {
        totalAccounts = accounts.count
        quotaAccounts = accounts.filter { $0.usage?.hasQuotaSignal == true }.count
        errorAccounts = accounts.filter { ($0.errorMessage ?? "").isEmpty == false }.count
        disabledAccounts = accounts.filter { $0.account.disabled || $0.statusKind == .disabled }.count
        primaryAverage = PoolSummary.average(accounts.compactMap(\.primaryRemainingPercent))
        weeklyAverage = PoolSummary.average(accounts.compactMap(\.weeklyRemainingPercent))
        self.fetchedAt = fetchedAt
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

public struct ProviderInfo: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let symbolName: String
    public let accentName: String
    public let priority: Int
    public let supportsUsage: Bool
}

public enum ProviderCatalog {
    private static let table: [String: ProviderInfo] = [
        "codex": ProviderInfo(key: "codex", displayName: "Codex", symbolName: "chevron.left.forwardslash.chevron.right", accentName: "teal", priority: 0, supportsUsage: true),
        "openai": ProviderInfo(key: "openai", displayName: "OpenAI", symbolName: "o.circle.fill", accentName: "mint", priority: 1, supportsUsage: true),
        "claude": ProviderInfo(key: "claude", displayName: "Claude", symbolName: "c.circle.fill", accentName: "orange", priority: 2, supportsUsage: true),
        "gemini": ProviderInfo(key: "gemini", displayName: "Gemini", symbolName: "g.circle.fill", accentName: "blue", priority: 3, supportsUsage: false),
        "gemini-cli": ProviderInfo(key: "gemini-cli", displayName: "Gemini CLI", symbolName: "g.circle", accentName: "blue", priority: 4, supportsUsage: false),
        "vertex": ProviderInfo(key: "vertex", displayName: "Vertex AI", symbolName: "cloud.fill", accentName: "indigo", priority: 5, supportsUsage: false),
        "antigravity": ProviderInfo(key: "antigravity", displayName: "Antigravity", symbolName: "paperplane.fill", accentName: "purple", priority: 6, supportsUsage: true),
        "xai": ProviderInfo(key: "xai", displayName: "Grok", symbolName: "x.circle.fill", accentName: "gray", priority: 7, supportsUsage: true),
        "kimi": ProviderInfo(key: "kimi", displayName: "Kimi", symbolName: "k.circle.fill", accentName: "pink", priority: 8, supportsUsage: true)
    ]

    public static func info(for rawKey: String) -> ProviderInfo {
        let normalized = normalizeProviderKey(rawKey)
        if let exact = table[normalized] {
            return exact
        }
        if normalized.contains("openai") {
            return ProviderInfo(key: normalized, displayName: "OpenAI Compat", symbolName: "circle.hexagongrid.fill", accentName: "mint", priority: 50, supportsUsage: false)
        }
        let display = normalized.isEmpty
            ? "Other"
            : normalized.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return ProviderInfo(
            key: normalized.isEmpty ? "other" : normalized,
            displayName: display,
            symbolName: "circle.dotted",
            accentName: "gray",
            priority: 200,
            supportsUsage: false
        )
    }

    private static func normalizeProviderKey(_ rawKey: String) -> String {
        let normalized = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalized == "x-ai" || normalized == "grok" {
            return "xai"
        }
        if normalized == "anthropic" {
            return "claude"
        }
        return normalized
    }
}

public enum APIKeyUsageParser {
    public static func flatten(_ response: [String: [String: APIKeyUsageEntry]]) -> [APIKeyUsageRecord] {
        response.flatMap { provider, entries in
            entries.map { compositeKey, entry in
                let parts = compositeKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let baseURL = parts.count > 1 ? String(parts[0]) : ""
                let apiKey = parts.count > 1 ? String(parts[1]) : compositeKey
                return APIKeyUsageRecord(
                    id: stableAPIKeyUsageID(provider: provider, baseURL: baseURL, apiKey: apiKey),
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
            apiKeyUsageSort(lhs, rhs)
        }
    }

    private static func apiKeyUsageSort(_ lhs: APIKeyUsageRecord, _ rhs: APIKeyUsageRecord) -> Bool {
        if lhs.failed != rhs.failed {
            return lhs.failed > rhs.failed
        }
        let lhsFailureRate = apiKeyFailureRate(lhs)
        let rhsFailureRate = apiKeyFailureRate(rhs)
        if lhsFailureRate != rhsFailureRate {
            return lhsFailureRate > rhsFailureRate
        }
        let lhsTotal = lhs.success + lhs.failed
        let rhsTotal = rhs.success + rhs.failed
        if lhsTotal != rhsTotal {
            return lhsTotal > rhsTotal
        }
        if lhs.provider != rhs.provider {
            return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
        }
        if lhs.baseURL != rhs.baseURL {
            return lhs.baseURL.localizedCaseInsensitiveCompare(rhs.baseURL) == .orderedAscending
        }
        if lhs.maskedAPIKey != rhs.maskedAPIKey {
            return lhs.maskedAPIKey.localizedCaseInsensitiveCompare(rhs.maskedAPIKey) == .orderedAscending
        }
        return lhs.apiKey.localizedCaseInsensitiveCompare(rhs.apiKey) == .orderedAscending
    }

    private static func stableAPIKeyUsageID(provider: String, baseURL: String, apiKey: String) -> String {
        let rawIdentity = [
            provider,
            baseURL,
            apiKey
        ].joined(separator: "\u{1F}")
        return [
            provider,
            baseURL,
            stableHash(rawIdentity)
        ].joined(separator: "|")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private static func apiKeyFailureRate(_ record: APIKeyUsageRecord) -> Double {
        let total = record.success + record.failed
        guard total > 0 else {
            return 0
        }
        return Double(record.failed) / Double(total)
    }
}

func firstNonEmptyString(_ first: String?) -> String? {
    nonEmptyString(first)
}

func firstNonEmptyString(_ first: String?, _ second: String?) -> String? {
    nonEmptyString(first) ?? nonEmptyString(second)
}

func firstNonEmptyString(_ first: String?, _ second: String?, _ third: String?) -> String? {
    nonEmptyString(first) ?? nonEmptyString(second) ?? nonEmptyString(third)
}

func firstNonEmptyString(_ first: String?, _ second: String?, _ third: String?, _ fourth: String?) -> String? {
    nonEmptyString(first) ?? nonEmptyString(second) ?? nonEmptyString(third) ?? nonEmptyString(fourth)
}

func firstNonEmptyString(
    _ first: String?,
    _ second: String?,
    _ third: String?,
    _ fourth: String?,
    _ fifth: String?
) -> String? {
    firstNonEmptyString(first, second, third, fourth) ?? nonEmptyString(fifth)
}

func firstNonEmptyString(
    _ first: String?,
    _ second: String?,
    _ third: String?,
    _ fourth: String?,
    _ fifth: String?,
    _ sixth: String?
) -> String? {
    firstNonEmptyString(first, second, third, fourth, fifth) ?? nonEmptyString(sixth)
}

func firstNonEmptyString(
    _ first: String?,
    _ second: String?,
    _ third: String?,
    _ fourth: String?,
    _ fifth: String?,
    _ sixth: String?,
    _ seventh: String?
) -> String? {
    firstNonEmptyString(first, second, third, fourth, fifth, sixth) ?? nonEmptyString(seventh)
}

func firstNonEmptyString(
    _ first: String?,
    _ second: String?,
    _ third: String?,
    _ fourth: String?,
    _ fifth: String?,
    _ sixth: String?,
    _ seventh: String?,
    _ eighth: String?
) -> String? {
    firstNonEmptyString(first, second, third, fourth, fifth, sixth, seventh) ?? nonEmptyString(eighth)
}

func firstNonEmptyString(
    _ first: String?,
    _ second: String?,
    _ third: String?,
    _ fourth: String?,
    _ fifth: String?,
    _ sixth: String?,
    _ seventh: String?,
    _ eighth: String?,
    _ ninth: String?
) -> String? {
    firstNonEmptyString(first, second, third, fourth, fifth, sixth, seventh, eighth) ?? nonEmptyString(ninth)
}

private func nonEmptyString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func singleValueString(from decoder: Decoder) -> String? {
    guard let container = try? decoder.singleValueContainer(), !container.decodeNil() else {
        return nil
    }
    if let value = try? container.decode(String.self) {
        return nonEmptyString(value)
    }
    if let value = try? container.decode(Int.self) {
        return String(value)
    }
    if let value = try? container.decode(Int64.self) {
        return String(value)
    }
    if let value = try? container.decode(Double.self), value.isFinite {
        return value.rounded(.towardZero) == value ? fixedDecimalString(value, fractionDigits: 0) : String(value)
    }
    if let value = try? container.decode(Bool.self) {
        return value ? "true" : "false"
    }
    return nil
}

public func displayPercent(_ value: Double?) -> String {
    guard let value, value.isFinite else {
        return "--"
    }
    if value >= 99.95 {
        return "100%"
    }
    if value < 10 {
        return "\(fixedDecimalString(max(0, value), fractionDigits: 1))%"
    }
    return "\(fixedDecimalString(max(0, value), fractionDigits: 0))%"
}

public func displayDuration(seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else {
        return "-"
    }
    let totalMinutes = Int((seconds / 60).rounded(.up))
    if totalMinutes < 60 {
        return "\(totalMinutes)分钟"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours < 24 {
        return minutes == 0 ? "\(hours)小时" : "\(hours)小时 \(minutes)分钟"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return remainingHours == 0 ? "\(days)天" : "\(days)天 \(remainingHours)小时"
}

public func displayErrorMessage(_ value: String?, limit: Int = 140) -> String {
    let collapsed = (value ?? "")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !collapsed.isEmpty else {
        return "未知错误"
    }
    guard collapsed.count > limit, limit > 3 else {
        return collapsed
    }
    return "\(collapsed.prefix(limit - 3))..."
}

public func displayCredits(_ value: Double?) -> String {
    guard let value, value.isFinite else {
        return "--"
    }
    let clamped = max(0, value)
    if clamped >= 1_000_000 {
        let millions = clamped / 1_000_000
        return millions >= 10
            ? "\(fixedDecimalString(millions, fractionDigits: 0))M"
            : "\(fixedDecimalString(millions, fractionDigits: 1))M"
    }
    if clamped >= 1_000 {
        let thousands = clamped / 1_000
        return thousands >= 10
            ? "\(fixedDecimalString(thousands, fractionDigits: 0))K"
            : "\(fixedDecimalString(thousands, fractionDigits: 1))K"
    }
    if clamped.rounded(.towardZero) == clamped {
        return fixedDecimalString(clamped, fractionDigits: 0)
    }
    return clamped < 10
        ? fixedDecimalString(clamped, fractionDigits: 1)
        : fixedDecimalString(clamped, fractionDigits: 0)
}

func fixedDecimalString(_ value: Double, fractionDigits: Int) -> String {
    guard value.isFinite else {
        return String(value)
    }
    let digits = max(0, fractionDigits)
    let scale = pow(10.0, Double(digits))
    let rounded = (abs(value) * scale).rounded()
    guard rounded <= Double(Int64.max), scale <= Double(Int64.max) else {
        return String(value)
    }

    let sign = value < 0 ? "-" : ""
    let scaled = Int64(rounded)
    let divisor = Int64(scale)
    guard digits > 0, divisor > 1 else {
        return "\(sign)\(scaled)"
    }

    let whole = scaled / divisor
    let fraction = scaled % divisor
    var fractionText = String(fraction)
    while fractionText.count < digits {
        fractionText = "0\(fractionText)"
    }
    return "\(sign)\(whole).\(fractionText)"
}

private func futureDate(_ date: Date?, relativeTo now: Date = Date()) -> Date? {
    guard let date, date > now else {
        return nil
    }
    return date
}

func displayClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

extension KeyedDecodingContainer {
    func decodeFlexibleDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(String.self, forKey: key) {
            return FlexibleDateParser.parse(value)
        }
        if let value = try? decode(Double.self, forKey: key), value > 0 {
            return FlexibleDateParser.parse(value)
        }
        if let value = try? decode(Int64.self, forKey: key), value > 0 {
            return FlexibleDateParser.parse(TimeInterval(value))
        }
        if let value = try? decode(Date.self, forKey: key) {
            return value
        }
        return nil
    }

    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let value = try? decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Double.self, forKey: key), value.isFinite {
            if value.rounded(.towardZero) == value {
                return fixedDecimalString(value, fractionDigits: 0)
            }
            return String(value)
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value ? "true" : "false"
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
        guard !trimmed.isEmpty, !isZeroTimeSentinel(trimmed) else {
            return nil
        }
        if let date = parseRFC3339(trimmed) {
            return date
        }
        if let unix = TimeInterval(trimmed) {
            return parse(unix)
        }
        return nil
    }

    private static func isZeroTimeSentinel(_ value: String) -> Bool {
        value.hasPrefix("0001-01-01T00:00:00") ||
            value.hasPrefix("0001-01-01 00:00:00")
    }

    public static func parse(_ timestamp: TimeInterval) -> Date? {
        guard timestamp > 0, timestamp.isFinite else {
            return nil
        }
        let seconds = timestamp >= 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 19,
              let year = parseFixedInt(bytes, start: 0, length: 4),
              bytes[4] == ascii("-"),
              let month = parseFixedInt(bytes, start: 5, length: 2),
              bytes[7] == ascii("-"),
              let day = parseFixedInt(bytes, start: 8, length: 2),
              bytes[10] == ascii("T") || bytes[10] == ascii(" "),
              let hour = parseFixedInt(bytes, start: 11, length: 2),
              bytes[13] == ascii(":"),
              let minute = parseFixedInt(bytes, start: 14, length: 2),
              bytes[16] == ascii(":"),
              let second = parseFixedInt(bytes, start: 17, length: 2),
              isValidDate(year: year, month: month, day: day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second)
        else {
            return nil
        }

        var index = 19
        var fraction = 0
        var divisor = 1
        if index < bytes.count, bytes[index] == ascii(".") {
            index += 1
            var digitCount = 0
            while index < bytes.count, let digit = decimalDigit(bytes[index]) {
                if digitCount < 9 {
                    fraction = fraction * 10 + digit
                    divisor *= 10
                }
                digitCount += 1
                index += 1
            }
            guard digitCount > 0 else {
                return nil
            }
        }

        let offsetSeconds: Int
        if index == bytes.count {
            offsetSeconds = 0
        } else if bytes[index] == ascii("Z") {
            index += 1
            guard index == bytes.count else {
                return nil
            }
            offsetSeconds = 0
        } else if bytes[index] == ascii("+") || bytes[index] == ascii("-") {
            let sign = bytes[index] == ascii("+") ? 1 : -1
            index += 1
            guard let offsetHour = parseFixedInt(bytes, start: index, length: 2),
                  (0...23).contains(offsetHour)
            else {
                return nil
            }
            index += 2
            if index < bytes.count, bytes[index] == ascii(":") {
                index += 1
            }
            guard let offsetMinute = parseFixedInt(bytes, start: index, length: 2),
                  (0...59).contains(offsetMinute)
            else {
                return nil
            }
            index += 2
            guard index == bytes.count else {
                return nil
            }
            offsetSeconds = sign * ((offsetHour * 60 + offsetMinute) * 60)
        } else {
            return nil
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let wholeSeconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(wholeSeconds) + TimeInterval(fraction) / TimeInterval(divisor))
    }

    private static func parseFixedInt(_ bytes: [UInt8], start: Int, length: Int) -> Int? {
        guard start >= 0, length > 0, start + length <= bytes.count else {
            return nil
        }
        var value = 0
        for index in start..<(start + length) {
            guard let digit = decimalDigit(bytes[index]) else {
                return nil
            }
            value = value * 10 + digit
        }
        return value
    }

    private static func decimalDigit(_ byte: UInt8) -> Int? {
        let zero = ascii("0")
        let nine = ascii("9")
        guard byte >= zero, byte <= nine else {
            return nil
        }
        return Int(byte - zero)
    }

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        guard month >= 1, month <= 12, day >= 1 else {
            return false
        }
        return day <= daysInMonth(year: year, month: month)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            return isLeapYear(year) ? 29 : 28
        default:
            return 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var adjustedYear = year
        adjustedYear -= month <= 2 ? 1 : 0
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let monthPrime = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func ascii(_ value: Character) -> UInt8 {
        value.asciiValue ?? 0
    }
}
