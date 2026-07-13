import Foundation

public struct ModelRouteDefinition: Identifiable, Equatable, Sendable {
    public let name: String
    public let alias: String
    public let prefix: String?
    public let source: String
    public let fork: Bool
    public let forceMapping: Bool
    private let explicitPublicModelID: String?

    public init(
        name: String,
        alias: String,
        prefix: String? = nil,
        source: String,
        fork: Bool = false,
        forceMapping: Bool = false,
        publicModelID: String? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prefix = firstNonEmptyString(prefix)
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fork = fork
        self.forceMapping = forceMapping
        explicitPublicModelID = firstNonEmptyString(publicModelID)
    }

    public var upstreamModelName: String { name }
    public var clientFacingAlias: String { alias }

    public var publicModelID: String {
        if let explicitPublicModelID {
            return explicitPublicModelID
        }
        guard let prefix else { return alias }
        return "\(prefix)/\(alias)"
    }

    public func resolvingPublicModelID(_ id: String) -> ModelRouteDefinition {
        ModelRouteDefinition(
            name: name,
            alias: alias,
            prefix: prefix,
            source: source,
            fork: fork,
            forceMapping: forceMapping,
            publicModelID: id
        )
    }

    public var id: String {
        [source, prefix ?? "", name, alias, publicModelID, fork ? "1" : "0", forceMapping ? "1" : "0"]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

public struct ProviderRoutingGroup: Identifiable, Equatable, Sendable {
    public let provider: ProviderInfo
    public let accountCount: Int
    public let advertisedModelCount: Int
    public let routes: [ModelRouteDefinition]
    public let excludedModels: [String]
    public let prefixes: [String]
    public let priorities: [Int]
    public let baseURLs: [String]
    public let proxyURLs: [String]
    public let notes: [String]
    public let officialAPIAccounts: Int

    public var id: String { provider.key }

    public init(
        provider: ProviderInfo,
        accountCount: Int,
        advertisedModelCount: Int,
        routes: [ModelRouteDefinition],
        excludedModels: [String],
        prefixes: [String],
        priorities: [Int],
        baseURLs: [String],
        proxyURLs: [String],
        notes: [String],
        officialAPIAccounts: Int
    ) {
        self.provider = provider
        self.accountCount = accountCount
        self.advertisedModelCount = advertisedModelCount
        self.routes = routes
        self.excludedModels = excludedModels
        self.prefixes = prefixes
        self.priorities = priorities
        self.baseURLs = baseURLs
        self.proxyURLs = proxyURLs
        self.notes = notes
        self.officialAPIAccounts = officialAPIAccounts
    }

    public var distinctClientModelCount: Int {
        Set(routes.map { $0.publicModelID.lowercased() }).count
    }
}

public struct ModelRoutingSnapshot: Equatable, Sendable {
    public let strategy: String
    public let forceModelPrefix: Bool
    public let providers: [ProviderRoutingGroup]
    public let failedSections: [String]
    public let fetchedAt: Date

    public init(
        strategy: String,
        forceModelPrefix: Bool,
        providers: [ProviderRoutingGroup],
        failedSections: [String] = [],
        fetchedAt: Date = Date()
    ) {
        self.strategy = strategy
        self.forceModelPrefix = forceModelPrefix
        self.providers = providers
        self.failedSections = failedSections
        self.fetchedAt = fetchedAt
    }

    public var routeCount: Int { providers.reduce(0) { $0 + $1.routes.count } }
    public var accountCount: Int { providers.reduce(0) { $0 + $1.accountCount } }
}

public enum ModelRoutingResolver {
    public static func expand(
        _ route: ModelRouteDefinition,
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        guard let prefix = firstNonEmptyString(route.prefix) else {
            return [route.resolvingPublicModelID(route.alias)]
        }

        let prefixedID = "\(prefix)/\(route.alias)"
        if forceModelPrefix {
            return [route.resolvingPublicModelID(prefixedID)]
        }
        return [
            route.resolvingPublicModelID(route.alias),
            route.resolvingPublicModelID(prefixedID)
        ]
    }

    public static func configRoutes(
        accounts: [ConfigChannelAccount],
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        deduplicated(accounts.flatMap { account in
            account.routes.flatMap { expand($0, forceModelPrefix: forceModelPrefix) }
        })
    }

    public static func oauthRoutes(
        entries: [OAuthModelAliasEntry],
        accounts: [CPAAccount],
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        oauthRoutes(
            globalEntries: entries,
            accounts: accounts,
            accountOverrides: [:],
            forceModelPrefix: forceModelPrefix
        )
    }

    public static func oauthRoutes(
        globalEntries: [OAuthModelAliasEntry],
        accounts: [CPAAccount],
        accountOverrides: [String: OAuthAccountRoutingOverride],
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        guard !accounts.isEmpty else {
            return deduplicated(globalEntries.flatMap {
                $0.routeDefinitions(prefix: nil, forceModelPrefix: forceModelPrefix)
            })
        }

        let routes = accounts.flatMap { account -> [ModelRouteDefinition] in
            let accountAliases = accountOverrides[account.id]?.aliases ?? []
            let effectiveAliases = mergedOAuthAliases(account: accountAliases, global: globalEntries)
            return effectiveAliases.flatMap { entry in
                entry.routeDefinitions(
                    prefix: effectivePrefix(for: account, accountOverrides: accountOverrides),
                    forceModelPrefix: forceModelPrefix
                )
            }
        }
        return deduplicated(routes)
    }

    public static func mergedExcludedModels(
        global: [String],
        accounts: [CPAAccount],
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> [String] {
        uniqueStrings(global + accounts.flatMap { accountOverrides[$0.id]?.excludedModels ?? [] })
    }

    public static func effectivePrefix(
        for account: CPAAccount,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> String? {
        firstNonEmptyString(accountOverrides[account.id]?.prefix, account.prefix)
    }

    public static func effectivePriority(
        for account: CPAAccount,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> Int? {
        accountOverrides[account.id]?.priority ?? account.priority
    }

    public static func effectiveUsingAPI(
        for account: CPAAccount,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> Bool? {
        accountOverrides[account.id]?.usingAPI ?? account.usingAPI
    }

    public static func effectiveProxyURL(
        for account: CPAAccount,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> String? {
        sanitizedEndpoint(accountOverrides[account.id]?.proxyURL ?? account.proxyURL)
    }

    public static func effectiveNote(
        for account: CPAAccount,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> String? {
        firstNonEmptyString(accountOverrides[account.id]?.note, account.note)
    }

    public static func sanitizedEndpoint(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let explicitScheme = trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        let schemeRelative = !explicitScheme && trimmed.hasPrefix("//")
        let candidate: String
        if explicitScheme {
            candidate = trimmed
        } else if schemeRelative {
            candidate = "https:\(trimmed)"
        } else {
            candidate = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let host = components.host,
              !host.isEmpty
        else {
            return "已配置（地址已隐藏）"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let sanitized = components.string else {
            return "已配置（地址已隐藏）"
        }
        if explicitScheme { return sanitized }
        if schemeRelative { return String(sanitized.dropFirst("https:".count)) }
        return String(sanitized.dropFirst("https://".count))
    }

    public static func deduplicated(_ routes: [ModelRouteDefinition]) -> [ModelRouteDefinition] {
        var seen = Set<String>()
        return routes.filter { route in
            seen.insert(semanticKey(route)).inserted
        }
    }

    private static func mergedOAuthAliases(
        account: [OAuthModelAliasEntry],
        global: [OAuthModelAliasEntry]
    ) -> [OAuthModelAliasEntry] {
        var seenAliases = Set<String>()
        return (account + global).filter { entry in
            let key = entry.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seenAliases.insert(key).inserted
        }
    }

    private static func semanticKey(_ route: ModelRouteDefinition) -> String {
        [
            route.publicModelID.lowercased(),
            route.upstreamModelName.lowercased(),
            route.fork ? "fork" : "replace",
            route.forceMapping ? "force" : "passthrough"
        ]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}
