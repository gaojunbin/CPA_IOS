import Foundation

public enum APIKeyChannelKind: String, CaseIterable, Sendable {
    case codex = "codex-api-key"
    case claude = "claude-api-key"
    case gemini = "gemini-api-key"
    case interactions = "interactions-api-key"
    case vertex = "vertex-api-key"

    var modelType: String {
        self == .codex ? "openai" : definitionsChannel
    }

    var modelOwner: String {
        switch self {
        case .codex: return "openai"
        case .claude: return "anthropic"
        case .gemini, .interactions, .vertex: return "google"
        }
    }

    public var managementPath: String { "/v0/management/\(rawValue)" }

    public var definitionsChannel: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini, .interactions: return "gemini"
        case .vertex: return "vertex"
        }
    }
}

public struct APIKeyChannelEntry: Equatable, Sendable {
    public let overrideModelIDs: [String]
    public let overrideRoutes: [ModelRouteDefinition]
    public let overrideModels: [CPAModelDefinition]
    public let excludedPatterns: [String]
    public let prefix: String?
    public let maskedKey: String?
    public let baseURL: String?
    public let priority: Int?
    public let proxyURL: String?

    public init(
        overrideModelIDs: [String],
        excludedPatterns: [String],
        prefix: String?,
        maskedKey: String? = nil,
        baseURL: String? = nil,
        overrideRoutes: [ModelRouteDefinition] = [],
        overrideModels: [CPAModelDefinition] = [],
        priority: Int? = nil,
        proxyURL: String? = nil
    ) {
        self.overrideModelIDs = overrideModelIDs
        self.overrideRoutes = overrideRoutes
        self.overrideModels = overrideModels
        self.excludedPatterns = excludedPatterns
        self.prefix = prefix
        self.maskedKey = maskedKey
        self.baseURL = baseURL
        self.priority = priority
        self.proxyURL = proxyURL
    }
}

public struct ConfigChannelAccount: Equatable, Sendable {
    public let account: CPAAccount
    public let models: [CPAModelDefinition]
    public let baseURL: String?
    public let routes: [ModelRouteDefinition]
    public let excludedPatterns: [String]

    public init(
        account: CPAAccount,
        models: [CPAModelDefinition],
        baseURL: String?,
        routes: [ModelRouteDefinition] = [],
        excludedPatterns: [String] = []
    ) {
        self.account = account
        self.models = models
        self.baseURL = baseURL
        self.routes = routes
        self.excludedPatterns = excludedPatterns
    }
}

public struct ConfigChannelFetch: Equatable, Sendable {
    public let accounts: [ConfigChannelAccount]
    public let failedSections: [String]

    public init(accounts: [ConfigChannelAccount], failedSections: [String]) {
        self.accounts = accounts
        self.failedSections = failedSections
    }
}

public struct OAuthModelAliasEntry: Identifiable, Equatable, Sendable {
    public let provider: String
    public let name: String
    public let alias: String
    public let fork: Bool
    public let forceMapping: Bool

    public init(
        provider: String,
        name: String,
        alias: String,
        fork: Bool = false,
        forceMapping: Bool = false
    ) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fork = fork
        self.forceMapping = forceMapping
    }

    public var id: String { routeDefinition().id }

    public func routeDefinition(prefix: String? = nil) -> ModelRouteDefinition {
        ModelRouteDefinition(
            name: name,
            alias: alias,
            prefix: prefix,
            source: provider,
            fork: fork,
            forceMapping: forceMapping
        )
    }

    public func routeDefinitions(
        prefix: String? = nil,
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        var canonical = [routeDefinition(prefix: prefix)]
        if fork, name.caseInsensitiveCompare(alias) != .orderedSame {
            canonical.append(
                ModelRouteDefinition(
                    name: name,
                    alias: name,
                    prefix: prefix,
                    source: provider,
                    fork: true
                )
            )
        }
        return canonical.flatMap {
            ModelRoutingResolver.expand($0, forceModelPrefix: forceModelPrefix)
        }
    }
}

public struct OAuthAccountRoutingOverride: Equatable, Sendable {
    public let aliases: [OAuthModelAliasEntry]
    public let excludedModels: [String]
    public let prefix: String?
    public let priority: Int?
    public let usingAPI: Bool?
    public let proxyURL: String?
    public let note: String?

    public init(
        aliases: [OAuthModelAliasEntry],
        excludedModels: [String],
        prefix: String? = nil,
        priority: Int? = nil,
        usingAPI: Bool? = nil,
        proxyURL: String? = nil,
        note: String? = nil
    ) {
        self.aliases = aliases
        self.excludedModels = excludedModels
        self.prefix = firstNonEmptyString(prefix)
        self.priority = priority
        self.usingAPI = usingAPI
        self.proxyURL = ModelRoutingResolver.sanitizedEndpoint(proxyURL)
        self.note = firstNonEmptyString(note)
    }
}

public enum OAuthAuthFileRoutingParser {
    public static func parse(data: Data, provider: String) -> OAuthAccountRoutingOverride? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawAliases = firstArray(root["model_aliases"], root["model-aliases"]) ?? []
        var aliases: [OAuthModelAliasEntry] = []
        var seenAliases = Set<String>()
        for raw in rawAliases {
            guard let item = raw as? [String: Any],
                  let name = firstString(item["name"]),
                  let alias = firstString(item["alias"]),
                  name.caseInsensitiveCompare(alias) != .orderedSame,
                  seenAliases.insert(alias.lowercased()).inserted
            else {
                continue
            }
            aliases.append(
                OAuthModelAliasEntry(
                    provider: provider,
                    name: name,
                    alias: alias,
                    fork: boolValue(item["fork"]) ?? false,
                    forceMapping: boolValue(
                        firstValue(item["force-mapping"], item["force_mapping"], item["forceMapping"])
                    ) ?? false
                )
            )
        }

        var excludedModels: [String] = []
        var seenExcluded = Set<String>()
        for raw in firstArray(root["excluded_models"], root["excluded-models"]) ?? [] {
            guard let value = firstString(raw), seenExcluded.insert(value.lowercased()).inserted else {
                continue
            }
            excludedModels.append(value)
        }

        return OAuthAccountRoutingOverride(
            aliases: aliases,
            excludedModels: excludedModels,
            prefix: firstString(root["prefix"]),
            priority: integerValue(root["priority"]),
            usingAPI: boolValue(firstValue(root["using_api"], root["using-api"], root["usingAPI"])),
            proxyURL: firstString(root["proxy_url"], root["proxy-url"], root["proxyURL"]),
            note: firstString(root["note"])
        )
    }
}

public enum OAuthModelRoutingParser {
    public static func aliases(root: [String: Any]) -> [String: [OAuthModelAliasEntry]] {
        guard let providers = firstDictionary(
            root["oauth-model-alias"],
            root["oauth_model_alias"],
            root["oauthModelAlias"]
        ) else {
            return [:]
        }

        var parsed: [String: [OAuthModelAliasEntry]] = [:]
        for (rawProvider, value) in providers {
            guard let provider = firstNonEmptyString(rawProvider), let items = value as? [Any] else {
                continue
            }
            let entries = items.compactMap { raw -> OAuthModelAliasEntry? in
                guard let item = raw as? [String: Any],
                      let name = firstString(item["name"]),
                      let alias = firstString(item["alias"])
                else {
                    return nil
                }
                return OAuthModelAliasEntry(
                    provider: provider,
                    name: name,
                    alias: alias,
                    fork: boolValue(item["fork"]) ?? false,
                    forceMapping: boolValue(
                        firstValue(item["force-mapping"], item["force_mapping"], item["forceMapping"])
                    ) ?? false
                )
            }
            if !entries.isEmpty {
                parsed[provider] = entries
            }
        }
        return parsed
    }

    public static func excludedModels(root: [String: Any]) -> [String: [String]] {
        guard let providers = firstDictionary(
            root["oauth-excluded-models"],
            root["oauth_excluded_models"],
            root["oauthExcludedModels"]
        ) else {
            return [:]
        }

        var parsed: [String: [String]] = [:]
        for (rawProvider, value) in providers {
            guard let provider = firstNonEmptyString(rawProvider), let items = value as? [Any] else {
                continue
            }
            let patterns = items.compactMap { firstString($0) }
            if !patterns.isEmpty {
                parsed[provider] = patterns
            }
        }
        return parsed
    }
}

public func isConfigChannelKey(_ providerKey: String) -> Bool {
    let normalized = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.hasSuffix("-api-key") ||
        normalized.hasPrefix("openai-compatible-") ||
        normalized == "openai-compatibility"
}

public func maskedSecret(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "••••" }
    if trimmed.count <= 4 {
        return "••••"
    }
    if trimmed.count <= 12 {
        return String(trimmed.prefix(2)) + "••••" + String(trimmed.suffix(2))
    }
    return String(trimmed.prefix(6)) + "••••••" + String(trimmed.suffix(4))
}

public enum ConfigChannelSynthesizer {
    public static func compatAccounts(root: [String: Any]) -> [ConfigChannelAccount] {
        let entries = firstArray(root["openai-compatibility"], root["openai_compatibility"]) ?? []
        var accounts: [ConfigChannelAccount] = []

        for (index, raw) in entries.enumerated() {
            guard let item = raw as? [String: Any], boolValue(item["disabled"]) != true else {
                continue
            }
            let name = firstString(item["name"]) ?? "openai-compatibility"
            let providerKey = compatProviderKey(name: name)
            let prefix = firstString(item["prefix"])
            let baseURL = firstString(item["base-url"], item["baseURL"], item["baseUrl"])
            let priority = integerValue(item["priority"])
            let excluded = (firstArray(item["excluded-models"], item["excludedModels"]) ?? [])
                .compactMap { firstString($0) }
            let routes = mappingRoutes(firstArray(item["models"]), prefix: prefix, source: providerKey)
                .filter { !matchesExcluded($0.alias, patterns: excluded) }
            let models = deduplicatedModelDefinitions(
                ConfiguredModelMetadata.definitions(
                    firstArray(item["models"]),
                    type: "openai-compatibility",
                    ownedBy: name,
                    useUpstreamName: false
                ).filter { !matchesExcluded($0.id, patterns: excluded) }.flatMap { model in
                    withPrefixVariants(model.id, prefix: prefix).map { model.withID($0) }
                }
            )

            let keyEntries = firstArray(item["api-key-entries"], item["apiKeyEntries"]) ?? []
            let credentials: [(maskedKey: String?, proxyURL: String?)] = keyEntries.isEmpty
                ? [(nil, nil)]
                : keyEntries.map { rawEntry in
                    guard let entry = rawEntry as? [String: Any] else { return (nil, nil) }
                    return (
                        firstString(entry["api-key"], entry["apiKey"]).map(maskedSecret),
                        firstString(entry["proxy-url"], entry["proxyURL"], entry["proxyUrl"])
                    )
                }

            for (keyIndex, credential) in credentials.enumerated() {
                let account = CPAAccount(
                    id: "\(providerKey)#\(index)-\(keyIndex)",
                    name: name,
                    type: providerKey,
                    provider: providerKey,
                    label: credential.maskedKey ?? name,
                    status: "active",
                    source: "config",
                    prefix: prefix,
                    proxyURL: credential.proxyURL,
                    priority: priority
                )
                accounts.append(
                    ConfigChannelAccount(
                        account: account,
                        models: models,
                        baseURL: baseURL,
                        routes: routes,
                        excludedPatterns: excluded
                    )
                )
            }
        }
        return accounts
    }

    public static func compatProviderKey(name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "openai-compatibility" || normalized.hasPrefix("openai-compatible-") {
            return normalized.isEmpty ? "openai-compatibility" : normalized
        }
        return "openai-compatible-\(normalized)"
    }

    public static func apiKeyEntries(
        kind: APIKeyChannelKind,
        root: [String: Any]
    ) -> [APIKeyChannelEntry] {
        (firstArray(root[kind.rawValue]) ?? []).compactMap { raw in
            guard let item = raw as? [String: Any] else { return nil }
            let excluded = (firstArray(item["excluded-models"], item["excludedModels"]) ?? [])
                .compactMap { firstString($0) }
            let prefix = firstString(item["prefix"])
            let routes = mappingRoutes(
                firstArray(item["models"]),
                prefix: prefix,
                source: kind.rawValue
            )
            return APIKeyChannelEntry(
                overrideModelIDs: deduplicatedIDs(routes.map(\.alias)),
                excludedPatterns: excluded,
                prefix: prefix,
                maskedKey: firstString(item["api-key"], item["apiKey"]).map(maskedSecret),
                baseURL: firstString(item["base-url"], item["baseURL"], item["baseUrl"]),
                overrideRoutes: routes,
                overrideModels: ConfiguredModelMetadata.definitions(
                    firstArray(item["models"]),
                    type: kind.modelType,
                    ownedBy: kind.modelOwner,
                    useUpstreamName: true
                ),
                priority: integerValue(item["priority"]),
                proxyURL: firstString(item["proxy-url"], item["proxyURL"], item["proxyUrl"])
            )
        }
    }

    public static func apiKeyAccounts(
        kind: APIKeyChannelKind,
        entries: [APIKeyChannelEntry],
        staticModels: [CPAModelDefinition]
    ) -> [ConfigChannelAccount] {
        entries.enumerated().map { index, entry in
            let hasOverrides = !entry.overrideRoutes.isEmpty || !entry.overrideModelIDs.isEmpty
            let routes: [ModelRouteDefinition]
            let baseModels: [CPAModelDefinition]
            if hasOverrides {
                let configuredRoutes = entry.overrideRoutes.isEmpty
                    ? entry.overrideModelIDs.map {
                        ModelRouteDefinition(name: $0, alias: $0, prefix: entry.prefix, source: kind.rawValue)
                    }
                    : entry.overrideRoutes
                routes = configuredRoutes.filter { !matchesExcluded($0.alias, patterns: entry.excludedPatterns) }
                let configuredModels = entry.overrideModels.isEmpty
                    ? deduplicatedIDs(configuredRoutes.map(\.alias)).map {
                        CPAModelDefinition(id: $0, ownedBy: kind.definitionsChannel)
                    }
                    : entry.overrideModels
                baseModels = configuredModels.filter { !matchesExcluded($0.id, patterns: entry.excludedPatterns) }
            } else {
                baseModels = staticModels.filter { !matchesExcluded($0.id, patterns: entry.excludedPatterns) }
                routes = baseModels.map {
                    ModelRouteDefinition(name: $0.id, alias: $0.id, prefix: entry.prefix, source: kind.rawValue)
                }
            }
            let models = deduplicatedModelDefinitions(baseModels.flatMap { model in
                withPrefixVariants(model.id, prefix: entry.prefix).map { model.withID($0) }
            })
            let account = CPAAccount(
                id: "\(kind.rawValue)#\(index)",
                name: kind.rawValue,
                type: kind.rawValue,
                provider: kind.rawValue,
                label: entry.maskedKey ?? kind.rawValue,
                status: "active",
                source: "config",
                prefix: entry.prefix,
                proxyURL: entry.proxyURL,
                priority: entry.priority
            )
            return ConfigChannelAccount(
                account: account,
                models: models,
                baseURL: entry.baseURL,
                routes: routes,
                excludedPatterns: entry.excludedPatterns
            )
        }
    }

    public static func failureResult(providerKey: String) -> AuthModelsResult {
        AuthModelsResult(
            account: CPAAccount(
                id: "\(providerKey)#error",
                name: providerKey,
                type: providerKey,
                provider: providerKey
            ),
            models: nil
        )
    }

    public static func matchesExcluded(_ modelID: String, patterns: [String]) -> Bool {
        let value = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return patterns.contains { rawPattern in
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !pattern.isEmpty && matchWildcard(pattern: pattern, value: value)
        }
    }

    private static func mappingRoutes(
        _ rawMappings: [Any]?,
        prefix: String?,
        source: String
    ) -> [ModelRouteDefinition] {
        (rawMappings ?? []).compactMap { raw in
            guard let item = raw as? [String: Any], let name = firstString(item["name"]) else {
                return nil
            }
            let alias = firstNonEmptyString(firstString(item["alias"]), name) ?? name
            return ModelRouteDefinition(
                name: name,
                alias: alias,
                prefix: prefix,
                source: source,
                fork: boolValue(item["fork"]) ?? false,
                forceMapping: boolValue(
                    firstValue(item["force-mapping"], item["force_mapping"], item["forceMapping"])
                ) ?? false
            )
        }
    }

    private static func deduplicatedIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private static func deduplicatedModelDefinitions(
        _ values: [CPAModelDefinition]
    ) -> [CPAModelDefinition] {
        var seen = Set<String>()
        return values.filter { model in
            let key = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private static func withPrefixVariants(_ id: String, prefix: String?) -> [String] {
        guard let prefix = firstNonEmptyString(prefix) else { return [id] }
        return [id, "\(prefix)/\(id)"]
    }

    private static func matchWildcard(pattern: String, value: String) -> Bool {
        if !pattern.contains("*") {
            return pattern == value
        }
        let parts = pattern.components(separatedBy: "*")
        var remaining = Substring(value)
        if let prefix = parts.first, !prefix.isEmpty {
            guard remaining.hasPrefix(prefix) else { return false }
            remaining = remaining.dropFirst(prefix.count)
        }
        if let suffix = parts.last, parts.count > 1, !suffix.isEmpty {
            guard remaining.hasSuffix(suffix) else { return false }
            remaining = remaining.dropLast(suffix.count)
        }
        for segment in parts.dropFirst().dropLast() where !segment.isEmpty {
            guard let range = remaining.range(of: segment) else { return false }
            remaining = remaining[range.upperBound...]
        }
        return true
    }
}
