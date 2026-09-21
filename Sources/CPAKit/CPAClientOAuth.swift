import Foundation

public extension CPAClient {
    func requestOAuthURL(for provider: OAuthProvider) async throws -> OAuthAuthURL {
        let (data, _) = try await dataRequest(path: provider.authPath)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String,
              let components = URLComponents(string: url), components.scheme == "https", components.host != nil,
              let state = object["state"] as? String, !state.isEmpty else {
            throw CPAAPIError.decoding("Invalid authorization URL or missing OAuth state")
        }
        return OAuthAuthURL(
            url: url, state: state, flow: object["flow"] as? String,
            userCode: object["user_code"] as? String, expiresIn: object["expires_in"] as? Int
        )
    }

    func submitOAuthCallback(provider: String, redirectURL: String, state: String) async throws {
        try validateOAuthCallback(redirectURL, state: state)
        let body = try JSONSerialization.data(withJSONObject: [
            "provider": provider, "redirect_url": redirectURL, "state": state
        ])
        _ = try await dataRequest(path: "/v0/management/oauth-callback", method: "POST", body: body)
    }

    func pollOAuthStatus(state: String) async throws -> OAuthStatus {
        let (data, _) = try await dataRequest(
            path: "/v0/management/get-auth-status", queryItems: [URLQueryItem(name: "state", value: state)]
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CPAAPIError.decoding("Invalid OAuth status response")
        }
        switch object["status"] as? String {
        case "ok": return .ok
        case "wait": return .wait
        case "error": return .error(object["error"] as? String ?? "授权失败")
        default: throw CPAAPIError.decoding("Unknown OAuth status")
        }
    }

    func cancelOAuthSession(state: String) async throws {
        guard !state.isEmpty else { return }
        _ = try await dataRequest(
            path: "/v0/management/oauth-session", method: "DELETE",
            queryItems: [URLQueryItem(name: "state", value: state)]
        )
    }
}
