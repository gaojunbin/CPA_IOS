import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Top-level "服务与设置" screen: lists every configured service, lets you add one, and
/// hosts the global (non-per-service) support + notification status.
struct SettingsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss
    var onPreview: (() -> Void)?

    @State private var showsAddService = false
    @State private var notificationCapabilitySummary: NotificationCapabilitySummary?
    @State private var diagnosticsCopied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(connectionStore.profiles) { profile in
                        NavigationLink {
                            ServiceEditorView(mode: .edit(profile))
                        } label: {
                            ServiceListRow(
                                profile: profile,
                                isSelected: profile.id == connectionStore.selectedID
                            )
                        }
                    }
                    .onMove { connectionStore.moveProfiles(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        let ids = offsets.map { connectionStore.profiles[$0].id }
                        ids.forEach { connectionStore.removeProfile($0) }
                    }

                    Button {
                        showsAddService = true
                    } label: {
                        Label("添加服务", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("服务")
                } footer: {
                    Text("每个服务相互独立：各自的服务器、管理密钥、刷新与提醒设置。点按编辑，左滑删除。")
                }

                Section("提醒") {
                    SettingsValueRow(
                        title: "通知权限",
                        value: notificationCapabilitySummary?.localizedStatusText ?? "读取中",
                        systemImage: "bell.badge.fill"
                    )
                    Text("低额度后台提醒仅监控当前选中的服务。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("支持") {
                    if let onPreview {
                        Button {
                            onPreview()
                            dismiss()
                        } label: {
                            Label("查看演示面板", systemImage: "rectangle.on.rectangle")
                        }
                    }

                    Button {
                        Task { await copyDiagnostics() }
                    } label: {
                        Label("复制诊断信息", systemImage: "doc.on.doc.fill")
                    }

                    if diagnosticsCopied {
                        Label("已复制，不包含管理密钥", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("服务与设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    if !connectionStore.profiles.isEmpty {
                        EditButton()
                    }
                }
                #endif
            }
            .task {
                await connectionStore.reconcileQuotaAlertAuthorization()
                await refreshNotificationCapabilitySummary()
            }
            .sheet(isPresented: $showsAddService) {
                NavigationStack {
                    ServiceEditorView(mode: .add)
                }
                .environmentObject(connectionStore)
            }
        }
    }

    @MainActor
    private func copyDiagnostics() async {
        await refreshNotificationCapabilitySummary()
        #if os(iOS)
        UIPasteboard.general.string = supportDiagnostics()
        #endif
        diagnosticsCopied = true
    }

    private func supportDiagnostics() -> String {
        var lines = [
            "CPA Panel Diagnostics",
            "Generated At: \(ISO8601DateFormatter().string(from: Date()))",
            "App Version: \(bundleValue("CFBundleShortVersionString"))",
            "Build: \(bundleValue("CFBundleVersion"))",
            "Service Count: \(connectionStore.profiles.count)",
            "Selected Service: \(connectionStore.connection?.displayHost ?? "none")"
        ]
        for (index, profile) in connectionStore.profiles.enumerated() {
            let host = (try? CPABaseURLNormalizer.normalize(profile.baseURLString))?.host ?? "invalid"
            let selected = profile.id == connectionStore.selectedID ? " (selected)" : ""
            let minutes = Int((profile.refreshIntervalSeconds / 60).rounded())
            lines.append("Service #\(index + 1)\(selected): host=\(host) refresh=\(minutes)min alerts=\(profile.quotaAlertsEnabled ? "on" : "off")")
        }
        lines.append(notificationCapabilitySummary?.diagnosticsLines.joined(separator: "\n") ?? "Notification Status: unknown")
        lines.append("Management Key Included: no")
        return lines.joined(separator: "\n")
    }

    private func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    @MainActor
    private func refreshNotificationCapabilitySummary() async {
        notificationCapabilitySummary = await QuotaAlertNotifier.currentCapabilitySummary()
    }
}

struct ServiceListRow: View {
    let profile: ServiceProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(profile.displayHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()
            }

            Spacer(minLength: 8)

            if profile.quotaAlertsEnabled {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.name)，\(profile.displayHost)\(isSelected ? "，当前服务" : "")")
    }
}

enum ServiceEditorMode {
    case add
    case edit(ServiceProfile)

    var isEditing: Bool {
        if case .edit = self { return true }
        return false
    }

    var profile: ServiceProfile? {
        if case let .edit(profile) = self { return profile }
        return nil
    }
}

/// The per-service form (name, server, key, refresh interval, low-quota alerts). Used both
/// for adding a new service and editing an existing one. Pushed for edit, presented as a
/// sheet for add.
struct ServiceEditorView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let mode: ServiceEditorMode

    @State private var name = ""
    @State private var baseURL = ""
    @State private var managementKey = ""
    @State private var refreshMinutes = 5.0
    @State private var quotaAlertsEnabled = false
    @State private var quotaAlertThreshold = 15.0
    @State private var quotaAlertShowsAccountNames = false
    @State private var errorMessage: String?
    @State private var notificationPermissionDenied = false
    @State private var isChecking = false
    @State private var confirmsDelete = false
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("连接") {
                TextField("名称", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("服务器", text: $baseURL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .privacySensitive()
                SecureField(keyPlaceholder, text: $managementKey)
                    .textContentType(.password)
                    .privacySensitive()

                if showsHTTPWarning {
                    Label("当前连接使用 HTTP，请只在可信网络中使用。", systemImage: "lock.open.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("刷新") {
                Stepper(value: $refreshMinutes, in: 1...1440, step: 1) {
                    SettingsValueRow(
                        title: "自动刷新",
                        value: "\(Int(refreshMinutes)) 分钟",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }

            Section("提醒") {
                Stepper(value: $quotaAlertThreshold, in: 1...50, step: 1) {
                    SettingsValueRow(
                        title: "关注阈值",
                        value: "\(Int(quotaAlertThreshold))%",
                        systemImage: "percent"
                    )
                }

                Toggle(isOn: $quotaAlertsEnabled) {
                    Label("低额度提醒", systemImage: "bell.badge.fill")
                }
                if quotaAlertsEnabled {
                    Toggle(isOn: $quotaAlertShowsAccountNames) {
                        Label("通知显示账号名称", systemImage: "eye.fill")
                    }
                    #if os(iOS)
                    SettingsValueRow(
                        title: "后台刷新",
                        value: backgroundRefreshStatusText,
                        systemImage: "arrow.clockwise.icloud"
                    )
                    if let warning = backgroundRefreshWarningText {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button {
                            openAppSettings()
                        } label: {
                            Label("打开应用设置", systemImage: "gearshape.fill")
                        }
                    }
                    #endif
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(notificationPermissionDenied ? .orange : .red)
                    #if os(iOS)
                    if notificationPermissionDenied {
                        Button {
                            openSystemNotificationSettings()
                        } label: {
                            Label("打开通知设置", systemImage: "gearshape.fill")
                        }
                    }
                    #endif
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    Label(isChecking ? "验证中" : "保存并验证", systemImage: "checkmark.circle.fill")
                }
                .disabled(!canSave)

                if let profile = mode.profile {
                    if profile.id != connectionStore.selectedID {
                        Button {
                            connectionStore.selectProfile(profile.id)
                            dismiss()
                        } label: {
                            Label("设为当前服务", systemImage: "checkmark.circle")
                        }
                    }
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("删除服务", systemImage: "trash.fill")
                    }
                }
            }
        }
        .navigationTitle(mode.isEditing ? "编辑服务" : "添加服务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !mode.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear { loadIfNeeded() }
        .confirmationDialog("删除该服务？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除服务", role: .destructive) {
                if let profile = mode.profile {
                    connectionStore.removeProfile(profile.id)
                }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除该服务保存的服务器地址、刷新设置和 Keychain 管理密钥。其它服务不受影响。")
        }
    }

    private var keyPlaceholder: String {
        mode.isEditing ? "管理密钥，留空保持当前密钥" : "Management key"
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let profile = mode.profile else {
            refreshMinutes = 5
            quotaAlertThreshold = 15
            return
        }
        name = profile.name
        baseURL = profile.baseURLString
        refreshMinutes = max(1, (profile.refreshIntervalSeconds / 60).rounded())
        quotaAlertsEnabled = profile.quotaAlertsEnabled
        quotaAlertThreshold = profile.quotaAlertThreshold
        quotaAlertShowsAccountNames = profile.quotaAlertShowsAccountNames
    }

    private func save() async {
        isChecking = true
        errorMessage = nil
        notificationPermissionDenied = false
        do {
            let normalizedURL = try CPABaseURLNormalizer.normalize(baseURL)
            let keyInput = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveKey: String
            if !keyInput.isEmpty {
                effectiveKey = keyInput
            } else if let id = mode.profile?.id,
                      let existing = connectionStore.managementKey(for: id), !existing.isEmpty {
                effectiveKey = existing
            } else {
                throw ConnectionError.emptyManagementKey
            }

            let client = CPAClient(baseURL: normalizedURL, managementKey: effectiveKey)
            _ = try await client.fetchDashboard(includeLiveUsage: false)

            var savedAlertsEnabled = quotaAlertsEnabled
            var savedShowsNames = quotaAlertShowsAccountNames
            if quotaAlertsEnabled {
                do {
                    let authorized = try await QuotaAlertNotifier.requestAuthorization()
                    let canSend = authorized ? await QuotaAlertNotifier.canSendAlerts() : false
                    if !canSend {
                        savedAlertsEnabled = false
                        savedShowsNames = false
                        quotaAlertsEnabled = false
                        quotaAlertShowsAccountNames = false
                        notificationPermissionDenied = true
                        errorMessage = "连接已验证；请允许通知后再开启低额度提醒"
                    }
                } catch {
                    savedAlertsEnabled = false
                    savedShowsNames = false
                    quotaAlertsEnabled = false
                    quotaAlertShowsAccountNames = false
                    notificationPermissionDenied = true
                    errorMessage = "连接已验证；通知设置暂不可用，低额度提醒已关闭"
                }
            }

            switch mode {
            case .add:
                try connectionStore.addProfile(
                    name: name,
                    baseURLString: normalizedURL.absoluteString,
                    managementKey: effectiveKey,
                    refreshIntervalSeconds: refreshMinutes * 60,
                    quotaAlertsEnabled: savedAlertsEnabled,
                    quotaAlertThreshold: quotaAlertThreshold,
                    quotaAlertShowsAccountNames: savedShowsNames
                )
            case let .edit(profile):
                try connectionStore.updateProfile(
                    id: profile.id,
                    name: name,
                    baseURLString: normalizedURL.absoluteString,
                    managementKey: keyInput.isEmpty ? nil : keyInput,
                    refreshIntervalSeconds: refreshMinutes * 60,
                    quotaAlertsEnabled: savedAlertsEnabled,
                    quotaAlertThreshold: quotaAlertThreshold,
                    quotaAlertShowsAccountNames: savedShowsNames
                )
            }

            if notificationPermissionDenied {
                isChecking = false
                managementKey = ""
                return
            }
            dismiss()
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 180)
        }
        isChecking = false
    }

    private var canSave: Bool {
        let hasURL = !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKeyInput = !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasStoredKey: Bool
        if let id = mode.profile?.id {
            hasStoredKey = connectionStore.managementKey(for: id)?.isEmpty == false
        } else {
            hasStoredKey = false
        }
        return !isChecking && hasURL && (hasKeyInput || hasStoredKey)
    }

    private var showsHTTPWarning: Bool {
        guard let normalizedURL = try? CPABaseURLNormalizer.normalize(baseURL) else {
            return false
        }
        return normalizedURL.scheme == "http"
    }

    #if os(iOS)
    @MainActor
    private var backgroundRefreshStatusText: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "可用"
        case .denied:
            return "已关闭"
        case .restricted:
            return "受限制"
        @unknown default:
            return "未知"
        }
    }

    @MainActor
    private var backgroundRefreshWarningText: String? {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return nil
        case .denied:
            return "后台刷新已关闭，低额度提醒仍可在前台刷新后触发。"
        case .restricted:
            return "系统限制后台刷新，低额度提醒仍可在前台刷新后触发。"
        @unknown default:
            return "无法确认后台刷新状态，低额度提醒仍可在前台刷新后触发。"
        }
    }

    @MainActor
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }

    @MainActor
    private func openSystemNotificationSettings() {
        if #available(iOS 16.0, *),
           let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
            return
        }
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }
    #endif
}

struct SettingsValueRow: View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var valueText: some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}
