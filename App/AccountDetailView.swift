import SwiftUI

struct AccountDetailView: View {
    let account: AccountQuota
    let client: CPAClient?
    var initialModels: [CPAModelDefinition] = []
    var onQuotaUpdated: ((AccountQuota) -> Void)?

    @State private var models: [CPAModelDefinition] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var liveAccount: AccountQuota?
    @State private var isLoadingLiveQuota = false

    private var detailRefreshKey: AccountDetailRefreshKey {
        AccountDetailRefreshKey(account: account.account)
    }

    private var canRefreshDetail: Bool {
        client != nil || !initialModels.isEmpty
    }

    var body: some View {
        let displayedAccount = liveAccount ?? account

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                DetailHero(account: displayedAccount)
                LiveQuotaDetailSection(account: displayedAccount, isRefreshing: isLoadingLiveQuota)
                QuotaDetailSection(account: displayedAccount)
                RecentRequestsSection(buckets: displayedAccount.account.recentRequests)
                ModelCooldownSection(account: displayedAccount)
                ModelListSection(account: displayedAccount, models: models, isLoading: isLoadingModels, error: modelError)
                AccountMetadataSection(account: displayedAccount)
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle(displayedAccount.account.providerName.uppercased())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await refreshDetail()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!canRefreshDetail || isLoadingLiveQuota || isLoadingModels)
                .accessibilityLabel("刷新详情")
            }
        }
        .task(id: detailRefreshKey) {
            liveAccount = nil
            models = initialModels
            modelError = nil
            await refreshDetail()
        }
    }

    @MainActor
    private func refreshDetail() async {
        guard client != nil else {
            models = initialModels
            return
        }
        async let liveQuotaRefresh: Void = refreshLiveQuota()
        async let modelRefresh: Void = loadModels(force: true)
        _ = await (liveQuotaRefresh, modelRefresh)
    }

    @MainActor
    private func loadModels(force: Bool = false) async {
        guard let client, !isLoadingModels, force || models.isEmpty else {
            return
        }
        isLoadingModels = true
        defer {
            isLoadingModels = false
        }
        modelError = nil
        do {
            let fetchedModels = try await client.fetchModels(for: account.account)
            guard !Task.isCancelled else {
                return
            }
            models = fetchedModels
        } catch {
            guard !isCancellation(error) else {
                return
            }
            modelError = displayErrorMessage(error.localizedDescription, limit: 160)
        }
    }

    @MainActor
    private func refreshLiveQuota() async {
        guard let client, account.supportsUsage, !isLoadingLiveQuota else {
            return
        }
        isLoadingLiveQuota = true
        defer {
            isLoadingLiveQuota = false
        }
        let updatedAccount = await client.fetchAccountQuota(for: account.account)
        guard !Task.isCancelled else {
            return
        }
        liveAccount = updatedAccount
        onQuotaUpdated?(updatedAccount)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private struct AccountDetailRefreshKey: Equatable {
    let id: String
    let authIndex: String
    let name: String
    let providerName: String

    init(account: CPAAccount) {
        id = account.id
        authIndex = account.authIndex ?? ""
        name = account.name
        providerName = account.providerName
    }
}

struct DetailHero: View {
    let account: AccountQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(provider: account.account.providerName)
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.account.displayName)
                        .font(.title2.weight(.bold))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.78)
                        .privacySensitive(account.account.displayNameIsSensitive)

                    Text(account.account.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .privacySensitive()
                }
                .layoutPriority(1)
                Spacer()
                StatusPill(kind: account.statusKind)
            }

            HStack(spacing: 10) {
                DetailCounter(title: "成功", value: "\(account.account.success)", tint: .green)
                DetailCounter(title: "失败", value: "\(account.account.failed)", tint: .red)
                DetailCounter(title: "最低剩余", value: displayPercent(account.lowestRemainingPercent), tint: quotaTint(account.lowestRemainingPercent))
            }
        }
        .padding(16)
        .cpaCard()
    }
}

struct DetailCounter: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cpaInset(tint.opacity(0.10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }
}

struct LiveQuotaDetailSection: View {
    let account: AccountQuota
    let isRefreshing: Bool

    var body: some View {
        DetailSection(title: "实时剩余额度", systemImage: "gauge.with.dots.needle.50percent") {
            VStack(spacing: 12) {
                if isRefreshing {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在同步实时额度")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(10)
                    .cpaInset(Color.teal.opacity(0.10))
                }

                if let fetchedAt = account.usage?.fetchedAt {
                    Label("同步于 \(relativeTime(fetchedAt))", systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = account.errorMessage, !errorMessage.isEmpty {
                    InlineErrorView(message: errorMessage)
                } else if account.quotaWindows.isEmpty {
                    EmptyStateView(title: account.supportsUsage ? "暂无额度窗口" : "该来源仅显示身份状态", systemImage: "gauge")
                } else {
                    ForEach(Array(account.quotaWindows.enumerated()), id: \.offset) { _, window in
                        QuotaWindowDetailRow(window: window)
                    }
                }
            }
        }
    }
}

struct QuotaWindowDetailRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer()
                Text(window.displayValue ?? displayPercent(window.remainingPercent))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(quotaTint(window.remainingPercent, isUsable: window.isUsable))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            ProgressView(value: (window.remainingPercent ?? 0) / 100)
                .tint(quotaTint(window.remainingPercent, isUsable: window.isUsable))

            QuotaWindowMetadataLabels(window: window, font: .caption.weight(.medium))
        }
        .padding(12)
        .cpaInset(Color.cpaSecondaryBackground)
        .accessibilityElement(children: .combine)
    }
}

struct QuotaDetailSection: View {
    let account: AccountQuota

    var body: some View {
        DetailSection(title: "运行状态", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusPill(kind: account.statusKind)
                    Spacer()
                    Text(account.account.quotaLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(account.statusKind.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                if let reason = account.account.quota?.reason ?? account.account.statusMessage, !reason.isEmpty {
                    DetailRow(title: "原因", value: reason)
                }
                if let nextRecoveryDate = account.account.nextRecoveryDate {
                    DetailRow(title: "预计恢复", value: absoluteTime(nextRecoveryDate))
                }
                if let lastRefresh = account.account.lastRefresh {
                    DetailRow(title: "上次刷新", value: absoluteTime(lastRefresh))
                }
                if let nextRefresh = account.account.nextRefreshAfter {
                    DetailRow(title: "下次刷新", value: absoluteTime(nextRefresh))
                }
                if let credits = account.account.antigravityCredits, credits.known {
                    DetailRow(title: "AI Credits", value: creditsLine(credits))
                }
                if let lastError = account.account.lastError, !lastError.message.isEmpty {
                    DetailRow(title: "最近错误", value: displayErrorMessage(lastError.message, limit: 220))
                }
            }
        }
    }
}

struct RecentRequestsSection: View {
    let buckets: [RecentRequestBucket]

    var body: some View {
        DetailSection(title: "最近请求", systemImage: "chart.bar.xaxis") {
            if buckets.isEmpty {
                EmptyStateView(title: "暂无请求记录", systemImage: "chart.bar")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SparklineBars(buckets: buckets)
                        .frame(height: 88)
                    HStack {
                        Label("\(buckets.reduce(0) { $0 + $1.success })", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("\(buckets.reduce(0) { $0 + $1.failed })", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

struct ModelCooldownSection: View {
    let account: AccountQuota

    var body: some View {
        DetailSection(title: "模型状态", systemImage: "hourglass") {
            if account.account.activeModelCooldowns.isEmpty {
                EmptyStateView(title: "没有模型限制", systemImage: "checkmark.seal")
            } else {
                VStack(spacing: 10) {
                    ForEach(account.account.activeModelCooldowns, id: \.model) { item in
                        let message = firstNonEmptyString(
                            item.state.statusMessage,
                            item.state.lastError?.message,
                            item.state.quota?.reason,
                            item.state.status
                        )
                        let isError = item.state.status?.lowercased() == "error" || item.state.lastError != nil
                        let tint: Color = isError ? .red : .orange
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.model)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if let message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                            if let date = item.state.nextRetryAfter {
                                Label(absoluteTime(date), systemImage: "clock.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .cpaInset(tint.opacity(0.10))
                    }
                }
            }
        }
    }
}

struct ModelListSection: View {
    let account: AccountQuota
    let models: [CPAModelDefinition]
    let isLoading: Bool
    let error: String?

    private var rows: [ModelListRowModel] {
        models
            .enumerated()
            .map { index, model in
                ModelListRowModel(index: index, model: model, state: runtimeState(for: model))
            }
            .sorted(by: modelRowSort)
    }

    var body: some View {
        DetailSection(title: "可用模型", systemImage: "square.stack.3d.up.fill") {
            if isLoading {
                ProgressView("正在加载模型")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else if let error {
                InlineErrorView(message: error)
            } else if models.isEmpty {
                EmptyStateView(title: "暂无模型数据", systemImage: "square.stack.3d.up")
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        ModelListRow(row: row)
                    }
                }
            }
        }
    }

    private func runtimeState(for model: CPAModelDefinition) -> ModelState? {
        let lookupValues = [
            model.id,
            model.displayName
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        for value in lookupValues {
            if let exact = account.account.modelStates.first(where: { $0.key.lowercased() == value }) {
                return exact.value
            }
        }
        return nil
    }

    private func modelRowSort(_ lhs: ModelListRowModel, _ rhs: ModelListRowModel) -> Bool {
        if lhs.runtimeKind.sortRank != rhs.runtimeKind.sortRank {
            return lhs.runtimeKind.sortRank < rhs.runtimeKind.sortRank
        }
        return lhs.sortName.localizedCaseInsensitiveCompare(rhs.sortName) == .orderedAscending
    }
}

struct ModelListRow: View {
    let row: ModelListRowModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                modelIdentity
                    .layoutPriority(1)
                Spacer(minLength: 8)
                modelStateSummary(alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 10) {
                modelIdentity
                modelStateSummary(alignment: .leading)
            }
        }
        .padding(12)
        .cpaInset(row.runtimeKind.tint.opacity(0.08))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func modelStateSummary(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 6) {
                if let typeText {
                    ModelTypeBadge(type: typeText)
                }
                ModelRuntimeBadge(kind: row.runtimeKind)
            }

            if let recoveryText = row.recoveryText {
                Label(recoveryText, systemImage: "clock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let message = row.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
        }
    }

    @ViewBuilder
    private var modelIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.model.displayName ?? row.model.id)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if row.model.displayName != nil {
                Text(row.model.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let ownedBy = row.model.ownedBy, !ownedBy.isEmpty {
                Label(ownedBy, systemImage: "building.2.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var typeText: String? {
        let trimmed = row.model.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var accessibilitySummary: String {
        [
            row.model.displayName ?? row.model.id,
            typeText,
            row.runtimeKind.title,
            row.statusMessage,
            row.recoveryText
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "，")
    }
}

struct ModelTypeBadge: View {
    let type: String

    var body: some View {
        Text(type.uppercased())
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(.teal)
            .background(Color.teal.opacity(0.12), in: Capsule())
            .accessibilityLabel("模型类型：\(type)")
    }
}

struct ModelRuntimeBadge: View {
    let kind: ModelRuntimeKind

    var body: some View {
        Label(kind.title, systemImage: kind.systemImage)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(kind.tint)
            .background(kind.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("模型状态：\(kind.title)")
    }
}

struct ModelListRowModel: Identifiable, Equatable {
    let index: Int
    let model: CPAModelDefinition
    let state: ModelState?

    var id: String {
        "\(index)|\(model.id)"
    }

    var sortName: String {
        firstNonEmptyString(model.displayName, model.id) ?? model.id
    }

    var runtimeKind: ModelRuntimeKind {
        ModelRuntimeKind(state: state)
    }

    var statusMessage: String? {
        guard let state else {
            return nil
        }
        return firstNonEmptyString(
            state.statusMessage,
            state.lastError?.message,
            state.quota?.reason,
            state.status
        ).map { displayErrorMessage($0, limit: 120) }
    }

    var recoveryText: String? {
        guard let nextRetryAfter = state?.nextRetryAfter, nextRetryAfter > Date() else {
            return nil
        }
        return absoluteTime(nextRetryAfter)
    }
}

enum ModelRuntimeKind: Equatable {
    case error
    case cooling
    case pending
    case available
    case unknown

    init(state: ModelState?) {
        guard let state else {
            self = .available
            return
        }
        let status = state.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if status.contains("error") ||
            status.contains("failed") ||
            status.contains("failure") ||
            (state.lastError?.message ?? "").isEmpty == false {
            self = .error
        } else if state.unavailable ||
            state.quota?.exceeded == true ||
            state.nextRetryAfter.map({ $0 > Date() }) == true ||
            status.contains("cool") ||
            status.contains("quota") ||
            status.contains("limit") ||
            status.contains("exceeded") ||
            status.contains("unavailable") {
            self = .cooling
        } else if status.contains("pending") || status.contains("refresh") {
            self = .pending
        } else if status.isEmpty || status == "active" || status == "available" || status == "ok" {
            self = .available
        } else {
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .error:
            return "异常"
        case .cooling:
            return "受限"
        case .pending:
            return "同步中"
        case .available:
            return "可用"
        case .unknown:
            return "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .error:
            return "exclamationmark.triangle.fill"
        case .cooling:
            return "hourglass"
        case .pending:
            return "arrow.triangle.2.circlepath"
        case .available:
            return "checkmark.seal.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .error:
            return .red
        case .cooling:
            return .orange
        case .pending:
            return .blue
        case .available:
            return .green
        case .unknown:
            return .secondary
        }
    }

    var sortRank: Int {
        switch self {
        case .error:
            return 0
        case .cooling:
            return 1
        case .pending:
            return 2
        case .unknown:
            return 3
        case .available:
            return 4
        }
    }
}

struct AccountMetadataSection: View {
    let account: AccountQuota

    var body: some View {
        DetailSection(title: "账号信息", systemImage: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow(title: "Provider", value: account.account.providerName)
                if let email = account.account.email, !email.isEmpty {
                    DetailRow(title: "邮箱", value: email, isSensitive: true)
                }
                if let projectID = account.account.projectID, !projectID.isEmpty {
                    DetailRow(title: "项目", value: projectID, isSensitive: true)
                }
                if let accountType = account.account.accountType, !accountType.isEmpty {
                    DetailRow(title: "账号类型", value: accountType)
                }
                if let accountID = account.account.account, !accountID.isEmpty {
                    DetailRow(title: "账号标识", value: accountID, isSensitive: true)
                }
                if let chatgptAccountID = account.account.chatgptAccountID, !chatgptAccountID.isEmpty {
                    DetailRow(title: "ChatGPT Account ID", value: chatgptAccountID, isSensitive: true)
                }
                if let authIndex = account.account.authIndex, !authIndex.isEmpty {
                    DetailRow(title: "Auth Index", value: authIndex, isSensitive: true)
                }
                if let planType = account.effectivePlanType, !planType.isEmpty {
                    DetailRow(title: "计划", value: planType)
                }
                if let subscriptionStart = account.account.idToken?.subscriptionActiveStart {
                    DetailRow(title: "订阅开始", value: absoluteTime(subscriptionStart))
                }
                if let subscriptionUntil = account.account.idToken?.subscriptionActiveUntil {
                    DetailRow(title: "订阅到期", value: absoluteTime(subscriptionUntil))
                }
                if account.account.runtimeOnly {
                    DetailRow(title: "来源", value: "运行时")
                } else if let source = account.account.source, !source.isEmpty {
                    DetailRow(title: "来源", value: source)
                }
                if let websockets = account.account.websockets {
                    DetailRow(title: "WebSocket", value: websockets ? "启用" : "关闭")
                }
                if let priority = account.account.priority {
                    DetailRow(title: "优先级", value: "\(priority)")
                }
                if let note = account.account.note, !note.isEmpty {
                    DetailRow(title: "备注", value: note, isSensitive: true)
                }
                if let updatedAt = account.account.updatedAt ?? account.account.modifiedAt {
                    DetailRow(title: "更新时间", value: absoluteTime(updatedAt))
                }
            }
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cpaCard()
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var isSensitive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .textSelection(.enabled)
                .privacySensitive(isSensitive)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
