import SwiftUI

struct AccountDetailView: View {
    let account: CPAAccount
    let client: CPAClient?

    @State private var models: [CPAModelDefinition] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                DetailHero(account: account)
                QuotaDetailSection(account: account)
                RecentRequestsSection(buckets: account.recentRequests)
                ModelCooldownSection(account: account)
                ModelListSection(models: models, isLoading: isLoadingModels, error: modelError)
                AccountMetadataSection(account: account)
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle(account.providerName.uppercased())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadModels()
        }
    }

    private func loadModels() async {
        guard let client, models.isEmpty, !isLoadingModels else {
            return
        }
        isLoadingModels = true
        modelError = nil
        do {
            models = try await client.fetchModels(for: account)
        } catch {
            modelError = error.localizedDescription
        }
        isLoadingModels = false
    }
}

struct DetailHero: View {
    let account: CPAAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(provider: account.providerName)
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.displayName)
                        .font(.title2.weight(.bold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.78)

                    Text(account.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(kind: account.statusKind)
            }

            HStack(spacing: 10) {
                DetailCounter(title: "成功", value: "\(account.success)", tint: .green)
                DetailCounter(title: "失败", value: "\(account.failed)", tint: .red)
                DetailCounter(title: "模型冷却", value: "\(account.activeModelCooldowns.count)", tint: .orange)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct QuotaDetailSection: View {
    let account: CPAAccount

    var body: some View {
        DetailSection(title: "额度状态", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusPill(kind: account.statusKind)
                    Spacer()
                    Text(account.quotaLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(account.statusKind.tint)
                }

                if let reason = account.quota?.reason ?? account.statusMessage, !reason.isEmpty {
                    DetailRow(title: "原因", value: reason)
                }
                if let nextRecoveryDate = account.nextRecoveryDate {
                    DetailRow(title: "预计恢复", value: absoluteTime(nextRecoveryDate))
                }
                if let lastRefresh = account.lastRefresh {
                    DetailRow(title: "上次刷新", value: absoluteTime(lastRefresh))
                }
                if let credits = account.antigravityCredits, credits.known {
                    DetailRow(title: "AI Credits", value: creditsLine(credits))
                }
                if let lastError = account.lastError, !lastError.message.isEmpty {
                    DetailRow(title: "最近错误", value: lastError.message)
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
    let account: CPAAccount

    var body: some View {
        DetailSection(title: "模型冷却", systemImage: "hourglass") {
            if account.activeModelCooldowns.isEmpty {
                EmptyStateView(title: "没有模型冷却", systemImage: "checkmark.seal")
            } else {
                VStack(spacing: 10) {
                    ForEach(account.activeModelCooldowns, id: \.model) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.model)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if let message = item.state.statusMessage, !message.isEmpty {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let date = item.state.nextRetryAfter {
                                Label(absoluteTime(date), systemImage: "clock.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

struct ModelListSection: View {
    let models: [CPAModelDefinition]
    let isLoading: Bool
    let error: String?

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
                    ForEach(models) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName ?? model.id)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                if model.displayName != nil {
                                    Text(model.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if let type = model.type, !type.isEmpty {
                                Text(type.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.teal.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(12)
                        .background(Color.cpaSecondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

struct AccountMetadataSection: View {
    let account: CPAAccount

    var body: some View {
        DetailSection(title: "账号信息", systemImage: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow(title: "Provider", value: account.providerName)
                if let email = account.email, !email.isEmpty {
                    DetailRow(title: "邮箱", value: email)
                }
                if let projectID = account.projectID, !projectID.isEmpty {
                    DetailRow(title: "项目", value: projectID)
                }
                if let accountType = account.accountType, !accountType.isEmpty {
                    DetailRow(title: "账号类型", value: accountType)
                }
                if let account = account.account, !account.isEmpty {
                    DetailRow(title: "账号标识", value: account)
                }
                if let planType = account.idToken?.planType, !planType.isEmpty {
                    DetailRow(title: "计划", value: planType)
                }
                if let priority = account.priority {
                    DetailRow(title: "优先级", value: "\(priority)")
                }
                if let note = account.note, !note.isEmpty {
                    DetailRow(title: "备注", value: note)
                }
                if let updatedAt = account.updatedAt ?? account.modifiedAt {
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
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
