import Foundation

public struct AuthModelsResult: Sendable {
    public let account: CPAAccount
    public let models: [CPAModelDefinition]?

    public init(account: CPAAccount, models: [CPAModelDefinition]?) {
        self.account = account
        self.models = models
    }
}

public struct PoolModelEntry: Identifiable, Equatable, Sendable {
    public let model: CPAModelDefinition
    public let accountCount: Int

    public var id: String { model.id }

    public init(model: CPAModelDefinition, accountCount: Int) {
        self.model = model
        self.accountCount = accountCount
    }

    public var displayName: String {
        firstNonEmptyString(model.displayName, model.id) ?? model.id
    }
}

public struct ProviderModelGroup: Identifiable, Equatable, Sendable {
    public let provider: ProviderInfo
    public let models: [PoolModelEntry]
    public let accountCount: Int

    public var id: String { provider.key }

    public init(provider: ProviderInfo, models: [PoolModelEntry], accountCount: Int) {
        self.provider = provider
        self.models = models
        self.accountCount = accountCount
    }
}

public struct ModelPoolSnapshot: Equatable, Sendable {
    public let providers: [ProviderModelGroup]
    public let queriedAccounts: Int
    public let failedAccounts: Int
    public let fetchedAt: Date

    public init(
        providers: [ProviderModelGroup],
        queriedAccounts: Int,
        failedAccounts: Int,
        fetchedAt: Date = Date()
    ) {
        self.providers = providers
        self.queriedAccounts = queriedAccounts
        self.failedAccounts = failedAccounts
        self.fetchedAt = fetchedAt
    }

    public var distinctModelCount: Int {
        Set(providers.flatMap { $0.models.map { $0.model.id.lowercased() } }).count
    }
}

public enum ModelPoolAggregator {
    public static func aggregate(
        _ results: [AuthModelsResult],
        fetchedAt: Date = Date()
    ) -> ModelPoolSnapshot {
        let grouped = Dictionary(grouping: results) { result in
            ProviderCatalog.info(for: result.account.normalizedProvider).key
        }

        var providers: [ProviderModelGroup] = []
        var failedAccounts = 0
        var queriedAccounts = 0

        for (providerKey, providerResults) in grouped {
            let provider = ProviderCatalog.info(for: providerKey)
            var order: [String] = []
            var merged: [String: (model: CPAModelDefinition, count: Int)] = [:]
            var successCount = 0

            let orderedResults = providerResults.sorted {
                $0.account.id.localizedCaseInsensitiveCompare($1.account.id) == .orderedAscending
            }
            for result in orderedResults {
                guard let models = result.models else {
                    failedAccounts += 1
                    continue
                }
                successCount += 1
                var seenForAccount = Set<String>()
                for model in models {
                    let key = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !key.isEmpty else { continue }
                    if seenForAccount.contains(key) {
                        if let existing = merged[key] {
                            merged[key] = (mergeDefinitions(existing.model, model), existing.count)
                        }
                        continue
                    }
                    seenForAccount.insert(key)
                    if let existing = merged[key] {
                        merged[key] = (mergeDefinitions(existing.model, model), existing.count + 1)
                    } else {
                        merged[key] = (model, 1)
                        order.append(key)
                    }
                }
            }

            queriedAccounts += successCount
            guard !merged.isEmpty else { continue }

            let entries = order
                .compactMap { merged[$0] }
                .map { PoolModelEntry(model: $0.model, accountCount: $0.count) }
                .sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            providers.append(
                ProviderModelGroup(
                    provider: provider,
                    models: entries,
                    accountCount: successCount
                )
            )
        }

        providers.sort { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }

        return ModelPoolSnapshot(
            providers: providers,
            queriedAccounts: queriedAccounts,
            failedAccounts: failedAccounts,
            fetchedAt: fetchedAt
        )
    }

    private static func mergeDefinitions(
        _ base: CPAModelDefinition,
        _ other: CPAModelDefinition
    ) -> CPAModelDefinition {
        CPAModelDefinition(
            id: base.id,
            displayName: firstNonEmptyString(base.displayName, other.displayName),
            type: firstNonEmptyString(base.type, other.type),
            ownedBy: firstNonEmptyString(base.ownedBy, other.ownedBy),
            description: firstNonEmptyString(base.description, other.description),
            contextLength: base.contextLength ?? other.contextLength,
            maxCompletionTokens: base.maxCompletionTokens ?? other.maxCompletionTokens,
            supportedInputModalities: mergeUniqueStrings(
                base.supportedInputModalities,
                other.supportedInputModalities
            ),
            supportedOutputModalities: mergeUniqueStrings(
                base.supportedOutputModalities,
                other.supportedOutputModalities
            ),
            supportsWebSearch: base.supportsWebSearch ?? other.supportsWebSearch,
            thinking: base.thinking?.mergingMissingMetadata(from: other.thinking) ?? other.thinking
        )
    }
}
