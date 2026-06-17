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
                        isLoading: viewModel.isBusy
                    )

                    DashboardSummaryCard(summary: viewModel.summary)

                    if let errorMessage = viewModel.errorMessage {
                        InlineErrorView(message: errorMessage)
                    }

                    AccountListView(
                        sections: viewModel.providerSections,
                        client: previewSnapshot == nil ? connectionStore.makeClient() : nil,
                        isDemoMode: previewSnapshot != nil,
                        onQuotaUpdated: viewModel.applyAccountQuota
                    )
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

struct DashboardHeader: View {
    let connection: SavedConnection
    let snapshot: ManagementDashboard?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(connection.baseURL.host ?? connection.baseURL.absoluteString)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
                    .privacySensitive()

                Label(
                    connection.baseURL.scheme?.uppercased() ?? "HTTP",
                    systemImage: connection.baseURL.scheme == "https" ? "lock.fill" : "lock.open.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
            } else if let date = snapshot?.fetchedAt {
                Text(relativeTime(date))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cpaCard()
    }
}

struct DashboardSummaryCard: View {
    let summary: DashboardSummary

    private var accountValue: String {
        if summary.quotaAccounts == summary.total || summary.quotaAccounts == 0 {
            return "\(summary.total)"
        }
        return "\(summary.quotaAccounts)/\(summary.total)"
    }

    private var caption: String {
        if summary.codexAccounts == 0 {
            return "5h · 7d 为 Codex 账号平均剩余额度（当前无 Codex 账号）；其他渠道额度见下方各自卡片。"
        }
        let suffix = summary.codexAccounts == 1 ? "" : "，共 \(summary.codexAccounts) 个"
        return "5h · 7d 为 Codex 账号平均剩余额度\(suffix)；其他渠道额度见下方各自卡片。"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                SummaryStat(title: "Codex 5h", value: displayPercent(summary.primaryAverage), tint: quotaTint(summary.primaryAverage))
                Divider().frame(height: 38)
                SummaryStat(title: "Codex 7d", value: displayPercent(summary.weeklyAverage), tint: quotaTint(summary.weeklyAverage))
                Divider().frame(height: 38)
                SummaryStat(title: "账号", value: accountValue, tint: .primary)
            }

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .cpaCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 5 小时剩余 \(displayPercent(summary.primaryAverage))，Codex 7 天剩余 \(displayPercent(summary.weeklyAverage))，账号 \(accountValue)。\(caption)")
    }
}

struct SummaryStat: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
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
                EmptyStateView(title: "没有账号", systemImage: "tray")
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
            } else {
                Text(account.liveQuotaLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(account.statusKind.tint)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            account.liveQuotaLine
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
