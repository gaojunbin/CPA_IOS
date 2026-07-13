import Foundation

public protocol CPAHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CPAHTTPSession {}

public enum CPAURLSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

public final class CPAClient: Sendable {
    public let baseURL: URL
    private let managementKey: String
    private let session: CPAHTTPSession
    private static let antigravityQuotaURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]
    private static let antigravityLegacyModelURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    ]
    private static let antigravitySubscriptionURL =
        "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let antigravityUserAgent =
        "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"
    private static let xaiClientVersion = "0.2.93"
    private static let xaiBillingWeeklyURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    private static let xaiBillingMonthlyURL = "https://cli-chat-proxy.grok.com/v1/billing"
    private static let accountQuotaBatchSize = 6
    private static let modelBatchSize = 8

    public init(baseURL: URL, managementKey: String, session: CPAHTTPSession = CPAURLSession.shared) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.session = session
    }

    public convenience init(baseURLString: String, managementKey: String, session: CPAHTTPSession = CPAURLSession.shared) throws {
        let url = try CPABaseURLNormalizer.normalize(baseURLString)
        self.init(baseURL: url, managementKey: managementKey, session: session)
    }

    public func fetchDashboard(includeLiveUsage: Bool = true) async throws -> ManagementDashboard {
        let authFilesResult: (AuthFilesResponse, HTTPURLResponse) = try await request(
            path: "/v0/management/auth-files"
        )
        let accounts = authFilesResult.0.files
        let accountQuotas = includeLiveUsage
            ? await fetchAccountQuotas(accounts)
            : accounts.map { AccountQuota(account: $0, usage: nil, errorMessage: nil) }

        return ManagementDashboard(
            accounts: accounts,
            accountQuotas: accountQuotas,
            serverVersion: authFilesResult.1.value(forHTTPHeaderField: "X-CPA-VERSION"),
            serverCommit: authFilesResult.1.value(forHTTPHeaderField: "X-CPA-COMMIT"),
            serverBuildDate: authFilesResult.1.value(forHTTPHeaderField: "X-CPA-BUILD-DATE"),
            fetchedAt: Date()
        )
    }

    public func fetchModels(for account: CPAAccount) async throws -> [CPAModelDefinition] {
        let queryName = account.name.isEmpty ? account.id : account.name
        let response: (ModelsResponse, HTTPURLResponse) = try await request(
            path: "/v0/management/auth-files/models",
            queryItems: [URLQueryItem(name: "name", value: queryName)]
        )
        return response.0.models
    }

    public func fetchAccountQuota(for account: CPAAccount) async -> AccountQuota {
        await quota(for: account)
    }

    private func optionalRequest<T: Decodable & Sendable>(path: String, timeout: TimeInterval = 20) async -> T? {
        do {
            let result: (T, HTTPURLResponse) = try await request(path: path, timeout: timeout)
            return result.0
        } catch {
            return nil
        }
    }

    func request<T: Decodable & Sendable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (T, HTTPURLResponse) {
        let request = try makeManagementRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            timeout: timeout
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CPAAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw CPAAPIError.httpStatus(
                code: httpResponse.statusCode,
                message: Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        do {
            return (try await Self.decodeResponse(T.self, from: data), httpResponse)
        } catch let decodingError as DecodingError {
            throw CPAAPIError.decoding(Self.decodingMessage(decodingError))
        } catch {
            throw CPAAPIError.decoding(error.localizedDescription)
        }
    }

    func dataRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeManagementRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            timeout: timeout
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CPAAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw CPAAPIError.httpStatus(
                code: httpResponse.statusCode,
                message: Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        return (data, httpResponse)
    }

    @MainActor
    private static func decodeResponse<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func fetchAccountQuotas(_ accounts: [CPAAccount]) async -> [AccountQuota] {
        var output: [AccountQuota] = []
        let sortedAccounts = accounts.sorted(by: accountSort)
        output.reserveCapacity(sortedAccounts.count)

        var start = 0
        while start < sortedAccounts.count {
            let batch = Array(sortedAccounts[start..<Swift.min(start + Self.accountQuotaBatchSize, sortedAccounts.count)])
            let results = await withTaskGroup(of: AccountQuota.self, returning: [AccountQuota].self) { group in
                for account in batch {
                    group.addTask {
                        await self.quota(for: account)
                    }
                }

                var values: [AccountQuota] = []
                values.reserveCapacity(batch.count)
                for await value in group {
                    values.append(value)
                }
                return values
            }
            output.append(contentsOf: results.sorted(by: accountQuotaSort))
            start += Self.accountQuotaBatchSize
        }
        return output
    }

    private func accountQuotaSort(_ lhs: AccountQuota, _ rhs: AccountQuota) -> Bool {
        accountSort(lhs.account, rhs.account)
    }

    private func accountSort(_ lhs: CPAAccount, _ rhs: CPAAccount) -> Bool {
        let leftInfo = ProviderCatalog.info(for: lhs.normalizedProvider)
        let rightInfo = ProviderCatalog.info(for: rhs.normalizedProvider)
        if leftInfo.priority != rightInfo.priority {
            return leftInfo.priority < rightInfo.priority
        }
        if lhs.normalizedProvider != rhs.normalizedProvider {
            return lhs.normalizedProvider < rhs.normalizedProvider
        }
        return stableAccountIdentitySort(lhs, rhs)
    }

    private func quota(for account: CPAAccount) async -> AccountQuota {
        let provider = ProviderCatalog.info(for: account.normalizedProvider)
        guard provider.supportsUsage else {
            return AccountQuota(account: account, usage: nil, errorMessage: nil, supportsUsage: false)
        }
        guard account.disabled == false else {
            return AccountQuota(account: account, usage: nil, errorMessage: nil, supportsUsage: true)
        }
        guard account.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return AccountQuota(account: account, usage: nil, errorMessage: "missing auth_index", supportsUsage: true)
        }

        do {
            let usage = try await fetchUsage(for: account)
            return AccountQuota(account: account, usage: usage, errorMessage: nil, supportsUsage: true)
        } catch {
            return AccountQuota(account: account, usage: nil, errorMessage: error.localizedDescription, supportsUsage: true)
        }
    }

    private func fetchUsage(for account: CPAAccount) async throws -> UsageSnapshot {
        if account.isAntigravity {
            return try await fetchAntigravityUsage(for: account)
        }
        if account.isClaude {
            return try await fetchClaudeUsage(for: account)
        }
        if account.isKimi {
            return try await fetchKimiUsage(for: account)
        }
        if account.isXAI {
            return try await fetchXAIUsage(for: account)
        }
        return try await fetchWhamUsage(for: account)
    }

    private func fetchWhamUsage(for account: CPAAccount) async throws -> UsageSnapshot {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Mac OS 15.0.0; arm64) CPA-iOS/1.3"
        ]
        if let accountID = account.chatgptAccountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let usagePayload = APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: headers,
            data: nil
        )
        var resetHeaders = headers
        resetHeaders["OpenAI-Beta"] = "codex-1"
        resetHeaders["Originator"] = "Codex Desktop"
        let resetPayload = APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
            header: resetHeaders,
            data: nil
        )

        async let usageTask = fetchAPICallEnvelope(payload: usagePayload)
        async let resetTask = fetchOptionalAPICallEnvelope(payload: resetPayload)
        let usageEnvelope = try await usageTask
        let resetEnvelope = await resetTask
        guard (200..<300).contains(usageEnvelope.statusCode) else {
            throw CPAAPIError.httpStatus(
                code: usageEnvelope.statusCode,
                message: Self.errorMessage(from: usageEnvelope.body) ?? usageEnvelope.body
            )
        }

        var usageObject = Self.jsonObject(from: usageEnvelope.body) ?? [:]
        if let resetEnvelope,
           (200..<300).contains(resetEnvelope.statusCode),
           let resetObject = Self.jsonObject(from: resetEnvelope.body) {
            usageObject["rate_limit_reset_credits"] = resetObject
        }
        if let snapshot = UsageParser.parse(try jsonString(usageObject)) {
            return snapshot
        }
        throw CPAAPIError.decoding("empty Codex quota")
    }

    private func fetchAntigravityUsage(for account: CPAAccount) async throws -> UsageSnapshot {
        guard let projectID = await antigravityProjectID(for: account) else {
            throw CPAAPIError.decoding("missing Antigravity project_id")
        }
        let payloadBody = try jsonString(["project": projectID])
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": Self.antigravityUserAgent
        ]

        async let subscriptionTask = fetchAntigravitySubscription(for: account, headers: headers)
        var lastError: Error?
        var emptySnapshot: UsageSnapshot?
        var sawSuccessfulResponse = false

        for url in Self.antigravityQuotaURLs {
            do {
                let envelope = try await fetchAPICallEnvelope(payload: APICallRequest(
                    authIndex: account.authIndex ?? "",
                    method: "POST",
                    url: url,
                    header: headers,
                    data: payloadBody
                ))
                guard (200..<300).contains(envelope.statusCode) else {
                    lastError = CPAAPIError.httpStatus(
                        code: envelope.statusCode,
                        message: Self.errorMessage(from: envelope.body) ?? envelope.body
                    )
                    continue
                }

                sawSuccessfulResponse = true
                let subscriptionData = await subscriptionTask
                let subscriptionObject = subscriptionData.flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? [:]
                let combined: [String: Any] = [
                    "_provider": "antigravity",
                    "quota": Self.jsonObject(from: envelope.body) ?? [:],
                    "subscription": subscriptionObject
                ]
                if let snapshot = UsageParser.parse(try jsonString(combined)) {
                    if snapshot.hasQuotaSignal {
                        return snapshot
                    }
                    emptySnapshot = snapshot
                } else {
                    lastError = CPAAPIError.decoding("empty Antigravity quota summary")
                }
            } catch {
                lastError = error
            }
        }

        for url in Self.antigravityLegacyModelURLs {
            do {
                let envelope = try await fetchAPICallEnvelope(payload: APICallRequest(
                    authIndex: account.authIndex ?? "",
                    method: "POST",
                    url: url,
                    header: headers,
                    data: payloadBody
                ))
                guard (200..<300).contains(envelope.statusCode) else {
                    lastError = CPAAPIError.httpStatus(
                        code: envelope.statusCode,
                        message: Self.errorMessage(from: envelope.body) ?? envelope.body
                    )
                    continue
                }
                sawSuccessfulResponse = true
                if let snapshot = UsageParser.parse(envelope.body), snapshot.hasQuotaSignal {
                    return snapshot
                }
            } catch {
                lastError = error
            }
        }

        if sawSuccessfulResponse {
            return emptySnapshot ?? UsageSnapshot(
                planType: nil,
                primary: nil,
                weekly: nil,
                rawStatus: "empty_models"
            )
        }
        throw lastError ?? CPAAPIError.decoding("empty Antigravity quota")
    }

    private func fetchAntigravitySubscription(
        for account: CPAAccount,
        headers: [String: String]
    ) async -> Data? {
        let body = try? jsonString(["metadata": ["ideType": "ANTIGRAVITY"]])
        guard let envelope = try? await fetchAPICallEnvelope(payload: APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "POST",
            url: Self.antigravitySubscriptionURL,
            header: headers,
            data: body
        )),
        (200..<300).contains(envelope.statusCode),
        let root = Self.jsonObject(from: envelope.body)
        else {
            return nil
        }

        let paidTier = firstDictionary(root["paidTier"], root["paid_tier"])
        let currentTier = firstDictionary(root["currentTier"], root["current_tier"])
        let tier = (firstString(paidTier?["id"]) == nil ? currentTier : paidTier) ?? [:]
        let tierID = firstString(tier["id"])
        let plan: String
        switch tierID?.lowercased() {
        case "free-tier": plan = "free"
        case "g1-pro-tier": plan = "pro"
        case "g1-ultra-tier": plan = "ultra"
        case "g1-ultra-lite-tier": plan = "ultra-lite"
        default: plan = "unknown"
        }
        var normalized: [String: Any] = ["plan": plan]
        if let tierID { normalized["tierId"] = tierID }
        if let tierName = firstString(tier["name"]) { normalized["tierName"] = tierName }
        if let paidTier { normalized["paidTier"] = paidTier }
        return try? JSONSerialization.data(withJSONObject: normalized)
    }

    private func fetchClaudeUsage(for account: CPAAccount) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20"
        ]
        let usagePayload = APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/usage",
            header: headers,
            data: nil
        )
        let profilePayload = APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/profile",
            header: headers,
            data: nil
        )
        async let usageTask = fetchAPICallEnvelope(payload: usagePayload)
        async let profileTask = fetchOptionalAPICallEnvelope(payload: profilePayload)
        let usageEnvelope = try await usageTask
        let profileEnvelope = await profileTask
        guard (200..<300).contains(usageEnvelope.statusCode) else {
            throw CPAAPIError.httpStatus(
                code: usageEnvelope.statusCode,
                message: Self.errorMessage(from: usageEnvelope.body) ?? usageEnvelope.body
            )
        }
        let usageObject = Self.jsonObject(from: usageEnvelope.body) ?? [:]
        let profileObject = profileEnvelope.flatMap { envelope -> [String: Any]? in
            guard (200..<300).contains(envelope.statusCode) else {
                return nil
            }
            return Self.jsonObject(from: envelope.body)
        }
        let body = try jsonString([
            "_provider": "claude",
            "usage": usageObject,
            "profile": profileObject ?? [:]
        ])
        if let snapshot = UsageParser.parse(body) {
            return snapshot
        }
        throw CPAAPIError.decoding("empty Claude quota")
    }

    private func fetchKimiUsage(for account: CPAAccount) async throws -> UsageSnapshot {
        try await fetchUsageViaAPICall(payload: APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: "https://api.kimi.com/coding/v1/usages",
            header: ["Authorization": "Bearer $TOKEN$"],
            data: nil
        ))
    }

    private func fetchXAIUsage(for account: CPAAccount) async throws -> UsageSnapshot {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "x-xai-token-auth": "xai-grok-cli",
            "x-grok-client-version": Self.xaiClientVersion,
            "Accept": "*/*",
            "User-Agent": "grok-pager/\(Self.xaiClientVersion) grok-shell/\(Self.xaiClientVersion) (macos; aarch64)"
        ]
        if let userID = await xaiUserID(for: account) {
            headers["x-userid"] = userID
        }

        let weeklyPayload = APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: Self.xaiBillingWeeklyURL,
            header: headers,
            data: nil
        )
        let monthlyPayload = APICallRequest(
            authIndex: account.authIndex ?? "",
            method: "GET",
            url: Self.xaiBillingMonthlyURL,
            header: headers,
            data: nil
        )
        async let weeklyTask = fetchOptionalAPICallEnvelope(payload: weeklyPayload)
        async let monthlyTask = fetchOptionalAPICallEnvelope(payload: monthlyPayload)
        let weeklyEnvelope = await weeklyTask
        let monthlyEnvelope = await monthlyTask

        let weeklyObject = weeklyEnvelope.flatMap { envelope in
            (200..<300).contains(envelope.statusCode) ? Self.jsonObject(from: envelope.body) : nil
        }
        let monthlyObject = monthlyEnvelope.flatMap { envelope in
            (200..<300).contains(envelope.statusCode) ? Self.jsonObject(from: envelope.body) : nil
        }
        guard weeklyObject != nil || monthlyObject != nil else {
            let failed = weeklyEnvelope ?? monthlyEnvelope
            throw CPAAPIError.httpStatus(
                code: failed?.statusCode ?? 502,
                message: Self.errorMessage(from: failed?.body ?? "") ?? "empty Grok billing response"
            )
        }
        let combined: [String: Any] = [
            "_provider": "xai",
            "weekly": weeklyObject ?? [:],
            "monthly": monthlyObject ?? [:]
        ]
        if let snapshot = UsageParser.parse(try jsonString(combined)), snapshot.hasQuotaSignal {
            return snapshot
        }
        throw CPAAPIError.decoding("empty Grok quota")
    }

    private func fetchUsageViaAPICall(payload: APICallRequest) async throws -> UsageSnapshot {
        let envelope = try await fetchAPICallEnvelope(payload: payload)
        if (200..<300).contains(envelope.statusCode),
           let snapshot = UsageParser.parse(envelope.body) {
            return snapshot
        }
        if (200..<300).contains(envelope.statusCode) {
            throw CPAAPIError.decoding("empty quota response")
        }
        if let snapshot = UsageParser.parse(envelope.body) {
            return snapshot
        }
        throw CPAAPIError.httpStatus(
            code: envelope.statusCode,
            message: Self.errorMessage(from: envelope.body) ?? envelope.body
        )
    }

    private func fetchAPICallEnvelope(payload: APICallRequest) async throws -> APICallEnvelope {
        let body = try JSONEncoder().encode(payload)
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let result: (APICallEnvelope, HTTPURLResponse) = try await request(
                    path: "/v0/management/api-call",
                    method: "POST",
                    body: body,
                    timeout: 65
                )
                return result.0
            } catch {
                lastError = error
                if attempt == 2 || !shouldRetry(error: error) {
                    break
                }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw lastError ?? CPAAPIError.invalidResponse
    }

    private func fetchOptionalAPICallEnvelope(payload: APICallRequest) async -> APICallEnvelope? {
        try? await fetchAPICallEnvelope(payload: payload)
    }

    private func antigravityProjectID(for account: CPAAccount) async -> String? {
        if let projectID = account.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        if let body = try? await downloadAuthFile(named: account.name),
           let projectID = Self.projectID(fromAuthFileBody: body) {
            return projectID
        }
        return nil
    }

    private func xaiUserID(for account: CPAAccount) async -> String? {
        guard let body = try? await downloadAuthFile(named: account.name),
              let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return firstNonEmptyString(
            firstString(root["sub"]),
            firstString(root["subject"]),
            firstString(root["user_id"]),
            firstString(root["userId"]),
            firstString(nested(root, "oauth", "sub")),
            firstString(nested(root, "user", "sub")),
            firstString(nested(root, "user", "id"))
        )
    }

    private func downloadAuthFile(named name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(".json"),
              !trimmed.contains("/"),
              !trimmed.contains("\\")
        else {
            throw CPAAPIError.invalidResponse
        }
        let (data, _) = try await dataRequest(
            path: "/v0/management/auth-files/download",
            queryItems: [URLQueryItem(name: "name", value: trimmed)]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func projectID(fromAuthFileBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return firstNonEmptyString(
            firstString(root["project_id"]),
            firstString(root["projectId"]),
            firstString(nested(root, "installed", "project_id")),
            firstString(nested(root, "installed", "projectId")),
            firstString(nested(root, "web", "project_id")),
            firstString(nested(root, "web", "projectId"))
        )
    }

    private static func jsonObject(from body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func jsonString(_ object: [String: String]) throws -> String {
        try jsonString(object as [String: Any])
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CPAAPIError.decoding("failed to encode JSON payload")
        }
        return string
    }

    private func shouldRetry(error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return [
            "timed out",
            "timeout",
            "request failed",
            "bad gateway",
            "service unavailable",
            "gateway timeout",
            "connection reset",
            "network connection was lost",
            "连接超时",
            "连接中断",
            "连接已重置",
            "网关超时",
            "服务暂不可用"
        ].contains { message.contains($0) }
    }

    private func makeManagementRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CPA-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CPAAPIError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = joinedPath.isEmpty ? "/" : "/\(joinedPath)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil

        guard let url = components.url else {
            throw CPAAPIError.invalidBaseURL
        }
        return url
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let message = errorText(in: object) {
            return message
        }
        if let envelope = try? JSONDecoder().decode(CPAErrorEnvelope.self, from: data) {
            return firstNonEmptyString(envelope.error, envelope.message)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func errorMessage(from body: String) -> String? {
        errorMessage(from: Data(body.utf8))
    }

    private static func transportError(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return CPAAPIError.transport(error.localizedDescription)
        }
        if nsError.code == NSURLErrorCancelled {
            return error
        }

        let message: String
        switch nsError.code {
        case NSURLErrorTimedOut:
            message = "连接超时，请确认 CLIProxyAPI 服务可访问"
        case NSURLErrorNotConnectedToInternet:
            message = "网络不可用，请检查 iPhone 网络连接"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            message = "找不到服务器，请检查服务器地址"
        case NSURLErrorCannotConnectToHost:
            message = "无法连接服务器，请确认 CLIProxyAPI 正在运行且允许远程管理"
        case NSURLErrorNetworkConnectionLost:
            message = "网络连接中断，请稍后重试"
        case NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid:
            message = "HTTPS 证书或 TLS 连接失败，请检查服务器证书"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            message = "公网 HTTP 不安全，请使用 HTTPS 或局域网地址"
        default:
            message = error.localizedDescription
        }
        return CPAAPIError.transport(message)
    }

    private static let errorTextPriorityKeys = [
        "message",
        "error",
        "detail",
        "reason",
        "description",
        "status_message",
        "statusMessage",
        "errors",
        "details",
        "cause",
        "causes",
        "code",
        "type",
        "status"
    ]

    private static func errorText(in value: Any, depth: Int = 0) -> String? {
        guard depth < 6 else {
            return nil
        }
        if let string = firstString(value) {
            return string
        }
        if let dictionary = value as? [String: Any] {
            for key in errorTextPriorityKeys {
                if let nested = dictionary[key],
                   let message = errorText(in: nested, depth: depth + 1) {
                    return message
                }
            }
            for nested in dictionary.values {
                if let message = errorText(in: nested, depth: depth + 1) {
                    return message
                }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let message = errorText(in: item, depth: depth + 1) {
                    return message
                }
            }
        }
        return nil
    }

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context):
            return context.debugDescription
        case let .keyNotFound(key, context):
            return "missing \(key.stringValue): \(context.debugDescription)"
        case let .typeMismatch(_, context):
            return context.debugDescription
        case let .valueNotFound(_, context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }
}

private struct APICallRequest: Encodable, Sendable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

private struct APICallEnvelope: Decodable, Sendable {
    let statusCode: Int
    let body: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusCodeCamel = "statusCode"
        case body
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedStatusCode = try container.decodeFlexibleIntIfPresent(forKey: .statusCode)
            ?? container.decodeFlexibleIntIfPresent(forKey: .statusCodeCamel)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .statusCode,
                in: container,
                debugDescription: "api-call response missing status_code"
            )
        }
        statusCode = decodedStatusCode
        if let value = try? container.decode(String.self, forKey: .body) {
            body = value
        } else if let value = try? container.decode(String.self, forKey: .data) {
            body = value
        } else if let value = try? container.decode(APICallBodyValue.self, forKey: .body) {
            body = value.jsonString
        } else if let value = try? container.decode(APICallBodyValue.self, forKey: .data) {
            body = value.jsonString
        } else {
            body = ""
        }
    }
}

private enum APICallBodyValue: Decodable, Sendable {
    case object([String: APICallBodyValue])
    case array([APICallBodyValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var jsonString: String {
        switch self {
        case let .string(value):
            return value
        case .null:
            return ""
        case let .object(values):
            return Self.encodedJSONObject(values.mapValues(\.jsonObject))
        case let .array(values):
            return Self.encodedJSONObject(values.map(\.jsonObject))
        case let .number(value):
            return value.isFinite ? String(value) : ""
        case let .bool(value):
            return value ? "true" : "false"
        }
    }

    private var jsonObject: Any {
        switch self {
        case let .object(values):
            return values.mapValues(\.jsonObject)
        case let .array(values):
            return values.map(\.jsonObject)
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: APICallBodyValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(APICallBodyValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var values: [APICallBodyValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(APICallBodyValue.self))
            }
            self = .array(values)
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Double.self) {
            self = .number(decoded)
        } else {
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: "unsupported api-call body value"
            )
        }
    }

    private static func encodedJSONObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
