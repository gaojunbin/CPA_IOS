import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var onPreview: (() -> Void)?

    @State private var baseURL = ""
    @State private var managementKey = ""
    @State private var refreshMinutes = 5.0
    @State private var quotaAlertsEnabled = false
    @State private var quotaAlertThreshold = 15.0
    @State private var quotaAlertShowsAccountNames = false
    @State private var errorMessage: String?
    @State private var notificationPermissionDenied = false
    @State private var notificationCapabilitySummary: NotificationCapabilitySummary?
    @State private var confirmsClearConnection = false
    @State private var isChecking = false
    @State private var diagnosticsCopied = false

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    TextField("服务器", text: $baseURL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .privacySensitive()
                    SecureField("管理密钥，留空保持当前密钥", text: $managementKey)
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

                    SettingsValueRow(
                        title: "通知权限",
                        value: notificationCapabilitySummary?.localizedStatusText ?? "读取中",
                        systemImage: "bell.badge.fill"
                    )

                    Toggle(isOn: $quotaAlertsEnabled) {
                        Label("低额度提醒", systemImage: "bell.badge.fill")
                    }
                    if quotaAlertsEnabled {
                        Toggle(isOn: $quotaAlertShowsAccountNames) {
                            Label("通知显示账号名称", systemImage: "eye.fill")
                        }
                        SettingsValueRow(
                            title: "后台刷新",
                            value: backgroundRefreshStatusText,
                            systemImage: "arrow.clockwise.icloud"
                        )
                        if let warning = backgroundRefreshWarningText {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            #if os(iOS)
                            Button {
                                openAppSettings()
                            } label: {
                                Label("打开应用设置", systemImage: "gearshape.fill")
                            }
                            #endif
                        }
                    }
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
                        Task {
                            await copyDiagnostics()
                        }
                    } label: {
                        Label("复制诊断信息", systemImage: "doc.on.doc.fill")
                    }

                    if diagnosticsCopied {
                        Label("已复制，不包含管理密钥", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
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
                        Task {
                            await save()
                        }
                    } label: {
                        Label(isChecking ? "验证中" : "保存并验证", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave)

                    Button(role: .destructive) {
                        confirmsClearConnection = true
                    } label: {
                        Label("清除连接", systemImage: "trash.fill")
                    }
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                loadStoredSettings()
            }
            .task {
                let disabledAlerts = await connectionStore.reconcileQuotaAlertAuthorization()
                await refreshNotificationCapabilitySummary()
                if disabledAlerts {
                    loadStoredSettings()
                    notificationPermissionDenied = true
                    errorMessage = "通知权限不可用，低额度提醒已关闭"
                }
            }
            .confirmationDialog("清除连接？", isPresented: $confirmsClearConnection, titleVisibility: .visible) {
                Button("清除连接", role: .destructive) {
                    connectionStore.clear()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除本机保存的服务器地址、刷新设置和 Keychain 管理密钥。")
            }
        }
    }

    private func loadStoredSettings() {
        baseURL = connectionStore.connection?.baseURL.absoluteString ?? connectionStore.lastBaseURLString
        refreshMinutes = max(1, (connectionStore.refreshIntervalSeconds / 60).rounded())
        quotaAlertsEnabled = connectionStore.quotaAlertsEnabled
        quotaAlertThreshold = connectionStore.quotaAlertThreshold
        quotaAlertShowsAccountNames = connectionStore.quotaAlertShowsAccountNames
    }

    private func save() async {
        isChecking = true
        errorMessage = nil
        notificationPermissionDenied = false
        do {
            let normalizedURL = try CPABaseURLNormalizer.normalize(baseURL)
            let keyInput = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = keyInput.isEmpty ? connectionStore.connection?.managementKey ?? "" : keyInput
            guard !key.isEmpty else {
                throw ConnectionError.emptyManagementKey
            }
            let client = CPAClient(baseURL: normalizedURL, managementKey: key)
            _ = try await client.fetchDashboard(includeLiveUsage: false)
            var savedAlertsEnabled = quotaAlertsEnabled
            var savedAlertShowsAccountNames = quotaAlertShowsAccountNames
            if quotaAlertsEnabled {
                do {
                    let authorized = try await QuotaAlertNotifier.requestAuthorization()
                    let canSendAlerts = authorized ? await QuotaAlertNotifier.canSendAlerts() : false
                    if !canSendAlerts {
                        savedAlertsEnabled = false
                        savedAlertShowsAccountNames = false
                        quotaAlertsEnabled = false
                        quotaAlertShowsAccountNames = false
                        notificationPermissionDenied = true
                        errorMessage = "连接和刷新设置已保存；请允许通知后再开启低额度提醒"
                    }
                } catch {
                    savedAlertsEnabled = false
                    savedAlertShowsAccountNames = false
                    quotaAlertsEnabled = false
                    quotaAlertShowsAccountNames = false
                    notificationPermissionDenied = true
                    errorMessage = "连接和刷新设置已保存；通知设置暂不可用，低额度提醒已关闭"
                }
            }
            await refreshNotificationCapabilitySummary()
            try connectionStore.save(
                baseURLString: normalizedURL.absoluteString,
                managementKey: key,
                refreshIntervalSeconds: refreshMinutes * 60,
                quotaAlertsEnabled: savedAlertsEnabled,
                quotaAlertThreshold: quotaAlertThreshold,
                quotaAlertShowsAccountNames: savedAlertShowsAccountNames
            )
            managementKey = ""
            loadStoredSettings()
            if notificationPermissionDenied {
                isChecking = false
                return
            }
            dismiss()
        } catch {
            if case ConnectionError.notificationPermissionDenied = error {
                notificationPermissionDenied = true
            } else {
                notificationPermissionDenied = false
            }
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 180)
        }
        isChecking = false
    }

    private var canSave: Bool {
        let hasURL = !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKeyInput = !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasStoredKey = connectionStore.connection?.managementKey.isEmpty == false
        return !isChecking && hasURL && (hasKeyInput || hasStoredKey)
    }

    private var showsHTTPWarning: Bool {
        guard let normalizedURL = try? CPABaseURLNormalizer.normalize(baseURL) else {
            return false
        }
        return normalizedURL.scheme == "http"
    }

    @MainActor
    private func copyDiagnostics() async {
        await refreshNotificationCapabilitySummary()
        let diagnostics = supportDiagnostics()
        #if os(iOS)
        UIPasteboard.general.string = diagnostics
        #endif
        diagnosticsCopied = true
    }

    private func supportDiagnostics() -> String {
        let currentConnection = connectionStore.connection
        let diagnosticURL = currentConnection?.baseURL ?? (try? CPABaseURLNormalizer.normalize(baseURL))
        let version = bundleValue("CFBundleShortVersionString")
        let build = bundleValue("CFBundleVersion")
        let hasStoredKey = currentConnection?.managementKey.isEmpty == false
        let hasPendingKey = !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return [
            "CPA Panel Diagnostics",
            "Generated At: \(diagnosticsTimestamp())",
            "App Version: \(version)",
            "Build: \(build)",
            "Connection Configured: \(currentConnection == nil ? "no" : "yes")",
            "Server URL: \(redactedURLString(diagnosticURL))",
            "Refresh Interval Minutes: \(Int(refreshMinutes.rounded()))",
            "Low Quota Alerts Enabled: \(quotaAlertsEnabled ? "yes" : "no")",
            "Attention Threshold: \(Int(quotaAlertThreshold.rounded()))%",
            "Detailed Notification Text: \(quotaAlertShowsAccountNames ? "yes" : "no")",
            "Background Refresh Status: \(backgroundRefreshStatusDiagnosticsText)",
            notificationCapabilitySummary?.diagnosticsLines.joined(separator: "\n") ?? "Notification Status: unknown",
            "Stored Management Key Present: \(hasStoredKey ? "yes" : "no")",
            "Unsaved Management Key Present: \(hasPendingKey ? "yes" : "no")",
            "Management Key Included: no"
        ].joined(separator: "\n")
    }

    private func redactedURLString(_ url: URL?) -> String {
        guard let url else {
            return "none"
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private func diagnosticsTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    @MainActor
    private func refreshNotificationCapabilitySummary() async {
        notificationCapabilitySummary = await QuotaAlertNotifier.currentCapabilitySummary()
    }

    @MainActor
    private var backgroundRefreshStatusText: String {
        #if os(iOS)
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
        #else
        return "不可用"
        #endif
    }

    @MainActor
    private var backgroundRefreshStatusDiagnosticsText: String {
        #if os(iOS)
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "available"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
        #else
        return "unavailable"
        #endif
    }

    @MainActor
    private var backgroundRefreshWarningText: String? {
        #if os(iOS)
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
        #else
        return nil
        #endif
    }

    #if os(iOS)
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
