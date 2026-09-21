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
    try expect(ProviderCatalog.info(for: "cognition").key == "devin", "Cognition resolves to Devin")
    try expect(!ProviderCatalog.info(for: "meta").supportsUsage, "Meta must not advertise an invented quota API")
    try expect(APIKeyChannelKind.meta.definitionsChannel == "meta", "Meta config models use their own catalog")
    try validateOAuthCallback("http://127.0.0.1:18317/callback?code=test&state=session", state: "session")
    for invalid in ["http://localhost/?code=test&state=other", "https://example.com/?code=test&state=session", "http://localhost/?state=session", "http://localhost/?code=test&state=session&state=other"] {
        var rejected = false
        do { try validateOAuthCallback(invalid, state: "session") } catch { rejected = true }
        try expect(rejected, "OAuth callback must belong to the current session")
    }

    let session = RouteSession(routes: [
        "/v0/management/devin-auth-url": (200, Data(#"{"url":"https://app.devin.ai/auth/cli/continue","state":"session"}"#.utf8)),
        "/v0/management/oauth-callback": (200, Data(#"{"status":"ok"}"#.utf8)),
        "/v0/management/get-auth-status": (200, Data(#"{"status":"wait"}"#.utf8)),
        "/v0/management/oauth-session": (200, Data(#"{"status":"ok"}"#.utf8)),
        "/v0/management/auth-files/refresh": (200, Data(#"{"ok":true,"auth":{"metadata":{"session_token":"synthetic-secret"},"quota":{"observed_at":"2026-09-21T12:00:00Z","signals":{"plan":"Pro","daily_quota_remaining_percent":"91%","weekly_quota_remaining_percent":"23%"}}}}"#.utf8))
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
    try expect(requests.count == 5, "Devin uses management endpoints only")
    for request in requests { try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret", "Management requests require bearer authentication") }
    try expect(requests[3].httpMethod == "DELETE", "Closing login cancels the server session")
    let body = try require(requests.last?.httpBody, "Missing Devin refresh body")
    let payload = try require(JSONSerialization.jsonObject(with: body) as? [String: String], "Invalid refresh body")
    try expect(payload == ["name": "devin account.json", "auth_index": "devin-index"], "Refresh must target exactly one account")

    try expect(ProviderQuotaMetricKind.devinDaily.remainingPercent(in: refreshed) == 91, "Devin dashboard average uses daily remaining quota")
    let kimiSession = CapturingSession(payload: Data(#"{"status_code":200,"body":"{\"usage\":{\"limit\":100,\"used\":20,\"remaining\":80}}"}"#.utf8))
    let kimi = try JSONDecoder().decode(CPAAccount.self, from: Data(#"{"id":"kimi-ai","name":"kimi-ai.json","provider":"kimi-ai","auth_index":"index"}"#.utf8))
    let kimiClient = try CPAClient(baseURLString: "https://pool.example", managementKey: "key", session: kimiSession)
    let kimiQuota = await kimiClient.fetchAccountQuota(for: kimi)
    try expect(kimiQuota.errorMessage == nil, "Kimi.ai usage must parse")
    let kimiBody = try require(kimiSession.lastRequest?.httpBody, "Missing Kimi.ai request")
    let kimiPayload = try require(JSONSerialization.jsonObject(with: kimiBody) as? [String: Any], "Invalid Kimi.ai request")
    try expect(kimiPayload["url"] as? String == "https://api.kimi.ai/coding/v1/usages", "Kimi.ai must use its own host")
    let kimiHeaders = kimiPayload["header"] as? [String: String]
    try expect(kimiHeaders?["Authorization"] == "Bearer $TOKEN$", "Account tokens must remain server-resolved")

    let missingState = CapturingSession(payload: Data(#"{"url":"https://app.devin.ai/auth/cli/continue"}"#.utf8))
    var rejected = false
    do { _ = try await CPAClient(baseURLString: "https://pool.example", managementKey: "key", session: missingState).requestOAuthURL(for: .devin) } catch { rejected = true }
    try expect(rejected, "Missing OAuth state must not be mistaken for successful login")
}
