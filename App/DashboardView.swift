import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showsSettings = false

    let connection: SavedConnection
    var previewSnapshot: ManagementDashboard?
    var onClosePreview: (() -> Void)?
    var onShowPreview: (() -> Void)?
    var attentionFocusRequestID = 0

    private var autoRefreshKey: AutoRefreshKey {
        AutoRefreshKey(connection: connection, isActive: scenePhase == .active)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("CPA 面板")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            if previewSnapshot != nil {
                                viewModel.showPreview(
                                    ManagementDashboard.demo(fetchedAt: Date()),
                                    attentionThreshold: connection.quotaAlertThreshold
                                )
                            } else {
                                await viewModel.refreshAndWait(using: connection, force: true)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isBusy)
                    .accessibilityLabel("刷新")
                }

                ToolbarItem(placement: .secondaryAction) {
                    if let onClosePreview {
                        Button {
                            onClosePreview()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel("退出演示")
                    } else {
                        Button {
                            showsSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("设置")
                    }
                }
            }
            .task(id: connection) {
                if let previewSnapshot {
                    viewModel.showPreview(previewSnapshot, attentionThreshold: connection.quotaAlertThreshold)
                } else {
                    await viewModel.refreshAndWait(using: connection, force: true)
                }
            }
            .task(id: autoRefreshKey) {
                guard previewSnapshot == nil, scenePhase == .active else {
                    return
                }
                await autoRefreshLoop()
            }
            .task(id: attentionFocusRequestID) {
                guard attentionFocusRequestID > 0, previewSnapshot == nil else {
                    return
                }
                viewModel.showAttentionAccounts()
                viewModel.refreshIfStale(using: connectionStore.connection ?? connection)
            }
            .refreshable {
                if previewSnapshot != nil {
                    viewModel.showPreview(
                        ManagementDashboard.demo(fetchedAt: Date()),
                        attentionThreshold: connection.quotaAlertThreshold
                    )
                } else if !viewModel.isBusy {
                    await viewModel.refreshAndWait(using: connection, force: true)
                }
            }
            .onScenePhaseChange(scenePhase) { phase in
                if phase == .active, previewSnapshot == nil {
                    Task { @MainActor in
                        await connectionStore.reconcileQuotaAlertAuthorization()
                        viewModel.refreshIfStale(using: connectionStore.connection ?? connection)
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView(onPreview: onShowPreview)
                    .environmentObject(connectionStore)
            }
        }
        .onDisappear {
            viewModel.cancelRefresh()
        }
    }

    private func autoRefreshLoop() async {
        guard scenePhase == .active else {
            return
        }
        let interval = max(60, connection.refreshIntervalSeconds)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if !Task.isCancelled, scenePhase == .active {
                viewModel.refresh(using: connection)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.snapshot == nil {
            ProgressView("正在加载账号")
                .controlSize(.large)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    DashboardHeader(
                        connection: connection,
                        snapshot: viewModel.snapshot,
                        isLoading: viewModel.isBusy,
                        liveUsageCompletedAt: viewModel.liveUsageCompletedAt,
                        liveUsageCompleted: viewModel.liveUsageCompleted,
                        liveUsageTotal: viewModel.liveUsageTotal
                    )

                    SummaryGrid(summary: viewModel.summary)

                    AttentionSectionView(
                        accounts: viewModel.attentionAccounts,
                        client: previewSnapshot == nil ? connectionStore.makeClient() : nil,
                        isDemoMode: previewSnapshot != nil,
                        onQuotaUpdated: viewModel.applyAccountQuota,
                        onShowAll: viewModel.showAttentionAccounts
                    )

                    if viewModel.isSyncingLiveUsage {
                        LiveUsageSyncView(
                            completed: viewModel.liveUsageCompleted,
                            total: viewModel.liveUsageTotal,
                            onCancel: viewModel.cancelLiveUsageRefresh
                        )
                    }

                    if let errorMessage = viewModel.errorMessage {
                        InlineErrorView(message: errorMessage)
                    }

                    FilterPanel(viewModel: viewModel)

                    AccountListView(
                        sections: viewModel.filteredProviderSections,
                        client: previewSnapshot == nil ? connectionStore.makeClient() : nil,
                        isDemoMode: previewSnapshot != nil,
                        onQuotaUpdated: viewModel.applyAccountQuota
                    )

                    if viewModel.hasAPIKeyUsage {
                        APIKeyUsageSection(records: viewModel.filteredAPIKeyUsage)
                    }

                    if let snapshot = viewModel.snapshot {
                        ServerMetadataSection(
                            snapshot: snapshot,
                            refreshIntervalSeconds: connection.refreshIntervalSeconds,
                            liveUsageCompletedAt: viewModel.liveUsageCompletedAt
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct AutoRefreshKey: Equatable {
    let connection: SavedConnection
    let isActive: Bool
}

struct AttentionSectionView: View {
    let accounts: [AccountQuota]
    let client: CPAClient?
    let isDemoMode: Bool
    let onQuotaUpdated: (AccountQuota) -> Void
    let onShowAll: () -> Void

    private var visibleAccounts: [AccountQuota] {
        Array(accounts.prefix(5))
    }

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("需要关注", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("\(accounts.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }

                VStack(spacing: 10) {
                    ForEach(visibleAccounts, id: \.stableIdentity) { account in
                        NavigationLink {
                            AccountDetailView(
                                account: account,
                                client: client,
                                initialModels: isDemoMode ? ManagementDashboard.demoModels(for: account.account) : [],
                                onQuotaUpdated: onQuotaUpdated
                            )
                        } label: {
                            AccountRow(account: account)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if accounts.count > visibleAccounts.count {
                    Button(action: onShowAll) {
                        Label("查看全部 \(accounts.count)", systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct LiveUsageSyncView: View {
    let completed: Int
    let total: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: total > 0 ? Double(completed) / Double(total) : nil)
                .tint(.teal)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("同步实时额度")
                    .font(.subheadline.weight(.semibold))
                Text("\(completed) / \(max(total, completed)) 个账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("停止实时额度同步")
        }
        .padding(12)
        .cpaInset(Color.teal.opacity(0.10))
    }
}

struct DashboardHeader: View {
    let connection: SavedConnection
    let snapshot: ManagementDashboard?
    let isLoading: Bool
    let liveUsageCompletedAt: Date?
    let liveUsageCompleted: Int
    let liveUsageTotal: Int

    private var serverBuildText: String? {
        let version = cleanBuildValue(snapshot?.serverVersion)
        let commit = cleanBuildValue(snapshot?.serverCommit)
        let shortCommit = commit.map { String($0.prefix(7)) }

        if let version, let shortCommit {
            return "\(version) · \(shortCommit)"
        }
        return version ?? shortCommit
    }

    private func cleanBuildValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = trimmed.lowercased()
        return trimmed.isEmpty || normalized == "unknown" || normalized == "none" ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(connection.baseURL.host ?? connection.baseURL.absoluteString)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .privacySensitive()

                    HStack(spacing: 8) {
                        Label(connection.baseURL.scheme?.uppercased() ?? "HTTP", systemImage: connection.baseURL.scheme == "https" ? "lock.fill" : "lock.open.fill")
                        if let serverBuildText = serverBuildText {
                            Label(serverBuildText, systemImage: "shippingbox.fill")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                } else if let date = snapshot?.fetchedAt {
                    Text(relativeTime(date))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                ToggleBadge(title: "切换项目", isOn: snapshot?.quotaSwitchProject)
                ToggleBadge(title: "预览模型", isOn: snapshot?.quotaSwitchPreviewModel)
            }

            if let liveUsageCompletedAt, liveUsageTotal > 0 {
                Label(
                    isLoading
                        ? "沿用上次实时额度 · \(relativeTime(liveUsageCompletedAt))"
                        : "实时额度 \(liveUsageCompleted) / \(liveUsageTotal) · \(relativeTime(liveUsageCompletedAt))",
                    systemImage: isLoading ? "clock.arrow.circlepath" : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(16)
        .cpaCard()
    }
}

struct ToggleBadge: View {
    let title: String
    let isOn: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isOn == true ? "checkmark.circle.fill" : "minus.circle")
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(isOn == true ? .green : .secondary)
        .background((isOn == true ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

struct SummaryGrid: View {
    let summary: DashboardSummary

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            MetricCard(title: "5h 剩余", value: displayPercent(summary.primaryAverage), subtitle: "\(summary.quotaAccounts) 个额度账号", systemImage: "gauge.with.dots.needle.50percent", tint: quotaTint(summary.primaryAverage))
            MetricCard(title: "7d 剩余", value: displayPercent(summary.weeklyAverage), subtitle: "按实时额度平均", systemImage: "calendar.badge.clock", tint: quotaTint(summary.weeklyAverage))
            MetricCard(title: "最低剩余", value: displayPercent(summary.lowestRemainingPercent), subtitle: "\(summary.attentionCount) 个需要关注", systemImage: "gauge.with.dots.needle.0percent", tint: quotaTint(summary.lowestRemainingPercent))
            MetricCard(title: "冷却", value: "\(summary.cooling)", subtitle: "\(summary.available) 可用 · \(summary.disabled) 停用", systemImage: "hourglass", tint: summary.cooling > 0 ? .orange : .secondary)
            MetricCard(title: "异常", value: "\(summary.error)", subtitle: "\(summary.liveQuotaErrors) 个实时额度异常", systemImage: "exclamationmark.triangle.fill", tint: summary.error > 0 ? .red : .secondary)
            MetricCard(title: "成功率", value: percent(summary.successRate), subtitle: "\(summary.totalRequests) 请求", systemImage: "chart.line.uptrend.xyaxis", tint: .green)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .cpaCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)，\(subtitle)")
    }
}

struct FilterPanel: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索账号、项目或 provider", text: $viewModel.searchText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .cpaFieldSurface()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "需要关注",
                        systemImage: "exclamationmark.triangle.fill",
                        isSelected: viewModel.showsAttentionOnly
                    ) {
                        viewModel.showsAttentionOnly.toggle()
                    }

                    ForEach([CPAStatusKind.all, .available, .cooling, .pending, .error, .disabled, .unknown]) { status in
                        FilterChip(
                            title: status.title,
                            systemImage: status.systemImage,
                            isSelected: viewModel.selectedStatus == status
                        ) {
                            viewModel.selectedStatus = status
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.providers, id: \.self) { provider in
                        let providerInfo = ProviderCatalog.info(for: provider)
                        FilterChip(
                            title: provider == "all" ? "全部来源" : providerInfo.displayName,
                            systemImage: provider == "all" ? providerIcon(provider) : providerInfo.symbolName,
                            isSelected: viewModel.selectedProvider == provider
                        ) {
                            viewModel.selectedProvider = provider
                        }
                    }
                }
            }

            if viewModel.hasActiveFilters {
                Button(action: viewModel.clearFilters) {
                    Label("清空筛选", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .cpaCard()
    }
}

struct FilterChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.teal : Color.cpaSecondaryBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

struct AccountListView: View {
    let sections: [AccountProviderSection]
    let client: CPAClient?
    let isDemoMode: Bool
    let onQuotaUpdated: (AccountQuota) -> Void

    private var accountCount: Int {
        sections.reduce(0) { $0 + $1.accounts.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("账号")
                    .font(.headline)
                Spacer()
                Text("\(accountCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if accountCount == 0 {
                EmptyStateView(title: "没有匹配账号", systemImage: "tray")
            } else {
                VStack(spacing: 16) {
                    ForEach(sections) { section in
                        AccountProviderSectionView(
                            section: section,
                            client: client,
                            isDemoMode: isDemoMode,
                            onQuotaUpdated: onQuotaUpdated
                        )
                    }
                }
            }
        }
    }
}

struct AccountProviderSectionView: View {
    let section: AccountProviderSection
    let client: CPAClient?
    let isDemoMode: Bool
    let onQuotaUpdated: (AccountQuota) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: providerIcon(section.provider.key))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(providerTint(section.provider.key))
                    .frame(width: 24, height: 24)
                    .cpaInset(providerTint(section.provider.key).opacity(0.13), cornerRadius: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.provider.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(sectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)

                Spacer()

                HStack(spacing: 6) {
                    if section.errorAccounts > 0 {
                        Label("\(section.errorAccounts)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Text("\(section.accounts.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 2)

            VStack(spacing: 10) {
                ForEach(section.accounts, id: \.stableIdentity) { account in
                    NavigationLink {
                        AccountDetailView(
                            account: account,
                            client: client,
                            initialModels: isDemoMode ? ManagementDashboard.demoModels(for: account.account) : [],
                            onQuotaUpdated: onQuotaUpdated
                        )
                    } label: {
                        AccountRow(account: account)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sectionSubtitle: String {
        if section.provider.supportsUsage {
            let quotaMetrics = [
                section.primaryAverage.map { "5h \(displayPercent($0))" },
                section.weeklyAverage.map { "7d \(displayPercent($0))" },
                section.lowestRemainingPercent.map { "最低 \(displayPercent($0))" }
            ].compactMap { $0 }
            if !quotaMetrics.isEmpty {
                return quotaMetrics.joined(separator: " · ")
            }
            if let lowest = section.lowestRemainingPercent {
                return "最低剩余 \(displayPercent(lowest)) · \(section.quotaAccounts) 个额度账号"
            }
            return "\(section.quotaAccounts) 个额度账号"
        }
        return "身份状态"
    }
}

struct AccountRow: View {
    let account: AccountQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(provider: account.account.providerName)

                VStack(alignment: .leading, spacing: 5) {
                    Text(account.account.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.82)
                        .privacySensitive(account.account.displayNameIsSensitive)

                    HStack(spacing: 8) {
                        Text(account.account.providerName.uppercased())
                            .fixedSize(horizontal: true, vertical: false)
                        if let projectID = account.account.projectID {
                            Text(projectID)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .minimumScaleFactor(0.8)
                                .privacySensitive()
                        }
                        if let plan = account.effectivePlanType {
                            Text(plan)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                StatusPill(kind: account.statusKind)
            }

            if !account.dashboardQuotaWindows.isEmpty {
                QuotaWindowStrip(windows: account.dashboardQuotaWindows)
                if account.hiddenDashboardQuotaWindowCount > 0 {
                    HiddenQuotaWindowCountView(count: account.hiddenDashboardQuotaWindowCount)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                RequestRatioView(success: account.account.success, failed: account.account.failed)

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(account.liveQuotaLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(account.statusKind.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                    if !account.account.recentRequests.isEmpty {
                        SparklineBars(buckets: account.account.recentRequests)
                            .frame(width: 86, height: 26)
                    }
                }
            }
        }
        .padding(14)
        .cpaCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("查看账号详情")
    }

    private var accessibilitySummary: String {
        [
            account.account.displayName,
            ProviderCatalog.info(for: account.account.normalizedProvider).displayName,
            "状态 \(account.statusKind.title)",
            account.liveQuotaLine,
            "成功 \(account.account.success)",
            "失败 \(account.account.failed)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "，")
    }
}

struct ProviderBadge: View {
    let provider: String

    var body: some View {
        Image(systemName: providerIcon(provider))
            .font(.title3.weight(.semibold))
            .foregroundStyle(providerTint(provider))
            .frame(width: 42, height: 42)
            .cpaInset(providerTint(provider).opacity(0.13), cornerRadius: CPALayout.chipRadius)
    }
}

struct StatusPill: View {
    let kind: CPAStatusKind

    var body: some View {
        Label(kind.title, systemImage: kind.systemImage)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(kind.tint)
            .background(kind.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("状态：\(kind.title)")
    }
}

struct RequestRatioView: View {
    let success: Int64
    let failed: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("\(success)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(failed)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            ProgressView(value: successRatio)
                .tint(.green)
                .frame(width: 120)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("成功 \(success)，失败 \(failed)")
    }

    private var successRatio: Double {
        let total = success + failed
        guard total > 0 else {
            return 0
        }
        return Double(success) / Double(total)
    }
}

struct QuotaWindowStrip: View {
    let windows: [QuotaWindow]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                QuotaWindowMiniRow(window: window)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct HiddenQuotaWindowCountView: View {
    let count: Int

    var body: some View {
        Label("另有 \(count) 个额度窗口", systemImage: "ellipsis.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel("另有 \(count) 个额度窗口在详情中显示")
    }
}

struct QuotaWindowMiniRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(window.displayValue ?? displayPercent(window.remainingPercent))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(quotaTint(window.remainingPercent, isUsable: window.isUsable))
                    .frame(minWidth: 42, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if hasMetadata {
                QuotaWindowMetadataLabels(window: window, font: .caption2.weight(.medium))
            }

            ProgressView(value: (window.remainingPercent ?? 0) / 100)
                .tint(quotaTint(window.remainingPercent, isUsable: window.isUsable))
        }
    }

    private var hasMetadata: Bool {
        let hasAmount = window.amountText?.isEmpty == false
        let hasReset = quotaResetText(window)?.isEmpty == false
        return hasAmount || hasReset
    }
}

struct SparklineBars: View {
    let buckets: [RecentRequestBucket]

    var body: some View {
        GeometryReader { geometry in
            let visible = Array(buckets.suffix(12))
            let maxValue = max(visible.map { $0.success + $0.failed }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, bucket in
                    let total = bucket.success + bucket.failed
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(bucket.failed > 0 ? Color.orange : Color.teal)
                        .frame(height: max(3, geometry.size.height * CGFloat(total) / CGFloat(maxValue)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .accessibilityHidden(true)
    }
}

struct APIKeyUsageSection: View {
    let records: [APIKeyUsageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API Key 使用")
                .font(.headline)

            if records.isEmpty {
                EmptyStateView(title: "没有匹配 API Key", systemImage: "key.fill")
            } else {
                VStack(spacing: 10) {
                    ForEach(records) { record in
                        APIKeyUsageRow(record: record)
                    }
                }
            }
        }
    }
}

struct APIKeyUsageRow: View {
    let record: APIKeyUsageRecord

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                keyIdentity
                Spacer()
                APIKeyUsageMetricsView(record: record, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 10) {
                keyIdentity
                APIKeyUsageMetricsView(record: record, alignment: .leading)
            }
        }
        .padding(12)
        .cpaCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var keyIdentity: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: record.provider)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.maskedAPIKey)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(providerLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive(!record.baseURL.isEmpty)
            }
            .layoutPriority(1)
        }
    }

    private var providerLine: String {
        let providerName = ProviderCatalog.info(for: record.provider).displayName
        guard !record.baseURL.isEmpty else {
            return providerName
        }
        return "\(providerName) · \(record.baseURL)"
    }

    private var accessibilitySummary: String {
        [
            "API Key \(record.maskedAPIKey)",
            ProviderCatalog.info(for: record.provider).displayName,
            record.baseURL,
            "成功 \(record.success)",
            "失败 \(record.failed)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "，")
    }
}

struct APIKeyUsageMetricsView: View {
    let record: APIKeyUsageRecord
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 7) {
            RequestRatioView(success: record.success, failed: record.failed)
            if !record.recentRequests.isEmpty {
                SparklineBars(buckets: record.recentRequests)
                    .frame(width: 86, height: 26)
            }
        }
    }
}

struct ServerMetadataSection: View {
    let snapshot: ManagementDashboard
    let refreshIntervalSeconds: TimeInterval
    let liveUsageCompletedAt: Date?

    private var rows: [(title: String, value: String, systemImage: String)] {
        [
            ("版本", serverBuildText, "shippingbox.fill"),
            ("构建", clean(snapshot.serverBuildDate), "calendar"),
            ("同步", relativeTime(liveUsageCompletedAt ?? snapshot.fetchedAt), "clock"),
            ("下次刷新", nextRefreshText, "arrow.triangle.2.circlepath")
        ].compactMap { title, value, systemImage in
            guard let value, !value.isEmpty else {
                return nil
            }
            return (title, value, systemImage)
        }
    }

    private var serverBuildText: String? {
        let version = clean(snapshot.serverVersion)
        let commit = clean(snapshot.serverCommit)
        let shortCommit = commit.map { String($0.prefix(7)) }

        if let version, let shortCommit {
            return "\(version) · \(shortCommit)"
        }
        return version ?? shortCommit
    }

    private var nextRefreshText: String? {
        let baseDate = liveUsageCompletedAt ?? snapshot.fetchedAt
        let interval = max(60, refreshIntervalSeconds)
        let nextRefresh = baseDate.addingTimeInterval(interval)
        return "前台 \(relativeTime(nextRefresh))"
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("服务器")
                    .font(.headline)

                VStack(spacing: 8) {
                    ForEach(rows, id: \.title) { row in
                        ServerMetadataRow(title: row.title, value: row.value, systemImage: row.systemImage)
                    }
                }
            }
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = trimmed.lowercased()
        return trimmed.isEmpty || normalized == "unknown" || normalized == "none" ? nil : trimmed
    }
}

struct ServerMetadataRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                label
                Spacer(minLength: 12)
                valueText
            }

            VStack(alignment: .leading, spacing: 4) {
                label
                valueText
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .cpaCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
    }

    private var valueText: some View {
        Text(value)
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(0.75)
    }
}

struct InlineErrorView: View {
    let message: String

    var body: some View {
        Label(displayErrorMessage(message, limit: 220), systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.red)
            .lineLimit(4)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cpaInset(Color.red.opacity(0.10))
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .cpaInset(Color.cpaSecondaryBackground)
    }
}
