import Foundation

public enum CPABaseURLNormalizer {
    public static func normalize(_ rawValue: String) throws -> URL {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw CPAAPIError.invalidBaseURL
        }

        if !candidate.contains("://") {
            candidate = "\(defaultScheme(for: candidate))://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty
        else {
            throw CPAAPIError.invalidBaseURL
        }

        guard scheme == "http" || scheme == "https" else {
            throw CPAAPIError.unsupportedScheme(scheme)
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        let normalizedPath = normalizePath(components.path)
        components.path = normalizedPath == "/" ? "" : normalizedPath

        guard let url = components.url else {
            throw CPAAPIError.invalidBaseURL
        }
        return url
    }

    private static func normalizePath(_ path: String) -> String {
        var path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return ""
        }

        if path.lowercased().hasSuffix("management.html") {
            path = String(path.dropLast("management.html".count))
        }
        if path.lowercased().hasPrefix("v0/management") {
            return ""
        }

        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? "" : "/\(path)"
    }

    private static func defaultScheme(for value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("localhost") ||
            lower.hasPrefix("127.") ||
            lower.hasPrefix("[::1]") ||
            lower.hasPrefix("10.") ||
            lower.hasPrefix("192.168.") ||
            isPrivate172Address(lower) {
            return "http"
        }
        return "https"
    }

    private static func isPrivate172Address(_ value: String) -> Bool {
        guard value.hasPrefix("172.") else {
            return false
        }
        let parts = value.split(separator: ".")
        guard parts.count > 1, let second = Int(parts[1]) else {
            return false
        }
        return (16...31).contains(second)
    }
}
