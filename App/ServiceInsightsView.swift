import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ModelPoolView: View {
    let client: CPAClient

    @State private var snapshot: ModelPoolSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredProviders: [ProviderModelGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return snapshot?.providers ?? [] }
        return (snapshot?.providers ?? []).compactMap { group in
            let models = group.models.filter { entry in
                [
                    entry.model.id,
                    entry.model.displayName ?? "",
                    entry.model.ownedBy ?? "",
                    entry.model.type ?? "",
                    entry.model.description ?? "",
                    modelCapabilitySummary(entry.model) ?? ""
                ].contains { $0.lowercased().contains(query) }
            }
            guard !models.isEmpty || group.provider.displayName.lowercased().contains(query) else {
                return nil
            }
            return ProviderModelGroup(
                provider: group.provider,
                models: models.isEmpty ? group.models : models,
                accountCount: group.accountCount
            )
        }
    }

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .navigationTitle("模型池")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "搜索模型 ID、能力或渠道")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新模型池")
            }
        }
        .task {
            if snapshot == nil {
                await load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && snapshot == nil {
            ProgressView("正在读取模型池")
                .controlSize(.large)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let snapshot {
                        ModelPoolOverview(snapshot: snapshot)
                    }
                    if let errorMessage {
                        InlineErrorView(message: errorMessage)
                    }
                    if filteredProviders.isEmpty {
                        EmptyStateView(
                            title: searchText.isEmpty ? "暂无已注册模型" : "没有匹配的模型",
                            systemImage: "square.stack.3d.up.slash"
                        )
                    } else {
                        ForEach(filteredProviders) { group in
                            ModelPoolProviderCard(group: group)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await client.fetchModelPool()
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 220)
        }
    }
}

private struct ModelPoolOverview: View {
    let snapshot: ModelPoolSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("当前服务已注册并可路由的模型", systemImage: "square.stack.3d.up.fill")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                InsightMetric(value: "\(snapshot.providers.count)", label: "渠道", tint: .primary)
                InsightMetric(value: "\(snapshot.distinctModelCount)", label: "模型", tint: .teal)
                InsightMetric(value: "\(snapshot.queriedAccounts)", label: "已查询凭据", tint: .blue)
                InsightMetric(
                    value: "\(snapshot.failedAccounts)",
                    label: "读取失败",
                    tint: snapshot.failedAccounts > 0 ? .orange : .green
                )
            }

            Text("同步于 \(relativeTime(snapshot.fetchedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .cpaCard()
    }
}

private struct ModelPoolProviderCard: View {
    let group: ProviderModelGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: group.provider.symbolName)
                    .font(.headline)
                    .foregroundStyle(providerTint(group.provider.key))
                    .frame(width: 34, height: 34)
                    .cpaInset(providerTint(group.provider.key).opacity(0.13), cornerRadius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.provider.displayName)
                        .font(.headline)
                    Text("\(group.accountCount) 个凭据 · \(group.models.count) 个模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(group.models) { entry in
                    ModelPoolRow(entry: entry)
                }
            }
        }
        .padding(14)
        .cpaCard()
    }
}

private struct ModelPoolRow: View {
    let entry: PoolModelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if entry.model.displayName != nil {
                        Text(entry.model.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Text("×\(entry.accountCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }

            if let capability = modelCapabilitySummary(entry.model) {
                Text(capability)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let description = entry.model.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .cpaInset(providerTint(entry.model.ownedBy ?? "").opacity(0.06))
        .contextMenu {
            Button {
                #if os(iOS)
                UIPasteboard.general.string = entry.model.id
                #endif
            } label: {
                Label("复制模型 ID", systemImage: "doc.on.doc")
            }
        }
    }
}

struct RoutingView: View {
    let client: CPAClient

    @State private var snapshot: ModelRoutingSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .navigationTitle("上游模型路由")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新上游模型路由")
            }
        }
        .task {
            if snapshot == nil {
                await load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && snapshot == nil {
            ProgressView("正在汇总路由")
                .controlSize(.large)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    Text("展示客户端模型 ID 如何映射到上游模型，以及前缀、优先级和全局调度策略。该页面是配置清单，不代表每条路由当前都可用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .cpaInset(Color.blue.opacity(0.08))

                    if let errorMessage {
                        InlineErrorView(message: errorMessage)
                    }
                    if let snapshot {
                        RoutingOverview(snapshot: snapshot)
                        ForEach(snapshot.providers) { group in
                            RoutingProviderCard(group: group)
                        }
                        if snapshot.providers.isEmpty {
                            EmptyStateView(title: "暂无可显示的路由", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        if !snapshot.failedSections.isEmpty {
                            Label(
                                "部分配置读取失败：\(snapshot.failedSections.joined(separator: "、"))",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .cpaInset(Color.orange.opacity(0.1))
                        }
                        Text("同步于 \(relativeTime(snapshot.fetchedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await client.fetchModelRoutingSnapshot()
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 220)
        }
    }
}

private struct RoutingOverview: View {
    let snapshot: ModelRoutingSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("路由总览", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Text(routingStrategyText(snapshot.strategy))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.teal.opacity(0.12), in: Capsule())
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                InsightMetric(value: "\(snapshot.providers.count)", label: "渠道", tint: .primary)
                InsightMetric(value: "\(snapshot.accountCount)", label: "凭据", tint: .primary)
                InsightMetric(value: "\(snapshot.routeCount)", label: "路由定义", tint: .blue)
                InsightMetric(
                    value: snapshot.forceModelPrefix ? "强制" : "兼容",
                    label: "模型前缀",
                    tint: snapshot.forceModelPrefix ? .orange : .green
                )
            }
        }
        .padding(16)
        .cpaCard()
    }
}

private struct InsightMetric: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .cpaInset(tint.opacity(0.07))
    }
}

private struct RoutingProviderCard: View {
    let group: ProviderRoutingGroup

    private var routeGroups: [[ModelRouteDefinition]] {
        Dictionary(grouping: explicitRoutes) { $0.publicModelID.lowercased() }
            .values
            .sorted {
                ($0.first?.publicModelID ?? "").localizedCaseInsensitiveCompare(
                    $1.first?.publicModelID ?? ""
                ) == .orderedAscending
            }
    }

    private var explicitRoutes: [ModelRouteDefinition] {
        group.routes.filter {
            $0.name.caseInsensitiveCompare($0.alias) != .orderedSame ||
                $0.prefix != nil || $0.fork || $0.forceMapping
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: group.provider.symbolName)
                    .font(.headline)
                    .foregroundStyle(providerTint(group.provider.key))
                    .frame(width: 34, height: 34)
                    .cpaInset(providerTint(group.provider.key).opacity(0.13), cornerRadius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.provider.displayName)
                        .font(.headline)
                    Text("\(group.accountCount) 个凭据 · \(group.advertisedModelCount) 个模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            FlowLayout(spacing: 6) {
                if let priority = group.priorities.first {
                    RoutingBadge(text: "优先级 \(priority)", tint: .indigo)
                }
                ForEach(group.prefixes, id: \.self) { prefix in
                    RoutingBadge(text: "前缀 \(prefix)", tint: .purple)
                }
                if group.officialAPIAccounts > 0 {
                    RoutingBadge(text: "官方 API ×\(group.officialAPIAccounts)", tint: .green)
                }
                if !group.excludedModels.isEmpty {
                    RoutingBadge(text: "排除 \(group.excludedModels.count)", tint: .orange)
                }
            }

            if let baseURL = group.baseURLs.first {
                RoutingMetadataRow(title: "Base URL", value: baseURL, isSensitive: true)
            }
            if let proxyURL = group.proxyURLs.first {
                RoutingMetadataRow(title: "代理", value: proxyURL, isSensitive: true)
            }
            if let note = group.notes.first {
                RoutingMetadataRow(title: "备注", value: note, isSensitive: true)
            }

            if routeGroups.isEmpty {
                Text("无显式别名映射；客户端模型以已注册模型列表为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .cpaInset(Color.secondary.opacity(0.07))
            } else {
                DisclosureGroup("客户端 → 上游映射（\(routeGroups.count)）") {
                    VStack(spacing: 8) {
                        ForEach(Array(routeGroups.enumerated()), id: \.offset) { _, routes in
                            RoutingRouteRow(routes: routes)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .cpaCard()
    }
}

private struct RoutingBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct RoutingMetadataRow: View {
    let title: String
    let value: String
    let isSensitive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .privacySensitive(isSensitive)
        }
    }
}

private struct RoutingRouteRow: View {
    let routes: [ModelRouteDefinition]

    var body: some View {
        if let first = routes.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(first.publicModelID)
                        .font(.caption.weight(.semibold).monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if routes.count > 1 {
                        RoutingBadge(text: "路由池 ×\(routes.count)", tint: .blue)
                    } else if first.fork {
                        RoutingBadge(text: "保留原模型", tint: .teal)
                    } else if first.forceMapping {
                        RoutingBadge(text: "响应改写", tint: .indigo)
                    }
                }
                Label(
                    routes.map(\.name).joined(separator: " · "),
                    systemImage: "arrow.turn.up.left"
                )
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .cpaInset(Color.secondary.opacity(0.07))
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
