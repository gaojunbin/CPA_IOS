import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Manages the current service's proxy API keys (`api-keys` in config.yaml):
/// list with masked display, copy, add, one-tap generate-and-copy, and
/// confirmed delete. Mirrors the macOS popover screen, adapted for iPhone.
struct APIKeysView: View {
    let client: CPAClient

    @State private var keys: [String]?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var errorMessage: String?
    @State private var newKey = ""
    @State private var pendingDeleteKey: String?
    @State private var toast: String?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AppBackground()
            content
            toastOverlay
        }
        .navigationTitle("API 密钥")
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
                .disabled(isLoading || isMutating)
                .accessibilityLabel("刷新 API 密钥")
            }
        }
        .task {
            if keys == nil {
                await load()
            }
        }
        .confirmationDialog(
            "删除该密钥？",
            isPresented: Binding(
                get: { pendingDeleteKey != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteKey = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("删除密钥", role: .destructive) {
                if let key = pendingDeleteKey {
                    pendingDeleteKey = nil
                    Task { await delete(key) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("正在使用该密钥的客户端将立即失去访问权限。")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && keys == nil {
            ProgressView("正在获取 API 密钥")
                .controlSize(.large)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    Text("管理当前服务的 API 密钥，可复制、新增或删除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .cpaInset(Color.blue.opacity(0.08))

                    if let errorMessage {
                        InlineErrorView(message: errorMessage)
                    }

                    addCard

                    if let keys {
                        if keys.isEmpty {
                            EmptyStateView(title: "暂无密钥，请在上方新增", systemImage: "key.slash")
                        } else {
                            keyListCard(keys)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("新增密钥", systemImage: "plus.circle.fill")
                .font(.headline)

            HStack(spacing: 10) {
                SecureField("输入新的 API 密钥", text: $newKey)
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .privacySensitive()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .cpaFieldSurface()

                Button {
                    let key = newKey
                    newKey = ""
                    Task { await add(key, copyAfterSave: false) }
                } label: {
                    Text("添加")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isMutating || newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                Task { await add(generateAPIKey(), copyAfterSave: true) }
            } label: {
                Label(
                    isMutating ? "处理中…" : "生成随机密钥并复制",
                    systemImage: "dice.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isMutating)
        }
        .padding(16)
        .cpaCard()
    }

    private func keyListCard(_ keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("已配置密钥", systemImage: "key.horizontal.fill")
                    .font(.headline)
                Spacer()
                Text("\(keys.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }

            VStack(spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    APIKeyRow(
                        maskedKey: maskedSecret(key),
                        isMutating: isMutating,
                        onCopy: { copyKey(key) },
                        onDelete: { pendingDeleteKey = key }
                    )
                }
            }
        }
        .padding(16)
        .cpaCard()
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            VStack {
                Spacer()
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 28)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            keys = try await client.fetchAPIKeys()
            pendingDeleteKey = nil
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 220)
        }
    }

    @MainActor
    private func add(_ key: String, copyAfterSave: Bool) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await client.addAPIKey(trimmed)
            keys = try await client.fetchAPIKeys()
            if copyAfterSave {
                copyKey(trimmed, notice: "已生成并复制密钥")
            } else {
                showToast("已新增密钥")
            }
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 220)
        }
    }

    @MainActor
    private func delete(_ key: String) async {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await client.deleteAPIKey(key)
            keys = try await client.fetchAPIKeys()
            showToast("已删除密钥")
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 220)
        }
    }

    @MainActor
    private func copyKey(_ key: String, notice: String = "已复制密钥") {
        #if os(iOS)
        UIPasteboard.general.string = key
        #endif
        showToast(notice)
    }

    @MainActor
    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(duration: 0.3)) {
            toast = message
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                toast = nil
            }
        }
    }
}

private struct APIKeyRow: View {
    let maskedKey: String
    let isMutating: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(maskedKey)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive()
            Spacer(minLength: 8)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(isMutating)
            .accessibilityLabel("复制密钥")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(isMutating)
            .accessibilityLabel("删除密钥")
        }
        .padding(12)
        .cpaInset(Color.secondary.opacity(0.07))
        .contextMenu {
            Button(action: onCopy) {
                Label("复制完整密钥", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除密钥", systemImage: "trash")
            }
        }
    }
}
