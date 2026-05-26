import Foundation
import CPAKit

final class CapturingSession: CPAHTTPSession {
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

func runValidation() async throws {
    let panelURL = try CPABaseURLNormalizer.normalize("https://cpa.junbingao.com/management.html#/quota")
    try expect(panelURL.absoluteString == "https://cpa.junbingao.com", "panel URL normalization failed")

    let localhostURL = try CPABaseURLNormalizer.normalize("127.0.0.1:8317")
    try expect(localhostURL.absoluteString == "http://127.0.0.1:8317", "localhost URL normalization failed")

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
          "disabled": false,
          "unavailable": true,
          "success": 12,
          "failed": 3,
          "project_id": "project-a",
          "next_retry_after": "2026-05-26T05:10:00Z",
          "recent_requests": [
            {"time": "04:00-04:10", "success": 2, "failed": 1}
          ],
          "quota": {
            "exceeded": true,
            "reason": "quota exceeded",
            "next_recover_at": "2026-05-26T05:20:00Z",
            "backoff_level": 2
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
              "status": "error",
              "unavailable": true,
              "next_retry_after": "2026-05-26T05:15:00Z",
              "quota": {"exceeded": true}
            }
          }
        }
      ]
    }
    """.data(using: .utf8)!

    let authFiles = try JSONDecoder().decode(AuthFilesResponse.self, from: authFilesJSON)
    let account = try require(authFiles.files.first, "auth file sample did not decode")
    try expect(account.displayName == "team@example.com", "display name fallback failed")
    try expect(account.providerName == "gemini", "provider fallback failed")
    try expect(account.totalRequests == 15, "request total failed")
    try expect(account.statusKind == .cooling, "status kind failed")
    try expect(account.activeModelCooldowns.count == 1, "model cooldown parsing failed")
    try expect(account.projectID == "project-a", "project id parsing failed")
    try expect(account.antigravityCredits?.creditAmount == 25000, "credits parsing failed")

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
