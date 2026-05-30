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
        if scheme == "http", !isLocalHTTPHost(host) {
            throw CPAAPIError.insecureHTTPHost(host)
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
        var components = path
            .split(separator: "/")
            .map(String.init)
        if components.isEmpty {
            return ""
        }

        if components.last?.lowercased() == "management.html" {
            components.removeLast()
        }

        if let managementIndex = components.indices.first(where: { index in
            guard index + 1 < components.endIndex else {
                return false
            }
            return components[index].lowercased() == "v0" &&
                components[index + 1].lowercased() == "management"
        }) {
            components = Array(components[..<managementIndex])
        }

        return components.isEmpty ? "" : "/\(components.joined(separator: "/"))"
    }

    private static func defaultScheme(for value: String) -> String {
        if isLocalHTTPHost(hostCandidate(from: value)) {
            return "http"
        }
        return "https"
    }

    private static func isLocalHTTPHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "localhost" ||
            isLANHostname(lower) ||
            lower == "::1" ||
            isLocalIPv4Address(lower) ||
            isLocalIPv6Address(lower)
    }

    private static func isLANHostname(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains(":"),
              !value.allSatisfy(\.isNumber)
        else {
            return false
        }
        return !value.contains(".") ||
            value.hasSuffix(".local") ||
            value.hasSuffix(".lan") ||
            value.hasSuffix(".home.arpa")
    }

    private static func hostCandidate(from value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = candidate.range(of: "://") {
            candidate = String(candidate[schemeRange.upperBound...])
        }
        if let atIndex = candidate.lastIndex(of: "@") {
            candidate = String(candidate[candidate.index(after: atIndex)...])
        }
        if candidate.hasPrefix("["),
           let endIndex = candidate.firstIndex(of: "]") {
            return String(candidate[candidate.index(after: candidate.startIndex)..<endIndex])
        }
        if let endIndex = candidate.firstIndex(where: { "/?#".contains($0) }) {
            candidate = String(candidate[..<endIndex])
        }
        let colonCount = candidate.filter { $0 == ":" }.count
        if colonCount == 1, let portIndex = candidate.firstIndex(of: ":") {
            candidate = String(candidate[..<portIndex])
        }
        return candidate
    }

    private static func isLocalIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let number = Int(part),
                  (0...255).contains(number)
            else {
                return nil
            }
            return number
        }
        guard octets.count == 4 else {
            return false
        }
        return octets[0] == 10 ||
            octets[0] == 127 ||
            (octets[0] == 169 && octets[1] == 254) ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private static func isLocalIPv6Address(_ value: String) -> Bool {
        let trimmed = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: "%", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        guard trimmed.contains(":") else {
            return false
        }
        return trimmed == "::1" ||
            trimmed.hasPrefix("fe80:") ||
            trimmed.hasPrefix("fc") ||
            trimmed.hasPrefix("fd")
    }
}
