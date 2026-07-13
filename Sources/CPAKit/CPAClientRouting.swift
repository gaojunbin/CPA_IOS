import Foundation

public extension CPAClient {
    func fetchModelPool() async throws -> ModelPoolSnapshot {
        async let configTask = fetchConfigChannelAccounts()
        async let forcePrefixTask = fetchForceModelPrefix()
        let accounts = try await fetchAuthFiles()
        return await buildModelPool(
            accounts: accounts,
            config: await configTask,
            forceModelPrefix: await forcePrefixTask
        )
    }

    func fetchModelRoutingSnapshot() async throws -> ModelRoutingSnapshot {
        async let accountsTask = fetchAuthFiles()
        async let configTask = fetchConfigChannelAccounts()
        async let aliasesTask = fetchOAuthAliases()
        async let excludedTask = fetchOAuthExcludedModels()
        async let strategyTask = fetchRoutingStrategy()
        async let forcePrefixTask = fetchForceModelPrefix()

        let accounts = try await accountsTask
        let config = await configTask
        let aliases = await aliasesTask
        let excluded = await excludedTask
        let strategy = await strategyTask
        let forceModelPrefix = await forcePrefixTask
        let routingAccounts = accounts.filter { !$0.disabled }

        async let overridesTask = fetchOAuthAccountRoutingOverrides(
            routingAccounts.filter { !$0.runtimeOnly }
        )
        async let modelPoolTask = buildModelPool(
            accounts: accounts,
            config: config,
            forceModelPrefix: forceModelPrefix
        )
        let accountOverrides = await overridesTask
        let modelPool = await modelPoolTask

        var allKeys = Set<String>()
        var accountsByKey: [String: [CPAAccount]] = [:]
        var configByKey: [String: [ConfigChannelAccount]] = [:]
        var routesByKey: [String: [ModelRouteDefinition]] = [:]
        var excludedByKey: [String: [String]] = [:]
        var advertisedByKey: [String: Int] = [:]
        var aliasesByKey: [String: [OAuthModelAliasEntry]] = [:]

        for account in routingAccounts {
            let key = Self.canonicalRoutingKey(account.normalizedProvider)
            accountsByKey[key, default: []].append(account)
            allKeys.insert(key)
        }
        for account in config.accounts {
            let key = Self.canonicalRoutingKey(account.account.normalizedProvider)
            configByKey[key, default: []].append(account)
            allKeys.insert(key)
        }
        for (key, accounts) in configByKey {
            routesByKey[key, default: []].append(contentsOf: ModelRoutingResolver.configRoutes(
                accounts: accounts,
                forceModelPrefix: forceModelPrefix
            ))
            excludedByKey[key, default: []].append(
                contentsOf: accounts.flatMap(\.excludedPatterns)
            )
        }
        for (rawProvider, entries) in aliases {
            let key = Self.canonicalRoutingKey(rawProvider)
            aliasesByKey[key, default: []].append(contentsOf: entries)
            allKeys.insert(key)
        }
        for key in Set(accountsByKey.keys).union(aliasesByKey.keys) {
            routesByKey[key, default: []].append(contentsOf: ModelRoutingResolver.oauthRoutes(
                globalEntries: aliasesByKey[key] ?? [],
                accounts: accountsByKey[key] ?? [],
                accountOverrides: accountOverrides,
                forceModelPrefix: forceModelPrefix
            ))
        }
        for (rawProvider, patterns) in excluded {
            let key = Self.canonicalRoutingKey(rawProvider)
            excludedByKey[key, default: []].append(contentsOf: patterns)
            allKeys.insert(key)
        }
        for group in modelPool.providers {
            let key = Self.canonicalRoutingKey(group.provider.key)
            advertisedByKey[key, default: 0] += group.models.count
            allKeys.insert(key)
        }

        let providers = allKeys.compactMap { key -> ProviderRoutingGroup? in
            let providerAccounts = accountsByKey[key] ?? []
            let configAccounts = configByKey[key] ?? []
            let routes = ModelRoutingResolver.deduplicated(routesByKey[key] ?? []).sorted { lhs, rhs in
                let publicOrder = lhs.publicModelID.localizedCaseInsensitiveCompare(rhs.publicModelID)
                if publicOrder != .orderedSame {
                    return publicOrder == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            let prefixes = Self.uniqueRoutingStrings(
                providerAccounts.compactMap {
                    ModelRoutingResolver.effectivePrefix(for: $0, accountOverrides: accountOverrides)
                } + configAccounts.compactMap { $0.account.prefix }
            )
            let priorities = Array(Set(
                providerAccounts.compactMap {
                    ModelRoutingResolver.effectivePriority(for: $0, accountOverrides: accountOverrides)
                } + configAccounts.compactMap { $0.account.priority }
            )).sorted(by: >)
            let baseURLs = Self.uniqueRoutingStrings(
                configAccounts.compactMap { ModelRoutingResolver.sanitizedEndpoint($0.baseURL) }
            )
            let proxyURLs = Self.uniqueRoutingStrings(
                providerAccounts.compactMap {
                    ModelRoutingResolver.effectiveProxyURL(for: $0, accountOverrides: accountOverrides)
                } + configAccounts.compactMap {
                    ModelRoutingResolver.sanitizedEndpoint($0.account.proxyURL)
                }
            )
            let notes = Self.uniqueRoutingStrings(providerAccounts.compactMap {
                ModelRoutingResolver.effectiveNote(for: $0, accountOverrides: accountOverrides)
            })
            let mergedExcluded = Self.uniqueRoutingStrings(
                (excludedByKey[key] ?? []) + ModelRoutingResolver.mergedExcludedModels(
                    global: [],
                    accounts: providerAccounts,
                    accountOverrides: accountOverrides
                )
            )

            return ProviderRoutingGroup(
                provider: ProviderCatalog.info(for: key),
                accountCount: providerAccounts.count + configAccounts.count,
                advertisedModelCount: advertisedByKey[key] ?? 0,
                routes: routes,
                excludedModels: mergedExcluded,
                prefixes: prefixes,
                priorities: priorities,
                baseURLs: baseURLs,
                proxyURLs: proxyURLs,
                notes: notes,
                officialAPIAccounts: providerAccounts.filter {
                    ModelRoutingResolver.effectiveUsingAPI(
                        for: $0,
                        accountOverrides: accountOverrides
                    ) == true
                }.count
            )
        }.sorted { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }

        return ModelRoutingSnapshot(
            strategy: strategy,
            forceModelPrefix: forceModelPrefix,
            providers: providers,
            failedSections: config.failedSections
        )
    }

    func fetchConfigChannelAccounts() async -> ConfigChannelFetch {
        await withTaskGroup(of: ConfigSectionResult.self, returning: ConfigChannelFetch.self) { group in
            group.addTask { await self.fetchCompatibilitySection() }
            for kind in APIKeyChannelKind.allCases {
                group.addTask { await self.fetchAPIKeySection(kind) }
            }

            var accounts: [ConfigChannelAccount] = []
            var failedSections: [String] = []
            for await result in group {
                accounts.append(contentsOf: result.accounts)
                if let failedSection = result.failedSection {
                    failedSections.append(failedSection)
                }
            }
            return ConfigChannelFetch(
                accounts: accounts,
                failedSections: failedSections.sorted()
            )
        }
    }

    func fetchStaticModelDefinitions(channel: String) async throws -> [CPAModelDefinition] {
        let response: (ModelsResponse, HTTPURLResponse) = try await request(
            path: "/v0/management/model-definitions/\(channel)"
        )
        return response.0.models
    }
}

private extension CPAClient {
    func fetchAuthFiles() async throws -> [CPAAccount] {
        let response: (AuthFilesResponse, HTTPURLResponse) = try await request(
            path: "/v0/management/auth-files"
        )
        return response.0.files
    }

    func buildModelPool(
        accounts: [CPAAccount],
        config: ConfigChannelFetch,
        forceModelPrefix: Bool
    ) async -> ModelPoolSnapshot {
        let eligible = accounts.filter { !$0.disabled && !$0.unavailable }
        var results: [AuthModelsResult] = []
        var start = 0

        while start < eligible.count {
            let batch = Array(eligible[start..<Swift.min(start + 8, eligible.count)])
            let batchResults = await withTaskGroup(
                of: AuthModelsResult.self,
                returning: [AuthModelsResult].self
            ) { group in
                for account in batch {
                    group.addTask {
                        do {
                            return AuthModelsResult(
                                account: account,
                                models: try await self.fetchModels(for: account)
                            )
                        } catch {
                            return AuthModelsResult(account: account, models: nil)
                        }
                    }
                }
                var values: [AuthModelsResult] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            results.append(contentsOf: batchResults)
            start += 8
        }

        results.append(contentsOf: config.accounts.map { account in
            let models: [CPAModelDefinition]
            if forceModelPrefix, let prefix = account.account.prefix, !prefix.isEmpty {
                let requiredPrefix = prefix.lowercased() + "/"
                models = account.models.filter { $0.id.lowercased().hasPrefix(requiredPrefix) }
            } else {
                models = account.models
            }
            return AuthModelsResult(account: account.account, models: models)
        })
        results.append(contentsOf: config.failedSections.map {
            ConfigChannelSynthesizer.failureResult(providerKey: $0)
        })
        return ModelPoolAggregator.aggregate(results)
    }

    func fetchCompatibilitySection() async -> ConfigSectionResult {
        do {
            let data = try await managementData(path: "/v0/management/openai-compatibility")
            guard let object = Self.object(from: data) else {
                return ConfigSectionResult(accounts: [], failedSection: "openai-compatibility")
            }
            return ConfigSectionResult(
                accounts: ConfigChannelSynthesizer.compatAccounts(root: object),
                failedSection: nil
            )
        } catch {
            return ConfigSectionResult(
                accounts: [],
                failedSection: Self.isNotFound(error) ? nil : "openai-compatibility"
            )
        }
    }

    func fetchAPIKeySection(_ kind: APIKeyChannelKind) async -> ConfigSectionResult {
        do {
            let data = try await managementData(path: kind.managementPath)
            guard let object = Self.object(from: data) else {
                return ConfigSectionResult(accounts: [], failedSection: kind.rawValue)
            }
            let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: kind, root: object)
            guard !entries.isEmpty else {
                return ConfigSectionResult(accounts: [], failedSection: nil)
            }
            let staticModels: [CPAModelDefinition]
            if entries.contains(where: { $0.overrideModelIDs.isEmpty }) {
                staticModels = (try? await fetchStaticModelDefinitions(channel: kind.definitionsChannel)) ?? []
            } else {
                staticModels = []
            }
            return ConfigSectionResult(
                accounts: ConfigChannelSynthesizer.apiKeyAccounts(
                    kind: kind,
                    entries: entries,
                    staticModels: staticModels
                ),
                failedSection: nil
            )
        } catch {
            return ConfigSectionResult(
                accounts: [],
                failedSection: Self.isNotFound(error) ? nil : kind.rawValue
            )
        }
    }

    func fetchOAuthAliases() async -> [String: [OAuthModelAliasEntry]] {
        guard let data = try? await managementData(path: "/v0/management/oauth-model-alias"),
              let object = Self.object(from: data)
        else {
            return [:]
        }
        return OAuthModelRoutingParser.aliases(root: object)
    }

    func fetchOAuthExcludedModels() async -> [String: [String]] {
        guard let data = try? await managementData(path: "/v0/management/oauth-excluded-models"),
              let object = Self.object(from: data)
        else {
            return [:]
        }
        return OAuthModelRoutingParser.excludedModels(root: object)
    }

    func fetchRoutingStrategy() async -> String {
        guard let data = try? await managementData(path: "/v0/management/routing/strategy"),
              let object = Self.object(from: data)
        else {
            return "round-robin"
        }
        return firstString(object["strategy"]) ?? "round-robin"
    }

    func fetchForceModelPrefix() async -> Bool {
        guard let data = try? await managementData(path: "/v0/management/force-model-prefix"),
              let object = Self.object(from: data)
        else {
            return false
        }
        return boolValue(object["force-model-prefix"]) ?? false
    }

    func fetchOAuthAccountRoutingOverrides(
        _ accounts: [CPAAccount]
    ) async -> [String: OAuthAccountRoutingOverride] {
        let candidates = accounts.filter { Self.downloadableAuthJSONName(for: $0) != nil }
        var overrides: [String: OAuthAccountRoutingOverride] = [:]
        var start = 0

        while start < candidates.count {
            let batch = Array(candidates[start..<Swift.min(start + 8, candidates.count)])
            let values = await withTaskGroup(
                of: AccountRoutingResult.self,
                returning: [AccountRoutingResult].self
            ) { group in
                for account in batch {
                    group.addTask {
                        AccountRoutingResult(
                            accountID: account.id,
                            override: await self.fetchOAuthAccountRoutingOverride(for: account)
                        )
                    }
                }
                var results: [AccountRoutingResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            for value in values {
                if let override = value.override {
                    overrides[value.accountID] = override
                }
            }
            start += 8
        }
        return overrides
    }

    func fetchOAuthAccountRoutingOverride(
        for account: CPAAccount
    ) async -> OAuthAccountRoutingOverride? {
        guard let name = Self.downloadableAuthJSONName(for: account),
              let response = try? await dataRequest(
                  path: "/v0/management/auth-files/download",
                  queryItems: [URLQueryItem(name: "name", value: name)]
              )
        else {
            return nil
        }
        return OAuthAuthFileRoutingParser.parse(
            data: response.0,
            provider: Self.canonicalRoutingKey(account.normalizedProvider)
        )
    }

    func managementData(path: String) async throws -> Data {
        try await dataRequest(path: path).0
    }

    static func object(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func downloadableAuthJSONName(for account: CPAAccount) -> String? {
        let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased().hasSuffix(".json"),
              !name.contains("/"),
              !name.contains("\\")
        else {
            return nil
        }
        return name
    }

    static func canonicalRoutingKey(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "anthropic": return "claude"
        case "grok", "x-ai": return "xai"
        default: return ProviderCatalog.info(for: normalized).key
        }
    }

    static func uniqueRoutingStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    static func isNotFound(_ error: Error) -> Bool {
        if case let CPAAPIError.httpStatus(code, _) = error {
            return code == 404
        }
        return false
    }
}

private struct ConfigSectionResult: Sendable {
    let accounts: [ConfigChannelAccount]
    let failedSection: String?
}

private struct AccountRoutingResult: Sendable {
    let accountID: String
    let override: OAuthAccountRoutingOverride?
}
