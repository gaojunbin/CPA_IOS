import Foundation
import UserNotifications

enum QuotaAlertNotifier {
    private static let lastFingerprintKey = "cpa.quotaAlert.lastFingerprint"
    private static let lastDateKey = "cpa.quotaAlert.lastDate"
    static let notificationIdentifier = "cpa.quota-alert"
    private static let minimumRepeatInterval: TimeInterval = 30 * 60

    static func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static func canSendAlerts() async -> Bool {
        let capabilities = await notificationCapabilities()
        return capabilities.canSendNotification
    }

    static func currentCapabilitySummary() async -> NotificationCapabilitySummary {
        await notificationCapabilities().summary
    }

    static func notifyIfNeeded(
        accounts: [AccountQuota],
        threshold: Double,
        source: String,
        showsAccountNames: Bool
    ) async {
        let candidates = alertCandidates(accounts: accounts, threshold: threshold)
        guard !candidates.isEmpty else {
            forgetRememberedAlert()
            await clearBadgeAndNotifications()
            return
        }

        let capabilities = await notificationCapabilities()
        guard capabilities.canSendNotification else {
            forgetRememberedAlert()
            await clearBadgeAndNotifications()
            return
        }
        if capabilities.canUpdateBadge {
            await updateBadgeCount(candidates.count)
        } else {
            await updateBadgeCount(0)
        }

        let fingerprint = alertFingerprint(candidates)
        guard shouldSendAlert(fingerprint: fingerprint) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = candidates.count == 1 ? "CPA 账号需要关注" : "\(candidates.count) 个 CPA 账号需要关注"
        content.subtitle = showsAccountNames ? source : "本地提醒"
        content.body = alertBody(candidates, threshold: threshold, showsAccountNames: showsAccountNames)
        content.sound = .default
        content.badge = capabilities.canUpdateBadge ? NSNumber(value: candidates.count) : nil

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await add(request)
            rememberAlert(fingerprint: fingerprint)
        } catch {
            forgetRememberedAlert()
            await clearBadgeAndNotifications()
        }
    }

    static func resetAlertHistory() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastFingerprintKey)
        defaults.removeObject(forKey: lastDateKey)
        Task {
            await clearBadgeAndNotifications()
        }
    }

    static func clearBadgeIfNeeded(alertsEnabled: Bool) {
        Task {
            guard alertsEnabled else {
                await clearBadgeAndNotifications()
                return
            }
            let capabilities = await notificationCapabilities()
            if !capabilities.canSendNotification {
                await clearBadgeAndNotifications()
            } else if !capabilities.canUpdateBadge {
                await updateBadgeCount(0)
            }
        }
    }

    private static func alertCandidates(accounts: [AccountQuota], threshold: Double) -> [AccountQuota] {
        accounts
            .filter { $0.needsQuotaAlert(threshold: threshold) }
            .sorted { alertSort($0, $1, threshold: threshold) }
    }

    private static func alertSort(_ lhs: AccountQuota, _ rhs: AccountQuota, threshold: Double) -> Bool {
        let leftRank = alertRank(lhs, threshold: threshold)
        let rightRank = alertRank(rhs, threshold: threshold)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        switch (lhs.lowestRemainingPercent, rhs.lowestRemainingPercent) {
        case let (.some(left), .some(right)) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return stableAccountIdentitySort(lhs.account, rhs.account)
        }
    }

    private static func alertRank(_ account: AccountQuota, threshold: Double) -> Int {
        if (account.errorMessage ?? "").isEmpty == false || account.statusKind == .error {
            return 0
        }
        if account.hasUnusableQuotaWindow || account.statusKind == .cooling {
            return 1
        }
        let criticalThreshold = min(15, threshold)
        if let lowest = account.lowestRemainingPercent, lowest <= criticalThreshold {
            return 2
        }
        if let lowest = account.lowestRemainingPercent, lowest <= threshold {
            return 3
        }
        return 4
    }

    private static func alertBody(
        _ candidates: [AccountQuota],
        threshold: Double,
        showsAccountNames: Bool
    ) -> String {
        guard showsAccountNames else {
            return privateAlertBody(candidates, threshold: threshold)
        }

        let visible = candidates.prefix(3).map { account in
            "\(account.account.displayName): \(account.quotaAlertReason)"
        }
        var lines = Array(visible)
        if candidates.count > visible.count {
            lines.append("另有 \(candidates.count - visible.count) 个账号需要处理。")
        }
        return lines.joined(separator: "\n")
    }

    private static func privateAlertBody(_ candidates: [AccountQuota], threshold: Double) -> String {
        let errorCount = candidates.filter { ($0.errorMessage ?? "").isEmpty == false || $0.statusKind == .error }.count
        let coolingCount = candidates.filter {
            ($0.errorMessage ?? "").isEmpty &&
                $0.statusKind == .cooling
        }.count
        let lowCount = candidates.count - errorCount - coolingCount
        let parts = [
            errorCount > 0 ? "\(errorCount) 异常" : nil,
            coolingCount > 0 ? "\(coolingCount) 冷却" : nil,
            lowCount > 0 ? "\(lowCount) 低于 \(Int(threshold.rounded()))%" : nil
        ].compactMap { $0 }
        return "发现 \(candidates.count) 个账号需要关注：\(parts.joined(separator: "、"))。打开 CPA 面板查看详情。"
    }

    private static func alertFingerprint(_ candidates: [AccountQuota]) -> String {
        candidates.prefix(5).map { account in
            let raw = [
                alertIdentity(for: account),
                account.statusKind.rawValue,
                String(Int((account.lowestRemainingPercent ?? -1).rounded())),
                account.quotaAlertReason
            ].joined(separator: ":")
            return stableHash(raw)
        }
        .joined(separator: "|")
    }

    private static func alertIdentity(for account: AccountQuota) -> String {
        [
            account.account.id,
            account.account.authIndex ?? "",
            account.account.name,
            account.account.providerName
        ].joined(separator: "\u{1F}")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private static func shouldSendAlert(fingerprint: String) -> Bool {
        let defaults = UserDefaults.standard
        let lastFingerprint = defaults.string(forKey: lastFingerprintKey)
        let lastDate = defaults.object(forKey: lastDateKey) as? Date
        guard lastFingerprint == fingerprint,
              let lastDate,
              Date().timeIntervalSince(lastDate) < minimumRepeatInterval
        else {
            return true
        }
        return false
    }

    private static func rememberAlert(fingerprint: String) {
        let defaults = UserDefaults.standard
        defaults.set(fingerprint, forKey: lastFingerprintKey)
        defaults.set(Date(), forKey: lastDateKey)
    }

    private static func forgetRememberedAlert() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastFingerprintKey)
        defaults.removeObject(forKey: lastDateKey)
    }

    private static func notificationCapabilities() async -> NotificationCapabilities {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let canSendNotification = canSendNotification(
                    status: settings.authorizationStatus,
                    alertSetting: settings.alertSetting
                )
                let canUpdateBadge = canSendNotification && settings.badgeSetting == .enabled
                continuation.resume(returning: NotificationCapabilities(
                    canSendNotification: canSendNotification,
                    canUpdateBadge: canUpdateBadge,
                    summary: NotificationCapabilitySummary(
                        authorizationStatus: authorizationStatusText(settings.authorizationStatus),
                        alertSetting: notificationSettingText(settings.alertSetting),
                        badgeSetting: notificationSettingText(settings.badgeSetting),
                        canSendNotification: canSendNotification,
                        canUpdateBadge: canUpdateBadge
                    )
                ))
            }
        }
    }

    private static func canSendNotification(
        status: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting
    ) -> Bool {
        guard alertSetting == .enabled else {
            return false
        }
        switch status {
        case .authorized, .provisional:
            return true
        #if os(iOS)
        case .ephemeral:
            return true
        #endif
        default:
            return false
        }
    }

    private static func authorizationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        #if os(iOS)
        case .ephemeral:
            return "ephemeral"
        #endif
        @unknown default:
            return "unknown"
        }
    }

    private static func notificationSettingText(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported:
            return "notSupported"
        case .disabled:
            return "disabled"
        case .enabled:
            return "enabled"
        @unknown default:
            return "unknown"
        }
    }

    private static func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func updateBadgeCount(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in
                continuation.resume()
            }
        }
    }

    private static func clearBadgeAndNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        await updateBadgeCount(0)
    }
}

private struct NotificationCapabilities: Sendable {
    let canSendNotification: Bool
    let canUpdateBadge: Bool
    let summary: NotificationCapabilitySummary
}

struct NotificationCapabilitySummary: Equatable, Sendable {
    let authorizationStatus: String
    let alertSetting: String
    let badgeSetting: String
    let canSendNotification: Bool
    let canUpdateBadge: Bool

    var localizedStatusText: String {
        if canSendNotification {
            return canUpdateBadge ? "提醒和角标可用" : "提醒可用，角标关闭"
        }
        switch authorizationStatus {
        case "notDetermined":
            return "未请求"
        case "denied":
            return "已拒绝"
        case "authorized", "provisional", "ephemeral":
            return "通知样式关闭"
        default:
            return "不可用"
        }
    }

    var diagnosticsLines: [String] {
        [
            "Notification Status: \(localizedStatusText)",
            "Notification Authorization: \(authorizationStatus)",
            "Notification Alert Setting: \(alertSetting)",
            "Notification Badge Setting: \(badgeSetting)",
            "Notification Alerts Available: \(canSendNotification ? "yes" : "no")",
            "Notification Badge Available: \(canUpdateBadge ? "yes" : "no")"
        ]
    }
}
