import Foundation

public protocol CPAHTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CPAHTTPSession {}

public final class CPAClient {
    public let baseURL: URL
    private let managementKey: String
    private let session: CPAHTTPSession
    private let decoder: JSONDecoder

    public init(baseURL: URL, managementKey: String, session: CPAHTTPSession = URLSession.shared) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.session = session
        decoder = JSONDecoder()
    }

    public convenience init(baseURLString: String, managementKey: String, session: CPAHTTPSession = URLSession.shared) throws {
        let url = try CPABaseURLNormalizer.normalize(baseURLString)
        self.init(baseURL: url, managementKey: managementKey, session: session)
    }

    public func fetchDashboard() async throws -> ManagementDashboard {
        let authFilesResult: (AuthFilesResponse, HTTPURLResponse) = try await request(path: "/v0/management/auth-files")

        let apiKeyUsageResponse: [String: [String: APIKeyUsageEntry]]? = await optionalRequest(path: "/v0/management/api-key-usage")
        let switchProjectResponse: BooleanValueResponse? = await optionalRequest(path: "/v0/management/quota-exceeded/switch-project")
        let switchPreviewResponse: BooleanValueResponse? = await optionalRequest(path: "/v0/management/quota-exceeded/switch-preview-model")

        let apiKeyUsage = APIKeyUsageParser.flatten(apiKeyUsageResponse ?? [:])
        let switchProject = switchProjectResponse?.switchProject ?? switchProjectResponse?.value
        let switchPreview = switchPreviewResponse?.switchPreviewModel ?? switchPreviewResponse?.value

        return ManagementDashboard(
            accounts: authFilesResult.0.files,
            apiKeyUsage: apiKeyUsage,
            quotaSwitchProject: switchProject,
            quotaSwitchPreviewModel: switchPreview,
            serverVersion: authFilesResult.1.value(forHTTPHeaderField: "X-CPA-VERSION"),
            serverCommit: authFilesResult.1.value(forHTTPHeaderField: "X-CPA-COMMIT"),
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

    private func optionalRequest<T: Decodable>(path: String) async -> T? {
        do {
            let result: (T, HTTPURLResponse) = try await request(path: path)
            return result.0
        } catch {
            return nil
        }
    }

    private func request<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> (T, HTTPURLResponse) {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CPA-iOS/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
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
            return (try decoder.decode(T.self, from: data), httpResponse)
        } catch {
            throw CPAAPIError.decoding(error.localizedDescription)
        }
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
        if let envelope = try? JSONDecoder().decode(CPAErrorEnvelope.self, from: data) {
            return envelope.error ?? envelope.message
        }
        return String(data: data, encoding: .utf8)
    }
}
