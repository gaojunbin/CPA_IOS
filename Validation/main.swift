import Darwin
import Foundation
import CPAKit

final class CapturingSession: CPAHTTPSession, @unchecked Sendable {
    private(set) var lastRequest: URLRequest?
    var payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (payload, response)
    }
}

final class QueueSession: CPAHTTPSession, @unchecked Sendable {
    private var payloads: [Data]
    private(set) var requests: [URLRequest] = []

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let payload = payloads.isEmpty ? Data("{}".utf8) : payloads.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (payload, response)
    }
}

final class ThrowingSession: CPAHTTPSession, @unchecked Sendable {
    let error: Error
    private(set) var requests: [URLRequest] = []

    init(error: Error) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        throw error
    }
}

actor AlwaysTimeoutSession: CPAHTTPSession {
    private var recordedRequests: [URLRequest] = []

    var requestCount: Int {
        recordedRequests.count
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        throw URLError(.timedOut)
    }
}

actor RouteSession: CPAHTTPSession {
    private let routes: [String: (statusCode: Int, payload: Data)]
    private let responseHeaders: [String: [String: String]]
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        recordedRequests
    }

    init(
        routes: [String: (statusCode: Int, payload: Data)],
        responseHeaders: [String: [String: String]] = [:]
    ) {
        self.routes = routes
        self.responseHeaders = responseHeaders
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)

        let path = request.url?.path ?? ""
        let route = routes[path] ?? (404, Data(#"{"error":"not found"}"#.utf8))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.statusCode,
            httpVersion: nil,
            headerFields: responseHeaders[path]
        )!
        return (route.payload, response)
    }
}

enum ValidationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ValidationError.failed(message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw ValidationError.failed(message)
    }
    return value
}

func fileText(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func filePermissions(_ path: String) throws -> Int {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return Int(info.st_mode & 0o777)
}

func validateDashboardClient(apiKeyUsageJSON: Data) async throws {
    let dashboardAuthFilesJSON = """
    {
      "files": [
        {
          "id": "dash-1",
          "auth_index": "dash-index",
          "name": "dash.json",
          "provider": "codex",
          "status": "active"
        }
      ]
    }
    """.data(using: .utf8)!
    let dashboardSession = RouteSession(routes: [
        "/v0/management/auth-files": (200, dashboardAuthFilesJSON),
        "/v0/management/api-key-usage": (200, apiKeyUsageJSON),
        "/v0/management/quota-exceeded/switch-project": (200, Data(#"{"switch-project":true}"#.utf8)),
        "/v0/management/quota-exceeded/switch-preview-model": (200, Data(#"{"switch-preview-model":false}"#.utf8))
    ], responseHeaders: [
        "/v0/management/auth-files": [
            "X-CPA-VERSION": "v7.1.0",
            "X-CPA-COMMIT": "abcdef1234567890",
            "X-CPA-BUILD-DATE": "2026-05-30T01:02:03Z"
        ]
    ])
    let dashboardClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: dashboardSession
    )
    let dashboard = try await dashboardClient.fetchDashboard(includeLiveUsage: false)
    try expect(dashboard.accounts.count == 1, "dashboard auth files failed")
    try expect(dashboard.apiKeyUsage.count == 1, "dashboard api key usage failed")
    try expect(dashboard.quotaSwitchProject == true, "dashboard switch project failed")
    try expect(dashboard.quotaSwitchPreviewModel == false, "dashboard switch preview failed")
    try expect(dashboard.serverVersion == "v7.1.0", "dashboard server version header failed")
    try expect(dashboard.serverCommit == "abcdef1234567890", "dashboard server commit header failed")
    try expect(dashboard.serverBuildDate == "2026-05-30T01:02:03Z", "dashboard server build date header failed")

    let dashboardRequests = await dashboardSession.requests
    var dashboardPaths: [String] = []
    for request in dashboardRequests {
        if let path = request.url?.path {
            dashboardPaths.append(path)
        }
    }
    try expect(dashboardPaths.contains("/v0/management/auth-files"), "dashboard auth-files request missing")
    try expect(dashboardPaths.contains("/v0/management/api-key-usage"), "dashboard api-key usage request missing")
    try expect(!dashboardPaths.contains("/v0/management/api-call"), "base dashboard should not fetch live usage")
    let dashboardAuthRequest = try require(
        dashboardRequests.first { $0.url?.path == "/v0/management/auth-files" },
        "dashboard auth-files request should be recorded"
    )
    try expect(dashboardAuthRequest.cachePolicy == .reloadIgnoringLocalCacheData, "management requests should bypass URL caches")
    try expect(dashboardAuthRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "management requests should send bearer auth")
    try expect(dashboardAuthRequest.value(forHTTPHeaderField: "Cache-Control") == "no-store", "management requests should disable cache storage")
    try expect(dashboardAuthRequest.value(forHTTPHeaderField: "Pragma") == "no-cache", "management requests should disable legacy cache storage")
}

struct AppIconManifest: Decodable {
    let images: [AppIconEntry]
}

struct AppIconEntry: Decodable {
    let filename: String?
    let idiom: String
    let scale: String
    let size: String
}

struct PNGInfo {
    let width: Int
    let height: Int
    let colorType: UInt8
}

func pngInfo(_ path: String) throws -> PNGInfo {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    try expect(data.starts(with: signature), "app icon is not a PNG: \(path)")
    try expect(data.count > 25, "app icon PNG is missing IHDR data: \(path)")
    let chunkType = String(data: data.subdata(in: 12..<16), encoding: .ascii)
    try expect(chunkType == "IHDR", "app icon PNG first chunk is not IHDR: \(path)")
    return PNGInfo(
        width: readBigEndianInt(data, offset: 16),
        height: readBigEndianInt(data, offset: 20),
        colorType: data[25]
    )
}

func readBigEndianInt(_ data: Data, offset: Int) -> Int {
    (Int(data[offset]) << 24) |
        (Int(data[offset + 1]) << 16) |
        (Int(data[offset + 2]) << 8) |
        Int(data[offset + 3])
}

func expectedIconPixels(size: String, scale: String) throws -> Int {
    let sizeParts = size.split(separator: "x")
    try expect(sizeParts.count == 2, "invalid app icon size: \(size)")
    let width = try require(Double(String(sizeParts[0])), "invalid app icon width: \(size)")
    let height = try require(Double(String(sizeParts[1])), "invalid app icon height: \(size)")
    try expect(width == height, "app icon slot is not square: \(size)")
    let scaleNumberText = scale.trimmingCharacters(in: CharacterSet(charactersIn: "x"))
    let scaleNumber = try require(Double(scaleNumberText), "invalid app icon scale: \(scale)")
    let pixels = width * scaleNumber
    let rounded = pixels.rounded()
    try expect(abs(pixels - rounded) < 0.001, "app icon slot is not whole pixels: \(size) @ \(scale)")
    return Int(rounded)
}

func validateAppIcons() throws {
    let iconDirectory = "App/Assets.xcassets/AppIcon.appiconset"
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: "\(iconDirectory)/Contents.json"))
    let manifest = try JSONDecoder().decode(AppIconManifest.self, from: manifestData)
    try expect(manifest.images.count >= 18, "app icon manifest should include iPhone, iPad, and marketing slots")

    var manifestFilenames = Set<String>()
    for entry in manifest.images {
        let filename = try require(entry.filename, "app icon slot missing filename for \(entry.idiom) \(entry.size) \(entry.scale)")
        let expectedPixels = try expectedIconPixels(size: entry.size, scale: entry.scale)
        let path = "\(iconDirectory)/\(filename)"
        try expect(FileManager.default.fileExists(atPath: path), "app icon image missing: \(filename)")
        let info = try pngInfo(path)
        try expect(info.width == expectedPixels, "app icon width mismatch for \(filename): \(info.width) != \(expectedPixels)")
        try expect(info.height == expectedPixels, "app icon height mismatch for \(filename): \(info.height) != \(expectedPixels)")
        try expect(info.colorType == 2, "app icon must be RGB without alpha: \(filename)")
        manifestFilenames.insert(filename)
    }

    let actualFilenames = Set(
        try FileManager.default.contentsOfDirectory(atPath: iconDirectory)
            .filter { $0.hasSuffix(".png") }
    )
    try expect(actualFilenames == manifestFilenames, "app icon PNG files should match the asset manifest exactly")
}

func validateLaunchScreenAssets(infoPlist: String, readme: String, submissionNotes: String) throws {
    let launchColorManifestPath = "App/Assets.xcassets/LaunchBackground.colorset/Contents.json"
    try expect(infoPlist.contains("<key>UILaunchScreen</key>"), "Info.plist should declare a launch screen")
    try expect(infoPlist.contains("<key>UIColorName</key>"), "Info.plist launch screen should use a named color")
    try expect(infoPlist.contains("<string>LaunchBackground</string>"), "Info.plist launch screen should reference LaunchBackground")
    try expect(FileManager.default.fileExists(atPath: launchColorManifestPath), "launch background named color asset should exist")

    let launchColorManifest = try fileText(launchColorManifestPath)
    try expect(launchColorManifest.contains("\"idiom\" : \"universal\""), "launch background should be a universal named color")
    try expect(launchColorManifest.contains("\"appearance\" : \"luminosity\""), "launch background should declare a luminosity appearance")
    try expect(launchColorManifest.contains("\"value\" : \"dark\""), "launch background should include a dark appearance")
    try expect(readme.contains("LaunchBackground"), "README should document the launch background named color")
    try expect(submissionNotes.contains("LaunchBackground"), "submission notes should document the launch background named color")
}

func validateNotificationAlertSettingSource(
    settingsSource: String,
    notifierSource: String,
    readme: String,
    submissionNotes: String
) throws {
    try expect(settingsSource.contains("let canSendAlerts = authorized ? await QuotaAlertNotifier.canSendAlerts() : false"), "settings should verify current alert delivery availability after notification authorization")
    try expect(notifierSource.contains("settings.alertSetting"), "quota alerts should respect the per-app alert presentation setting")
    try expect(notifierSource.contains("alertSetting == .enabled"), "quota alerts should disable local alerts when notification banners are turned off")
    try expect(readme.contains("turns off notification banners/alerts"), "README should document alert setting availability")
    try expect(submissionNotes.contains("Notification alert setting"), "submission notes should document per-app alert setting behavior")
    try expect(submissionNotes.contains("notification banners/alerts are disabled"), "submission notes should document disabled alert presentation handling")
}

func validateStableAccountIdentity(
    duplicateA: CPAAccount,
    duplicateB: CPAAccount,
    duplicateBQuota: AccountQuota
) throws {
    try expect(duplicateA.stableIdentity != duplicateB.stableIdentity, "stable account identity should distinguish duplicate backend IDs")
    try expect(stableAccountIdentitySort(duplicateA, duplicateB), "stable account sorting should distinguish duplicate display names")
    try expect(!stableAccountIdentitySort(duplicateB, duplicateA), "stable account sorting should be deterministic for duplicate display names")
    try expect(duplicateBQuota.stableIdentity == duplicateB.stableIdentity, "account quota stable identity should mirror account identity")
}

func validateStableAccountIdentitySource(modelsSource: String, dashboardSource: String) throws {
    try expect(modelsSource.contains("public func stableAccountIdentitySort"), "models should expose deterministic account identity sorting")
    try expect(modelsSource.contains("var stableIdentity: String"), "accounts should expose a stable SwiftUI row identity")
    try expect(modelsSource.contains("public var stableIdentity: String"), "account quota should expose a stable SwiftUI row identity")
    try expect(modelsSource.contains("account.stableIdentity"), "dashboard replacement should share the same stable account identity used by SwiftUI rows")
    try expect(dashboardSource.contains("ForEach(visibleAccounts, id: \\.stableIdentity)"), "attention account rows should use stable auth identity instead of backend IDs or offsets")
    try expect(dashboardSource.contains("ForEach(section.accounts, id: \\.stableIdentity)"), "provider account rows should use stable auth identity instead of backend IDs or offsets")
}

func validateAPIKeyUsageDashboardSource(
    dashboardSource: String,
    dashboardViewModelSource: String,
    readme: String
) throws {
    try expect(dashboardSource.contains("Text(record.maskedAPIKey)") && dashboardSource.contains(".truncationMode(.middle)"), "API key usage rows should middle-truncate long masked keys")
    try expect(dashboardSource.contains("private var providerLine: String"), "API key usage rows should expose a provider display line")
    try expect(dashboardSource.contains("ProviderCatalog.info(for: record.provider).displayName"), "API key usage rows should use catalog provider display names")
    try expect(dashboardSource.contains("if viewModel.hasAPIKeyUsage"), "API key usage section should stay visible when filters hide all key rows")
    try expect(dashboardSource.contains("APIKeyUsageSection(records: viewModel.filteredAPIKeyUsage)"), "API key usage rows should honor dashboard filters")
    try expect(dashboardSource.contains("EmptyStateView(title: \"没有匹配 API Key\""), "API key usage section should show an empty state for filtered-away rows")
    try expect(dashboardSource.contains("ForEach(records) { record in"), "API key usage rows should use stable hashed record identities")
    try expect(dashboardSource.contains("struct APIKeyUsageRow"), "API key usage rows should have a dedicated responsive layout")
    try expect(dashboardSource.contains("struct APIKeyUsageMetricsView"), "API key usage rows should have a dedicated metrics layout")
    try expect(dashboardSource.contains("if !record.recentRequests.isEmpty"), "API key usage rows should only show activity charts when data exists")
    try expect(dashboardSource.contains("SparklineBars(buckets: record.recentRequests)"), "API key usage rows should show recent request activity")
    try expect(dashboardViewModelSource.contains("var filteredAPIKeyUsage: [APIKeyUsageRecord]"), "dashboard should expose filtered API key usage")
    try expect(dashboardViewModelSource.contains("var hasAPIKeyUsage: Bool"), "dashboard should expose raw API key usage presence for filtered empty states")
    try expect(dashboardViewModelSource.contains("apiKeyUsageMatchesStatus(record)"), "API key usage filtering should honor applicable status filters")
    try expect(dashboardViewModelSource.contains("record.maskedAPIKey.lowercased()"), "API key usage search should use masked key text")
    try expect(dashboardViewModelSource.contains("record.baseURL.lowercased()"), "API key usage search should include base URLs")
    try expect(dashboardViewModelSource.contains("record.failed > 0"), "attention filtering should include failing API keys")
    try expect(readme.contains("Filter API key usage with the same dashboard provider"), "README should document filtered API key usage")
    try expect(readme.contains("scoped empty state when filters hide all key rows"), "README should document filtered API key empty states")
}

func validateAPIKeyUsageParser() throws -> Data {
    let apiKeyUsageJSON = """
    {
      "openai": {
        "https://api.example.com|sk-1234567890abcdef": {
          "success": 8,
          "failed": 2,
          "recent_requests": []
        }
      }
    }
    """.data(using: .utf8)!

    let usage = try JSONDecoder().decode([String: [String: APIKeyUsageEntry]].self, from: apiKeyUsageJSON)
    let records = APIKeyUsageParser.flatten(usage)
    try expect(records.count == 1, "api key usage flatten count failed")
    try expect(records[0].provider == "openai", "api key usage provider failed")
    try expect(records[0].baseURL == "https://api.example.com", "api key base URL failed")
    try expect(records[0].maskedAPIKey == "sk-123...cdef", "api key masking failed")
    try expect(!records[0].id.contains("sk-1234567890abcdef"), "api key usage row identity should not contain raw API keys")

    let camelAPIKeyUsageJSON = """
    {
      "openai": {
        "https://api.example.com|sk-camel": {
          "success": 1,
          "failed": 0,
          "recentRequests": [
            {"time": "09:00", "success": 1, "failed": 0}
          ]
        }
      }
    }
    """.data(using: .utf8)!
    let camelUsage = try JSONDecoder().decode([String: [String: APIKeyUsageEntry]].self, from: camelAPIKeyUsageJSON)
    let camelRecords = APIKeyUsageParser.flatten(camelUsage)
    try expect(camelRecords.first?.recentRequests.count == 1, "camel API key recent requests should decode")

    let sortedAPIKeyRecords = APIKeyUsageParser.flatten([
        "openai": [
            "https://api.example.com|ok-key-123456": APIKeyUsageEntry(success: 100, failed: 0, recentRequests: []),
            "https://api.example.com|bad-key-123456": APIKeyUsageEntry(success: 1, failed: 5, recentRequests: [])
        ],
        "claude": [
            "https://api.anthropic.com|warn-key-123456": APIKeyUsageEntry(success: 50, failed: 2, recentRequests: [])
        ]
    ])
    try expect(sortedAPIKeyRecords.map(\.maskedAPIKey) == ["bad-ke...3456", "warn-k...3456", "ok-key...3456"], "api key usage should sort failing keys first")

    let shortKeyRecord = try require(
        APIKeyUsageParser.flatten([
            "openai": [
                "https://api.example.com|short": APIKeyUsageEntry(success: 1, failed: 0, recentRequests: [])
            ]
        ]).first,
        "short api key record missing"
    )
    try expect(shortKeyRecord.maskedAPIKey == "****", "short api keys should never be displayed raw")

    let mediumKeyRecord = try require(
        APIKeyUsageParser.flatten([
            "openai": [
                "https://api.example.com|key123456": APIKeyUsageEntry(success: 1, failed: 0, recentRequests: [])
            ]
        ]).first,
        "medium api key record missing"
    )
    try expect(mediumKeyRecord.maskedAPIKey == "****3456", "medium api keys should be partially masked")

    let bareKeyRecord = try require(
        APIKeyUsageParser.flatten([
            "openai": [
                "sk-only-key-123456": APIKeyUsageEntry(success: 1, failed: 0, recentRequests: [])
            ]
        ]).first,
        "bare api key record missing"
    )
    try expect(bareKeyRecord.baseURL.isEmpty, "bare api key records should not expose the key as a base URL")
    try expect(bareKeyRecord.maskedAPIKey == "sk-onl...3456", "bare api keys should still be masked")

    return apiKeyUsageJSON
}

@MainActor
func runValidation() async throws {
    let panelURL = try CPABaseURLNormalizer.normalize("https://cpa.junbingao.com/management.html#/quota")
    try expect(panelURL.absoluteString == "https://cpa.junbingao.com", "panel URL normalization failed")
    let subpathPanelURL = try CPABaseURLNormalizer.normalize("https://proxy.example.com/cpa/management.html#/quota")
    try expect(subpathPanelURL.absoluteString == "https://proxy.example.com/cpa", "subpath panel URL normalization failed")
    let managementAPIURL = try CPABaseURLNormalizer.normalize("https://proxy.example.com/cpa/v0/management/auth-files?name=codex.json")
    try expect(managementAPIURL.absoluteString == "https://proxy.example.com/cpa", "subpath management API URL normalization failed")
    let rootManagementAPIURL = try CPABaseURLNormalizer.normalize("https://proxy.example.com/v0/management/api-call")
    try expect(rootManagementAPIURL.absoluteString == "https://proxy.example.com", "root management API URL normalization failed")

    let localhostURL = try CPABaseURLNormalizer.normalize("127.0.0.1:8317")
    try expect(localhostURL.absoluteString == "http://127.0.0.1:8317", "localhost URL normalization failed")
    let privateIPv4URL = try CPABaseURLNormalizer.normalize("10.1.2.3:8317")
    try expect(privateIPv4URL.absoluteString == "http://10.1.2.3:8317", "private IPv4 URL normalization failed")
    let localHostnameURL = try CPABaseURLNormalizer.normalize("cpa.local:8317")
    try expect(localHostnameURL.absoluteString == "http://cpa.local:8317", "local hostname URL normalization failed")
    let lanHostnameURL = try CPABaseURLNormalizer.normalize("cpa.lan:8317")
    try expect(lanHostnameURL.absoluteString == "http://cpa.lan:8317", "LAN hostname URL normalization failed")
    let homeArpaURL = try CPABaseURLNormalizer.normalize("cpa.home.arpa:8317")
    try expect(homeArpaURL.absoluteString == "http://cpa.home.arpa:8317", "home.arpa URL normalization failed")
    let singleLabelHostnameURL = try CPABaseURLNormalizer.normalize("cpa-box:8317")
    try expect(singleLabelHostnameURL.absoluteString == "http://cpa-box:8317", "single-label LAN hostname URL normalization failed")
    let localIPv6URL = try CPABaseURLNormalizer.normalize("[fd00::1]:8317")
    try expect(localIPv6URL.absoluteString == "http://[fd00::1]:8317", "local IPv6 URL normalization failed")
    let publicPrefixHostnameURL = try CPABaseURLNormalizer.normalize("10.example.com")
    try expect(publicPrefixHostnameURL.absoluteString == "https://10.example.com", "public hostname with private-looking prefix should default to HTTPS")
    do {
        _ = try CPABaseURLNormalizer.normalize("http://cpa.example.com")
        throw ValidationError.failed("public HTTP URL should be rejected")
    } catch CPAAPIError.insecureHTTPHost {
    }
    do {
        _ = try CPABaseURLNormalizer.normalize("http://10.example.com")
        throw ValidationError.failed("public hostname with private-looking prefix should reject HTTP")
    } catch CPAAPIError.insecureHTTPHost {
    }

    let authFilesJSON = """
    {
      "files": [
        {
          "id": "auth-1",
          "auth_index": "abc123",
          "name": "gemini.json",
          "provider": "gemini",
          "label": "team@example.com",
          "status": "active",
          "status_message": 503,
          "disabled": false,
          "unavailable": true,
          "runtime_only": true,
          "source": "memory",
          "success": 12,
          "failed": 3,
          "project_id": "project-a",
          "priority": "7",
          "note": 12345,
          "websockets": "true",
          "next_retry_after": "2026-05-26T05:10:00Z",
          "recent_requests": [
            {"time": "04:00-04:10", "success": 2, "failed": 1}
          ],
          "quota": {
            "exceeded": true,
            "reason": 429,
            "next_recover_at": "2026-05-26T05:20:00Z",
            "backoff_level": 2
          },
          "last_error": {
            "error": {"message": "quota exhausted"},
            "httpStatus": "429",
            "retryable": "true"
          },
          "antigravity_credits": {
            "known": true,
            "available": true,
            "credit_amount": 25000,
            "min_credit_amount": "50",
            "paid_tier_id": "tier-1",
            "updated_at": "2026-05-26T05:00:00Z"
          },
          "model_states": {
            "gemini-2.5-pro": {
              "status": 429,
              "status_message": {"detail": "model quota cooling"},
              "unavailable": true,
              "next_retry_after": "2026-05-26T05:15:00Z",
              "last_error": "model quota exhausted",
              "quota": {"exceeded": true}
            },
            "gemini-2.5-flash": {
              "status": "error",
              "last_error": {"message": "model backend error"}
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!

    let authFiles = try JSONDecoder().decode(AuthFilesResponse.self, from: authFilesJSON)
    let account = try require(authFiles.files.first, "auth file sample did not decode")
    try expect(account.displayName == "team@example.com", "display name fallback failed")
    try expect(account.displayNameIsSensitive == true, "email display names should be privacy-sensitive")
    try expect(account.providerName == "gemini", "provider fallback failed")
    try expect(account.totalRequests == 15, "request total failed")
    try expect(account.statusKind == .cooling, "status kind failed")
    try expect(account.activeModelCooldowns.count == 2, "model cooldown parsing failed")
    try expect(account.projectID == "project-a", "project id parsing failed")
    try expect(account.antigravityCredits?.creditAmount == 25000, "credits parsing failed")
    try expect(account.statusMessage == "503", "numeric status message should decode")
    try expect(account.runtimeOnly == true, "runtime-only auth should decode")
    try expect(account.source == "memory", "auth source should decode")
    try expect(account.priority == 7, "string priority should decode")
    try expect(account.note == "12345", "numeric note should decode")
    try expect(account.websockets == true, "string websockets should decode")
    try expect(account.quota?.reason == "429", "numeric quota reason should decode")
    try expect(account.lastError?.message == "quota exhausted", "nested last error message failed")
    try expect(account.lastError?.httpStatus == 429, "camel http status parsing failed")
    try expect(account.lastError?.retryable == true, "string retryable parsing failed")
    let modelState = try require(account.modelStates["gemini-2.5-pro"], "model state sample did not decode")
    try expect(modelState.status == "429", "numeric model status should decode")
    try expect(modelState.statusMessage == "model quota cooling", "object model status message should decode")
    try expect(modelState.lastError?.message == "model quota exhausted", "string model last error should decode")
    try expect(
        account.activeModelCooldowns.contains { $0.model == "gemini-2.5-flash" },
        "model last_error should be shown as an active model issue"
    )
    let camelRuntimeJSON = """
    {
      "files": [
        {
          "id": "camel-runtime",
          "name": "camel-runtime.json",
          "provider": "codex",
          "status": "active",
          "quota": {
            "exceeded": "true",
            "reason": "camel quota",
            "nextRecoverAt": 1900000000,
            "backoffLevel": "3"
          },
          "model_states": {
            "gpt-camel": {
              "status": "cooling",
              "statusMessage": {"message": "camel model cooling"},
              "nextRetryAfter": "2030-03-17T17:46:40Z",
              "lastError": {"message": "camel model error"},
              "updatedAt": "2030-03-17T17:40:00Z"
            }
          },
          "antigravity_credits": {
            "known": "true",
            "available": "false",
            "creditAmount": "30",
            "minCreditAmount": "50",
            "paidTierId": "tier-camel",
            "updatedAt": "2030-03-17T17:30:00Z"
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let camelRuntime = try JSONDecoder().decode(AuthFilesResponse.self, from: camelRuntimeJSON)
    let camelRuntimeAccount = try require(camelRuntime.files.first, "camel runtime sample did not decode")
    try expect(camelRuntimeAccount.quota?.backoffLevel == 3, "camel quota backoff level should decode")
    try expect(
        abs((camelRuntimeAccount.quota?.nextRecoverAt?.timeIntervalSince1970 ?? 0) - 1_900_000_000) < 0.001,
        "camel quota recovery timestamp should decode"
    )
    let camelModelState = try require(camelRuntimeAccount.modelStates["gpt-camel"], "camel model state sample did not decode")
    try expect(camelModelState.statusMessage == "camel model cooling", "camel model status message should decode")
    try expect(camelModelState.lastError?.message == "camel model error", "camel model last error should decode")
    try expect(camelModelState.updatedAt != nil, "camel model updated_at should decode")
    try expect(camelRuntimeAccount.antigravityCredits?.creditAmount == 30, "camel credit amount should decode")
    try expect(camelRuntimeAccount.antigravityCredits?.minCreditAmount == 50, "camel minimum credit should decode")
    try expect(camelRuntimeAccount.antigravityCredits?.paidTierID == "tier-camel", "camel paid tier should decode")
    try expect(ProviderCatalog.info(for: "x-ai").key == "xai", "x-ai provider alias failed")
    try expect(ProviderCatalog.info(for: "anthropic").displayName == "Claude", "anthropic provider alias failed")
    try expect(ProviderCatalog.info(for: "anthropic").key == "claude", "anthropic provider should group with claude")
    try expect(ProviderCatalog.info(for: "openai-compatible").symbolName == "circle.hexagongrid.fill", "OpenAI-compatible providers should expose a distinct dashboard symbol")
    try expect(ProviderCatalog.info(for: "openai-compatible").accentName == "mint", "OpenAI-compatible providers should expose a catalog accent")

    let camelAccountJSON = """
    {
      "files": [
        {
          "id": "camel-account",
          "authIndex": "camel-index",
          "name": "camel-account.json",
          "provider": "codex",
          "status": "active",
          "statusMessage": {"message": "camel status"},
          "runtimeOnly": "true",
          "recentRequests": [
            {"time": 900, "success": 2, "failed": 1}
          ],
          "projectID": "project-upper",
          "accountType": "oauth",
          "chatgptAccountId": "acct-camel",
          "planType": "team",
          "createdAt": "2030-03-17T17:20:00Z",
          "updatedAt": "2030-03-17T17:30:00Z",
          "modifiedAt": "2030-03-17T17:35:00Z",
          "nextRetryAfter": "2030-03-17T17:50:00Z",
          "nextRefreshAfter": "2030-03-17T18:00:00Z",
          "modelStates": {
            "gpt-account-camel": {
              "status": "error",
              "lastError": "camel model failure"
            }
          },
          "lastError": {"message": "camel account failure"},
          "idToken": {
            "chatgptAccountID": "acct-token",
            "planType": "enterprise",
            "chatgptSubscriptionActiveStart": "2030-03-17T00:00:00Z",
            "chatgptSubscriptionActiveUntil": "2030-04-17T00:00:00Z"
          },
          "webSockets": "true",
          "antigravityCredits": {
            "known": true,
            "available": true,
            "creditAmount": 99,
            "minimumCreditAmountForUsage": 50
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let camelAccountResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: camelAccountJSON)
    let camelAccount = try require(camelAccountResponse.files.first, "camel account sample did not decode")
    try expect(camelAccount.authIndex == "camel-index", "camel account auth index should decode")
    try expect(camelAccount.statusMessage == "camel status", "camel account status message should decode")
    try expect(camelAccount.runtimeOnly, "camel account runtimeOnly should decode")
    try expect(camelAccount.recentRequests.count == 1, "camel account recent requests should decode")
    try expect(camelAccount.recentRequests.first?.time == "900", "numeric recent request time should decode")
    try expect(camelAccount.projectID == "project-upper", "upper-camel projectID should decode")
    try expect(camelAccount.accountType == "oauth", "camel account accountType should decode")
    try expect(camelAccount.chatgptAccountID == "acct-token", "idToken should still win over camel top-level ChatGPT account IDs")
    try expect(camelAccount.planType == "enterprise", "idToken should still win over camel top-level plan type")
    try expect(camelAccount.idToken?.subscriptionActiveStart != nil, "camel idToken subscription start should decode")
    try expect(camelAccount.idToken?.subscriptionActiveUntil != nil, "camel idToken subscription expiry should decode")
    try expect(camelAccount.createdAt != nil, "camel account createdAt should decode")
    try expect(camelAccount.updatedAt != nil, "camel account updatedAt should decode")
    try expect(camelAccount.modifiedAt != nil, "camel account modifiedAt should decode")
    try expect(camelAccount.nextRetryAfter != nil, "camel account nextRetryAfter should decode")
    try expect(camelAccount.nextRefreshAfter != nil, "camel account nextRefreshAfter should decode")
    try expect(camelAccount.modelStates["gpt-account-camel"]?.lastError?.message == "camel model failure", "camel account modelStates should decode")
    try expect(camelAccount.lastError?.message == "camel account failure", "camel account lastError should decode")
    try expect(camelAccount.websockets == true, "camel webSockets should decode")
    try expect(camelAccount.antigravityCredits?.creditAmount == 99, "camel account antigravityCredits should decode")

    let flexibleAuthJSON = """
    {
      "files": [
        {
          "id": 123,
          "authIndex": 456,
          "name": "codex.json",
          "provider": "codex",
          "projectId": "project-camel",
          "chatgpt_account_id": "acct-top-level",
          "plan": "team",
          "updated_at": 1779830400000,
          "last_refreshed_at": "2026-05-26T05:05:00Z"
        }
      ]
    }
    """.data(using: .utf8)!
    let flexibleAuth = try JSONDecoder().decode(AuthFilesResponse.self, from: flexibleAuthJSON)
    let flexibleAccount = try require(flexibleAuth.files.first, "flexible auth sample did not decode")
    try expect(flexibleAccount.id == "123", "flexible id parsing failed")
    try expect(flexibleAccount.authIndex == "456", "camel auth index parsing failed")
    try expect(flexibleAccount.projectID == "project-camel", "camel project id parsing failed")
    try expect(flexibleAccount.chatgptAccountID == "acct-top-level", "top-level ChatGPT account parsing failed")
    try expect(flexibleAccount.planType == "team", "top-level plan parsing failed")
    try expect(
        abs((flexibleAccount.updatedAt?.timeIntervalSince1970 ?? 0) - 1_779_830_400) < 0.001,
        "millisecond timestamp parsing failed"
    )
    try expect(
        abs((flexibleAccount.lastRefresh?.timeIntervalSince1970 ?? 0) - 1_779_771_900) < 0.001,
        "snake-case last refreshed timestamp parsing failed"
    )

    let camelRefreshJSON = """
    {
      "files": [
        {
          "id": "camel-refresh",
          "name": "camel.json",
          "provider": "codex",
          "lastRefreshedAt": 1779771901
        }
      ]
    }
    """.data(using: .utf8)!
    let camelRefresh = try JSONDecoder().decode(AuthFilesResponse.self, from: camelRefreshJSON)
    let camelRefreshAccount = try require(camelRefresh.files.first, "camel refresh auth sample did not decode")
    try expect(
        abs((camelRefreshAccount.lastRefresh?.timeIntervalSince1970 ?? 0) - 1_779_771_901) < 0.001,
        "camel last refreshed timestamp parsing failed"
    )
    let nanoRuntimeJSON = """
    {
      "files": [
        {
          "id": "nano-runtime",
          "name": "nano-runtime.json",
          "provider": "antigravity",
          "status": "active",
          "next_refresh_after": "2026-05-26T08:00:00.123456789Z",
          "next_retry_after": "2026-05-26T08:01:00.987654321+00:00",
          "quota": {
            "exceeded": true,
            "next_recover_at": "2026-05-26T08:02:00.555555555Z"
          },
          "model_states": {
            "gpt-nano": {
              "next_retry_after": "2026-05-26T08:03:00.444444444Z",
              "updated_at": "2026-05-26T08:04:00.333333333Z"
            }
          },
          "antigravity_credits": {
            "known": true,
            "available": true,
            "updated_at": "2026-05-26T08:05:00.222222222Z"
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let nanoRuntime = try JSONDecoder().decode(AuthFilesResponse.self, from: nanoRuntimeJSON)
    let nanoRuntimeAccount = try require(nanoRuntime.files.first, "nanosecond runtime sample did not decode")
    try expect(nanoRuntimeAccount.nextRefreshAfter != nil, "RFC3339Nano next_refresh_after should decode")
    try expect(nanoRuntimeAccount.nextRetryAfter != nil, "RFC3339Nano next_retry_after should decode")
    try expect(nanoRuntimeAccount.quota?.nextRecoverAt != nil, "RFC3339Nano quota next_recover_at should decode")
    let nanoRuntimeModel = try require(nanoRuntimeAccount.modelStates["gpt-nano"], "nanosecond model state missing")
    try expect(nanoRuntimeModel.nextRetryAfter != nil, "RFC3339Nano model next_retry_after should decode")
    try expect(nanoRuntimeModel.updatedAt != nil, "RFC3339Nano model updated_at should decode")
    try expect(nanoRuntimeAccount.antigravityCredits?.updatedAt != nil, "RFC3339Nano antigravity credits updated_at should decode")
    let pastRetryJSON = """
    {
      "files": [
        {
          "id": "past-retry",
          "name": "past-retry.json",
          "provider": "codex",
          "status": "active",
          "next_retry_after": "2020-01-01T00:00:00Z"
        }
      ]
    }
    """.data(using: .utf8)!
    let pastRetry = try JSONDecoder().decode(AuthFilesResponse.self, from: pastRetryJSON)
    let pastRetryAccount = try require(pastRetry.files.first, "past retry sample did not decode")
    try expect(pastRetryAccount.nextRecoveryDate == nil, "past retry timestamps should not be active recovery dates")
    try expect(pastRetryAccount.statusKind == .available, "past retry timestamps should not keep an active account cooling")
    let zeroTimeJSON = """
    {
      "files": [
        {
          "id": "zero-time",
          "name": "zero-time.json",
          "provider": "codex",
          "status": "active",
          "next_refresh_after": "0001-01-01T00:00:00.000Z",
          "model_states": {
            "gpt-zero": {
              "next_retry_after": "0001-01-01T00:00:00.000000Z",
              "updated_at": "0001-01-01 00:00:00 +0000 UTC"
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let zeroTimeAuth = try JSONDecoder().decode(AuthFilesResponse.self, from: zeroTimeJSON)
    let zeroTimeAccount = try require(zeroTimeAuth.files.first, "zero time sample did not decode")
    try expect(zeroTimeAccount.nextRefreshAfter == nil, "fractional Go zero next_refresh_after should be ignored")
    let zeroTimeModel = try require(zeroTimeAccount.modelStates["gpt-zero"], "zero time model state missing")
    try expect(zeroTimeModel.nextRetryAfter == nil, "fractional Go zero model next_retry_after should be ignored")
    try expect(zeroTimeModel.updatedAt == nil, "space-formatted Go zero model updated_at should be ignored")
    let blankProviderJSON = """
    {
      "files": [
        {
          "id": "type-fallback",
          "name": "type-fallback.json",
          "provider": "   ",
          "type": "codex"
        }
      ]
    }
    """.data(using: .utf8)!
    let blankProviderAuth = try JSONDecoder().decode(AuthFilesResponse.self, from: blankProviderJSON)
    let blankProviderAccount = try require(blankProviderAuth.files.first, "blank provider sample did not decode")
    try expect(blankProviderAccount.providerName == "codex", "blank provider should fall back to type")
    try expect(blankProviderAccount.normalizedProvider == "codex", "blank provider fallback should preserve normalized provider")
    try expect(ProviderCatalog.info(for: blankProviderAccount.normalizedProvider).supportsUsage, "blank provider fallback should keep usage support")
    try expect(
        abs((FlexibleDateParser.parse("1779830400000")?.timeIntervalSince1970 ?? 0) - 1_779_830_400) < 0.001,
        "string millisecond timestamp parsing failed"
    )
    try expect(
        abs((FlexibleDateParser.parse("4102444800")?.timeIntervalSince1970 ?? 0) - 4_102_444_800) < 0.001,
        "10-digit future Unix seconds should not be treated as milliseconds"
    )
    try expect(FlexibleDateParser.parse("2026-05-26T08:00:00.123456789Z") != nil, "RFC3339Nano ISO date should decode")
    try expect(
        FlexibleDateParser.parse("2026-05-26T16:00:00+08:00") == FlexibleDateParser.parse("2026-05-26T08:00:00Z"),
        "RFC3339 numeric timezone offsets should decode"
    )
    try expect(FlexibleDateParser.parse("2026-02-30T08:00:00Z") == nil, "invalid RFC3339 calendar dates should be rejected")
    try expect(FlexibleDateParser.parse("0001-01-01T00:00:00.000Z") == nil, "fractional Go zero ISO date should be ignored")
    try expect(FlexibleDateParser.parse("0001-01-01 00:00:00 +0000 UTC") == nil, "Go zero date string should be ignored")

    let flexibleModelsJSON = """
    {
      "models": [
        {
          "id": 123,
          "displayName": "Camel Model",
          "ownedBy": "team-a",
          "type": true
        }
      ]
    }
    """.data(using: .utf8)!
    let flexibleModels = try JSONDecoder().decode(ModelsResponse.self, from: flexibleModelsJSON)
    let flexibleModel = try require(flexibleModels.models.first, "flexible model sample did not decode")
    try expect(flexibleModel.id == "123", "flexible model id parsing failed")
    try expect(flexibleModel.displayName == "Camel Model", "camel model display name parsing failed")
    try expect(flexibleModel.ownedBy == "team-a", "camel model owner parsing failed")
    try expect(flexibleModel.type == "true", "flexible model type parsing failed")
    try expect(displayDuration(seconds: 61) == "2分钟", "short reset durations should be localized")
    try expect(displayDuration(seconds: 3_600) == "1小时", "hour reset durations should be localized")
    try expect(displayDuration(seconds: 90_000) == "1天 1小时", "day reset durations should be localized")

    let whamUsageJSON = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {
          "used_percent": 40,
          "reset_after_seconds": 3600,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 75,
          "reset_after_seconds": 86400,
          "limit_window_seconds": 604800
        }
      }
    }
    """
    let whamUsage = try require(UsageParser.parse(whamUsageJSON), "wham usage sample did not parse")
    try expect(whamUsage.planType == "plus", "usage plan parsing failed")
    try expect(whamUsage.primary?.remainingPercent == 60, "5h remaining parsing failed")
    try expect(whamUsage.weekly?.remainingPercent == 25, "7d remaining parsing failed")

    let whamRemainingJSON = """
    {
      "plan_type": "team",
      "rate_limit": {
        "primary_window": {
          "remaining_percent": "63%",
          "reset_after_seconds": 1800,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "remainingPercent": 22,
          "reset_after_seconds": 86400,
          "limit_window_seconds": 604800
        }
      }
    }
    """
    let whamRemaining = try require(UsageParser.parse(whamRemainingJSON), "wham remaining-percent sample did not parse")
    try expect(whamRemaining.primary?.remainingPercent == 63, "5h direct remaining percent parsing failed")
    try expect(whamRemaining.primary?.usedPercent == 37, "5h direct remaining should derive used percent")
    try expect(whamRemaining.weekly?.remainingPercent == 22, "7d camel remaining percent parsing failed")
    try expect(whamRemaining.weekly?.usedPercent == 78, "7d direct remaining should derive used percent")

    let whamZeroResetJSON = """
    {
      "rate_limit": {
        "primary_window": {
          "used_percent": 12,
          "reset_at": "0001-01-01T00:00:00.000Z",
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 22,
          "reset_at": 0,
          "limit_window_seconds": 604800
        }
      }
    }
    """
    let whamZeroReset = try require(UsageParser.parse(whamZeroResetJSON), "wham zero reset sample did not parse")
    try expect(whamZeroReset.primary?.resetAt == nil, "WHAM Go zero reset_at should be ignored")
    try expect(whamZeroReset.weekly?.resetAt == nil, "WHAM zero numeric reset_at should be ignored")

    let whamLimitJSON = """
    {
      "error": {
        "code": "rate_limit_exceeded",
        "message": "usage limit"
      },
      "rate_limit": {
        "primary_window": {
          "reset_after_seconds": 600,
          "limit_window_seconds": 18000
        },
        "allowed": false,
        "limit_reached": true
      }
    }
    """
    let whamLimit = try require(UsageParser.parse(whamLimitJSON), "wham limit sample did not parse")
    try expect(whamLimit.primary?.remainingPercent == 0, "limit response remaining percent failed")
    try expect(whamLimit.primary?.usedPercent == 100, "limit response used percent failed")
    try expect(whamLimit.rawStatus == "rate_limit_exceeded", "limit response status failed")

    let antigravityModelsJSON = """
    {
      "models": {
        "claude-sonnet-4-6": {
          "displayName": "claude-sonnet-4-6",
          "quotaInfo": {
            "remainingFraction": 0.32,
            "resetTime": "2026-05-26T08:00:00Z"
          }
        },
        "gemini-3-pro-high": {
          "quotaInfo": {
            "remainingFraction": 0,
            "resetTime": "2026-05-26T09:00:00Z"
          }
        }
      }
    }
    """
    let antigravityUsage = try require(UsageParser.parse(antigravityModelsJSON), "antigravity usage sample did not parse")
    try expect(antigravityUsage.additionalWindows.count == 2, "antigravity model groups failed")
    try expect(antigravityUsage.additionalWindows[0].remainingPercent == 32, "antigravity remaining percent failed")

    let antigravityPercentModelsJSON = """
    {
      "models": {
        "gemini-2.5-flash": {
          "displayName": "Gemini 2.5 Flash",
          "quotaInfo": {
            "remainingPercent": "42%",
            "resetTime": "2026-05-26T09:00:00Z"
          }
        }
      }
    }
    """
    let antigravityPercentUsage = try require(UsageParser.parse(antigravityPercentModelsJSON), "antigravity remaining-percent model sample did not parse")
    let antigravityPercentWindow = try require(antigravityPercentUsage.additionalWindows.first, "antigravity remaining-percent window missing")
    try expect(antigravityPercentWindow.remainingPercent == 42, "antigravity direct remaining percent parsing failed")
    try expect(antigravityPercentWindow.usedPercent == 58, "antigravity direct remaining percent should derive used percent")

    let antigravityNumericPercentJSON = """
    {
      "models": {
        "gemini-2.5-flash-lite": {
          "displayName": "Gemini 2.5 Flash Lite",
          "quotaInfo": {
            "remainingFraction": 37
          }
        }
      }
    }
    """
    let antigravityNumericPercentUsage = try require(UsageParser.parse(antigravityNumericPercentJSON), "antigravity numeric percent-like fraction sample did not parse")
    let antigravityNumericPercentWindow = try require(antigravityNumericPercentUsage.additionalWindows.first, "antigravity numeric percent-like fraction window missing")
    try expect(antigravityNumericPercentWindow.remainingPercent == 37, "antigravity percent-like remaining fraction parsing failed")
    try expect(antigravityNumericPercentWindow.usedPercent == 63, "antigravity percent-like remaining fraction should derive used percent")

    let antigravityZeroResetJSON = """
    {
      "models": {
        "gemini-3-flash": {
          "displayName": "Gemini 3 Flash",
          "quotaInfo": {
            "remainingFraction": 0.91,
            "resetTime": "0001-01-01T00:00:00.000000Z"
          }
        }
      }
    }
    """
    let antigravityZeroResetUsage = try require(UsageParser.parse(antigravityZeroResetJSON), "antigravity zero reset sample did not parse")
    let antigravityZeroResetWindow = try require(antigravityZeroResetUsage.additionalWindows.first, "antigravity zero reset window missing")
    try expect(antigravityZeroResetWindow.resetAt == nil, "antigravity Go zero reset time should be ignored")
    try expect(antigravityZeroResetWindow.detailText == nil, "antigravity Go zero reset time should not show placeholder detail text")

    let antigravityFullModelsJSON = """
    {
      "models": {
        "claude-sonnet-4-6": {
          "displayName": "Claude Sonnet 4.6",
          "quotaInfo": {
            "remainingFraction": 1,
            "resetTime": "2026-05-27T17:09:00Z"
          }
        },
        "gemini-3.1-pro-high": {
          "displayName": "Gemini 3.1 Pro High",
          "quotaInfo": {
            "remainingFraction": 1,
            "resetTime": "2026-05-27T17:09:00Z"
          }
        },
        "gemini-2.5-flash": {
          "displayName": "Gemini 2.5 Flash",
          "quotaInfo": {
            "remainingFraction": "100%",
            "resetTime": "2026-05-27T17:09:00Z"
          }
        },
        "gemini-2.5-flash-lite": {
          "displayName": "Gemini 2.5 Flash Lite",
          "quotaInfo": {
            "remainingFraction": 1,
            "resetTime": "2026-05-27T17:09:00Z"
          }
        },
        "gemini-3-flash": {
          "displayName": "Gemini 3 Flash",
          "quotaInfo": {
            "remainingFraction": 1,
            "resetTime": "2026-05-27T17:09:00Z"
          }
        },
        "gemini-3.1-flash-image": {
          "displayName": "Gemini 3.1 Flash Image",
          "quotaInfo": {
            "remainingFraction": 1
          }
        }
      }
    }
    """
    let antigravityFullUsage = try require(UsageParser.parse(antigravityFullModelsJSON), "full antigravity usage sample did not parse")
    try expect(antigravityFullUsage.additionalWindows.map(\.label) == [
        "Claude/GPT",
        "Gemini 3.1 Pro Series",
        "Gemini 2.5 Flash",
        "Gemini 2.5 Flash Lite",
        "Gemini 3 Flash",
        "Gemini 3.1 Flash Image"
    ], "full antigravity labels failed")
    try expect(antigravityFullUsage.additionalWindows.compactMap(\.displayValue) == Array(repeating: "100%", count: 6), "full antigravity display values failed")

    let claudeUsageJSON = """
    {
      "_provider": "claude",
      "profile": {
        "account": {
          "has_claude_pro": true,
          "has_claude_max": false
        }
      },
      "usage": {
        "five_hour": {
          "utilization": 25,
          "resets_at": "2026-05-27T17:31:04Z"
        },
        "seven_day_opus": {
          "utilization": 80,
          "resets_at": "2026-05-27T17:31:04Z"
        },
        "extra_usage": {
          "is_enabled": true,
          "used_credits": 123,
          "monthly_limit": 1000
        }
      }
    }
    """
    let claudeUsage = try require(UsageParser.parse(claudeUsageJSON), "claude usage sample did not parse")
    try expect(claudeUsage.planType == "专业版", "claude plan parsing failed")
    try expect(claudeUsage.additionalWindows.map(\.label) == ["5 小时限额", "7 天 Opus", "额外用量"], "claude labels failed")
    try expect(claudeUsage.additionalWindows.first?.remainingPercent == 75, "claude remaining percent failed")
    try expect(claudeUsage.additionalWindows.last?.amountText == "$1.23 / $10.00", "claude extra usage amount failed")
    let claudeCurrencyUsageJSON = """
    {
      "_provider": "claude",
      "usage": {
        "extra_usage": {
          "is_enabled": true,
          "used_credits": "$1.23",
          "monthly_limit": "$10.00"
        }
      }
    }
    """
    let claudeCurrencyUsage = try require(UsageParser.parse(claudeCurrencyUsageJSON), "claude currency usage sample did not parse")
    try expect(claudeCurrencyUsage.additionalWindows.last?.amountText == "$1.23 / $10.00", "claude currency amount parsing failed")

    let kimiUsageJSON = """
    {
      "usage": {
        "limit": 100,
        "used": 40,
        "reset_in": 3600
      },
      "limits": [
        {
          "window": {
            "duration": 7,
            "timeUnit": "DAYS"
          },
          "detail": {
            "limit": 1000,
            "remaining": 900,
            "reset_time": "2026-05-27T17:31:04Z"
          }
        }
      ]
    }
    """
    let kimiUsage = try require(UsageParser.parse(kimiUsageJSON), "kimi usage sample did not parse")
    try expect(kimiUsage.additionalWindows.map(\.label) == ["周限额", "7天限额"], "kimi labels failed")
    try expect(kimiUsage.additionalWindows.first?.remainingPercent == 60, "kimi summary remaining failed")
    try expect(kimiUsage.additionalWindows.first?.amountText == "40 / 100", "kimi amount text failed")
    try expect(kimiUsage.additionalWindows.first?.detailText == "1小时后重置", "kimi reset text should be localized")
    try expect(kimiUsage.additionalWindows.last?.remainingPercent == 90, "kimi detail remaining failed")
    let kimiCommaUsageJSON = """
    {
      "usage": {
        "limit": "1,000",
        "remaining": "900"
      }
    }
    """
    let kimiCommaUsage = try require(UsageParser.parse(kimiCommaUsageJSON), "kimi comma-number sample did not parse")
    try expect(kimiCommaUsage.additionalWindows.first?.remainingPercent == 90, "kimi comma number remaining failed")
    try expect(kimiCommaUsage.additionalWindows.first?.amountText == "100 / 1000", "kimi comma number amount text failed")
    let kimiPastResetJSON = """
    {
      "usage": {
        "limit": 100,
        "used": 1,
        "reset_time": "2001-01-01T00:00:00Z"
      }
    }
    """
    let kimiPastResetUsage = try require(
        UsageParser.parse(kimiPastResetJSON, now: Date(timeIntervalSince1970: 1_779_830_400)),
        "kimi past reset sample did not parse"
    )
    try expect(kimiPastResetUsage.additionalWindows.first?.detailText == "已重置", "kimi past reset text should be localized")

    let xaiUsageJSON = """
    {
      "config": {
        "monthlyLimit": { "val": 10000 },
        "used": { "val": 2500 },
        "onDemandCap": { "val": 5000 },
        "billingPeriodEnd": "2026-05-27T17:31:04Z"
      }
    }
    """
    let xaiUsage = try require(UsageParser.parse(xaiUsageJSON), "xai usage sample did not parse")
    try expect(xaiUsage.additionalWindows.map(\.label) == ["按量付费", "月度积分"], "xai labels failed")
    try expect(xaiUsage.additionalWindows.first?.displayValue == "已启用", "xai on-demand display failed")
    try expect(xaiUsage.additionalWindows.first?.amountText == "封顶 $50.00", "xai on-demand cap failed")
    try expect(xaiUsage.additionalWindows.last?.remainingPercent == 75, "xai monthly remaining failed")
    try expect(xaiUsage.additionalWindows.last?.amountText == "$25.00 / $100.00", "xai monthly amount failed")
    let xaiCurrencyUsageJSON = """
    {
      "config": {
        "monthlyLimit": { "val": "$100.00" },
        "used": { "val": "$25.00" },
        "onDemandCap": { "val": "$50.00" }
      }
    }
    """
    let xaiCurrencyUsage = try require(UsageParser.parse(xaiCurrencyUsageJSON), "xai currency usage sample did not parse")
    try expect(xaiCurrencyUsage.additionalWindows.first?.amountText == "封顶 $50.00", "xai currency on-demand cap failed")
    try expect(xaiCurrencyUsage.additionalWindows.last?.remainingPercent == 75, "xai currency monthly remaining failed")
    try expect(xaiCurrencyUsage.additionalWindows.last?.amountText == "$25.00 / $100.00", "xai currency monthly amount failed")

    let genericLimitJSON = """
    {
      "error": {
        "message": "quota exhausted"
      },
      "reset_at": "2026-05-27T17:31:04Z"
    }
    """
    let genericLimitUsage = try require(UsageParser.parse(genericLimitJSON), "generic quota reset sample did not parse")
    try expect(genericLimitUsage.primary?.remainingPercent == 0, "generic ISO reset quota should be treated as exhausted")
    try expect(genericLimitUsage.primary?.resetAt != nil, "generic ISO reset quota should keep reset time")

    let genericFutureSecondsJSON = """
    {
      "error": {
        "message": "quota exhausted"
      },
      "reset_at": 4102444800
    }
    """
    let genericFutureSecondsUsage = try require(UsageParser.parse(genericFutureSecondsJSON), "generic Unix seconds reset sample did not parse")
    try expect(
        abs((genericFutureSecondsUsage.primary?.resetAt?.timeIntervalSince1970 ?? 0) - 4_102_444_800) < 0.001,
        "generic 10-digit Unix reset seconds should not be treated as milliseconds"
    )

    let genericRemainingJSON = """
    {
      "quota": {
        "remaining_percentage": "12%",
        "reset_after_seconds": 240
      }
    }
    """
    let genericRemainingUsage = try require(UsageParser.parse(genericRemainingJSON), "generic remaining-percent sample did not parse")
    try expect(genericRemainingUsage.primary?.remainingPercent == 12, "generic direct remaining percent parsing failed")
    try expect(genericRemainingUsage.primary?.usedPercent == 88, "generic direct remaining should derive used percent")
    try expect(genericRemainingUsage.primary?.resetAfterSeconds == 240, "generic remaining reset seconds failed")

    let booleanQuotaNoiseJSON = """
    {
      "quota": {
        "remaining_percentage": true,
        "used_percent": false,
        "reset_after_seconds": true
      },
      "status": true
    }
    """
    try expect(UsageParser.parse(booleanQuotaNoiseJSON) == nil, "boolean quota fields should not parse as numeric percentages")

    let antigravityCreditsUsageJSON = """
    {
      "paidTier": {
        "id": "tier-1",
        "availableCredits": [
          {
            "creditType": "GOOGLE_ONE_AI",
            "creditAmount": 30,
            "minimumCreditAmountForUsage": 50
          }
        ]
      }
    }
    """
    let antigravityCreditsUsage = try require(UsageParser.parse(antigravityCreditsUsageJSON), "antigravity credits usage sample did not parse")
    let antigravityCreditsWindow = try require(antigravityCreditsUsage.additionalWindows.first, "antigravity credits window missing")
    try expect(antigravityCreditsWindow.amountText == "min 50", "antigravity credits minimum should be numeric metadata")
    try expect(antigravityCreditsWindow.detailText == nil, "antigravity credits minimum should not be treated as reset timing")
    let antigravityCommaCreditsUsageJSON = """
    {
      "paidTier": {
        "availableCredits": [
          {
            "creditType": "GOOGLE_ONE_AI",
            "creditAmount": "1,200",
            "minimumCreditAmountForUsage": "2,000"
          }
        ]
      }
    }
    """
    let antigravityCommaCreditsUsage = try require(UsageParser.parse(antigravityCommaCreditsUsageJSON), "antigravity comma credits sample did not parse")
    let antigravityCommaCreditsWindow = try require(antigravityCommaCreditsUsage.additionalWindows.first, "antigravity comma credits window missing")
    try expect(antigravityCommaCreditsWindow.remainingPercent == 60, "antigravity comma credits percent failed")
    try expect(antigravityCommaCreditsWindow.displayValue == "1.2K", "antigravity comma credit display failed")
    try expect(antigravityCommaCreditsWindow.amountText == "min 2.0K", "antigravity comma credit minimum display failed")

    let longError = """
    HTTP 502
    {"error":"bad gateway","message":"upstream quota endpoint returned a long HTML or JSON body that should not stretch account cards beyond the available width"}
    """
    let trimmedError = displayErrorMessage(longError, limit: 72)
    try expect(trimmedError.count <= 72, "trimmed error should respect display limit")
    try expect(!trimmedError.contains("\n"), "trimmed error should collapse newlines")
    try expect(trimmedError.hasSuffix("..."), "trimmed error should indicate truncation")

    let accountQuota = AccountQuota(account: account, usage: whamUsage, errorMessage: nil)
    try expect(accountQuota.lowestRemainingPercent == 25, "account quota lowest remaining failed")
    try expect(accountQuota.statusKind == .cooling, "runtime cooldown should not be hidden by live quota")
    let errorQuota = AccountQuota(account: flexibleAccount, usage: nil, errorMessage: longError)
    try expect(errorQuota.liveQuotaLine.count <= 72, "row error should be compact")
    try expect(!errorQuota.liveQuotaLine.contains("\n"), "row error should be single-line")
    let accountLastErrorJSON = """
    {
      "files": [
        {
          "id": "runtime-error",
          "name": "runtime-error.json",
          "provider": "codex",
          "status": "active",
          "last_error": {"message": "refresh failed"}
        }
      ]
    }
    """.data(using: .utf8)!
    let accountLastErrorResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: accountLastErrorJSON)
    let accountLastError = try require(accountLastErrorResponse.files.first, "account last_error sample did not decode")
    try expect(accountLastError.statusKind == .error, "account-level last_error should be surfaced as an error state")
    try expect(accountLastError.quotaLine == "refresh failed", "account-level last_error should drive the row status line")
    let accountLastErrorQuota = AccountQuota(account: accountLastError, usage: nil, errorMessage: nil)
    try expect(accountLastErrorQuota.needsQuotaAlert(threshold: 15), "account-level last_error should be attention-worthy")
    let modelOnlyErrorJSON = """
    {
      "files": [
        {
          "id": "model-only-error",
          "name": "model-only-error.json",
          "provider": "codex",
          "status": "active",
          "model_states": {
            "gpt-model-error": {
              "status": "error",
              "last_error": {"message": "model backend failed"}
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let modelOnlyErrorResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: modelOnlyErrorJSON)
    let modelOnlyError = try require(modelOnlyErrorResponse.files.first, "model-only error sample did not decode")
    try expect(modelOnlyError.statusKind == .error, "model-level last_error should promote account status to error")
    try expect(modelOnlyError.quotaLine == "gpt-model-error: model backend failed", "model-level last_error should drive the row status line")
    let modelOnlyErrorQuota = AccountQuota(account: modelOnlyError, usage: nil, errorMessage: nil)
    try expect(modelOnlyErrorQuota.needsQuotaAlert(threshold: 15), "model-level last_error should be attention-worthy")
    let modelOnlyCooldownJSON = """
    {
      "files": [
        {
          "id": "model-only-cooldown",
          "name": "model-only-cooldown.json",
          "provider": "codex",
          "status": "active",
          "model_states": {
            "gpt-model-cooling": {
              "status": "active",
              "unavailable": true,
              "next_retry_after": "2030-03-17T17:46:40Z"
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let modelOnlyCooldownResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: modelOnlyCooldownJSON)
    let modelOnlyCooldown = try require(modelOnlyCooldownResponse.files.first, "model-only cooldown sample did not decode")
    try expect(modelOnlyCooldown.statusKind == .cooling, "model-level cooldown should promote account status to cooling")
    try expect(modelOnlyCooldown.quotaLine == "gpt-model-cooling: active", "model-level cooldown should drive the row status line")
    let modelOnlyQuotaStatusJSON = """
    {
      "files": [
        {
          "id": "model-only-quota-status",
          "name": "model-only-quota-status.json",
          "provider": "codex",
          "status": "active",
          "model_states": {
            "gpt-model-quota": {
              "status": "quota_exceeded"
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let modelOnlyQuotaStatusResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: modelOnlyQuotaStatusJSON)
    let modelOnlyQuotaStatus = try require(modelOnlyQuotaStatusResponse.files.first, "model-only quota status sample did not decode")
    try expect(modelOnlyQuotaStatus.statusKind == .cooling, "model quota status should promote account status to cooling")
    try expect(
        modelOnlyQuotaStatus.activeModelCooldowns.contains { $0.model == "gpt-model-quota" },
        "model quota status should appear in account runtime issue list"
    )
    try expect(
        modelOnlyQuotaStatus.quotaLine == "gpt-model-quota: quota_exceeded",
        "model quota status should drive the row status line"
    )
    let modelOnlyFailedStatusJSON = """
    {
      "files": [
        {
          "id": "model-only-failed-status",
          "name": "model-only-failed-status.json",
          "provider": "codex",
          "status": "active",
          "model_states": {
            "gpt-model-failed": {
              "status": "request_failed"
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let modelOnlyFailedStatusResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: modelOnlyFailedStatusJSON)
    let modelOnlyFailedStatus = try require(modelOnlyFailedStatusResponse.files.first, "model-only failed status sample did not decode")
    try expect(modelOnlyFailedStatus.statusKind == .error, "model failed status should promote account status to error")
    try expect(
        modelOnlyFailedStatus.quotaLine == "gpt-model-failed: request_failed",
        "model failed status should drive the row status line"
    )
    let baseDashboard = ManagementDashboard(accounts: [account], accountQuotas: [AccountQuota(account: account, usage: nil, errorMessage: nil)])
    let updatedDashboard = baseDashboard.replacingAccountQuota(accountQuota)
    try expect(updatedDashboard.accountQuotas.count == 1, "dashboard quota replacement count failed")
    try expect(updatedDashboard.accountQuotas[0].lowestRemainingPercent == 25, "dashboard quota replacement failed")
    let refreshedBaseDashboard = ManagementDashboard(accounts: [account], accountQuotas: [AccountQuota(account: account, usage: nil, errorMessage: nil)])
    let preservedDashboard = refreshedBaseDashboard.preservingLiveUsage(from: updatedDashboard)
    try expect(preservedDashboard.accountQuotas[0].lowestRemainingPercent == 25, "dashboard should preserve live quota during base refresh")
    let duplicatePreviousDashboard = ManagementDashboard(accounts: [account], accountQuotas: [
        AccountQuota(account: account, usage: nil, errorMessage: nil),
        accountQuota
    ])
    let duplicatePreservedDashboard = refreshedBaseDashboard.preservingLiveUsage(from: duplicatePreviousDashboard)
    try expect(duplicatePreservedDashboard.accountQuotas[0].usage == nil, "dashboard should ignore ambiguous duplicate prior quota IDs without crashing")
    let duplicateAccountJSON = """
    {
      "files": [
        {
          "id": "duplicate-id",
          "auth_index": "dup-a",
          "name": "duplicate-a.json",
          "label": "Shared Duplicate",
          "provider": "codex",
          "status": "active"
        },
        {
          "id": "duplicate-id",
          "auth_index": "dup-b",
          "name": "duplicate-b.json",
          "label": "Shared Duplicate",
          "provider": "codex",
          "status": "active"
        }
      ]
    }
    """.data(using: .utf8)!
    let duplicateAccountsResponse = try JSONDecoder().decode(AuthFilesResponse.self, from: duplicateAccountJSON)
    try expect(duplicateAccountsResponse.files.count == 2, "duplicate account sample did not decode")
    let duplicateA = duplicateAccountsResponse.files[0]
    let duplicateB = duplicateAccountsResponse.files[1]
    let duplicateBQuota = AccountQuota(account: duplicateB, usage: whamUsage, errorMessage: nil)
    try validateStableAccountIdentity(
        duplicateA: duplicateA,
        duplicateB: duplicateB,
        duplicateBQuota: duplicateBQuota
    )
    let duplicateBaseDashboard = ManagementDashboard(accounts: [duplicateA, duplicateB])
    let duplicateUpdatedDashboard = duplicateBaseDashboard.replacingAccountQuota(duplicateBQuota)
    try expect(duplicateUpdatedDashboard.accountQuotas[0].usage == nil, "duplicate ID replacement should not update the wrong account")
    try expect(duplicateUpdatedDashboard.accountQuotas[1].lowestRemainingPercent == 25, "duplicate ID replacement should match auth identity")
    let duplicateRefreshDashboard = ManagementDashboard(accounts: [duplicateA, duplicateB])
    let duplicateIdentityPreservedDashboard = duplicateRefreshDashboard.preservingLiveUsage(from: duplicateUpdatedDashboard)
    try expect(duplicateIdentityPreservedDashboard.accountQuotas[0].usage == nil, "duplicate ID preservation should not attach quota to the wrong account")
    try expect(duplicateIdentityPreservedDashboard.accountQuotas[1].lowestRemainingPercent == 25, "duplicate ID preservation should match auth identity")
    let removedAccountDashboard = ManagementDashboard(accounts: [duplicateA])
    let ignoredRemovedAccountUpdate = removedAccountDashboard.replacingAccountQuota(duplicateBQuota)
    try expect(
        ignoredRemovedAccountUpdate.accountQuotas.count == removedAccountDashboard.accountQuotas.count,
        "dashboard should not append stale per-account refresh results"
    )
    try expect(
        ignoredRemovedAccountUpdate.accountQuotas.allSatisfy { $0.account.authIndex != duplicateB.authIndex },
        "dashboard should ignore stale per-account refresh results for removed accounts"
    )
    let duplicateKeyPreviousDashboard = ManagementDashboard(accounts: [duplicateB, duplicateB], accountQuotas: [
        AccountQuota(account: duplicateB, usage: nil, errorMessage: "first duplicate"),
        duplicateBQuota
    ])
    let duplicateKeyRefreshedDashboard = ManagementDashboard(accounts: [duplicateB, duplicateB])
    let duplicateKeyPreservedDashboard = duplicateKeyRefreshedDashboard.preservingLiveUsage(from: duplicateKeyPreviousDashboard)
    try expect(
        duplicateKeyPreservedDashboard.accountQuotas.allSatisfy { $0.usage == nil && $0.errorMessage == nil },
        "non-unique account keys should not preserve quota onto indistinguishable rows"
    )
    let reusedIDPreviousJSON = """
    {
      "files": [
        {
          "id": "reused-id",
          "auth_index": "old-auth",
          "name": "old-account.json",
          "provider": "codex",
          "status": "active"
        }
      ]
    }
    """.data(using: .utf8)!
    let reusedIDCurrentJSON = """
    {
      "files": [
        {
          "id": "reused-id",
          "auth_index": "new-auth",
          "name": "new-account.json",
          "provider": "codex",
          "status": "active"
        }
      ]
    }
    """.data(using: .utf8)!
    let reusedIDPrevious = try require(
        JSONDecoder().decode(AuthFilesResponse.self, from: reusedIDPreviousJSON).files.first,
        "reused ID previous account did not decode"
    )
    let reusedIDCurrent = try require(
        JSONDecoder().decode(AuthFilesResponse.self, from: reusedIDCurrentJSON).files.first,
        "reused ID current account did not decode"
    )
    let reusedIDPreviousDashboard = ManagementDashboard(
        accounts: [reusedIDPrevious],
        accountQuotas: [AccountQuota(account: reusedIDPrevious, usage: whamUsage, errorMessage: nil)]
    )
    let reusedIDPreservedDashboard = ManagementDashboard(accounts: [reusedIDCurrent])
        .preservingLiveUsage(from: reusedIDPreviousDashboard)
    try expect(
        reusedIDPreservedDashboard.accountQuotas[0].usage == nil,
        "conflicting reused account IDs should not preserve stale live quota"
    )
    let previousErrorDashboard = refreshedBaseDashboard.replacingAccountQuota(AccountQuota(account: account, usage: nil, errorMessage: longError))
    let preservedErrorDashboard = refreshedBaseDashboard.preservingLiveUsage(from: previousErrorDashboard)
    try expect(preservedErrorDashboard.accountQuotas[0].usage == nil, "dashboard should not invent usage when preserving a live quota error")
    try expect(preservedErrorDashboard.accountQuotas[0].errorMessage == longError, "dashboard should preserve live quota errors during base refresh")
    let crowdedQuota = AccountQuota(
        account: flexibleAccount,
        usage: UsageSnapshot(
            planType: nil,
            primary: QuotaWindow(
                id: "primary-safe",
                label: "5h",
                usedPercent: 20,
                remainingPercent: 80,
                resetAfterSeconds: nil,
                resetAt: nil
            ),
            weekly: QuotaWindow(
                id: "weekly-safe",
                label: "7d",
                usedPercent: 30,
                remainingPercent: 70,
                resetAfterSeconds: nil,
                resetAt: nil
            ),
            additionalWindows: [
                QuotaWindow(id: "safe-a", label: "Safe A", usedPercent: 10, remainingPercent: 90, resetAfterSeconds: nil, resetAt: nil),
                QuotaWindow(id: "safe-b", label: "Safe B", usedPercent: 12, remainingPercent: 88, resetAfterSeconds: nil, resetAt: nil),
                QuotaWindow(id: "exhausted-late", label: "Late Exhausted", usedPercent: 100, remainingPercent: 0, resetAfterSeconds: nil, resetAt: nil),
                QuotaWindow(id: "low-late", label: "Late Low", usedPercent: 90, remainingPercent: 10, resetAfterSeconds: nil, resetAt: nil)
            ],
            rawStatus: "validation"
        ),
        errorMessage: nil
    )
    try expect(crowdedQuota.dashboardQuotaWindows.map(\.id).contains("exhausted-late"), "dashboard quota windows should not hide exhausted late windows")
    try expect(crowdedQuota.dashboardQuotaWindows.map(\.id).contains("low-late"), "dashboard quota windows should include low late windows")
    try expect(Array(crowdedQuota.dashboardQuotaWindows.map(\.id).prefix(2)) == ["primary-safe", "weekly-safe"], "dashboard quota windows should preserve primary and weekly rows")
    try expect(crowdedQuota.hiddenDashboardQuotaWindowCount == 2, "hidden dashboard quota window count failed")

    let exhaustedCreditsJSON = """
    {
      "files": [
        {
          "id": "ag-1",
          "name": "antigravity.json",
          "provider": "antigravity",
          "status": "active",
          "antigravity_credits": {
            "known": true,
            "available": false,
            "credit_amount": 30,
            "min_credit_amount": 50
          }
        }
      ]
    }
    """.data(using: .utf8)!
    let exhaustedCredits = try JSONDecoder().decode(AuthFilesResponse.self, from: exhaustedCreditsJSON)
    let exhaustedAccount = try require(exhaustedCredits.files.first, "credits sample did not decode")
    try expect(exhaustedAccount.statusKind == .cooling, "exhausted credits should be cooling")

    let apiKeyUsageJSON = try validateAPIKeyUsageParser()

    let camelSwitch = try JSONDecoder().decode(BooleanValueResponse.self, from: Data(#"{"switchProject":"true","switchPreviewModel":"false"}"#.utf8))
    try expect(camelSwitch.switchProject == true, "camel switch project response should decode")
    try expect(camelSwitch.switchPreviewModel == false, "camel switch preview response should decode")
    let snakeSwitch = try JSONDecoder().decode(BooleanValueResponse.self, from: Data(#"{"switch_project":false,"switch_preview_model":true}"#.utf8))
    try expect(snakeSwitch.switchProject == false, "snake switch project response should decode")
    try expect(snakeSwitch.switchPreviewModel == true, "snake switch preview response should decode")

    let demoDashboard = ManagementDashboard.demo()
    try expect(demoDashboard.accounts.count >= 6, "demo dashboard account count failed")
    try expect(demoDashboard.accountQuotas.contains { $0.usage?.hasQuotaSignal == true }, "demo dashboard quota signal missing")
    try expect(demoDashboard.apiKeyUsage.count == 1, "demo dashboard api key usage missing")
    try expect(demoDashboard.accountQuotas.contains { $0.statusKind == .cooling }, "demo dashboard cooling account missing")
    try expect(demoDashboard.accountQuotas.contains { ProviderCatalog.info(for: $0.account.normalizedProvider).key == "kimi" }, "demo dashboard should include Kimi")
    let demoKimi = try require(
        demoDashboard.accountQuotas.first { ProviderCatalog.info(for: $0.account.normalizedProvider).key == "kimi" },
        "demo Kimi account missing"
    )
    try expect(demoKimi.usage?.hasQuotaSignal == true, "demo Kimi account should include quota signal")
    let demoClaude = try require(
        demoDashboard.accountQuotas.first { ProviderCatalog.info(for: $0.account.normalizedProvider).key == "claude" },
        "demo Claude account missing"
    )
    let demoClaudeModels = ManagementDashboard.demoModels(for: demoClaude.account)
    try expect(demoClaudeModels.contains { $0.id == "claude-opus-4" }, "demo Claude models should include runtime-limited model metadata")
    try expect(demoClaude.account.modelStates["claude-opus-4"]?.quota?.exceeded == true, "demo Claude should include model runtime quota state")
    let demoXAI = try require(
        demoDashboard.accountQuotas.first { ProviderCatalog.info(for: $0.account.normalizedProvider).key == "xai" },
        "demo xAI account missing"
    )
    try expect(ManagementDashboard.demoModels(for: demoXAI.account).contains { $0.id == "grok-code-fast-1" }, "demo xAI models should include runtime-error model metadata")
    try expect(demoXAI.account.modelStates["grok-code-fast-1"]?.lastError?.message.contains("429") == true, "demo xAI should include model runtime error state")

    let submissionNotes = try fileText("APP_STORE_SUBMISSION.md")
    let appStoreMetadata = try fileText("APP_STORE_METADATA.md")
    let supportPage = try fileText("SUPPORT.md")
    let privacyPolicy = try fileText("PRIVACY_POLICY.md")
    try expect(submissionNotes.contains("built-in demo dashboard"), "submission notes should mention demo dashboard")
    try expect(submissionNotes.contains("reopened from Settings"), "submission notes should document Settings demo access")
    try expect(submissionNotes.contains("APP_STORE_METADATA.md"), "submission notes should reference App Store metadata copy")
    try expect(submissionNotes.contains("SUPPORT.md") && submissionNotes.contains("PRIVACY_POLICY.md"), "submission notes should reference public support and privacy policy sources")
    try expect(submissionNotes.contains("Codex, Claude, Antigravity, Kimi, Grok"), "submission notes should document demo provider coverage")
    try expect(submissionNotes.contains("bundled account-detail model metadata"), "submission notes should document demo model metadata coverage")
    try expect(submissionNotes.contains("does not store credentials"), "submission notes should mention demo credential storage")
    try expect(submissionNotes.contains("ephemeral URLSession"), "submission notes should document non-persistent network sessions")
    try expect(submissionNotes.contains("no-store cache headers"), "submission notes should document cache-bypassing management requests")
    try expect(submissionNotes.contains("model runtime status badges"), "submission notes should document account-detail model runtime status")
    try expect(submissionNotes.contains("Background App Refresh"), "submission notes should document background refresh behavior")
    try expect(submissionNotes.contains("marked privacy-sensitive"), "submission notes should document sensitive UI redaction hints")
    try expect(submissionNotes.contains("does not include the management key value"), "submission notes should document no-key support diagnostics")
    try expect(submissionNotes.contains("Final Xcode Gates"), "submission notes should include Xcode gates")
    try expect(submissionNotes.contains("Scripts/validate_local.sh"), "submission notes should include the local validation script")
    try expect(submissionNotes.contains("Scripts/validate_xcode_release.sh"), "submission notes should include the full Xcode release validation script")
    try expect(appStoreMetadata.contains("CLIProxyAPI 额度监控"), "App Store metadata should include the localized subtitle")
    try expect(appStoreMetadata.contains("## Promotional Text"), "App Store metadata should include promotional text")
    try expect(appStoreMetadata.contains("## Description"), "App Store metadata should include description copy")
    try expect(appStoreMetadata.contains("## Keywords"), "App Store metadata should include keywords")
    try expect(appStoreMetadata.contains("## Screenshot Checklist"), "App Store metadata should include screenshot planning")
    try expect(appStoreMetadata.contains("## Privacy Answers"), "App Store metadata should include privacy answers")
    try expect(appStoreMetadata.contains("no-key diagnostics copy action"), "App Store metadata should include support diagnostics screenshot planning")
    try expect(appStoreMetadata.contains("built-in demo dashboard"), "App Store metadata should mention demo review without credentials")
    try expect(appStoreMetadata.contains("Settings screen with the demo action"), "App Store metadata should include Settings demo screenshot planning")
    try expect(appStoreMetadata.contains("notification-tap attention view"), "App Store metadata should include notification tap screenshot planning")
    try expect(appStoreMetadata.contains("model runtime status badges"), "App Store metadata should mention model runtime status")
    try expect(appStoreMetadata.contains("Keychain") && appStoreMetadata.contains("UserDefaults"), "App Store metadata should document local credential storage")
    try expect(appStoreMetadata.contains("notification delivery and badge status"), "App Store metadata should include notification diagnostics screenshot planning")
    try expect(appStoreMetadata.contains("dashboard server hosts, dashboard account identifiers, project IDs, API base URLs"), "App Store metadata should document dashboard privacy-sensitive fields")
    try expect(appStoreMetadata.contains("local notifications only"), "App Store metadata should document local-only notifications")
    try expect(appStoreMetadata.contains("Background App Refresh"), "App Store metadata should document background refresh usage")
    try expect(appStoreMetadata.contains("Publish `SUPPORT.md`"), "App Store metadata should call out required support URL source")
    try expect(appStoreMetadata.contains("Publish `PRIVACY_POLICY.md`"), "App Store metadata should call out required privacy policy URL source")
    try expect(appStoreMetadata.contains("DEVELOPMENT_TEAM=YOURTEAMID Scripts/validate_xcode_release.sh"), "App Store metadata should include the release validation command")
    try expect(appStoreMetadata.contains("CPA_ALLOW_PROVISIONING_UPDATES=1"), "App Store metadata should document optional provisioning updates")
    try expect(supportPage.contains("remote-management.allow-remote"), "support page should document remote management setup")
    try expect(supportPage.contains("/v0/management/api-call"), "support page should document live quota API requirements")
    try expect(supportPage.contains("Copy Diagnostics"), "support page should document diagnostics copy")
    try expect(supportPage.contains("generation time"), "support page should document diagnostics timestamps")
    try expect(supportPage.contains("does not include the key value"), "support page should document no-key diagnostics")
    try expect(supportPage.contains("Background App Refresh status"), "support page should document background refresh diagnostics")
    try expect(supportPage.contains("notification authorization") && supportPage.contains("badge availability"), "support page should document notification diagnostics")
    try expect(supportPage.contains("built-in demo dashboard"), "support page should document demo review mode")
    try expect(supportPage.contains("opened from Settings without clearing credentials"), "support page should document Settings demo access")
    try expect(supportPage.contains("Tapping a low-quota alert opens the attention-only dashboard list"), "support page should document notification tap routing")
    try expect(supportPage.contains("Background App Refresh"), "support page should document background refresh expectations")
    try expect(supportPage.contains("bundled model metadata and runtime badges"), "support page should document demo model detail coverage")
    try expect(supportPage.contains("PRIVACY_POLICY.md"), "support page should link the privacy policy source")
    try expect(privacyPolicy.contains("does not collect analytics"), "privacy policy should state no analytics collection")
    try expect(privacyPolicy.contains("iOS Keychain"), "privacy policy should document Keychain storage")
    try expect(privacyPolicy.contains("UserDefaults"), "privacy policy should document UserDefaults storage")
    try expect(privacyPolicy.contains("does not register for remote push notifications"), "privacy policy should document no remote push")
    try expect(privacyPolicy.contains("Background App Refresh"), "privacy policy should document background refresh behavior")
    try expect(privacyPolicy.contains("attention-only dashboard view"), "privacy policy should document notification tap routing")
    try expect(privacyPolicy.contains("clear the saved connection"), "privacy policy should document local data deletion")
    try expect(privacyPolicy.contains("support diagnostics report"), "privacy policy should document diagnostics copy")
    try expect(privacyPolicy.contains("generation time"), "privacy policy should document diagnostics timestamps")
    try expect(privacyPolicy.contains("does not include the management key value"), "privacy policy should document no-key diagnostics")
    try expect(privacyPolicy.contains("Background App Refresh status"), "privacy policy should document background refresh diagnostics")
    try expect(privacyPolicy.contains("notification authorization") && privacyPolicy.contains("badge availability"), "privacy policy should document notification diagnostics")
    try expect(privacyPolicy.contains("dashboard server hosts, dashboard account identifiers, project IDs, API base URLs"), "privacy policy should document dashboard privacy-sensitive fields")
    let readme = try fileText("README.md")
    try expect(readme.contains("Preview the finished dashboard"), "README should mention preview mode")
    try expect(readme.contains("reopen the demo from Settings"), "README should document Settings demo access")
    try expect(readme.contains("APP_STORE_METADATA.md"), "README should reference App Store metadata copy")
    try expect(readme.contains("SUPPORT.md") && readme.contains("PRIVACY_POLICY.md"), "README should reference support and privacy policy sources")
    try expect(readme.contains("Codex, Claude, Antigravity, Kimi, Grok"), "README should document demo provider coverage")
    try expect(readme.contains("Demo account detail includes bundled model metadata"), "README should document demo model detail coverage")
    try expect(readme.contains("App/PrivacyInfo.xcprivacy"), "README should mention privacy manifest")
    try expect(readme.contains("Apply account detail refresh results back to the dashboard"), "README should document detail refresh propagation")
    try expect(readme.contains("Sort attention lists and local alert candidates with that same threshold"), "README should document shared attention sorting threshold")
    try expect(readme.contains("low-quota local notification is tapped"), "README should document notification tap routing")
    try expect(readme.contains("Show backend refresh schedule and Codex subscription dates"), "README should document account detail refresh schedule and subscription dates")
    try expect(readme.contains("slow quota providers do not block model status visibility"), "README should document independent detail quota/model loading")
    try expect(readme.contains("Mark available models with runtime status badges"), "README should document model runtime status badges")
    try expect(readme.contains("Show provider-level 5h/7d averages"), "README should document provider section quota summaries")
    try expect(readme.contains("reset filters when switching to a different server or management key"), "README should document monitoring-target filter reset")
    try expect(readme.contains("Sort API key usage by failure count and failure rate"), "README should document API key failure-first sorting")
    try expect(readme.contains("Show API key recent request activity with compact sparklines"), "README should document API key recent request sparklines")
    try expect(readme.contains("privacy-sensitive"), "README should document sensitive UI redaction hints")
    try expect(readme.contains("server hosts, dashboard account identifiers, project IDs, API base URLs"), "README should document dashboard privacy-sensitive fields")
    try expect(readme.contains("without including the management key"), "README should document no-key support diagnostics")
    try expect(readme.contains("records the generation time"), "README should document diagnostics timestamps")
    try expect(readme.contains("notification authorization, alert presentation, badge availability"), "README should document notification diagnostics")
    try expect(readme.contains("Show CLIProxyAPI version, short commit, and build date"), "README should document dashboard server build metadata")
    try expect(readme.contains("Show the next foreground auto-refresh time"), "README should document next refresh timing")
    try expect(readme.contains("localized connection and network errors"), "README should document localized network errors")
    try expect(readme.contains("copied management API URL"), "README should document management API URL normalization")
    try expect(readme.contains("Scripts/validate_local.sh"), "README should document the one-command local validation script")
    try expect(readme.contains("Scripts/validate_xcode_release.sh"), "README should document the full Xcode release validation script")
    try expect(readme.contains("`swift test` is not part of the local gate"), "README should document why swift test is not a local gate")
    try expect(readme.contains("bash -n Scripts/validate_local.sh Scripts/validate_xcode_release.sh"), "README should document shell script syntax validation")
    let validationScript = try fileText("Scripts/validate_local.sh")
    try expect(validationScript.contains("swift run CPAKitValidation"), "local validation script should run CPAKitValidation")
    try expect(validationScript.contains("bash -n Scripts/validate_local.sh Scripts/validate_xcode_release.sh"), "local validation script should syntax-check shell scripts")
    try expect(validationScript.contains("git diff --check"), "local validation script should check whitespace errors")
    try expect(validationScript.contains("CPA_VALIDATE_XCODE"), "local validation script should expose an opt-in Xcode gate")
    try expect(validationScript.contains("find App/Assets.xcassets -name Contents.json"), "local validation script should validate every asset catalog manifest")
    try expect(validationScript.contains("xcodebuild -project CPA-IOS.xcodeproj"), "local validation script should include the Xcode simulator gate")
    let scriptPermissions = try filePermissions("Scripts/validate_local.sh")
    try expect(scriptPermissions & 0o111 != 0, "local validation script should be executable")
    let xcodeValidationScript = try fileText("Scripts/validate_xcode_release.sh")
    try expect(xcodeValidationScript.contains("Scripts/validate_local.sh"), "Xcode validation script should run local validation first")
    try expect(xcodeValidationScript.contains("iphonesimulator"), "Xcode validation script should verify simulator SDK availability")
    try expect(xcodeValidationScript.contains("iphoneos"), "Xcode validation script should verify iPhoneOS SDK availability")
    try expect(xcodeValidationScript.contains("-destination \"$SIMULATOR_DESTINATION\""), "Xcode validation script should build the configured simulator destination")
    try expect(xcodeValidationScript.contains("-configuration Release"), "Xcode validation script should archive the Release configuration")
    try expect(xcodeValidationScript.contains("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"), "Xcode validation script should allow signing-team overrides")
    try expect(xcodeValidationScript.contains("require_signing_team_for_archive"), "Xcode validation script should fail early when archive signing is not configured")
    try expect(xcodeValidationScript.contains("CPA_SKIP_ARCHIVE=1"), "Xcode validation script should allow simulator-only validation")
    try expect(xcodeValidationScript.contains("CPA_ALLOW_PROVISIONING_UPDATES"), "Xcode validation script should expose optional provisioning updates")
    try expect(xcodeValidationScript.contains("rm -rf \"$ARCHIVE_PATH\""), "Xcode validation script should remove stale archive output before archiving")
    try expect(xcodeValidationScript.contains("test -d \"$ARCHIVE_PATH\""), "Xcode validation script should verify archive output exists")
    try expect(readme.contains("requires a signing team before creating the Release archive"), "README should document release script signing preflight")
    try expect(readme.contains("CPA_ALLOW_PROVISIONING_UPDATES=1"), "README should document optional provisioning updates")
    try expect(submissionNotes.contains("requires a signing team for archive creation"), "submission notes should document release script signing preflight")
    try expect(submissionNotes.contains("verifies the Release `.xcarchive` directory was created"), "submission notes should document archive output verification")
    try expect(xcodeValidationScript.contains("CPA_PRODUCT_BUNDLE_IDENTIFIER"), "Xcode validation script should allow bundle identifier overrides")
    let xcodeScriptPermissions = try filePermissions("Scripts/validate_xcode_release.sh")
    try expect(xcodeScriptPermissions & 0o111 != 0, "Xcode validation script should be executable")
    let rootSource = try fileText("App/RootView.swift")
    try expect(rootSource.contains("if showsPreview"), "root view should allow demo mode even after a saved connection exists")
    try expect(rootSource.contains("onShowPreview: { showsPreview = true }"), "root view should let the live dashboard open demo mode")
    try expect(rootSource.contains("@EnvironmentObject private var notificationRouter"), "root view should observe durable notification routing state")
    try expect(rootSource.contains("notificationRouter.attentionFocusRequestID"), "root view should forward notification attention focus requests")
    try expect(rootSource.contains("notificationRouter.$attentionFocusRequestID"), "root view should exit demo when a notification attention request arrives")
    try expect(rootSource.contains("private var canConnect"), "connection setup should gate empty submit attempts")
    try expect(rootSource.contains(".disabled(!canConnect)"), "connection button should be disabled until required fields are present")
    try expect(rootSource.contains("isSensitive: true") && rootSource.contains(".privacySensitive(isSensitive)"), "connection setup should mark server URL and management key inputs privacy-sensitive")
    try expect(rootSource.contains("displayErrorMessage(error.localizedDescription, limit: 180)"), "connection errors should be compact on small screens")
    let projectFile = try fileText("CPA-IOS.xcodeproj/project.pbxproj")
    try expect(projectFile.contains("CPAUsageParser.swift in Sources"), "Xcode project should compile CPAUsageParser.swift")
    try expect(projectFile.contains("QuotaAlertNotifier.swift in Sources"), "Xcode project should compile QuotaAlertNotifier.swift")
    try expect(projectFile.contains("BackgroundQuotaRefreshScheduler.swift in Sources"), "Xcode project should compile background refresh scheduler")
    try expect(projectFile.contains("PrivacyInfo.xcprivacy in Resources"), "Xcode project should bundle PrivacyInfo.xcprivacy")
    try expect(projectFile.contains("SWIFT_VERSION = 6.0"), "Xcode project should use Swift 6")
    let appIconManifest = try fileText("App/Assets.xcassets/AppIcon.appiconset/Contents.json")
    try expect(appIconManifest.contains("\"idiom\" : \"ios-marketing\""), "app icon should include an iOS marketing image")
    try expect(appIconManifest.contains("\"idiom\" : \"iphone\""), "app icon should include iPhone slots")
    try expect(appIconManifest.contains("\"idiom\" : \"ipad\""), "app icon should include iPad slots")
    try expect(appIconManifest.contains("AppIcon-iPhone-60@3x.png"), "app icon should include the iPhone 180px slot")
    try expect(appIconManifest.contains("AppIcon-iPad-83_5@2x.png"), "app icon should include the iPad Pro slot")
    try validateAppIcons()
    let infoPlist = try fileText("App/Info.plist")
    try validateLaunchScreenAssets(infoPlist: infoPlist, readme: readme, submissionNotes: submissionNotes)
    try expect(infoPlist.contains("<key>ITSAppUsesNonExemptEncryption</key>") && infoPlist.contains("<false/>"), "Info.plist should declare platform-only encryption export status")
    try expect(infoPlist.contains("<key>NSAppTransportSecurity</key>"), "Info.plist should declare App Transport Security settings")
    try expect(infoPlist.contains("<key>NSAllowsLocalNetworking</key>") && infoPlist.contains("<true/>"), "Info.plist should allow local-network CLIProxyAPI endpoints")
    try expect(infoPlist.contains("<key>NSLocalNetworkUsageDescription</key>"), "Info.plist should explain local network access")
    try expect(infoPlist.contains("CLIProxyAPI"), "local network usage text should name the self-hosted server purpose")
    try expect(infoPlist.contains("<key>BGTaskSchedulerPermittedIdentifiers</key>"), "Info.plist should declare permitted background task identifiers")
    try expect(infoPlist.contains("com.rootclaw.CPAPanel.quota-refresh"), "Info.plist should permit the quota refresh background task")
    try expect(infoPlist.contains("<key>UIBackgroundModes</key>") && infoPlist.contains("<string>fetch</string>"), "Info.plist should declare Background App Refresh fetch mode")
    try expect(!infoPlist.contains("remote-notification"), "Info.plist should not declare remote notification background mode")
    try expect(!projectFile.contains("aps-environment"), "Xcode project should not declare remote push entitlements")
    let privacyManifest = try fileText("App/PrivacyInfo.xcprivacy")
    try expect(privacyManifest.contains("<key>NSPrivacyTracking</key>") && privacyManifest.contains("<false/>"), "privacy manifest should declare no tracking")
    try expect(privacyManifest.contains("<key>NSPrivacyCollectedDataTypes</key>") && privacyManifest.contains("<array/>"), "privacy manifest should declare no collected data types")
    try expect(privacyManifest.contains("NSPrivacyAccessedAPICategoryUserDefaults"), "privacy manifest should declare UserDefaults required-reason API access")
    try expect(privacyManifest.contains("<string>CA92.1</string>"), "privacy manifest should use the local UserDefaults required reason")
    let schemeFile = try fileText("CPA-IOS.xcodeproj/xcshareddata/xcschemes/CPA-IOS.xcscheme")
    try expect(schemeFile.contains("BuildableName = \"CPA-IOS.app\""), "Xcode scheme should build CPA-IOS.app")
    try expect(schemeFile.contains("BlueprintName = \"CPA-IOS\""), "Xcode scheme should reference the CPA-IOS target")
    let connectionStoreSource = try fileText("App/ConnectionStore.swift")
    try expect(connectionStoreSource.contains("enum ConnectionStorage"), "connection storage keys should be shared by foreground and background refresh paths")
    try expect(connectionStoreSource.contains("static func disableQuotaAlerts"), "connection storage should expose alert disablement for background permission loss")
    try expect(connectionStoreSource.contains("nonisolated static func loadSavedConnectionFromStorage()"), "background refresh should load the saved connection without creating UI state")
    try expect(!connectionStoreSource.contains("BackgroundQuotaRefreshScheduler.reschedule(for: connection)"), "connection store init should not submit background tasks before app delegate registration")
    try expect(connectionStoreSource.contains("BackgroundQuotaRefreshScheduler.reschedule(for: savedConnection)"), "saving or disabling alerts should reschedule background refresh state")
    try expect(connectionStoreSource.contains("BackgroundQuotaRefreshScheduler.cancel()"), "clearing or disabling alerts should cancel background refresh")
    try expect(connectionStoreSource.contains("SecItemUpdate"), "Keychain save should update existing items before adding")
    try expect(connectionStoreSource.contains("SecItemUpdate(query as CFDictionary, [\n            kSecValueData as String: data,\n            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"), "Keychain updates should migrate existing management keys for Background App Refresh access")
    try expect(connectionStoreSource.contains("addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"), "new management keys should be readable after first unlock for Background App Refresh")
    try expect(connectionStoreSource.contains("QuotaAlertNotifier.resetAlertHistory()"), "disabling alerts should clear local alert state")
    try expect(connectionStoreSource.contains("QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: connection?.quotaAlertsEnabled == true)"), "app launch should clear stale local badge state when alerts cannot run")
    try expect(connectionStoreSource.contains("QuotaAlertNotifier.clearBadgeIfNeeded(alertsEnabled: true)"), "foreground permission reconciliation should clear stale badges when only badge permission is disabled")
    try expect(connectionStoreSource.contains("func reconcileQuotaAlertAuthorization() async"), "connection store should reconcile revoked notification permission")
    try expect(connectionStoreSource.contains("QuotaAlertNotifier.canSendAlerts()"), "connection store should check current notification permission")
    try expect(connectionStoreSource.contains("disableQuotaAlertsAfterPermissionLoss"), "connection store should disable alerts after notification permission is lost")
    try expect(connectionStoreSource.contains("let hasExistingConnection = connection != nil"), "connection save should distinguish first setup from settings updates")
    try expect(connectionStoreSource.contains("quotaAlertsEnabled ?? (hasExistingConnection ? self.quotaAlertsEnabled : false)"), "first connection setup should not inherit stale low-quota alert defaults")
    try expect(connectionStoreSource.contains("quotaAlertShowsAccountNames ?? (hasExistingConnection ? self.quotaAlertShowsAccountNames : false)"), "first connection setup should not inherit stale detailed notification defaults")
    try expect(connectionStoreSource.contains("guard connection != nil else"), "connection store should clear alert defaults when no saved connection exists")
    try expect(connectionStoreSource.contains("let showAccountNames = alertsEnabled ? requestedShowAccountNames : false"), "disabling alerts should also disable detailed notification text")
    try expect(connectionStoreSource.contains("private func shouldResetAlertHistory"), "connection changes should reset local alert throttle")
    try expect(connectionStoreSource.contains("previousConnection.managementKey != newManagementKey"), "management key changes should reset local alert throttle")
    try expect(connectionStoreSource.contains("previousAlertSettings.threshold != newAlertThreshold"), "threshold changes should reset local alert throttle")
    let viewHelpersSource = try fileText("App/ViewHelpers.swift")
    try expect(viewHelpersSource.contains("return ProviderCatalog.info(for: provider).symbolName"), "provider badges should use catalog symbols instead of hard-coded provider switches")
    try expect(viewHelpersSource.contains("providerAccentColor(ProviderCatalog.info(for: provider).accentName)"), "provider badges should use catalog accent colors")
    try expect(viewHelpersSource.contains("case \"mint\":\n        return .mint"), "provider badges should render OpenAI-compatible catalog accents")
    try expect(viewHelpersSource.contains("return remaining > 0 ? displayDuration(seconds: remaining) : \"现在\""), "quota reset text should not show untranslated English")
    try expect(viewHelpersSource.contains("normalizedQuotaResetDetail(window.detailText)"), "quota reset text should normalize provider placeholder detail text")
    try expect(viewHelpersSource.contains("normalizedQuotaResetDetail(displayDuration(seconds: seconds))"), "quota reset text should normalize duration placeholder values")
    try expect(viewHelpersSource.contains("normalized != \"-\" && normalized != \"--\""), "quota reset text should ignore placeholder dash values")
    try expect(viewHelpersSource.contains("struct QuotaWindowMetadataLabels"), "quota metadata labels should use a shared responsive view")
    try expect(viewHelpersSource.contains("ViewThatFits(in: .horizontal)"), "quota metadata labels should adapt on narrow screens")
    let usageParserSource = try fileText("Sources/CPAKit/CPAUsageParser.swift")
    try expect(!usageParserSource.contains(": \"now\""), "usage parser should not surface untranslated reset text")
    try expect(usageParserSource.contains("displayKimiDuration(duration, unit: unit))限额"), "Kimi quota windows should use localized duration labels")
    try expect(usageParserSource.contains("displayDuration(seconds: seconds))后重置"), "quota reset hints should use localized Chinese countdown text")
    let clientSource = try fileText("Sources/CPAKit/CPAClient.swift")
    try expect(clientSource.contains("X-CPA-BUILD-DATE"), "client should read server build date headers")
    try expect(clientSource.contains("stableAccountIdentitySort(lhs, rhs)"), "client live quota sorting should have deterministic account identity tie-breaks")
    try expect(clientSource.contains("private static func transportError"), "client should localize transport errors")
    try expect(clientSource.contains("NSURLErrorCancelled"), "client should preserve cancellation errors")
    try expect(clientSource.contains("连接超时，请确认 CLIProxyAPI 服务可访问"), "client should show localized timeout guidance")
    try expect(clientSource.contains("public enum CPAURLSession"), "client should use an app-owned default URLSession")
    try expect(clientSource.contains("URLSessionConfiguration.ephemeral"), "default URLSession should not persist caches or cookies")
    try expect(clientSource.contains("httpCookieStorage = nil"), "default URLSession should disable persistent cookie storage")
    try expect(clientSource.contains("cachePolicy: .reloadIgnoringLocalCacheData"), "management requests should ignore local caches")
    try expect(clientSource.contains("Cache-Control"), "management requests should include explicit no-store cache headers")
    try expect(clientSource.contains("@MainActor\n    private static func decodeResponse"), "management response decoding should avoid cooperative-executor stack overflows")
    let apiErrorSource = try fileText("Sources/CPAKit/CPAAPIError.swift")
    try expect(apiErrorSource.contains("case transport(String)"), "API errors should include transport failures")
    try expect(apiErrorSource.contains("网络请求失败"), "transport errors should have localized descriptions")
    let modelsSource = try fileText("Sources/CPAKit/CPAModels.swift")
    try expect(modelsSource.contains("public var dashboardQuotaWindows"), "account quota should expose dashboard-prioritized quota windows")
    try expect(modelsSource.contains("var displayNameIsSensitive"), "account model should identify sensitive dashboard display names")
    try expect(modelsSource.contains("public static func demoModels(for account: CPAAccount)"), "demo dashboard should expose bundled account-detail model metadata")
    try expect(modelsSource.contains("CPAModelDefinition(id: \"claude-opus-4\""), "demo model metadata should include runtime-limited Claude sample")
    try expect(modelsSource.contains("quotaWindowAttentionSort"), "dashboard quota windows should prioritize exhausted and low quota rows")
    try expect(modelsSource.contains("hiddenDashboardQuotaWindowCount"), "account quota should expose hidden dashboard quota count")
    try expect(modelsSource.contains("lastRefreshedAt = \"last_refreshed_at\""), "auth decoder should accept SDK-style last_refreshed_at timestamps")
    try expect(modelsSource.contains("lastRefreshedAtCamel = \"lastRefreshedAt\""), "auth decoder should accept camel refresh timestamps")
    try expect(modelsSource.contains("projectIDUpperCamel = \"projectID\""), "auth decoder should accept upper-camel projectID")
    try expect(modelsSource.contains("case webSockets"), "auth decoder should accept camel webSockets")
    try expect(!modelsSource.contains("ISO8601DateFormatter"), "date parsing should avoid formatter construction crashes in CLT async validation")
    try expect(modelsSource.contains("decodeFlexibleStringIfPresent(forKey: .time)"), "recent request buckets should decode numeric times safely")
    try expect(modelsSource.contains("chatgptSubscriptionActiveUntil"), "id token claims should accept camel subscription dates")
    try expect(modelsSource.contains("firstNonEmptyString(provider, type)"), "provider name should ignore blank provider values and fall back to type")
    try expect(modelsSource.contains("if let lastError, !lastError.message.isEmpty"), "auth decoder should surface account-level last_error as an error state")
    try expect(modelsSource.contains("serverBuildDate"), "dashboard model should store server build dates")
    try expect(modelsSource.contains("private func quotaByID()"), "dashboard should merge previous live quota without duplicate-ID crashes")
    try expect(modelsSource.contains("quotaByAccountKey"), "dashboard should preserve live quota by auth identity before falling back to IDs")
    try expect(modelsSource.contains("duplicateKeys"), "dashboard should not preserve quota by non-unique account keys")
    try expect(modelsSource.contains("private static func accountKey(for account: CPAAccount)"), "dashboard should use a stable account key for replacement")
    try expect(modelsSource.contains("canReplaceByID"), "dashboard should only fall back to IDs when auth identity does not conflict")
    try expect(modelsSource.contains("return self"), "dashboard should ignore stale per-account refresh results")
    try expect(!modelsSource.contains("values.append(quota)"), "dashboard should not append stale per-account refresh results")
    try expect(!modelsSource.contains("Dictionary(uniqueKeysWithValues: previous.accountQuotas"), "dashboard should not use duplicate-sensitive dictionary construction")
    try expect(modelsSource.contains("activeModelIssueLine"), "model-level runtime issues should drive account row status text")
    try expect(modelsSource.contains("hasActiveModelError"), "model-level runtime errors should promote account status")
    try expect(modelsSource.contains("modelStatusIndicatesError"), "account rows should classify broad model error statuses")
    try expect(modelsSource.contains("\"exceeded\""), "account rows should classify standalone model exceeded statuses")
    try expect(modelsSource.contains("apiKeyUsageSort"), "api key usage records should have stable failure-first sorting")
    try expect(modelsSource.contains("lhs.failed > rhs.failed"), "api key usage sorting should put failing keys first")
    try expect(modelsSource.contains("let baseURL = parts.count > 1 ? String(parts[0]) : \"\""), "api key usage parser should not show bare keys as base URLs")
    try expect(modelsSource.contains("fileprivate let apiKey: String"), "API key usage records should not expose raw keys as public model state")
    try expect(modelsSource.contains("stableAPIKeyUsageID"), "API key usage row identity should use a stable redacted identifier")
    try expect(modelsSource.contains("stableHash(rawIdentity)"), "API key usage row identity should hash raw key material")
    try expect(modelsSource.contains("return \"\\(totalMinutes)分钟\""), "shared duration formatting should use Chinese minute labels")
    let accountDetailSource = try fileText("App/AccountDetailView.swift")
    try expect(accountDetailSource.contains("accessibilityLabel(\"刷新详情\")"), "account detail should expose a manual refresh button")
    try expect(accountDetailSource.contains("var initialModels: [CPAModelDefinition]"), "account detail should accept bundled demo model metadata")
    try expect(accountDetailSource.contains("models = initialModels"), "account detail should seed models before live refresh")
    try expect(accountDetailSource.contains("async let liveQuotaRefresh"), "account detail should refresh live quota without blocking model metadata")
    try expect(accountDetailSource.contains("async let modelRefresh"), "account detail should load model metadata without waiting for live quota")
    try expect(accountDetailSource.contains("@MainActor\n    private func refreshDetail() async"), "account detail refresh state changes should remain on the main actor")
    try expect(accountDetailSource.contains("同步于"), "account detail should show live quota sync time")
    try expect(accountDetailSource.contains("onQuotaUpdated?(updatedAccount)"), "account detail refresh should publish refreshed quota to the dashboard")
    try expect(accountDetailSource.contains(".task(id: detailRefreshKey)"), "account detail refresh should be keyed by stable auth identity")
    try expect(accountDetailSource.contains("struct AccountDetailRefreshKey"), "account detail should distinguish duplicate backend account IDs")
    try expect(accountDetailSource.contains("guard !Task.isCancelled else"), "account detail should ignore stale async refresh results")
    try expect(accountDetailSource.contains("displayErrorMessage(error.localizedDescription, limit: 160)"), "account detail model errors should stay compact")
    try expect(accountDetailSource.contains("模型状态"), "account detail should label model errors and cooldowns together")
    try expect(accountDetailSource.contains("item.state.lastError?.message"), "account detail should show model last_error messages")
    try expect(accountDetailSource.contains("没有模型限制"), "account detail empty model status text should include errors and cooldowns")
    try expect(accountDetailSource.contains("model.ownedBy"), "account detail should show model ownership metadata")
    try expect(accountDetailSource.contains("struct ModelListRow"), "account detail model list should use a dedicated responsive row")
    try expect(accountDetailSource.contains("struct ModelListRowModel"), "account detail model rows should merge model metadata with runtime state")
    try expect(accountDetailSource.contains("ModelRuntimeKind(state: state)"), "account detail model rows should classify runtime state")
    try expect(accountDetailSource.contains("modelRowSort"), "account detail model list should sort runtime issues first")
    try expect(accountDetailSource.contains("state.nextRetryAfter.map({ $0 > Date() })"), "account detail model status should treat future retry dates as limited")
    try expect(accountDetailSource.contains("status.contains(\"failure\")"), "account detail model badges should treat broad failure statuses as errors")
    try expect(accountDetailSource.contains("status.contains(\"exceeded\")"), "account detail model badges should treat standalone exceeded statuses as limited")
    try expect(accountDetailSource.contains("ModelRuntimeBadge(kind: row.runtimeKind)"), "account detail model rows should show runtime status badges")
    try expect(accountDetailSource.contains("struct ModelTypeBadge"), "account detail model type should use a compact badge")
    try expect(accountDetailSource.contains("ModelTypeBadge(type: typeText)"), "account detail model type badge should stack when narrow")
    try expect(accountDetailSource.contains("ViewThatFits(in: .horizontal)"), "account detail model rows should adapt on narrow screens")
    try expect(accountDetailSource.contains("Auth Index"), "account detail should expose auth_index for debugging")
    try expect(accountDetailSource.contains("ChatGPT Account ID"), "account detail should expose ChatGPT account IDs for debugging")
    try expect(accountDetailSource.contains("var isSensitive = false"), "account detail metadata rows should opt into privacy-sensitive values")
    try expect(accountDetailSource.contains(".privacySensitive(isSensitive)"), "account detail should mark sensitive metadata for system redaction")
    try expect(accountDetailSource.contains(".privacySensitive(account.account.displayNameIsSensitive)"), "account detail hero should mark sensitive display names privacy-sensitive")
    try expect(accountDetailSource.contains("Text(account.account.name)\n                        .font(.caption.weight(.medium))\n                        .foregroundStyle(.secondary)\n                        .lineLimit(1)\n                        .truncationMode(.middle)\n                        .privacySensitive()"), "account detail hero should mark account identifiers privacy-sensitive")
    try expect(accountDetailSource.contains("DetailRow(title: \"Auth Index\", value: authIndex, isSensitive: true)"), "account detail should mark auth indexes privacy-sensitive")
    try expect(accountDetailSource.contains("DetailRow(title: \"ChatGPT Account ID\", value: chatgptAccountID, isSensitive: true)"), "account detail should mark ChatGPT account IDs privacy-sensitive")
    try expect(accountDetailSource.contains("account.account.runtimeOnly"), "account detail should show runtime auth source")
    try expect(accountDetailSource.contains("account.account.websockets"), "account detail should show websocket routing mode")
    try expect(accountDetailSource.contains("account.account.nextRefreshAfter"), "account detail should show backend next refresh timing")
    try expect(accountDetailSource.contains("订阅开始"), "account detail should expose subscription start dates")
    try expect(accountDetailSource.contains("订阅到期"), "account detail should expose subscription expiration dates")
    try expect(accountDetailSource.contains("subscriptionActiveUntil"), "account detail should read Codex subscription expiry from ID token claims")
    try expect(accountDetailSource.contains("ForEach(Array(account.quotaWindows.enumerated()), id: \\.offset)"), "account detail quota rows should tolerate duplicate provider window IDs")
    try expect(accountDetailSource.contains("ModelListRowModel(index: index"), "account detail model rows should tolerate duplicate model IDs")
    try expect(accountDetailSource.contains("QuotaWindowMetadataLabels(window: window, font: .caption.weight(.medium))"), "account detail quota metadata should adapt on narrow screens")
    try expect(accountDetailSource.contains("Text(account.account.name)") && accountDetailSource.contains(".truncationMode(.middle)"), "account detail should middle-truncate long account filenames")
    try expect(accountDetailSource.contains(".accessibilityLabel(\"\\(title)，\\(value)\")"), "detail counters should expose compact accessibility labels")
    let dashboardSource = try fileText("App/DashboardView.swift")
    try validateStableAccountIdentitySource(modelsSource: modelsSource, dashboardSource: dashboardSource)
    try expect(dashboardSource.contains("isDemoMode ? ManagementDashboard.demoModels(for: account.account) : []"), "demo navigation should provide bundled account-detail model metadata")
    try expect(dashboardSource.contains("最低剩余"), "dashboard summary should show the lowest remaining quota")
    try expect(dashboardSource.contains("个需要关注"), "dashboard summary should show attention count")
    try expect(dashboardSource.contains("viewModel.showsAttentionOnly.toggle()"), "dashboard filters should expose attention-only mode")
    try expect(dashboardSource.contains("onShowAll: viewModel.showAttentionAccounts"), "attention section should jump to full attention list")
    try expect(dashboardSource.contains("查看全部"), "attention section should expose a show-all action")
    try expect(dashboardSource.contains("清空筛选"), "dashboard filters should expose clear filters action")
    try expect(dashboardSource.contains("liveUsageCompletedAt"), "dashboard header should show live quota sync completion time")
    try expect(dashboardSource.contains("实时额度 \\(liveUsageCompleted) / \\(liveUsageTotal)"), "dashboard header should show live quota sync completion count")
    try expect(dashboardSource.contains("沿用上次实时额度"), "dashboard header should avoid mixing previous sync time with current progress")
    try expect(dashboardSource.contains("serverBuildText"), "dashboard header should format server build metadata")
    try expect(dashboardSource.contains("snapshot?.serverCommit"), "dashboard header should include server commits when available")
    try expect(dashboardSource.contains("prefix(7)"), "dashboard header should keep commits compact")
    try expect(dashboardSource.contains("cleanBuildValue"), "dashboard header should hide empty server metadata placeholders")
    try expect(dashboardSource.contains("struct ServerMetadataSection"), "dashboard should expose server metadata beyond the compact header")
    try expect(dashboardSource.contains("snapshot.serverBuildDate"), "dashboard server metadata should show build dates when available")
    try expect(dashboardSource.contains("nextRefreshText"), "dashboard server metadata should show the next refresh timing")
    try expect(dashboardSource.contains("liveUsageCompletedAt ?? snapshot.fetchedAt"), "dashboard next refresh should use the latest live sync when available")
    try expect(dashboardSource.contains("normalized == \"unknown\" || normalized == \"none\""), "dashboard server metadata should hide placeholder build values")
    try expect(dashboardSource.contains("quotaResetText(window)"), "dashboard account rows should show quota reset timing")
    try expect(dashboardSource.contains("account.dashboardQuotaWindows"), "dashboard account rows should show prioritized quota windows")
    try expect(dashboardSource.contains("HiddenQuotaWindowCountView"), "dashboard account rows should indicate hidden quota windows")
    try expect(dashboardSource.contains("ForEach(Array(windows.enumerated()), id: \\.offset)"), "dashboard quota rows should tolerate duplicate provider window IDs")
    try expect(dashboardSource.contains("section.primaryAverage.map { \"5h \\(displayPercent($0))\" }"), "provider headers should show 5h quota averages")
    try expect(dashboardSource.contains("section.weeklyAverage.map { \"7d \\(displayPercent($0))\" }"), "provider headers should show 7d quota averages")
    try expect(dashboardSource.contains("section.lowestRemainingPercent.map { \"最低 \\(displayPercent($0))\" }"), "provider headers should show lowest remaining quota")
    try expect(viewHelpersSource.contains("Label(resetText, systemImage: \"clock\")"), "quota metadata should show reset timing with a clock label")
    try expect(dashboardSource.contains("QuotaWindowMetadataLabels(window: window, font: .caption2.weight(.medium))"), "dashboard quota metadata should adapt on narrow screens")
    try expect(dashboardSource.contains("Text(projectID)") && dashboardSource.contains(".truncationMode(.middle)"), "dashboard account rows should middle-truncate long project IDs")
    try expect(dashboardSource.contains(".privacySensitive(account.account.displayNameIsSensitive)"), "dashboard account rows should mark sensitive display names privacy-sensitive")
    try expect(dashboardSource.contains("Text(connection.baseURL.host ?? connection.baseURL.absoluteString)") && dashboardSource.contains(".privacySensitive()"), "dashboard header should mark server host privacy-sensitive")
    try expect(dashboardSource.contains("Text(projectID)") && dashboardSource.contains(".privacySensitive()"), "dashboard account rows should mark project IDs privacy-sensitive")
    try expect(dashboardSource.contains(".privacySensitive(!record.baseURL.isEmpty)"), "API key rows should mark provider base URLs privacy-sensitive")
    try expect(dashboardSource.contains("if !account.account.recentRequests.isEmpty"), "account rows should only show activity charts when data exists")
    try expect(dashboardSource.contains("ViewThatFits(in: .horizontal)"), "API key usage rows should stack on narrow screens")
    try expect(dashboardSource.contains(".fixedSize(horizontal: true, vertical: false)"), "dashboard status and provider labels should keep stable compact widths")
    try expect(dashboardSource.contains(".accessibilityLabel(\"\\(title)，\\(value)，\\(subtitle)\")"), "metric cards should expose compact accessibility labels")
    try expect(dashboardSource.contains(".accessibilityLabel(\"状态：\\(kind.title)\")"), "status pills should expose state accessibility labels")
    try expect(dashboardSource.contains(".accessibilityLabel(\"成功 \\(success)，失败 \\(failed)\")"), "request ratios should expose count accessibility labels")
    try expect(dashboardSource.contains(".accessibilityValue(isSelected ? \"已选择\" : \"未选择\")"), "filter chips should expose selected state to accessibility")
    try expect(dashboardSource.contains(".accessibilityHint(\"查看账号详情\")"), "account rows should expose navigation hints")
    try expect(dashboardSource.contains("\"API Key \\(record.maskedAPIKey)\""), "API key rows should expose masked accessibility summaries")
    try expect(dashboardSource.contains(".accessibilityHidden(true)"), "decorative sparklines should be hidden from accessibility")
    try expect(dashboardSource.contains("onQuotaUpdated: viewModel.applyAccountQuota"), "dashboard should receive account-detail live quota refreshes")
    try expect(dashboardSource.contains("onQuotaUpdated: onQuotaUpdated"), "account provider sections should forward detail refresh callbacks")
    try expect(dashboardSource.contains(".disabled(viewModel.isBusy)"), "dashboard manual refresh should wait while any refresh work is running")
    try expect(dashboardSource.contains(".task(id: autoRefreshKey)"), "dashboard auto-refresh should be keyed by connection and active scene state")
    try expect(dashboardSource.contains(".task(id: attentionFocusRequestID)"), "dashboard should respond to notification attention requests")
    try expect(dashboardSource.contains("viewModel.showAttentionAccounts()"), "dashboard should show attention-only list after notification taps")
    try expect(dashboardSource.contains("guard previewSnapshot == nil, scenePhase == .active"), "dashboard auto-refresh should only run for active real connections")
    try expect(dashboardSource.contains("} else if !viewModel.isBusy {"), "pull-to-refresh should not restart a running live quota sync")
    try expect(dashboardSource.contains("await connectionStore.reconcileQuotaAlertAuthorization()"), "dashboard should reconcile revoked notification permission when returning foreground")
    try expect(
        dashboardSource.contains(".sheet(isPresented: $showsSettings)") &&
            dashboardSource.contains("}\n        .onDisappear {\n            viewModel.cancelRefresh()"),
        "dashboard should cancel refresh only when the enclosing navigation stack disappears"
    )
    let dashboardViewModelSource = try fileText("App/DashboardViewModel.swift")
    try expect(dashboardViewModelSource.contains("lowestRemainingPercent = accounts.compactMap"), "dashboard summary should compute the lowest remaining quota")
    try expect(dashboardViewModelSource.contains("attentionCount = accounts.filter"), "dashboard summary should compute attention count")
    try expect(dashboardViewModelSource.contains("attentionThreshold = connection.quotaAlertThreshold"), "dashboard attention should use the saved attention threshold")
    try expect(dashboardViewModelSource.contains("quota.needsQuotaAlert(threshold: attentionThreshold)"), "attention filtering should not use a hard-coded quota threshold")
    try expect(dashboardViewModelSource.contains("attentionRank(lhs, threshold: attentionThreshold)"), "attention sorting should use the saved attention threshold")
    try expect(dashboardViewModelSource.contains("lowest <= threshold"), "attention rank should compare low quota against the saved threshold")
    try expect(dashboardViewModelSource.contains("private func accountListRank"), "dashboard account lists should use attention-aware sorting")
    try expect(dashboardViewModelSource.contains("let lhsRank = accountListRank(lhs)"), "dashboard account list sorting should rank attention accounts first")
    try expect(dashboardViewModelSource.contains("case let (.some(left), .some(right)) where left != right:\n            return left < right"), "dashboard account list sorting should put lower remaining quota first")
    try expect(dashboardViewModelSource.contains("stableAccountIdentitySort(lhs.account, rhs.account)"), "dashboard account sorting should use deterministic account identity tie-breaks")
    try expect(dashboardViewModelSource.contains("DashboardSummary(accounts: accountQuotas, attentionThreshold: attentionThreshold)"), "dashboard summary should use the saved attention threshold")
    try expect(dashboardViewModelSource.contains("matchesAttention"), "dashboard filtering should include attention-only mode")
    try validateAPIKeyUsageDashboardSource(
        dashboardSource: dashboardSource,
        dashboardViewModelSource: dashboardViewModelSource,
        readme: readme
    )
    try expect(dashboardViewModelSource.contains("account.chatgptAccountID"), "dashboard search should include ChatGPT account IDs")
    try expect(dashboardViewModelSource.contains("account.name.lowercased()"), "dashboard search should include auth file names")
    try expect(dashboardViewModelSource.contains("providerKey.contains(query)"), "dashboard search should include canonical provider keys")
    try expect(dashboardViewModelSource.contains("providerInfo.displayName.lowercased()"), "dashboard search should include provider display names")
    try expect(dashboardViewModelSource.contains("account.authIndex"), "dashboard search should include auth indexes")
    try expect(dashboardViewModelSource.contains("account.accountType"), "dashboard search should include account types")
    try expect(dashboardViewModelSource.contains("account.source"), "dashboard search should include auth sources")
    try expect(dashboardViewModelSource.contains("account.note"), "dashboard search should include auth notes")
    try expect(dashboardViewModelSource.contains("quota.effectivePlanType"), "dashboard search should include effective plan types")
    try expect(dashboardViewModelSource.contains("quota.statusKind == .error"), "provider section should count runtime and backend errors")
    try expect(dashboardViewModelSource.contains("liveUsageCompletedAt = Date()"), "dashboard view model should record live quota sync completion time")
    try expect(dashboardViewModelSource.contains("liveUsageTotal = targets.count"), "dashboard live quota progress should reset for each target set")
    try expect(dashboardViewModelSource.contains("guard !targets.isEmpty else {\n            if generation == refreshGeneration {\n                liveUsageCompletedAt = nil"), "dashboard live quota progress should clear stale sync time when no usage targets remain")
    try expect(dashboardViewModelSource.contains("clearIncompleteLiveUsageTimestamp()"), "dashboard should clear completed-sync timestamps after canceling an incomplete live quota sync")
    try expect(dashboardViewModelSource.contains("liveUsageTotal > 0 && liveUsageCompleted < liveUsageTotal"), "dashboard should detect incomplete live quota syncs before keeping completion timestamps")
    try expect(dashboardViewModelSource.contains("liveUsageCompleted = dashboard.accountQuotas"), "preview dashboard should initialize live quota sync count")
    try expect(dashboardViewModelSource.contains("liveUsageTotal = dashboard.accountQuotas"), "preview dashboard should initialize live quota sync total")
    try expect(dashboardViewModelSource.contains("previousSnapshot"), "dashboard refresh should preserve previous live quota while syncing")
    try expect(dashboardViewModelSource.contains("preservingLiveUsage"), "dashboard refresh should merge previous live quota into base snapshot")
    try expect(dashboardViewModelSource.contains("snapshot = nil"), "dashboard refresh should clear stale snapshots for a new connection")
    try expect(dashboardViewModelSource.contains("private func isSameMonitoringTarget"), "dashboard should distinguish server/key changes from refresh setting changes")
    try expect(dashboardViewModelSource.contains("activeConnection.baseURL == connection.baseURL"), "dashboard should keep live quota when only non-target settings change")
    try expect(dashboardViewModelSource.contains("if !isSameTarget {\n            clearFilters()"), "dashboard should reset filters when switching monitoring targets")
    try expect(dashboardViewModelSource.contains("displayErrorMessage(error.localizedDescription, limit: 180)"), "dashboard refresh errors should be compact")
    try expect(dashboardViewModelSource.contains("刷新失败，继续显示上次数据"), "dashboard refresh errors should clarify when stale data remains visible")
    try expect(dashboardViewModelSource.contains("func applyAccountQuota(_ quota: AccountQuota)"), "dashboard view model should apply per-account refreshed quota")
    try expect(dashboardViewModelSource.contains("func showAttentionAccounts()"), "dashboard view model should support attention-only jump")
    try expect(dashboardViewModelSource.contains("func clearFilters()"), "dashboard view model should support clearing filters")
    let settingsSource = try fileText("App/SettingsView.swift")
    try expect(settingsSource.contains("var onPreview: (() -> Void)?"), "settings should accept a demo action callback")
    try expect(settingsSource.contains("if let onPreview"), "settings should show demo action only when the dashboard provides one")
    try expect(settingsSource.contains("Label(\"查看演示面板\", systemImage: \"rectangle.on.rectangle\")"), "settings should expose demo mode after connection setup")
    try expect(settingsSource.contains("低额度提醒"), "settings should expose local quota alerts")
    try expect(settingsSource.contains("showsHTTPWarning"), "settings should warn before saving a local HTTP connection")
    try expect(settingsSource.contains("当前连接使用 HTTP，请只在可信网络中使用。"), "settings HTTP warning should match setup guidance")
    try expect(settingsSource.contains("关注阈值"), "settings should expose the dashboard attention threshold")
    try expect(settingsSource.contains("title: \"通知权限\""), "settings should show notification delivery status")
    try expect(settingsSource.contains("通知显示账号名称"), "settings should make account-name notification text opt-in")
    try expect(settingsSource.contains("title: \"后台刷新\""), "settings should show Background App Refresh status with low-quota alerts")
    try expect(settingsSource.contains("backgroundRefreshStatusText"), "settings should render localized Background App Refresh status")
    try expect(settingsSource.contains("backgroundRefreshWarningText"), "settings should warn when Background App Refresh is denied or restricted")
    try expect(settingsSource.contains("@MainActor\n    private var backgroundRefreshStatusText"), "settings should read UIApplication background refresh state on the main actor")
    try expect(settingsSource.contains("@MainActor\n    private var backgroundRefreshStatusDiagnosticsText"), "settings diagnostics should read UIApplication background refresh state on the main actor")
    try expect(settingsSource.contains("@MainActor\n    private var backgroundRefreshWarningText"), "settings background refresh warning should read UIApplication state on the main actor")
    try expect(settingsSource.contains("openAppSettings()"), "settings should offer an app settings shortcut for background refresh recovery")
    try expect(settingsSource.contains("打开通知设置"), "settings should offer recovery for denied notification permission")
    try expect(settingsSource.contains("UIApplication.openNotificationSettingsURLString"), "settings should deep-link to iOS notification settings when available")
    try expect(settingsSource.contains("UIApplication.openSettingsURLString"), "settings should deep-link to iOS notification settings")
    try expect(settingsSource.contains("@MainActor\n    private func openAppSettings()"), "settings app-settings shortcut should run on the main actor")
    try expect(settingsSource.contains("@MainActor\n    private func openSystemNotificationSettings()"), "settings notification-settings shortcut should run on the main actor")
    try expect(settingsSource.contains("struct SettingsValueRow"), "settings should use a responsive value row for compact form controls")
    try expect(settingsSource.contains("SettingsValueRow("), "settings steppers should use the responsive value row")
    try expect(settingsSource.contains("ViewThatFits(in: .horizontal)"), "settings value rows should stack on narrow screens")
    try expect(settingsSource.contains(".accessibilityLabel(\"\\(title)，\\(value)\")"), "settings value rows should expose compact accessibility labels")
    try expect(settingsSource.contains("confirmationDialog(\"清除连接？\""), "settings should confirm before clearing saved credentials")
    try expect(settingsSource.contains("Keychain 管理密钥"), "clear-connection confirmation should mention the saved management key")
    try expect(settingsSource.contains("TextField(\"服务器\", text: $baseURL)") && settingsSource.contains(".privacySensitive()\n                    SecureField"), "settings should mark server URL input privacy-sensitive")
    try expect(settingsSource.contains(".textContentType(.password)") && settingsSource.contains(".privacySensitive()"), "settings should mark management key input privacy-sensitive")
    try expect(settingsSource.contains("private var canSave"), "settings should gate empty save attempts")
    try expect(settingsSource.contains(".disabled(!canSave)"), "settings save button should be disabled until required fields are present")
    try expect(settingsSource.contains("displayErrorMessage(error.localizedDescription, limit: 180)"), "settings errors should be compact on small screens")
    try expect(settingsSource.contains("savedAlertsEnabled = false"), "settings should save core settings even if notification permission is denied")
    try expect(settingsSource.contains("do {\n                    let authorized = try await QuotaAlertNotifier.requestAuthorization()"), "settings should isolate notification authorization failures from connection saving")
    try expect(settingsSource.contains("quotaAlertsEnabled = false"), "settings should turn off local alerts when notification permission is denied")
    try expect(settingsSource.contains("managementKey = \"\""), "settings should clear the transient management key field after a verified save")
    try expect(settingsSource.contains("复制诊断信息"), "settings should expose support diagnostics copy")
    try expect(settingsSource.contains("await copyDiagnostics()"), "settings diagnostics copy should refresh asynchronous capability state")
    try expect(settingsSource.contains("UIPasteboard.general.string = diagnostics"), "settings should copy diagnostics to the iOS pasteboard")
    try expect(settingsSource.contains("Management Key Included: no"), "settings diagnostics should explicitly omit management key values")
    try expect(settingsSource.contains("Generated At: \\(diagnosticsTimestamp())"), "settings diagnostics should include a generation timestamp")
    try expect(settingsSource.contains("ISO8601DateFormatter().string(from: Date())"), "settings diagnostics timestamp should use ISO-8601")
    try expect(settingsSource.contains("Stored Management Key Present"), "settings diagnostics should only report whether a saved key exists")
    try expect(settingsSource.contains("Background Refresh Status: \\(backgroundRefreshStatusDiagnosticsText)"), "settings diagnostics should include Background App Refresh status")
    try expect(settingsSource.contains("notificationCapabilitySummary?.diagnosticsLines"), "settings diagnostics should include notification capability lines")
    try expect(settingsSource.contains("refreshNotificationCapabilitySummary()"), "settings should refresh notification diagnostics")
    try expect(settingsSource.contains("await refreshNotificationCapabilitySummary()\n        let diagnostics = supportDiagnostics()"), "settings should refresh notification diagnostics immediately before copying")
    try expect(settingsSource.contains("components.password = nil"), "settings diagnostics should remove URL credentials")
    try expect(settingsSource.contains("连接和刷新设置已保存"), "settings should tell the user that non-notification settings were saved")
    try expect(settingsSource.contains("通知设置暂不可用，低额度提醒已关闭"), "settings should save core settings when notification authorization throws")
    try expect(settingsSource.contains("通知权限不可用，低额度提醒已关闭"), "settings should explain when revoked notification permission disables alerts")
    try expect(settingsSource.contains("loadStoredSettings()"), "settings should reload saved values after permission reconciliation")
    try expect(settingsSource.contains("notificationPermissionDenied ? .orange : .red"), "settings should distinguish notification warnings from connection errors")
    try expect(settingsSource.contains("} else {\n                notificationPermissionDenied = false"), "settings should not misclassify save failures as notification warnings")
    try expect(settingsSource.contains("if notificationPermissionDenied {\n                isChecking = false\n                return"), "settings should keep the sheet open after saving without notification permission")
    let notifierSource = try fileText("App/QuotaAlertNotifier.swift")
    try expect(notifierSource.contains("UNUserNotificationCenter"), "quota alerts should use local notifications")
    try expect(notifierSource.contains("requestAuthorization"), "quota alerts should request notification permission")
    try expect(notifierSource.contains("static func canSendAlerts() async"), "quota alerts should expose current notification availability")
    try expect(notifierSource.contains("static func currentCapabilitySummary() async"), "quota alerts should expose notification capability diagnostics")
    try expect(notifierSource.contains("struct NotificationCapabilitySummary"), "quota alerts should model notification diagnostic status")
    try expect(notifierSource.contains("authorizationStatusText"), "quota alerts should summarize notification authorization state")
    try expect(notifierSource.contains("Notification Alerts Available"), "quota alert diagnostics should include local alert availability")
    try expect(notifierSource.contains("Notification Badge Available"), "quota alert diagnostics should include badge availability")
    try expect(notifierSource.contains(".badge"), "quota alerts should request badge permission")
    try expect(notifierSource.contains("showsAccountNames"), "quota alerts should support private notification text")
    try expect(notifierSource.contains("privateAlertBody"), "quota alerts should hide account names by default")
    try expect(notifierSource.contains("content.subtitle = showsAccountNames ? source : \"本地提醒\""), "quota alerts should hide server names by default")
    try expect(notifierSource.contains("struct NotificationCapabilities"), "quota alerts should track notification and badge capabilities separately")
    try expect(notifierSource.contains("settings.badgeSetting == .enabled"), "quota alerts should respect the per-app badge setting")
    try expect(notifierSource.contains("if capabilities.canUpdateBadge {\n            await updateBadgeCount(candidates.count)"), "quota alerts should update app badge only when badge permission is enabled")
    try expect(notifierSource.contains("} else {\n            await updateBadgeCount(0)\n        }\n\n        let fingerprint"), "quota alerts should clear stale badges while keeping alerts available when only badge permission is disabled")
    try expect(notifierSource.contains("content.badge = capabilities.canUpdateBadge ? NSNumber(value: candidates.count) : nil"), "quota alerts should omit notification badge payloads when badge permission is disabled")
    try expect(notifierSource.contains(".sorted { alertSort($0, $1, threshold: threshold) }"), "quota alerts should sort candidates with the configured threshold")
    try expect(notifierSource.contains("alertRank(lhs, threshold: threshold)"), "quota alert rank should use the configured threshold")
    try expect(
        notifierSource.contains("guard capabilities.canSendNotification else {\n            forgetRememberedAlert()\n            await clearBadgeAndNotifications()"),
        "quota alerts should clear badge when notification permission is unavailable"
    )
    try expect(notifierSource.contains("removePendingNotificationRequests"), "quota alerts should remove pending local notifications when clearing")
    try expect(notifierSource.contains("removeDeliveredNotifications"), "quota alerts should remove delivered local notifications when clearing")
    try expect(notifierSource.contains("static func clearBadgeIfNeeded(alertsEnabled: Bool)"), "quota alerts should expose startup stale-badge cleanup")
    try expect(notifierSource.contains("setBadgeCount(max(0, count))"), "quota alerts should clear local badge count")
    try expect(notifierSource.contains("catch {\n            forgetRememberedAlert()\n            await clearBadgeAndNotifications()"), "quota alerts should clear badge if local notification scheduling fails")
    try expect(notifierSource.contains("forgetRememberedAlert()"), "quota alerts should reset duplicate throttle after candidates clear or notifications fail")
    try expect(notifierSource.contains("private static func forgetRememberedAlert()"), "quota alerts should expose an internal alert-throttle reset helper")
    try expect(notifierSource.contains("stableHash"), "quota alert fingerprint should not store raw account text")
    try expect(notifierSource.contains("static let notificationIdentifier"), "quota alert notification identifier should be available for tap routing")
    try expect(notifierSource.contains("private static func alertIdentity(for account: AccountQuota)"), "quota alert fingerprint should use stable account identity")
    try expect(notifierSource.contains("account.account.authIndex ?? \"\""), "quota alert fingerprint should distinguish duplicate backend account IDs")
    try expect(notifierSource.contains("stableAccountIdentitySort(lhs.account, rhs.account)"), "quota alert sorting should use deterministic account identity tie-breaks")
    let appSource = try fileText("App/CPA_IOSApp.swift")
    try expect(appSource.contains("UNUserNotificationCenter.current().delegate"), "app should present foreground local notifications")
    try expect(appSource.contains("BackgroundQuotaRefreshScheduler.register()"), "app should register the Background App Refresh task at launch")
    try expect(appSource.contains("BackgroundQuotaRefreshScheduler.reschedule(for: ConnectionStore.loadSavedConnectionFromStorage())"), "app launch should reschedule background refresh after registration")
    try expect(appSource.contains("didReceive response: UNNotificationResponse"), "app should handle local notification taps")
    try expect(appSource.contains("final class NotificationRouter"), "app should use durable notification routing state")
    try expect(appSource.contains("@StateObject private var notificationRouter = NotificationRouter.shared"), "app should keep notification routing alive before SwiftUI views render")
    try expect(appSource.contains("NotificationRouter.shared.requestAttentionFocus()"), "app should route quota notification taps to the dashboard")
    try expect(appSource.contains(".banner"), "foreground notifications should use banner presentation on iOS")
    try expect(!appSource.contains("registerForRemoteNotifications"), "app should not register for remote notifications")
    let backgroundRefreshSource = try fileText("App/BackgroundQuotaRefreshScheduler.swift")
    try expect(backgroundRefreshSource.contains("import BackgroundTasks"), "background refresh scheduler should use BackgroundTasks")
    try expect(backgroundRefreshSource.contains("@MainActor"), "background refresh scheduler should run task registration and completion from the main actor")
    try expect(backgroundRefreshSource.contains("BGTaskScheduler.shared.register"), "background refresh scheduler should register a task handler")
    try expect(backgroundRefreshSource.contains("using: DispatchQueue.main"), "background refresh launch handler should run on the main queue")
    try expect(backgroundRefreshSource.contains("BGAppRefreshTaskRequest"), "background refresh scheduler should submit app refresh requests")
    try expect(backgroundRefreshSource.contains("connection.quotaAlertsEnabled"), "background refresh should run only when low-quota alerts are enabled")
    try expect(backgroundRefreshSource.contains("ConnectionStorage.disableQuotaAlerts()"), "background refresh should disable local alerts when notification permission is unavailable")
    try expect(backgroundRefreshSource.contains("cancel()\n        guard let connection"), "background refresh should replace existing pending task requests when rescheduling")
    try expect(backgroundRefreshSource.contains("fetchDashboard(includeLiveUsage: true)"), "background refresh should sync live quota before alerting")
    try expect(backgroundRefreshSource.contains("QuotaAlertNotifier.notifyIfNeeded"), "background refresh should generate the same local low-quota alerts")
    try expect(backgroundRefreshSource.contains("cancel(taskRequestWithIdentifier:"), "background refresh should be cancellable when alerts are disabled")
    try expect(backgroundRefreshSource.contains("maximumRefreshInterval"), "background refresh should bound scheduled refresh intervals")
    try expect(readme.contains("local notifications"), "README should document local notifications")
    try expect(readme.contains("first connection setup does not inherit stale alert defaults"), "README should document first-connection alert defaults")
    try expect(readme.contains("quota reset timing directly in account rows"), "README should document dashboard reset timing")
    try expect(readme.contains("Search by account name, provider key or display name"), "README should document expanded dashboard search")
    try expect(readme.contains("account-level backend `last_error`"), "README should document account-level backend error surfacing")
    try expect(readme.contains("Mask API keys in the API key usage section"), "README should document API key masking")
    try expect(readme.contains("stable hashed row identifiers"), "README should document redacted API key row identities")
    try expect(readme.contains("configurable attention threshold"), "README should document the shared attention threshold")
    try expect(readme.contains("hide account names and server names by default"), "README should document private notification text")
    try expect(readme.contains("Turning low-quota alerts off also turns detailed notification text off"), "README should document detailed notification reset")
    try expect(readme.contains("local app icon badge"), "README should document local badge behavior")
    try expect(readme.contains("app badge setting is enabled"), "README should document per-app badge setting behavior")
    try expect(readme.contains("badge counts are cleared and omitted"), "README should document badge-only permission behavior")
    try expect(readme.contains("notification permission is unavailable"), "README should document badge clearing when notification permission is unavailable")
    try expect(readme.contains("turns low-quota alerts off the next time"), "README should document alert disabling after permission revocation")
    try expect(readme.contains("no saved connection is active"), "README should document badge clearing when no connection is active")
    try expect(readme.contains("keeps the verified connection and refresh settings"), "README should document save behavior when notification permission is denied")
    try expect(readme.contains("pending CPA alert notifications"), "README should document local alert cleanup")
    try expect(readme.contains("resets its local alert throttle"), "README should document alert throttle reset after recovery")
    try expect(readme.contains("server/key/alert settings change"), "README should document alert throttle reset after settings changes")
    try expect(readme.contains("localized Chinese timing text"), "README should document localized quota timing text")
    try expect(readme.contains("notification settings page when available"), "README should document direct notification settings recovery")
    try expect(readme.contains("Background App Refresh"), "README should document background refresh behavior")
    try expect(readme.contains("Background App Refresh status for support"), "README should document background refresh diagnostics")
    try expect(readme.contains("ephemeral URLSession"), "README should document non-persistent network sessions")
    try expect(readme.contains("no persistent URL cache or cookie storage"), "README should document disabled network cache and cookie storage")
    try expect(submissionNotes.contains("remote push notifications"), "submission notes should document no remote push notifications")
    try expect(submissionNotes.contains("does not run continuous background monitoring"), "submission notes should document background refresh limits")
    try expect(submissionNotes.contains("stable hashed row identifiers"), "submission notes should document redacted API key row identities")
    try expect(submissionNotes.contains("first connection setup keeps alerts off"), "submission notes should document first-connection alert defaults")
    try expect(submissionNotes.contains("hides account and server identifiers by default"), "submission notes should document notification privacy")
    try expect(submissionNotes.contains("turning low-quota alerts off also turns detailed notification text off"), "submission notes should document detailed notification reset")
    try expect(submissionNotes.contains("app icon badge"), "submission notes should document local badge behavior")
    try expect(submissionNotes.contains("app badge setting is enabled"), "submission notes should document per-app badge setting behavior")
    try expect(submissionNotes.contains("local alerts remain available but badge counts are cleared and omitted"), "submission notes should document badge-only permission behavior")
    try expect(submissionNotes.contains("alerts are disabled on the next app launch, foreground resume, or Settings open"), "submission notes should document alert disabling when notification permission is unavailable")
    try expect(submissionNotes.contains("verified connection and refresh settings remain saved"), "submission notes should document save behavior when notification permission is denied")
    try expect(submissionNotes.contains("Notification recovery"), "submission notes should document notification settings recovery")
    try expect(submissionNotes.contains("badge plus pending CPA alert notifications clear"), "submission notes should document local alert cleanup smoke test")
    try expect(submissionNotes.contains("resets that throttle after all attention candidates clear"), "submission notes should document alert throttle reset after recovery")
    try expect(submissionNotes.contains("saved server/key/alert settings change"), "submission notes should document alert throttle reset after settings changes")
    try expect(submissionNotes.contains("Reviewer Smoke Test"), "submission notes should include reviewer smoke test")
    try expect(submissionNotes.contains("本地提醒"), "submission notes should document private notification subtitle")
    try validateNotificationAlertSettingSource(
        settingsSource: settingsSource,
        notifierSource: notifierSource,
        readme: readme,
        submissionNotes: submissionNotes
    )

    try await validateDashboardClient(apiKeyUsageJSON: apiKeyUsageJSON)

    let whamEnvelope = """
    {
      "status_code": 200,
      "body": "{\\"plan_type\\":\\"plus\\",\\"rate_limit\\":{\\"primary_window\\":{\\"used_percent\\":40,\\"limit_window_seconds\\":18000},\\"secondary_window\\":{\\"used_percent\\":75,\\"limit_window_seconds\\":604800}}}"
    }
    """.data(using: .utf8)!
    let liveSession = QueueSession(payloads: [whamEnvelope])
    let liveClient = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"), managementKey: "secret", session: liveSession)
    let liveQuota = await liveClient.fetchAccountQuota(for: flexibleAccount)
    try expect(liveQuota.errorMessage == nil, "live quota fetch returned error: \(liveQuota.errorMessage ?? "")")
    try expect(liveQuota.primaryRemainingPercent == 60, "live quota primary remaining failed")
    let liveRequest = try require(liveSession.requests.first, "live quota request missing")
    try expect(liveRequest.httpMethod == "POST", "live quota should use POST")
    try expect(liveRequest.url?.absoluteString == "https://proxy.example.com/v0/management/api-call", "live quota URL failed")
    let liveBodyData = try require(liveRequest.httpBody, "live quota body missing")
    let liveBody = try require(
        JSONSerialization.jsonObject(with: liveBodyData) as? [String: Any],
        "live quota body did not decode"
    )
    let liveHeaders = try require(liveBody["header"] as? [String: String], "live quota headers missing")
    try expect(liveBody["auth_index"] as? String == "456", "live quota auth_index failed")
    try expect(liveBody["url"] as? String == "https://chatgpt.com/backend-api/wham/usage", "live quota upstream URL failed")
    try expect(liveHeaders["ChatGPT-Account-Id"] == "acct-top-level", "live quota ChatGPT account header failed")

    let antigravityAuthJSON = """
    {
      "files": [
        {
          "id": "ag-live",
          "auth_index": "ag-index",
          "name": "antigravity.json",
          "provider": "antigravity",
          "status": "active"
        }
      ]
    }
    """.data(using: .utf8)!
    let antigravityAuth = try JSONDecoder().decode(AuthFilesResponse.self, from: antigravityAuthJSON)
    let antigravityAccount = try require(antigravityAuth.files.first, "antigravity auth sample did not decode")
    let antigravityEnvelope = """
    {
      "status_code": 200,
      "body": {
        "models": {
          "claude-sonnet-4-6": {
            "displayName": "Claude Sonnet 4.6",
            "quotaInfo": {
              "remainingFraction": 0.4
            }
          }
        }
      }
    }
    """.data(using: .utf8)!
    let antigravitySession = QueueSession(payloads: [
        Data(#"{"project_id":"project-from-auth-file"}"#.utf8),
        antigravityEnvelope
    ])
    let antigravityClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: antigravitySession
    )
    let antigravityQuota = await antigravityClient.fetchAccountQuota(for: antigravityAccount)
    try expect(antigravityQuota.errorMessage == nil, "antigravity live quota returned error: \(antigravityQuota.errorMessage ?? "")")
    try expect(antigravityQuota.lowestRemainingPercent == 40, "antigravity live quota remaining failed")
    try expect(
        antigravitySession.requests.first?.url?.absoluteString == "https://proxy.example.com/v0/management/auth-files/download?name=antigravity.json",
        "antigravity project fallback should download the auth file"
    )
    let antigravityRequest = try require(antigravitySession.requests.dropFirst().first, "antigravity api-call request missing")
    let antigravityBodyData = try require(antigravityRequest.httpBody, "antigravity api-call body missing")
    let antigravityBody = try require(
        JSONSerialization.jsonObject(with: antigravityBodyData) as? [String: Any],
        "antigravity api-call body did not decode"
    )
    try expect(antigravityBody["auth_index"] as? String == "ag-index", "antigravity api-call auth_index failed")
    try expect((antigravityBody["data"] as? String)?.contains("project-from-auth-file") == true, "antigravity api-call should use project_id from downloaded auth file")

    let objectBodyEnvelope = """
    {
      "status_code": 200,
      "body": {
        "plan_type": "plus",
        "rate_limit": {
          "primary_window": {
            "used_percent": 40,
            "limit_window_seconds": 18000
          }
        }
      }
    }
    """.data(using: .utf8)!
    let objectBodyClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: QueueSession(payloads: [objectBodyEnvelope])
    )
    let objectBodyQuota = await objectBodyClient.fetchAccountQuota(for: flexibleAccount)
    try expect(objectBodyQuota.errorMessage == nil, "object body live quota returned error: \(objectBodyQuota.errorMessage ?? "")")
    try expect(objectBodyQuota.primaryRemainingPercent == 60, "api-call object body should be parsed as live quota JSON")

    let emptySuccessEnvelope = #"{"status_code":200,"body":"{}"}"#.data(using: .utf8)!
    let emptySuccessClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: QueueSession(payloads: [emptySuccessEnvelope])
    )
    let emptySuccessQuota = await emptySuccessClient.fetchAccountQuota(for: flexibleAccount)
    try expect(emptySuccessQuota.errorMessage?.contains("empty quota response") == true, "empty 2xx live quota body should surface as a decoding error")
    try expect(emptySuccessQuota.errorMessage?.contains("HTTP 200") == false, "empty 2xx live quota body should not be reported as an HTTP 200 failure")

    let invalidEnvelope = #"{"body":"{}"}"#.data(using: .utf8)!
    let invalidSession = QueueSession(payloads: [invalidEnvelope])
    let invalidClient = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"), managementKey: "secret", session: invalidSession)
    let invalidQuota = await invalidClient.fetchAccountQuota(for: flexibleAccount)
    try expect(invalidQuota.errorMessage?.contains("status_code") == true, "missing status_code should be surfaced")

    let providerErrorEnvelope = """
    {
      "status_code": 502,
      "body": {
        "error": {
          "message": "provider unavailable",
          "code": "bad_gateway"
        }
      }
    }
    """.data(using: .utf8)!
    let providerErrorClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: QueueSession(payloads: [providerErrorEnvelope])
    )
    let providerErrorQuota = await providerErrorClient.fetchAccountQuota(for: flexibleAccount)
    try expect(providerErrorQuota.errorMessage?.contains("provider unavailable") == true, "api-call envelope errors should extract nested provider messages")
    try expect(providerErrorQuota.errorMessage?.contains("\"error\"") == false, "api-call envelope errors should not surface raw JSON")

    let nestedErrorSession = RouteSession(routes: [
        "/v0/management/auth-files": (
            502,
            Data(#"{"error":{"message":"upstream quota endpoint failed","code":"bad_gateway"}}"#.utf8)
        )
    ])
    let nestedErrorClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: nestedErrorSession
    )
    do {
        _ = try await nestedErrorClient.fetchDashboard(includeLiveUsage: false)
        throw ValidationError.failed("nested HTTP error should throw")
    } catch let error as CPAAPIError {
        try expect(error.localizedDescription.contains("upstream quota endpoint failed"), "nested HTTP error message should be extracted")
        try expect(!error.localizedDescription.contains("\"error\""), "nested HTTP error should not surface raw JSON")
    }

    let arrayErrorSession = RouteSession(routes: [
        "/v0/management/auth-files": (
            502,
            Data(#"{"errors":[{"message":"provider array failure","code":"bad_gateway"}]}"#.utf8)
        )
    ])
    let arrayErrorClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: arrayErrorSession
    )
    do {
        _ = try await arrayErrorClient.fetchDashboard(includeLiveUsage: false)
        throw ValidationError.failed("array HTTP error should throw")
    } catch let error as CPAAPIError {
        try expect(error.localizedDescription.contains("provider array failure"), "array HTTP error message should be extracted")
        try expect(!error.localizedDescription.contains("\"errors\""), "array HTTP error should not surface raw JSON")
    }

    let timeoutClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: ThrowingSession(error: URLError(.timedOut))
    )
    do {
        _ = try await timeoutClient.fetchDashboard(includeLiveUsage: false)
        throw ValidationError.failed("transport timeout should throw")
    } catch let error as CPAAPIError {
        try expect(error.localizedDescription.contains("网络请求失败"), "transport errors should be wrapped")
        try expect(error.localizedDescription.contains("连接超时"), "timeout errors should be localized")
    }

    let cancelClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: ThrowingSession(error: URLError(.cancelled))
    )
    do {
        _ = try await cancelClient.fetchDashboard(includeLiveUsage: false)
        throw ValidationError.failed("cancelled transport should throw")
    } catch let error as URLError {
        try expect(error.code == .cancelled, "cancelled URL errors should not be wrapped as display errors")
    } catch {
        throw ValidationError.failed("cancelled transport should stay a URL cancellation error, got \(error)")
    }

    let retryCancelSession = AlwaysTimeoutSession()
    let retryCancelClient = CPAClient(
        baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com"),
        managementKey: "secret",
        session: retryCancelSession
    )
    let retryCancelTask = Task {
        await retryCancelClient.fetchAccountQuota(for: flexibleAccount)
    }
    for _ in 0..<10 {
        if await retryCancelSession.requestCount > 0 {
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let retryCancelInitialCount = await retryCancelSession.requestCount
    try expect(retryCancelInitialCount == 1, "retry cancellation test did not start the first live quota request")
    retryCancelTask.cancel()
    _ = await retryCancelTask.value
    try await Task.sleep(nanoseconds: 800_000_000)
    let retryCancelFinalCount = await retryCancelSession.requestCount
    try expect(retryCancelFinalCount == 1, "cancelled live quota retry should not issue a second api-call request")

    let modelsPayload = #"{"models":[{"id":"model-a"}]}"#.data(using: .utf8)!
    let session = CapturingSession(payload: modelsPayload)
    let client = CPAClient(baseURL: try CPABaseURLNormalizer.normalize("https://proxy.example.com/cpa/management.html#/quota"), managementKey: "secret", session: session)
    _ = try await client.fetchModels(for: account)
    let modelURL = try require(session.lastRequest?.url?.absoluteString, "model request URL missing")
    try expect(
        modelURL == "https://proxy.example.com/cpa/v0/management/auth-files/models?name=gemini.json",
        "subpath model URL failed: \(modelURL)"
    )
}

do {
    try await runValidation()
    print("CPAKitValidation passed")
} catch {
    fputs("CPAKitValidation failed: \(error)\n", stderr)
    exit(1)
}
