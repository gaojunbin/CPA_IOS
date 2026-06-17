import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: ManagementDashboard?
    @Published private(set) var isLoading = false
    @Published private(set) var isSyncingLiveUsage = false
    @Published private(set) var liveUsageCompleted = 0
    @Published private(set) var liveUsageTotal = 0
    @Published private(set) var liveUsageCompletedAt: Date?
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var showsAttentionOnly = false
    @Published var selectedStatus: CPAStatusKind = .all
    @Published var selectedProvider = "all"

    private var refreshGeneration = 0
    private let liveUsageBatchSize = 6
    private var activeConnection: SavedConnection?
    private var refreshTask: Task<Void, Never>?
    private var liveUsageTask: Task<Void, Never>?
    private var attentionThreshold = 35.0

    var isBusy: Bool {
        isLoading || isSyncingLiveUsage
    }

    func refreshIfStale(using connection: SavedConnection) {
        guard activeConnection == connection || !isBusy else {
            return
        }
        guard let fetchedAt = snapshot?.fetchedAt else {
            refresh(using: connection)
            return
        }
        if Date().timeIntervalSince(fetchedAt) >= max(60, connection.refreshIntervalSeconds) {
            refresh(using: connection)
        }
    }

    func refresh(using connection: SavedConnection, force: Bool = false) {
        _ = startRefresh(using: connection, force: force)
    }

    func refreshAndWait(using connection: SavedConnection, force: Bool = false) async {
        guard let task = startRefresh(using: connection, force: force) else {
            return
        }
        await task.value
    }

    @discardableResult
    private func startRefresh(using connection: SavedConnection, force: Bool = false) -> Task<Void, Never>? {
        let isSameTarget = isSameMonitoringTarget(as: connection)
        if isBusy, isSameTarget, !force {
            return refreshTask
        }
        attentionThreshold = connection.quotaAlertThreshold
        let previousSnapshot = isSameTarget ? snapshot : nil
        if !isSameTarget {
            clearFilters()
        }
        refreshTask?.cancel()
        liveUsageTask?.cancel()
        activeConnection = connection
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runRefresh(using: connection, generation: generation, previousSnapshot: previousSnapshot)
        }
        refreshTask = task
        return task
    }

    private func isSameMonitoringTarget(as connection: SavedConnection) -> Bool {
        guard let activeConnection else {
            return false
        }
        return activeConnection.baseURL == connection.baseURL &&
            activeConnection.managementKey == connection.managementKey
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        liveUsageTask?.cancel()
        refreshTask = nil
        liveUsageTask = nil
        refreshGeneration += 1
        clearIncompleteLiveUsageTimestamp()
        isLoading = false
        isSyncingLiveUsage = false
    }

    func cancelLiveUsageRefresh() {
        liveUsageTask?.cancel()
        liveUsageTask = nil
        refreshGeneration += 1
        clearIncompleteLiveUsageTimestamp()
        isSyncingLiveUsage = false
    }

    func showPreview(_ dashboard: ManagementDashboard, attentionThreshold: Double = 35) {
        cancelRefresh()
        activeConnection = nil
        self.attentionThreshold = attentionThreshold
        snapshot = dashboard
        liveUsageCompleted = dashboard.accountQuotas.filter { $0.usage?.hasQuotaSignal == true }.count
        liveUsageTotal = dashboard.accountQuotas.filter(\.supportsUsage).count
        liveUsageCompletedAt = dashboard.fetchedAt
        errorMessage = nil
    }

    func showAttentionAccounts() {
        showsAttentionOnly = true
        selectedStatus = .all
        selectedProvider = "all"
        searchText = ""
    }

    func applyAccountQuota(_ quota: AccountQuota) {
        guard let current = snapshot else {
            return
        }
        snapshot = current.replacingAccountQuota(quota)
    }

    private func runRefresh(
        using connection: SavedConnection,
        generation: Int,
        previousSnapshot: ManagementDashboard?
    ) async {
        isLoading = true
        isSyncingLiveUsage = false
        if previousSnapshot == nil {
            liveUsageCompleted = 0
            liveUsageTotal = 0
            liveUsageCompletedAt = nil
        }
        errorMessage = nil
        let client = CPAClient(baseURL: connection.baseURL, managementKey: connection.managementKey)
        do {
            if previousSnapshot == nil {
                snapshot = nil
            }
            let baseSnapshot = try await client.fetchDashboard(includeLiveUsage: false)
            guard generation == refreshGeneration else {
                return
            }
            let visibleSnapshot = baseSnapshot.preservingLiveUsage(from: previousSnapshot)
            snapshot = visibleSnapshot
            isLoading = false
            startLiveUsageRefresh(from: baseSnapshot.accounts, client: client, connection: connection, generation: generation)
        } catch {
            guard generation == refreshGeneration else {
                return
            }
            if isCancellation(error) {
                isLoading = false
                isSyncingLiveUsage = false
                return
            }
            let message = displayErrorMessage(error.localizedDescription, limit: 180)
            errorMessage = previousSnapshot == nil ? message : "刷新失败，继续显示上次数据：\(message)"
            isLoading = false
            isSyncingLiveUsage = false
        }
        if generation == refreshGeneration {
            refreshTask = nil
        }
    }

    private func startLiveUsageRefresh(
        from accounts: [CPAAccount],
        client: CPAClient,
        connection: SavedConnection,
        generation: Int
    ) {
        liveUsageTask?.cancel()
        liveUsageTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.refreshLiveUsage(from: accounts, client: client, connection: connection, generation: generation)
        }
    }

    private func refreshLiveUsage(
        from accounts: [CPAAccount],
        client: CPAClient,
        connection: SavedConnection,
        generation: Int
    ) async {
        let targets = accounts
            .filter { ProviderCatalog.info(for: $0.normalizedProvider).supportsUsage }
            .sorted(by: accountSort)

        liveUsageTotal = targets.count
        liveUsageCompleted = 0
        guard !targets.isEmpty else {
            if generation == refreshGeneration {
                liveUsageCompletedAt = nil
                await sendQuotaAlertIfNeeded(connection: connection, generation: generation)
                liveUsageTask = nil
            }
            return
        }

        isSyncingLiveUsage = true
        defer {
            if generation == refreshGeneration {
                isSyncingLiveUsage = false
                liveUsageTask = nil
            }
        }

        var start = 0
        while start < targets.count {
            let batch = Array(targets[start..<Swift.min(start + liveUsageBatchSize, targets.count)])
            await withTaskGroup(of: AccountQuota.self) { group in
                for account in batch {
                    group.addTask {
                        await client.fetchAccountQuota(for: account)
                    }
                }

                for await quota in group {
                    guard !Task.isCancelled, generation == refreshGeneration else {
                        group.cancelAll()
                        return
                    }
                    applyAccountQuota(quota)
                    liveUsageCompleted += 1
                }
            }
            guard generation == refreshGeneration else {
                return
            }
            start += liveUsageBatchSize
        }

        if generation == refreshGeneration {
            liveUsageCompletedAt = Date()
        }
        await sendQuotaAlertIfNeeded(connection: connection, generation: generation)
    }

    private func sendQuotaAlertIfNeeded(connection: SavedConnection, generation: Int) async {
        guard generation == refreshGeneration, connection.quotaAlertsEnabled else {
            return
        }
        await QuotaAlertNotifier.notifyIfNeeded(
            accounts: accountQuotas,
            threshold: connection.quotaAlertThreshold,
            source: connection.baseURL.host ?? connection.baseURL.absoluteString,
            showsAccountNames: connection.quotaAlertShowsAccountNames
        )
    }

    private func accountSort(_ lhs: CPAAccount, _ rhs: CPAAccount) -> Bool {
        let lhsProvider = ProviderCatalog.info(for: lhs.normalizedProvider)
        let rhsProvider = ProviderCatalog.info(for: rhs.normalizedProvider)
        if lhsProvider.priority != rhsProvider.priority {
            return lhsProvider.priority < rhsProvider.priority
        }
        if lhs.normalizedProvider != rhs.normalizedProvider {
            return lhs.normalizedProvider < rhs.normalizedProvider
        }
        return stableAccountIdentitySort(lhs, rhs)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func clearIncompleteLiveUsageTimestamp() {
        if liveUsageTotal > 0 && liveUsageCompleted < liveUsageTotal {
            liveUsageCompletedAt = nil
        }
    }

    var accounts: [CPAAccount] {
        snapshot?.accounts ?? []
    }

    var accountQuotas: [AccountQuota] {
        snapshot?.accountQuotas ?? accounts.map { AccountQuota(account: $0, usage: nil, errorMessage: nil) }
    }

    var providers: [String] {
        let values = Set(accountQuotas.map { ProviderCatalog.info(for: $0.account.normalizedProvider).key })
        return ["all"] + values.sorted { lhs, rhs in
            let lhsProvider = ProviderCatalog.info(for: lhs)
            let rhsProvider = ProviderCatalog.info(for: rhs)
            if lhsProvider.priority != rhsProvider.priority {
                return lhsProvider.priority < rhsProvider.priority
            }
            return lhsProvider.displayName.localizedCaseInsensitiveCompare(rhsProvider.displayName) == .orderedAscending
        }
    }

    var filteredAccounts: [AccountQuota] {
        filteredAccountValues.sorted(by: accountQuotaSort)
    }

    var hasAPIKeyUsage: Bool {
        snapshot?.apiKeyUsage.isEmpty == false
    }

    var filteredAPIKeyUsage: [APIKeyUsageRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (snapshot?.apiKeyUsage ?? []).filter { record in
            let providerInfo = ProviderCatalog.info(for: record.provider)
            let providerKey = providerInfo.key
            let matchesAttention = !showsAttentionOnly || record.failed > 0
            let matchesProvider = selectedProvider == "all" || providerKey == selectedProvider
            let matchesStatus = apiKeyUsageMatchesStatus(record)
            let matchesQuery = query.isEmpty ||
                record.provider.lowercased().contains(query) ||
                providerKey.contains(query) ||
                providerInfo.displayName.lowercased().contains(query) ||
                record.baseURL.lowercased().contains(query) ||
                record.maskedAPIKey.lowercased().contains(query)
            return matchesAttention && matchesProvider && matchesStatus && matchesQuery
        }
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            showsAttentionOnly ||
            selectedStatus != .all ||
            selectedProvider != "all"
    }

    func clearFilters() {
        searchText = ""
        showsAttentionOnly = false
        selectedStatus = .all
        selectedProvider = "all"
    }

    var attentionAccounts: [AccountQuota] {
        accountQuotas
            .filter(isAttentionAccount)
            .sorted(by: attentionSort)
    }

    /// All accounts grouped by provider, sorted, with no search/status/provider filtering.
    /// Drives the simplified dashboard which mirrors the macOS menu-bar content.
    var providerSections: [AccountProviderSection] {
        let grouped = Dictionary(grouping: accountQuotas) { quota in
            ProviderCatalog.info(for: quota.account.normalizedProvider).key
        }
        return grouped.map { key, values in
            AccountProviderSection(
                provider: ProviderCatalog.info(for: key),
                accounts: values.sorted(by: accountQuotaSort)
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }
    }

    var filteredProviderSections: [AccountProviderSection] {
        let grouped = Dictionary(grouping: filteredAccountValues) { quota in
            ProviderCatalog.info(for: quota.account.normalizedProvider).key
        }
        return grouped.map { key, values in
            let provider = ProviderCatalog.info(for: key)
            return AccountProviderSection(
                provider: provider,
                accounts: values.sorted(by: accountQuotaSort)
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }
    }

    private func isAttentionAccount(_ quota: AccountQuota) -> Bool {
        quota.needsQuotaAlert(threshold: attentionThreshold)
    }

    private func attentionSort(_ lhs: AccountQuota, _ rhs: AccountQuota) -> Bool {
        let lhsRank = attentionRank(lhs, threshold: attentionThreshold)
        let rhsRank = attentionRank(rhs, threshold: attentionThreshold)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        switch (lhs.lowestRemainingPercent, rhs.lowestRemainingPercent) {
        case let (.some(left), .some(right)) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return accountQuotaSort(lhs, rhs)
        }
    }

    private func attentionRank(_ quota: AccountQuota, threshold: Double) -> Int {
        if (quota.errorMessage ?? "").isEmpty == false || quota.statusKind == .error {
            return 0
        }
        if quota.hasUnusableQuotaWindow || quota.statusKind == .cooling {
            return 1
        }
        let criticalThreshold = min(15, threshold)
        if let lowest = quota.lowestRemainingPercent, lowest <= criticalThreshold {
            return 2
        }
        if let lowest = quota.lowestRemainingPercent, lowest <= threshold {
            return 3
        }
        return 4
    }

    private var filteredAccountValues: [AccountQuota] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return accountQuotas.filter { quota in
            let account = quota.account
            let providerInfo = ProviderCatalog.info(for: account.normalizedProvider)
            let providerKey = providerInfo.key
            let matchesAttention = !showsAttentionOnly || isAttentionAccount(quota)
            let matchesProvider = selectedProvider == "all" || providerKey == selectedProvider
            let matchesStatus = selectedStatus == .all || quota.statusKind == selectedStatus
            let matchesQuery = query.isEmpty ||
                account.displayName.lowercased().contains(query) ||
                account.name.lowercased().contains(query) ||
                account.providerName.lowercased().contains(query) ||
                providerKey.contains(query) ||
                providerInfo.displayName.lowercased().contains(query) ||
                (account.email?.lowercased().contains(query) ?? false) ||
                (account.projectID?.lowercased().contains(query) ?? false) ||
                (account.account?.lowercased().contains(query) ?? false) ||
                (account.chatgptAccountID?.lowercased().contains(query) ?? false) ||
                (account.authIndex?.lowercased().contains(query) ?? false) ||
                (account.accountType?.lowercased().contains(query) ?? false) ||
                (account.source?.lowercased().contains(query) ?? false) ||
                (account.note?.lowercased().contains(query) ?? false) ||
                (quota.effectivePlanType?.lowercased().contains(query) ?? false)
            return matchesAttention && matchesProvider && matchesStatus && matchesQuery
        }
    }

    private func apiKeyUsageMatchesStatus(_ record: APIKeyUsageRecord) -> Bool {
        switch selectedStatus {
        case .all:
            return true
        case .available:
            return record.failed == 0
        case .error:
            return record.failed > 0
        case .cooling, .pending, .disabled, .unknown:
            return false
        }
    }

    private func accountQuotaSort(_ lhs: AccountQuota, _ rhs: AccountQuota) -> Bool {
        let lhsRank = accountListRank(lhs)
        let rhsRank = accountListRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        switch (lhs.lowestRemainingPercent, rhs.lowestRemainingPercent) {
        case let (.some(left), .some(right)) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        if lhs.statusKind != rhs.statusKind {
            return lhs.statusKind.sortOrder < rhs.statusKind.sortOrder
        }
        return stableAccountIdentitySort(lhs.account, rhs.account)
    }

    private func accountListRank(_ quota: AccountQuota) -> Int {
        attentionRank(quota, threshold: attentionThreshold)
    }

    var summary: DashboardSummary {
        DashboardSummary(accounts: accountQuotas, attentionThreshold: attentionThreshold)
    }
}

struct AccountProviderSection: Identifiable, Equatable {
    let provider: ProviderInfo
    let accounts: [AccountQuota]

    var id: String { provider.key }

    var quotaAccounts: Int {
        accounts.filter { $0.usage?.hasQuotaSignal == true }.count
    }

    var errorAccounts: Int {
        accounts.filter { quota in
            quota.statusKind == .error || (quota.errorMessage ?? "").isEmpty == false
        }.count
    }

    var lowestRemainingPercent: Double? {
        accounts.compactMap(\.lowestRemainingPercent).min()
    }

    var primaryAverage: Double? {
        average(accounts.compactMap(\.primaryRemainingPercent))
    }

    var weeklyAverage: Double? {
        average(accounts.compactMap(\.weeklyRemainingPercent))
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct DashboardSummary: Equatable {
    let total: Int
    let available: Int
    let cooling: Int
    let disabled: Int
    let error: Int
    let success: Int64
    let failed: Int64
    let quotaAccounts: Int
    let liveQuotaErrors: Int
    let attentionCount: Int
    /// Number of Codex accounts the 5h/7d averages are based on.
    let codexAccounts: Int
    let primaryAverage: Double?
    let weeklyAverage: Double?
    let lowestRemainingPercent: Double?

    init(accounts: [AccountQuota], attentionThreshold: Double = 35) {
        total = accounts.count
        available = accounts.filter { $0.statusKind == .available }.count
        cooling = accounts.filter { $0.statusKind == .cooling }.count
        disabled = accounts.filter { $0.statusKind == .disabled }.count
        error = accounts.filter { $0.statusKind == .error }.count
        success = accounts.reduce(0) { $0 + $1.account.success }
        failed = accounts.reduce(0) { $0 + $1.account.failed }
        quotaAccounts = accounts.filter { $0.usage?.hasQuotaSignal == true }.count
        liveQuotaErrors = accounts.filter { ($0.errorMessage ?? "").isEmpty == false }.count
        attentionCount = accounts.filter { $0.needsQuotaAlert(threshold: attentionThreshold) }.count
        // The 5h/7d headline is a Codex-only rolling window, so average over Codex
        // accounts exclusively and never mix in other providers' quota shapes.
        let codexAccountList = accounts.filter { $0.account.isCodexLike }
        codexAccounts = codexAccountList.count
        primaryAverage = DashboardSummary.average(codexAccountList.compactMap(\.primaryRemainingPercent))
        weeklyAverage = DashboardSummary.average(codexAccountList.compactMap(\.weeklyRemainingPercent))
        lowestRemainingPercent = accounts.compactMap(\.lowestRemainingPercent).min()
    }

    var totalRequests: Int64 {
        success + failed
    }

    var successRate: Double {
        guard totalRequests > 0 else {
            return 0
        }
        return Double(success) / Double(totalRequests)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

extension CPAStatusKind {
    var title: String {
        switch self {
        case .all:
            return "全部"
        case .available:
            return "可用"
        case .cooling:
            return "冷却"
        case .pending:
            return "处理中"
        case .error:
            return "异常"
        case .disabled:
            return "停用"
        case .unknown:
            return "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "circle.grid.2x2"
        case .available:
            return "checkmark.seal.fill"
        case .cooling:
            return "hourglass"
        case .pending:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "pause.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var sortOrder: Int {
        switch self {
        case .cooling:
            return 0
        case .error:
            return 1
        case .pending:
            return 2
        case .available:
            return 3
        case .unknown:
            return 4
        case .disabled:
            return 5
        case .all:
            return 6
        }
    }
}
