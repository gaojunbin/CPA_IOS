import Foundation
import Security

/// Generates a cryptographically random API key suitable for CLIProxyAPI's `api-keys` list.
/// Format: `<prefix>` + URL-safe base64 of `byteCount` random bytes (e.g. `sk-cpa-…`).
public func generateAPIKey(prefix: String = "sk-cpa-", byteCount: Int = 24) -> String {
    var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let data = status == errSecSuccess ? Data(bytes) : Data(UUID().uuidString.utf8)
    let token = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return prefix + token
}

public extension CPAClient {
    /// Returns the configured proxy API key list (`GET /v0/management/api-keys`).
    func fetchAPIKeys() async throws -> [String] {
        let (data, _) = try await dataRequest(path: "/v0/management/api-keys")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CPAAPIError.decoding("api-keys 响应不是 JSON 对象")
        }
        let raw = firstArray(object["api-keys"], object["api_keys"], object["apiKeys"]) ?? []
        return raw.compactMap { firstString($0) }
    }

    /// Appends an API key. The server's PATCH replaces `old` in place when found and
    /// appends `new` otherwise, so sending `old == new == key` adds the key idempotently.
    func addAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CPAAPIError.decoding("API 密钥不能为空")
        }
        let body = try JSONSerialization.data(withJSONObject: ["old": trimmed, "new": trimmed])
        _ = try await dataRequest(path: "/v0/management/api-keys", method: "PATCH", body: body)
    }

    /// Deletes an API key by exact value (`DELETE /v0/management/api-keys?value=…`).
    func deleteAPIKey(_ key: String) async throws {
        _ = try await dataRequest(
            path: "/v0/management/api-keys",
            method: "DELETE",
            queryItems: [URLQueryItem(name: "value", value: key)]
        )
    }
}
