import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showsSettings = false

    let connection: SavedConnection

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
                        Task { await viewModel.refresh(using: connection) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("刷新")
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .task {
                if viewModel.snapshot == nil {
                    await viewModel.refresh(using: connection)
                }
            }
            .refreshable {
                await viewModel.refresh(using: connection)
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
                    .environmentObject(connectionStore)
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
                        isLoading: viewModel.isLoading
                    )

                    SummaryGrid(summary: viewModel.summary)

                    if let errorMessage = viewModel.errorMessage {
                        InlineErrorView(message: errorMessage)
                    }

                    FilterPanel(viewModel: viewModel)

                    AccountListView(
                        accounts: viewModel.filteredAccounts,
                        client: connectionStore.makeClient()
                    )

                    if let usage = viewModel.snapshot?.apiKeyUsage, !usage.isEmpty {
                        APIKeyUsageSection(records: usage)
                    }
                }
                .padding(16)
            }
        }
    }
}

struct DashboardHeader: View {
    let connection: SavedConnection
    let snapshot: ManagementDashboard?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(connection.baseURL.host ?? connection.baseURL.absoluteString)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    HStack(spacing: 8) {
                        Label(connection.baseURL.scheme?.uppercased() ?? "HTTP", systemImage: connection.baseURL.scheme == "https" ? "lock.fill" : "lock.open.fill")
                        if let version = snapshot?.serverVersion, !version.isEmpty {
                            Label(version, systemImage: "shippingbox.fill")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            MetricCard(title: "账号", value: "\(summary.total)", subtitle: "\(summary.available) 可用", systemImage: "person.2.fill", tint: .teal)
            MetricCard(title: "冷却", value: "\(summary.cooling)", subtitle: "需要关注", systemImage: "hourglass", tint: .orange)
            MetricCard(title: "停用", value: "\(summary.disabled)", subtitle: "\(summary.error) 异常", systemImage: "pause.circle.fill", tint: .gray)
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
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
                        FilterChip(
                            title: provider == "all" ? "全部来源" : provider.uppercased(),
                            systemImage: providerIcon(provider),
                            isSelected: viewModel.selectedProvider == provider
                        ) {
                            viewModel.selectedProvider = provider
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.teal : Color.cpaSecondaryBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AccountListView: View {
    let accounts: [CPAAccount]
    let client: CPAClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("账号")
                    .font(.headline)
                Spacer()
                Text("\(accounts.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if accounts.isEmpty {
                EmptyStateView(title: "没有匹配账号", systemImage: "tray")
            } else {
                VStack(spacing: 10) {
                    ForEach(accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account, client: client)
                        } label: {
                            AccountRow(account: account)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct AccountRow: View {
    let account: CPAAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(provider: account.providerName)

                VStack(alignment: .leading, spacing: 5) {
                    Text(account.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    HStack(spacing: 8) {
                        Text(account.providerName.uppercased())
                        if let projectID = account.projectID {
                            Text(projectID)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                StatusPill(kind: account.statusKind)
            }

            HStack(alignment: .center, spacing: 12) {
                RequestRatioView(success: account.success, failed: account.failed)

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(account.quotaLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(account.statusKind.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    SparklineBars(buckets: account.recentRequests)
                        .frame(width: 86, height: 26)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ProviderBadge: View {
    let provider: String

    var body: some View {
        Image(systemName: providerIcon(provider))
            .font(.title3.weight(.semibold))
            .foregroundStyle(providerTint(provider))
            .frame(width: 42, height: 42)
            .background(providerTint(provider).opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StatusPill: View {
    let kind: CPAStatusKind

    var body: some View {
        Label(kind.title, systemImage: kind.systemImage)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(kind.tint)
            .background(kind.tint.opacity(0.12), in: Capsule())
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

            ProgressView(value: successRatio)
                .tint(.green)
                .frame(width: 120)
        }
    }

    private var successRatio: Double {
        let total = success + failed
        guard total > 0 else {
            return 0
        }
        return Double(success) / Double(total)
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
    }
}

struct APIKeyUsageSection: View {
    let records: [APIKeyUsageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API Key 使用")
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(records) { record in
                    HStack(spacing: 12) {
                        ProviderBadge(provider: record.provider)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.maskedAPIKey)
                                .font(.subheadline.weight(.semibold))
                            Text(record.baseURL.isEmpty ? record.provider.uppercased() : record.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        RequestRatioView(success: record.success, failed: record.failed)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

struct InlineErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
