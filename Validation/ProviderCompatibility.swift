import Foundation
import CPAKit

func validateProviderCompatibility() async throws {
    let raw = Data(#"{"observed_at":"2026-09-21T12:00:00.123Z","signals":{"plan":"Pro","daily_quota_remaining_percent":"0%","weekly_quota_remaining_percent":"73%","daily_quota_reset_at":"2099-01-01T00:00:00Z","plan_end":"2099-02-01T00:00:00Z"}}"#.utf8)
    let quota = try JSONDecoder().decode(DevinQuota.self, from: raw)
    let usage = quota.usage()
    try expect(usage.primary?.remainingPercent == 0 && usage.primary?.usedPercent == 100, "Devin zero remaining quota is valid")
    try expect(usage.weekly?.remainingPercent == 73 && usage.planType == "Pro", "Devin quota and plan must decode")
    try expect(usage.observation == .server(quota.observedAt), "Devin quota must retain its observation timestamp")
    for invalid in [#"{}"#, #"{"signals":null}"#, #"{"signals":{"daily_quota_remaining_percent":"NaN","weekly_quota_remaining_percent":"101%"}}"#, #"{"signals":{"daily_quota_remaining_percent":"0%","daily_quota_reset_at":"2020-01-01T00:00:00Z"}}"#] {
        let unknown = try JSONDecoder().decode(DevinQuota.self, from: Data(invalid.utf8))
        try expect(!unknown.usage().hasQuotaSignal, "Invalid or expired Devin observations must stay unknown")
    }
    try expect(!OAuthProvider.devin.usesDeviceFlow && OAuthProvider.devin.callbackPort == nil, "Devin uses authorization code with a dynamic port")
    try expect(OAuthProvider.meta.usesDeviceFlow && OAuthProvider.kimiAI.usesDeviceFlow, "Meta and Kimi.ai use device flow")
    let authProviders = Dictionary(uniqueKeysWithValues: OAuthProvider.allCases.map { ($0, $0.authProvider) })
    try expect(authProviders == [
        .codex: "codex", .claude: "claude", .antigravity: "antigravity", .xai: "xai",
        .kimi: "kimi", .devin: "devin", .meta: "meta", .kimiAI: "kimi-ai"
    ], "OAuth providers must use the shared v8 auth-url provider names")
    try expect(ProviderCatalog.info(for: "cognition").key == "devin", "Cognition resolves to Devin")
    try expect(ProviderCatalog.info(for: "kimi-ai").displayName == "Kimi.ai", "Kimi.ai keeps its own display name")
    for alias in ["kimi.ai", "kimi_ai"] {
        try expect(ProviderCatalog.info(for: alias).key == "kimi-ai", "Kimi.ai credential aliases must resolve to Kimi.ai")
    }
    try expect(ProviderCatalog.info(for: "kimi.com").key == "kimi", "Domain-style Kimi credentials must resolve to Kimi")
    try expect(ProviderCatalog.info(for: "meta").supportsUsage, "Meta must report quota through its Muse endpoint")
    try expect(APIKeyChannelKind.meta.definitionsChannel == "meta", "Meta config models use their own catalog")
    try validateOAuthCallback("http://127.0.0.1:18317/callback?code=test&state=session", state: "session")
    for invalid in ["http://localhost/?code=test&state=other", "https://example.com/?code=test&state=session", "http://localhost/?state=session", "http://localhost/?code=test&state=session&state=other"] {
        var rejected = false
        do { try validateOAuthCallback(invalid, state: "session") } catch { rejected = true }
        try expect(rejected, "OAuth callback must belong to the current session")
    }

    let session = RouteSession(routes: [
        "/v8/management/oauth/auth-url": (200, Data(#"{"url":"https://app.devin.ai/auth/cli/continue","state":"session"}"#.utf8)),
        "/v8/management/oauth/callback": (200, Data(#"{"status":"ok"}"#.utf8)),
        "/v8/management/oauth/status": (200, Data(#"{"status":"wait"}"#.utf8)),
        "/v8/management/oauth/session": (200, Data(#"{"status":"ok"}"#.utf8)),
        "/v8/management/credentials/refresh": (200, Data(#"{"ok":true,"auth":{"metadata":{"session_token":"synthetic-secret"},"quota":{"observed_at":"2026-09-21T12:00:00Z","signals":{"plan":"Pro","daily_quota_remaining_percent":"91%","weekly_quota_remaining_percent":"23%"}}}}"#.utf8))
    ])
    let client = try CPAClient(baseURLString: "https://pool.example", managementKey: "management-secret", session: session)
    let auth = try await client.requestOAuthURL(for: .devin)
    try expect(!auth.isDeviceFlow && auth.state == "session", "Devin authorization URL must preserve state")
    try await client.submitOAuthCallback(provider: "devin", redirectURL: "http://127.0.0.1:18317/callback?code=test&state=session", state: auth.state)
    let status = try await client.pollOAuthStatus(state: auth.state)
    try expect(status == .wait, "Successful callback submission is not completed authorization")
    try await client.cancelOAuthSession(state: auth.state)
    let account = try JSONDecoder().decode(CPAAccount.self, from: Data(#"{"id":"virtual-id","name":"devin account.json","provider":"devin","auth_index":"devin-index","status":"active","quota":{"signals":{"daily_quota_remaining_percent":"0%"}}}"#.utf8))
    let cached = AccountQuota(account: account, usage: nil, errorMessage: nil)
    try expect(cached.usage?.primary?.remainingPercent == 0, "Dashboard should surface server quota observations")
    try expect(account.quota?.exceeded == false && account.nextRecoveryDate == nil, "Zero quota does not invent a scheduler cooldown")
    let refreshed = await client.fetchAccountQuota(for: account)
    try expect(refreshed.errorMessage == nil && refreshed.usage?.primary?.remainingPercent == 91, "Devin active refresh must decode the safe quota projection")
    try expect(!String(describing: refreshed).contains("synthetic-secret"), "Credential material must not enter client snapshots")
    let requests = await session.requests
    try expect(requests.map { $0.url?.path ?? "" } == [
        "/v8/management/oauth/auth-url",
        "/v8/management/oauth/callback",
        "/v8/management/oauth/status",
        "/v8/management/oauth/session",
        "/v8/management/credentials/refresh"
    ], "Devin uses the v8 management endpoints only")
    try expect(requests[0].url?.query == "provider=devin", "The shared auth-url endpoint must name the provider")
    try expect(requests[2].url?.query == "state=session", "Status polling must target the login state")
    for request in requests { try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret", "Management requests require bearer authentication") }
    try expect(requests[3].httpMethod == "DELETE" && requests[3].url?.query == "state=session", "Closing login cancels the server session")
    let body = try require(requests.last?.httpBody, "Missing Devin refresh body")
    let payload = try require(JSONSerialization.jsonObject(with: body) as? [String: String], "Invalid refresh body")
    try expect(payload == ["name": "devin account.json", "auth_index": "devin-index"], "Refresh must target exactly one account")

    try expect(ProviderQuotaMetricKind.devinDaily.remainingPercent(in: refreshed) == 91, "Devin dashboard average uses daily remaining quota")
    try await validateDeviceAuthorizationURLs()
    try await validateKimiQuotaHosts()

    let missingState = CapturingSession(payload: Data(#"{"url":"https://app.devin.ai/auth/cli/continue"}"#.utf8))
    var rejected = false
    do { _ = try await CPAClient(baseURLString: "https://pool.example", managementKey: "key", session: missingState).requestOAuthURL(for: .devin) } catch { rejected = true }
    try expect(rejected, "Missing OAuth state must not be mistaken for successful login")
    try await validateMetaQuota()
}

private func validateDeviceAuthorizationURLs() async throws {
    let session = RouteSession(routes: [
        "/v8/management/oauth/auth-url": (200, Data(#"{"url":"https://example.com/device","state":"session","flow":"device","user_code":"EXAMPLE","expires_in":1800}"#.utf8))
    ])
    let client = try CPAClient(baseURLString: "https://pool.example", managementKey: "management-secret", session: session)
    for provider in [OAuthProvider.xai, .meta, .kimiAI] {
        let auth = try await client.requestOAuthURL(for: provider)
        try expect(auth.isDeviceFlow && auth.userCode == "EXAMPLE" && auth.expiresIn == 1800, "Device authorization metadata must survive the shared auth-url endpoint")
    }
    let requests = await session.requests
    try expect(requests.allSatisfy { $0.url?.path == "/v8/management/oauth/auth-url" }, "Device providers must use the shared auth-url endpoint")
    try expect(requests.map { $0.url?.query ?? "" } == ["provider=xai", "provider=meta", "provider=kimi-ai"], "The auth-url request must name each provider")
}

private func validateKimiQuotaHosts() async throws {
    let hosts = [
        "kimi-ai": "https://api.kimi.ai/coding/v1/usages",
        "kimi.ai": "https://api.kimi.ai/coding/v1/usages",
        "kimi_ai": "https://api.kimi.ai/coding/v1/usages",
        "kimi": "https://api.kimi.com/coding/v1/usages",
        "kimi.com": "https://api.kimi.com/coding/v1/usages"
    ]
    for (provider, host) in hosts {
        let session = CapturingSession(payload: Data(#"{"status_code":200,"body":"{\"usage\":{\"limit\":100,\"used\":20,\"remaining\":80}}"}"#.utf8))
        let client = try CPAClient(baseURLString: "https://pool.example", managementKey: "key", session: session)
        let account = CPAAccount(id: provider, authIndex: "index", name: "\(provider).json", provider: provider)
        let quota = await client.fetchAccountQuota(for: account)
        try expect(quota.errorMessage == nil && quota.usage?.additionalWindows.first?.remainingPercent == 80, "Kimi usage must parse for \(provider)")
        let request = try require(session.lastRequest, "Missing Kimi request for \(provider)")
        try expect(request.url?.path == "/v8/management/requests/api-call", "Kimi quota must use the v8 api-call route")
        let payload = try require(apiCallPayloads([request]).first, "Invalid Kimi request for \(provider)")
        try expect(payload["url"] as? String == host, "\(provider) must use its own coding API host")
        try expect(apiCallHeaders(payload)["Authorization"] == "Bearer $TOKEN$", "Account tokens must remain server-resolved")
    }
}

private func validateMetaQuota() async throws {
    let baseURL = try CPABaseURLNormalizer.normalize("https://pool.example")
    let quotaURL = "https://api.meta.ai/muse-code/key"
    let quotaBody = #"{"api_key":"LLM|synthetic-response","user_email":"fixture@example.invalid","subs_tier_name":"Muse Code Everyday Usage","subs_usage":{"window":{"used_percent":2,"window_duration_mins":300,"resets_at":4102444800},"weekly":{"used_percent":0,"resets_at":4103049600},"tier":"fixture-tier"}}"#
    let session = UpstreamRouteSession(
        managementRoutes: [
            "/v8/management/credentials": Data(#"{"files":[{"id":"meta-account","auth_index":"meta-index","name":"meta-account.json","provider":"meta"}]}"#.utf8),
            "/v8/management/credentials/download": Data(#"{"type":"meta","api_key":"LLM|synthetic","dca_token":"dca:synthetic-token"}"#.utf8)
        ],
        upstreamRoutes: [quotaURL: apiCallEnvelope(quotaBody)]
    )
    let dashboard = try await CPAClient(baseURL: baseURL, managementKey: "management-secret", session: session).fetchDashboard()
    let quota = try require(dashboard.accountQuotas.first { $0.account.providerKey == "meta" }, "Missing Meta account")
    try expect(quota.supportsUsage && quota.errorMessage == nil, "Meta quota must refresh: \(quota.errorMessage ?? "")")
    let usage = try require(quota.usage, "Missing Meta quota")
    try expect(usage.planType == "Muse Code Everyday Usage", "Meta plan must come from subs_tier_name")
    try expect(usage.additionalWindows.map(\.id) == ["meta-window", "meta-weekly"], "Meta must expose its rolling and weekly windows")
    try expect(usage.additionalWindows.map(\.remainingPercent) == [98, 100], "Meta remaining quota must derive from used_percent")
    try expect(usage.additionalWindows.first?.detailText?.hasPrefix("5 小时周期") == true, "Meta rolling windows must show their duration")
    let snapshotText = String(describing: dashboard)
    for secret in ["LLM|synthetic", "fixture@example.invalid", "dca:synthetic-token"] {
        try expect(!snapshotText.contains(secret), "Meta credentials and profile data must not enter client snapshots")
    }
    let requests = await session.requests
    try expect(requests.contains { $0.url?.path == "/v8/management/credentials/download" }, "Meta must read its DCA token from the v8 credential download")
    let calls = apiCallPayloads(requests)
    try expect(calls.count == 1, "Meta quota must use exactly one upstream request")
    try expect(calls[0]["url"] as? String == quotaURL && calls[0]["method"] as? String == "POST", "Meta quota must POST the Muse quota endpoint")
    try expect(calls[0]["auth_index"] as? String == "meta-index" && calls[0]["data"] as? String == "{}", "Meta quota must send an empty JSON object for its account")
    try expect(apiCallHeaders(calls[0]) == [
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": "Bearer dca:synthetic-token",
        "x-api-version": "1.0.0"
    ], "Meta quota must authenticate with the persisted DCA token only")

    let metaAccount = CPAAccount(id: "meta-account", authIndex: "meta-index", name: "meta-account.json", provider: "meta")
    func metaSession(credential: String, response: Data) -> UpstreamRouteSession {
        UpstreamRouteSession(
            managementRoutes: ["/v8/management/credentials/download": Data(credential.utf8)],
            upstreamRoutes: [quotaURL: response]
        )
    }
    for credential in [#"{"api_key":"LLM|synthetic"}"#, #"{"dca_token":"LLM|synthetic"}"#, #"{"dca_token":"dca:"}"#] {
        let rejectedSession = metaSession(credential: credential, response: apiCallEnvelope(quotaBody))
        let rejected = await CPAClient(baseURL: baseURL, managementKey: "key", session: rejectedSession).fetchAccountQuota(for: metaAccount)
        let rejectedRequests = await rejectedSession.requests
        try expect(rejected.errorMessage?.contains("missing Meta dca_token") == true, "Meta quota must require a persisted dca: token")
        try expect(apiCallPayloads(rejectedRequests).isEmpty, "The LLM API key must never be sent as a Meta quota token")
    }
    let trimmedSession = metaSession(credential: #"{"dca_token":" dca:abc "}"#, response: apiCallEnvelope(quotaBody))
    _ = await CPAClient(baseURL: baseURL, managementKey: "key", session: trimmedSession).fetchAccountQuota(for: metaAccount)
    let trimmedRequests = await trimmedSession.requests
    let trimmedCall = try require(apiCallPayloads(trimmedRequests).first, "Missing trimmed Meta quota request")
    try expect(apiCallHeaders(trimmedCall)["Authorization"] == "Bearer dca:abc", "Meta DCA tokens must be trimmed")

    let failedSession = metaSession(
        credential: #"{"dca_token":"dca:synthetic-token"}"#,
        response: apiCallEnvelope(#"{"api_key":"LLM|leaked","user_email":"leak@example.invalid"}"#, status: 403)
    )
    let failure = await CPAClient(baseURL: baseURL, managementKey: "key", session: failedSession).fetchAccountQuota(for: metaAccount).errorMessage ?? ""
    try expect(failure.contains("HTTP 403") && failure.contains("Meta quota request failed"), "Meta quota failures must report the upstream status")
    try expect(!failure.contains("LLM|leaked") && !failure.contains("leak@example.invalid"), "Meta quota failures must not echo the response body")

    let unknownSession = metaSession(credential: #"{"dca_token":"dca:synthetic-token"}"#, response: apiCallEnvelope(#"{"subs_tier_name":"Muse Code"}"#))
    let unknown = await CPAClient(baseURL: baseURL, managementKey: "key", session: unknownSession).fetchAccountQuota(for: metaAccount)
    try expect(unknown.errorMessage == nil && unknown.usage?.planType == "Muse Code", "Meta plan must survive missing usage")
    try expect(unknown.usage?.additionalWindows.isEmpty == true && unknown.usage?.rawStatus == "usage_unknown", "Missing Meta usage stays unknown instead of zero")

    let minutes = try require(UsageParser.parse(#"{"_provider":"meta","quota":{"subs_usage":{"tier":"fallback-tier","window":{"used_percent":150,"window_duration_mins":90}}}}"#), "Meta minute windows must parse")
    try expect(minutes.planType == "fallback-tier", "Meta plan falls back to subs_usage.tier")
    let rolling = try require(minutes.additionalWindows.first, "Missing Meta rolling window")
    try expect(rolling.detailText == "90 分钟周期" && rolling.remainingPercent == 0 && rolling.isUsable == false, "Meta minute windows must clamp usage and keep their duration")
    try expect(minutes.additionalWindows.last?.remainingPercent == nil, "Missing Meta weekly usage stays unknown")
}
