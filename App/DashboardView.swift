import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showsSettings = false
    #if DEBUG
    // Launch argument `-CPAAutoOpenScreen models|routing` deep-links the insight
    // screens so simulator automation can exercise them. Debug builds only.
    @State private var autoOpenScreen = UserDefaults.standard.string(forKey: "CPAAutoOpenScreen")
    #endif

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
                ToolbarItem(placement: .principal) {
                    principalView
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    refreshButton
                    trailingSecondaryButton
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
            #if DEBUG
            .navigationDestination(isPresented: autoOpenBinding("models")) {
                ModelPoolView(client: CPAClient(
                    baseURL: connection.baseURL,
                    managementKey: connection.managementKey
                ))
            }
            .navigationDestination(isPresented: autoOpenBinding("routing")) {
                RoutingView(client: CPAClient(
                    baseURL: connection.baseURL,
                    managementKey: connection.managementKey
                ))
            }
            .navigationDestination(isPresented: autoOpenBinding("apikeys")) {
                APIKeysView(client: CPAClient(
                    baseURL: connection.baseURL,
                    managementKey: connection.managementKey
                ))
            }
            #endif
        }
        .onDisappear {
            viewModel.cancelRefresh()
        }
    }

    #if DEBUG
    private func autoOpenBinding(_ screen: String) -> Binding<Bool> {
        Binding(
            get: { autoOpenScreen == screen },
            set: { isPresented in
                if !isPresented, autoOpenScreen == screen {
                    autoOpenScreen = nil
                }
            }
        )
    }
    #endif

    @ViewBuilder private var principalView: some View {
        if previewSnapshot != nil {
            Text("演示面板").font(.headline)
        } else if connectionStore.hasProfiles {
            serviceSwitcher
        } else {
            Text("CPA 面板").font(.headline)
        }
    }

    private var serviceSwitcher: some View {
        Menu {
            ForEach(connectionStore.profiles) { profile in
                Button {
                    connectionStore.selectProfile(profile.id)
                } label: {
                    if profile.id == connectionStore.selectedID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button {
                showsSettings = true
            } label: {
                Label("管理服务…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 4) {
                Text(connection.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("切换服务，当前 \(connection.name)")
    }

    @ViewBuilder private var refreshButton: some View {
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

    @ViewBuilder private var trailingSecondaryButton: some View {
        if let onClosePreview {
            Button {
                onClosePreview()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .accessibilityLabel("退出演示")
        } else {
            Menu {
                NavigationLink {
                    ModelPoolView(client: CPAClient(
                        baseURL: connection.baseURL,
                        managementKey: connection.managementKey
                    ))
                } label: {
                    Label("模型池", systemImage: "square.stack.3d.up.fill")
                }

                NavigationLink {
                    RoutingView(client: CPAClient(
                        baseURL: connection.baseURL,
                        managementKey: connection.managementKey
                    ))
                } label: {
                    Label("上游模型路由", systemImage: "arrow.triangle.branch")
                }

                NavigationLink {
                    APIKeysView(client: CPAClient(
                        baseURL: connection.baseURL,
                        managementKey: connection.managementKey
                    ))
                } label: {
                    Label("API 密钥", systemImage: "key.horizontal.fill")
                }

                Divider()
                Button {
                    showsSettings = true
                } label: {
                    Label("服务与设置", systemImage: "gearshape.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
            }
            .accessibilityLabel("更多")
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
                        syncProgressText: viewModel.liveUsageProgressText
                    )

                    DashboardOverviewCard(
                        health: viewModel.accountQuotas.healthRatio,
                        sections: viewModel.providerSections
                    )

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
    let syncProgressText: String?

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

            VStack(alignment: .trailing, spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if let syncProgressText {
                    Text(syncProgressText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isLoading ? .teal : .secondary)
                }
                if let date = snapshot?.fetchedAt {
                    Text(relativeTime(date))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .cpaCard()
    }
}

struct DashboardOverviewCard: View {
    let health: AccountHealthRatio
    let sections: [AccountProviderSection]

    private var focusSections: [AccountProviderSection] {
        let providerAware = sections.filter {
            !ProviderQuotaMetricKind.metrics(for: $0.provider.key).isEmpty
        }
        return Array((providerAware.isEmpty ? sections : providerAware).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账号与渠道健康")
                    .font(.headline)
                Spacer()
                Text(health.displayValue)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(healthTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(healthTint.opacity(0.12), in: Capsule())
                    .accessibilityLabel("健康账号 \(health.healthy)，总账号 \(health.total)")
            }

            if focusSections.isEmpty {
                Text("暂无账号健康数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(focusSections) { section in
                        ProviderPulseTile(section: section)
                    }
                }
            }
        }
        .padding(16)
        .cpaCard()
    }

    private var healthTint: Color {
        guard health.total > 0 else { return .secondary }
        if health.isFullyHealthy { return .green }
        if health.healthy == 0 { return .red }
        return .orange
    }
}

private struct ProviderPulseTile: View {
    let section: AccountProviderSection

    private var health: AccountHealthRatio { section.healthRatio }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: section.provider.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(providerTint(section.provider.key))
                Text(section.provider.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 3)
                Text(health.displayValue)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(healthTint)
            }

            ForEach(Array(quotaLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 3)
                    Text(displayPercent(line.value))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(quotaTint(line.value))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(10)
        .cpaInset(providerTint(section.provider.key).opacity(0.08))
    }

    private var quotaLines: [(label: String, value: Double?)] {
        let averages = section.quotaAverages
        func value(_ kind: ProviderQuotaMetricKind) -> Double? {
            averages.first { $0.kind == kind }?.remainingPercent
        }
        switch section.provider.key {
        case "codex", "openai":
            return [("5h", value(.codexFiveHour)), ("7d", value(.codexSevenDay))]
        case "claude":
            return [("5h", value(.claudeFiveHour)), ("7d", value(.claudeSevenDay))]
        case "antigravity":
            return [
                ("Gemini 5h", value(.antigravityGeminiFiveHour)),
                ("Gemini 7d", value(.antigravityGeminiSevenDay)),
                ("Claude/GPT 5h", value(.antigravityClaudeGPTFiveHour)),
                ("Claude/GPT 7d", value(.antigravityClaudeGPTSevenDay))
            ]
        case "xai":
            return [("周", value(.xaiWeekly)), ("月", value(.xaiMonthly))]
        default:
            return []
        }
    }

    private var healthTint: Color {
        guard health.total > 0 else { return .secondary }
        if health.isFullyHealthy { return .green }
        if health.healthy == 0 { return .red }
        return .orange
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
                    Text(section.healthRatio.displayValue)
                        .foregroundStyle(sectionHealthTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(sectionHealthTint.opacity(0.12), in: Capsule())
                }
                .font(.caption.weight(.bold).monospacedDigit())
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

    private var sectionHealthTint: Color {
        let health = section.healthRatio
        guard health.total > 0 else { return .secondary }
        if health.isFullyHealthy { return .green }
        if health.healthy == 0 { return .red }
        return .orange
    }

    private var sectionSubtitle: String {
        let health = "健康 \(section.healthRatio.displayValue)"
        let values = section.quotaAverages.compactMap { average -> String? in
            guard let remaining = average.remainingPercent else { return nil }
            return "\(average.kind.cardLabel) \(displayPercent(remaining))"
        }
        if !values.isEmpty {
            return (values + [health]).joined(separator: " · ")
        }
        if section.provider.supportsUsage, let lowest = section.lowestRemainingPercent {
            return "最低 \(displayPercent(lowest)) · \(health)"
        }
        return health
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

            if let remainingPercent = window.remainingPercent {
                ProgressView(value: remainingPercent / 100)
                    .tint(quotaTint(remainingPercent, isUsable: window.isUsable))
            }
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
