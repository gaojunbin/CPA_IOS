import Foundation
import CPAKit

func validateConfiguredModels(_ check: (Bool, String) throws -> Void) throws {
    // Fixture shapes follow CLIProxyAPI v7.3.10 config handlers and model registration.
    for kind in APIKeyChannelKind.allCases {
        let root: [String: Any] = [kind.rawValue: [[
            "api-key": "",
            "base-url": "http://localhost:8080/v1",
            "prefix": "team",
            "excluded-models": ["blocked-*"],
            "models": [
                ["name": "upstream-a", "alias": "blocked-a"],
                ["name": "upstream-b", "alias": "chat", "display-name": "Custom Chat",
                 "max-context-length": 1_048_576, "thinking": ["levels": ["low", "high"]]],
                ["name": "upstream-c", "alias": "chat", "display-name": "Second Route"]
            ]
        ]]]
        let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: kind, root: root)
        let accounts = ConfigChannelSynthesizer.apiKeyAccounts(
            kind: kind, entries: entries, staticModels: [CPAModelDefinition(id: "default-only")]
        )
        try check(accounts.count == 1, "Base-URL-only credentials must remain visible")
        let account = accounts[0]
        try check(account.models.map(\.id) == ["chat", "team/chat"], "Exclusions apply to aliases before prefix expansion")
        try check(account.routes.map(\.name) == ["upstream-b", "upstream-c"], "Distinct upstreams sharing an alias must remain visible")
        for model in account.models {
            try check(model.displayName == "Custom Chat", "First configured display name must survive deduplication and prefixes")
            try check(model.contextLength == 1_048_576, "Configured context length must survive prefixes")
            try check(model.thinking?.levels == ["low", "high"], "Configured thinking capabilities must survive prefixes")
        }

        let excludedRoot: [String: Any] = [kind.rawValue: [[
            "models": [["name": "upstream", "alias": "blocked"]], "excluded-models": ["blocked"]
        ]]]
        let excluded = ConfigChannelSynthesizer.apiKeyAccounts(
            kind: kind,
            entries: ConfigChannelSynthesizer.apiKeyEntries(kind: kind, root: excludedRoot),
            staticModels: [CPAModelDefinition(id: "unrelated-default")]
        )
        try check(excluded.first?.models.isEmpty == true, "Fully excluded overrides must not restore default models")
        try check(excluded.first?.routes.isEmpty == true, "Fully excluded routes must not remain advertised")

        let defaults = ConfigChannelSynthesizer.apiKeyAccounts(
            kind: kind,
            entries: [APIKeyChannelEntry(overrideModelIDs: [], excludedPatterns: [], prefix: "team")],
            staticModels: [CPAModelDefinition(
                id: "default", displayName: "Default Model", description: "Static metadata",
                contextLength: 200_000, maxCompletionTokens: 32_000,
                supportedInputModalities: ["text", "image"], supportedOutputModalities: ["text"],
                supportsWebSearch: true
            )]
        )
        for model in defaults[0].models {
            try check(model.displayName == "Default Model", "Static display names must survive prefixes")
            try check(model.contextLength == 200_000 && model.maxCompletionTokens == 32_000, "Static token limits must remain intact")
            try check(model.supportedInputModalities == ["text", "image"] && model.supportsWebSearch == true, "Static capabilities must remain intact")
            try check(model.description == "Static metadata", "Static descriptions must remain intact")
        }
    }

    let compat = ConfigChannelSynthesizer.compatAccounts(root: ["openai-compatibility": [[
        "name": "gateway", "prefix": "team", "base-url": "http://localhost:8080/v1",
        "models": [["name": "upstream", "alias": "chat", "display-name": "Gateway Chat",
                    "max-context-length": 128_000, "input-modalities": ["TEXT", "IMAGE"],
                    "output-modalities": ["TEXT"]]]
    ]]])
    try check(compat.count == 1, "Keyless compatibility channels must remain visible")
    try check(compat[0].models.map(\.id) == ["chat", "team/chat"], "Compatibility prefixes must remain intact")
    for model in compat[0].models {
        try check(model.displayName == "Gateway Chat" && model.contextLength == 128_000, "Compatibility model metadata must remain intact")
        try check(model.supportedInputModalities == ["text", "image"], "Configured input modalities must be normalized")
        try check(model.supportedOutputModalities == ["text"], "Configured output modalities must remain intact")
    }
}

func validateManagementRuntimeCompatibility() throws {
    let data = Data(#"{"files":[{"id":"account","name":"account.json","provider":"codex","auth_index":"index","status":"active","quota":{"observed_at":"2026-09-09T00:00:00Z","signals":{"X-Codex-Primary-Used-Percent":"100"}},"model_quotas":{"model":{"signals":{"X-Codex-Primary-Used-Percent":"100"}}}}]}"#.utf8)
    let account = try require(JSONDecoder().decode(AuthFilesResponse.self, from: data).files.first, "Missing account")
    try expect(!account.hasModelRuntimeStatus, "Passive model quota signals must not imply runtime-state availability")
    try expect(account.quota?.exceeded == false && account.nextRecoveryDate == nil, "Passive quota observations must not become scheduler cooldowns")
    try expect(account.quotaLine == "账号就绪", "An active account does not prove available quota")
    let empty = try JSONDecoder().decode(CPAAccount.self, from: Data(#"{"id":"empty","model_states":{}}"#.utf8))
    try expect(empty.hasModelRuntimeStatus, "An explicitly returned runtime-state dictionary must be recognized")
    let model: [String: Any] = ["scope": "model", "model_key": "gpt-5", "reason": "quota",
                                "retry_at": "2099-01-01T00:00:00.123456789Z", "remaining_seconds": 20]
    func decodeCooldowns(_ value: Any) throws -> CPAAccount {
        try JSONDecoder().decode(CPAAccount.self, from: JSONSerialization.data(withJSONObject: [
            "id": "test", "status": "active", "cooldowns": value,
            "quota": ["signals": ["used": "100"]]
        ]))
    }
    let partial = try decodeCooldowns([model])
    try expect(partial.activeModelCooldowns.map(\.model) == ["gpt-5"], "Model cooldowns must be visible")
    try expect(partial.modelRuntimeStates["gpt-5"]?.statusMessage == "模型额度冷却", "Cooldown reasons must be displayed")
    var rateLimited = model
    rateLimited["reason"] = "transient_rate_limit"
    let transient = try decodeCooldowns([rateLimited])
    try expect(transient.modelRuntimeStates["gpt-5"]?.statusMessage == "上游临时限流", "Transient upstream rate limits must be named")
    try expect(partial.statusKind == .available, "A model cooldown must not block the whole credential")
    try expect(partial.nextRecoveryDate != nil && partial.quota?.exceeded == false, "Cooldown timers and observed quota remain independent")
    try expect(AccountQuota(account: partial, usage: nil, errorMessage: nil).isHealthy, "Partial model cooldowns preserve account health")
    try expect(!partial.hasModelRuntimeStatus, "Cooldown snapshots do not assert positive model availability")
    var credential = model
    credential["scope"] = "credential"
    credential["reason"] = "credential_quota"
    let blocked = try decodeCooldowns([credential])
    try expect(blocked.statusKind == .cooling && blocked.activeModelCooldowns.isEmpty, "Credential cooldowns must remain separate from model cooldowns")
    let unknownCooldowns = try decodeCooldowns(NSNull())
    try expect(unknownCooldowns.cooldowns == nil, "Null cooldowns mean unknown")
    let emptyCooldowns = try decodeCooldowns([])
    try expect(emptyCooldowns.cooldowns == [], "An empty cooldown snapshot means no reported timers")
    var expired = model
    expired["retry_at"] = "2000-01-01T00:00:00Z"
    let cleared = try decodeCooldowns([expired])
    try expect(cleared.activeModelCooldowns.isEmpty && cleared.nextRecoveryDate == nil, "Expired timers must disappear without leaving stale limitations")
    var invalid = model
    invalid["retry_at"] = "invalid"
    let invalidCooldowns = try decodeCooldowns([invalid])
    try expect(invalidCooldowns.activeCooldowns.isEmpty, "Malformed timers must not assert a restriction")
    for status in ["error", "failed", "disabled"] {
        let failed = CPAAccount(id: status, name: status, status: status)
        try expect(!AccountQuota(account: failed, usage: nil, errorMessage: nil).isHealthy, "Backend error status must not count as healthy")
    }
}

/// Wraps an upstream JSON body in the management `api-call` response envelope.
func apiCallEnvelope(_ body: String, status: Int = 200) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["status_code": status, "body": body])) ?? Data()
}

/// Decodes the `api-call` payloads forwarded through the v8 management route, in request order.
func apiCallPayloads(_ requests: [URLRequest]) -> [[String: Any]] {
    requests.compactMap { request in
        guard request.url?.path == "/v8/management/requests/api-call", let body = request.httpBody else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

func apiCallHeaders(_ payload: [String: Any]) -> [String: String] {
    payload["header"] as? [String: String] ?? [:]
}

func validateV8ManagementClient() async throws {
    try await validateUnsupportedServer()
    try await validateClaudeRequestIdentity()
    try await validateCodexRequestIdentity()
    try await validateAntigravityRequestIdentity()
    try await validateXAIRequestIdentity()
}

private func validateUnsupportedServer() async throws {
    let message = "需要 CLIProxyAPI v8.0.0 或更高版本并启用管理 API（/v8/management 返回 404）"
    try expect(CPAAPIError.unsupportedServer.localizedDescription == message, "Servers without v8 routes must get a dedicated error")
    let session = RouteSession(routes: [:])
    let client = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://pool.example"), managementKey: "management-secret", session: session)
    do {
        _ = try await client.fetchDashboard(includeLiveUsage: false)
        throw ValidationError.failed("the dashboard must reject servers without v8 routes")
    } catch CPAAPIError.unsupportedServer {
    }
    do {
        _ = try await client.fetchModelPool()
        throw ValidationError.failed("the model pool must reject servers without v8 routes")
    } catch CPAAPIError.unsupportedServer {
    }
    let requests = await session.requests
    let paths = requests.compactMap { $0.url?.path }
    try expect(paths.contains("/v8/management/credentials"), "Credential lists must use the v8 route")
    try expect(!paths.contains { $0.hasPrefix("/v0/management/auth-files") }, "Credential lists must not fall back to v0 routes")
}

private func validateClaudeRequestIdentity() async throws {
    let session = UpstreamRouteSession(upstreamRoutes: [
        "https://api.anthropic.com/api/oauth/usage": apiCallEnvelope(#"{"five_hour":{"utilization":20,"resets_at":"2099-01-01T00:00:00Z"}}"#),
        "https://api.anthropic.com/api/oauth/profile": apiCallEnvelope(#"{"account":{"has_claude_pro":true}}"#)
    ])
    let client = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://pool.example"), managementKey: "key", session: session)
    let quota = await client.fetchAccountQuota(for: CPAAccount(id: "claude", authIndex: "index", name: "claude.json", provider: "claude"))
    try expect(quota.usage?.additionalWindows.first?.remainingPercent == 80 && quota.usage?.planType == "专业版", "Claude usage and profile must parse")
    let calls = apiCallPayloads(await session.requests)
    try expect(calls.count == 2, "Claude quota reads usage and profile")
    for call in calls {
        let headers = apiCallHeaders(call)
        try expect(headers["User-Agent"] == "claude-cli/2.1.280 (external, cli)", "Claude quota requests must use the Claude CLI identity")
        try expect(headers["anthropic-beta"] == "oauth-2025-04-20", "Claude quota requests must keep the OAuth beta header")
        let isUsage = (call["url"] as? String)?.hasSuffix("/usage") == true
        try expect(headers["Accept"] == (isUsage ? "application/json" : nil), "Only the Claude usage request asks for JSON explicitly")
    }
}

private func validateCodexRequestIdentity() async throws {
    let userAgent = "codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)"
    let session = UpstreamRouteSession(upstreamRoutes: [
        "https://chatgpt.com/backend-api/wham/usage": apiCallEnvelope(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}},"credits":{"has_credits":true,"balance":"12.50"}}"#),
        "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits": apiCallEnvelope(#"{"available_count":2,"credits":[]}"#)
    ])
    let client = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://pool.example"), managementKey: "key", session: session)
    let account = CPAAccount(id: "codex", authIndex: "codex-index", name: "codex.json", provider: "codex", chatgptAccountID: "chatgpt-account")
    let quota = await client.fetchAccountQuota(for: account)
    let credit = try require(quota.usage?.additionalWindows.first { $0.id == "codex-credit-balance" }, "Codex credit balance missing")
    try expect(credit.label == "Credit 余额" && credit.displayValue == "12.50", "Codex credit balance must keep its decimal text")
    let calls = apiCallPayloads(await session.requests)
    try expect(calls.count == 2, "Codex quota reads usage and reset credits")
    try expect(calls.allSatisfy { apiCallHeaders($0)["User-Agent"] == userAgent }, "Codex quota requests must use the Codex TUI identity")
    let reset = try require(calls.first { ($0["url"] as? String)?.hasSuffix("rate-limit-reset-credits") == true }, "Codex reset-credit request missing")
    let headers = apiCallHeaders(reset)
    try expect(headers["OpenAI-Beta"] == "codex-1" && headers["Originator"] == "Codex Desktop", "Codex reset credits keep the desktop headers")
    try expect(headers["ChatGPT-Account-Id"] == "chatgpt-account", "Codex reset credits target the ChatGPT account")
}

private func validateAntigravityRequestIdentity() async throws {
    let session = UpstreamRouteSession(upstreamRoutes: [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels": apiCallEnvelope(#"{"models":{"gemini-3-pro-high":{"quotaInfo":{"remainingFraction":0.5}}}}"#)
    ])
    let client = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://pool.example"), managementKey: "key", session: session)
    let account = CPAAccount(id: "ag", authIndex: "ag-index", name: "ag.json", provider: "antigravity", projectID: "project-123")
    let quota = await client.fetchAccountQuota(for: account)
    try expect(quota.errorMessage == nil && quota.usage?.hasQuotaSignal == true, "Antigravity must fall back to the legacy model quota")
    let calls = apiCallPayloads(await session.requests)
    let targets = calls.compactMap { $0["url"] as? String }
    try expect(targets.contains { $0.contains("retrieveUserQuotaSummary") } && targets.contains { $0.contains("fetchAvailableModels") }, "Antigravity must try the summary before the legacy endpoint")
    try expect(calls.allSatisfy { apiCallHeaders($0)["User-Agent"] == "antigravity/hub/2.23.0 darwin/arm64" }, "Antigravity requests must use the Hub identity")
}

private func validateXAIRequestIdentity() async throws {
    let session = UpstreamRouteSession(
        managementRoutes: ["/v8/management/credentials/download": Data(#"{"sub":"xai-user-123"}"#.utf8)],
        upstreamRoutes: [
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits": apiCallEnvelope(#"{"config":{"currentPeriod":{"type":"weekly","end":"2099-08-01T00:00:00Z"},"creditUsagePercent":25,"productUsage":[{"product":"Grok Code","usagePercent":40}]}}"#),
            "https://cli-chat-proxy.grok.com/v1/billing": apiCallEnvelope(#"{"config":{"monthlyLimit":{"val":10000},"used":{"val":2000},"onDemandCap":{"val":5000},"billingPeriodEnd":"2099-08-01T00:00:00Z"}}"#)
        ]
    )
    let client = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://pool.example"), managementKey: "key", session: session)
    let quota = await client.fetchAccountQuota(for: CPAAccount(id: "xai", authIndex: "xai-index", name: "xai.json", provider: "xai"))
    let weekly = try require(quota.usage?.additionalWindows.first, "Grok weekly credits missing")
    try expect(weekly.label == "周积分" && weekly.remainingPercent == 75, "Grok weekly credits must parse")
    let requests = await session.requests
    try expect(requests.contains { $0.url?.path == "/v8/management/credentials/download" }, "Grok user IDs must come from the v8 credential download")
    let calls = apiCallPayloads(requests)
    try expect(Set(calls.compactMap { $0["url"] as? String }) == [
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
        "https://cli-chat-proxy.grok.com/v1/billing"
    ], "Grok quota reads weekly and monthly billing")
    for call in calls {
        let headers = apiCallHeaders(call)
        try expect(headers["x-xai-token-auth"] == "xai-grok-cli" && headers["x-userid"] == "xai-user-123", "Grok billing keeps its CLI auth headers")
        try expect(headers["x-grok-client-version"] == "1.0.46", "Grok billing must send a supported CLI version")
        try expect(headers["User-Agent"] == "grok-pager/1.0.46 grok-shell/1.0.46 (macos; aarch64)", "Grok billing must use the matching CLI identity")
    }
}

func validateCurrentQuotaPayloads() throws {
    try validateAntigravityWeeklyGate()
    try validateClaudeCurrentWindows()
    try validateKimiCurrentWindows()
    try validateCodexCreditBalance()
}

private func validateAntigravityWeeklyGate() throws {
    let usage = try require(UsageParser.parse("""
    {
      "_provider": "antigravity",
      "quota": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "description": "Models within this group: Gemini Flash, Gemini Pro",
            "buckets": [
              { "bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "resetTime": "2099-10-23T02:43:12Z", "remainingFraction": 0.4 },
              { "bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "resetTime": "2099-10-20T02:43:12Z", "remainingFraction": 0.9 }
            ]
          },
          {
            "displayName": "Claude and GPT models",
            "buckets": [
              { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "resetTime": "2099-10-23T02:43:12Z", "remainingFraction": 0 },
              { "bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "resetTime": "2099-10-20T02:43:12Z", "remainingFraction": 1 }
            ]
          }
        ]
      },
      "subscription": {}
    }
    """), "Current Antigravity summary must parse")
    let account = AccountQuota(account: CPAAccount(id: "ag", authIndex: "idx-ag", name: "ag.json", provider: "antigravity"), usage: usage, errorMessage: nil)
    let geminiFiveHour = try require(ProviderQuotaMetricKind.antigravityGeminiFiveHour.averagedWindow(in: account), "Gemini 5h slot missing")
    try expect(abs((geminiFiveHour.remainingPercent ?? 0) - 90) < 0.001 && geminiFiveHour.isUsable == true, "Gemini 5h slot must use its 5h bucket")
    let geminiWeekly = try require(ProviderQuotaMetricKind.antigravityGeminiSevenDay.averagedWindow(in: account), "Gemini weekly slot missing")
    try expect(abs((geminiWeekly.remainingPercent ?? 0) - 40) < 0.001, "Gemini weekly slot must use its weekly bucket")
    try expect(ProviderQuotaMetricKind.antigravityClaudeGPTSevenDay.averagedWindow(in: account)?.remainingPercent == 0, "Claude/GPT weekly slot must report exhaustion")
    // A full 5h bucket cannot be used while its group's weekly limit is exhausted.
    let blocked = try require(ProviderQuotaMetricKind.antigravityClaudeGPTFiveHour.matchingWindows(in: account).first, "Claude/GPT 5h bucket missing")
    try expect(blocked.remainingPercent == 100 && blocked.isUsable == false, "Weekly exhaustion must block the 5h bucket")
    try expect(blocked.detailText?.hasSuffix("周限额已用尽") == true, "Blocked 5h buckets must explain the weekly limit")
    try expect(ProviderQuotaMetricKind.antigravityClaudeGPTFiveHour.averagedWindow(in: account)?.isUsable == false, "A slot with only blocked buckets stays unusable")
    try expect(ProviderQuotaMetricKind.antigravityGeminiFiveHour.matchingWindows(in: account).first?.id == "antigravity-gemini-models-gemini-5h", "Antigravity bucket IDs must stay stable")
}

private func validateClaudeCurrentWindows() throws {
    let usage = try require(UsageParser.parse("""
    {
      "_provider": "claude",
      "profile": {
        "account": { "has_claude_max": true, "has_claude_pro": false },
        "organization": { "organization_type": "claude_team", "subscription_status": "active" }
      },
      "usage": {
        "seven_day": { "utilization": 10, "resets_at": "2026-05-27T17:31:04Z" },
        "iguana_necktie": { "utilization": 99, "resets_at": "2026-05-27T17:31:04Z" },
        "limits": [
          { "kind": "weekly_scoped", "percent": 40, "is_active": false, "scope": { "model": { "display_name": "Fable" } } },
          { "kind": "weekly_scoped", "percent": 30, "is_active": true, "resets_at": "2026-05-29T17:31:04Z", "scope": { "model": { "display_name": "Fable 5" } } }
        ],
        "workspace_spend": {
          "limit_dollars": 50, "used_dollars": 12.5, "remaining_dollars": 37.5,
          "utilization": 25, "resets_at": null
        },
        "extra_usage": {
          "is_enabled": false, "used_credits": 0, "monthly_limit": 2000,
          "utilization": 0, "currency": "EUR", "user_disabled": true
        }
      }
    }
    """), "Current Claude usage must parse")
    try expect(usage.planType == "团队版", "An active Team organization takes precedence over personal plan flags")
    try expect(usage.additionalWindows.map(\.id) == [
        "claude-seven-day",
        "claude-seven-day-fable",
        "claude-balance-workspace-spend",
        "claude-extra-usage"
    ], "Claude windows must follow the current usage contract")
    let fable = usage.additionalWindows[1]
    try expect(fable.label == "7 天 Fable 5" && fable.remainingPercent == 70, "The active Fable limit supersedes iguana_necktie")
    try expect(fable.resetAt == FlexibleDateParser.parse("2026-05-29T17:31:04Z"), "The Fable window must use its own reset time")
    let balance = usage.additionalWindows[2]
    try expect(balance.label == "workspace_spend" && balance.displayValue == "剩余 $37.50", "Independent dollar balances must show the remaining amount")
    try expect(balance.amountText == "已花费 $12.50 / 限额 $50.00" && balance.detailText == "重置时间未提供", "Dollar balances must show spend and a missing reset")
    let extra = usage.additionalWindows[3]
    try expect(extra.displayValue == "已禁用" && extra.amountText == "已花费 0.00 EUR / 限额 20.00 EUR", "Disabled extra usage must remain visible in its currency")
    try expect(extra.detailText == "已使用 0% · 用户已禁用", "Extra usage notes must be retained")

    let creditPool = try require(UsageParser.parse(#"{"_provider":"claude","usage":{"iguana_necktie":{"utilization":40,"resets_at":"2026-05-27T17:31:04Z","limit_dollars":20,"used_dollars":8,"remaining_dollars":12}}}"#), "Claude cloud session credits must parse")
    try expect(creditPool.additionalWindows.map(\.id) == ["claude-cloud-session-credits"], "Dollar-denominated iguana_necktie is the cloud session pool")
    let pool = creditPool.additionalWindows[0]
    try expect(pool.label == "云端会话额度" && pool.remainingPercent == 60, "Cloud session credits must keep their utilization")
    try expect(pool.amountText == "已花费 $8.00 / 限额 $20.00", "Cloud session credits must show their dollar amounts")

    let legacyFable = try require(UsageParser.parse(#"{"_provider":"claude","usage":{"iguana_necktie":{"utilization":25,"resets_at":"2026-05-27T17:31:04Z"}}}"#), "Legacy Claude Fable usage must parse")
    try expect(legacyFable.additionalWindows.map(\.label) == ["7 天 Fable 5"], "iguana_necktie without limits[] is the Fable 5 window")
    try expect(legacyFable.additionalWindows.first?.remainingPercent == 75, "The legacy Fable window must keep its utilization")
}

private func validateKimiCurrentWindows() throws {
    let usage = try require(UsageParser.parse("""
    {
      "limits": [
        {
          "detail": { "limit": "100", "used": "5", "remaining": "95", "resetTime": "2099-09-27T00:30:34.136523Z" },
          "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }
        },
        {
          "detail": { "limit": "10", "used": "1" },
          "window": { "duration": 90 }
        },
        {
          "detail": { "limit": "10", "used": "1" },
          "window": { "duration": 2, "timeUnit": "TIME_UNIT_WEEK" }
        }
      ],
      "usages": { "limit_month_total": { "used_ratio": 0.2529, "reset_time": "2099-10-22T00:00:00Z" } }
    }
    """), "Current Kimi usage must parse")
    try expect(usage.additionalWindows.map(\.label) == ["5小时限额", "90分钟限额", "2周限额", "月限额"], "Kimi protobuf units and the monthly total must be labelled")
    try expect(usage.additionalWindows.first?.remainingPercent == 95, "Kimi rolling limits must keep their remaining quota")
    try expect(usage.additionalWindows.first?.detailText?.hasSuffix("后重置") == true, "Kimi rolling limits must show their reset")
    let monthly = try require(usage.additionalWindows.last, "Kimi monthly total missing")
    try expect(monthly.id == "kimi-monthly" && monthly.usedPercent == 25 && monthly.remainingPercent == 75, "Kimi monthly totals must derive from used_ratio")
    try expect(monthly.detailText?.hasSuffix("后重置") == true, "Kimi monthly totals must show their reset")

    let unknownUnit = try require(UsageParser.parse(#"{"limits":[{"detail":{"limit":"10","used":"1"},"window":{"duration":120,"timeUnit":"TIME_UNIT_UNSPECIFIED"}}]}"#), "Unknown Kimi units must parse")
    try expect(unknownUnit.additionalWindows.map(\.label) == ["2小时限额"], "Unknown Kimi units are minutes")
    let monthlyOnly = try require(UsageParser.parse(#"{"usages":{"limit_month_total":{"used_ratio":"0.5"}}}"#), "Kimi monthly-only usage must parse")
    try expect(monthlyOnly.additionalWindows.map(\.label) == ["月限额"], "Plans without a weekly limit report the monthly total")
    try expect(UsageParser.parse(#"{"usages":{}}"#)?.additionalWindows.first { $0.id == "kimi-monthly" } == nil, "A missing monthly total must not invent quota")
}

private func validateCodexCreditBalance() throws {
    func creditWindow(_ credits: String) throws -> QuotaWindow? {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":"# + credits + "}"
        return try require(UsageParser.parse(body), "Codex usage with credits must parse")
            .additionalWindows.first { $0.id == "codex-credit-balance" }
    }
    let decimal = try creditWindow(#"{"has_credits":true,"balance":"12.50"}"#)
    try expect(decimal?.label == "Credit 余额" && decimal?.displayValue == "12.50", "Decimal credit balances must keep their text")
    let numeric = try creditWindow(#"{"balance":7}"#)
    try expect(numeric?.displayValue == "7", "Numeric credit balances must be shown")
    let unlimited = try creditWindow(#"{"unlimited":true,"balance":null}"#)
    try expect(unlimited?.displayValue == "无限额", "Unlimited credits must be shown")
    for invalid in [#"{"balance":"-1"}"#, #"{"balance":"abc"}"#, #"{"has_credits":false}"#] {
        let window = try creditWindow(invalid)
        try expect(window == nil, "Only plain non-negative credit balances are shown")
    }
}
