import Foundation

public struct AccountHealthRatio: Equatable, Sendable {
    public let healthy: Int
    public let total: Int

    public init(healthy: Int, total: Int) {
        self.healthy = healthy
        self.total = total
    }

    public var displayValue: String { "\(healthy)/\(total)" }
    public var isFullyHealthy: Bool { total > 0 && healthy == total }
}

public extension AccountQuota {
    var isHealthy: Bool {
        !account.disabled && !account.unavailable && (errorMessage ?? "").isEmpty
    }
}

public extension Array where Element == AccountQuota {
    var healthRatio: AccountHealthRatio {
        AccountHealthRatio(healthy: filter(\.isHealthy).count, total: count)
    }
}

public enum ProviderQuotaMetricKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case codexFiveHour
    case codexSevenDay
    case claudeFiveHour
    case claudeSevenDay
    case antigravityGeminiFiveHour
    case antigravityGeminiSevenDay
    case antigravityClaudeGPTFiveHour
    case antigravityClaudeGPTSevenDay
    case xaiWeekly
    case xaiMonthly

    public var cardLabel: String {
        switch self {
        case .codexFiveHour, .claudeFiveHour: return "5h"
        case .codexSevenDay, .claudeSevenDay: return "7d"
        case .antigravityGeminiFiveHour: return "Gemini 5h"
        case .antigravityGeminiSevenDay: return "Gemini 7d"
        case .antigravityClaudeGPTFiveHour: return "Claude/GPT 5h"
        case .antigravityClaudeGPTSevenDay: return "Claude/GPT 7d"
        case .xaiWeekly: return "周积分"
        case .xaiMonthly: return "月积分"
        }
    }

    public static func metrics(for providerKey: String) -> [ProviderQuotaMetricKind] {
        switch ProviderCatalog.info(for: providerKey).key {
        case "codex", "openai":
            return [.codexFiveHour, .codexSevenDay]
        case "claude":
            return [.claudeFiveHour, .claudeSevenDay]
        case "antigravity":
            return [
                .antigravityGeminiFiveHour,
                .antigravityGeminiSevenDay,
                .antigravityClaudeGPTFiveHour,
                .antigravityClaudeGPTSevenDay
            ]
        case "xai":
            return [.xaiWeekly, .xaiMonthly]
        default:
            return []
        }
    }

    public func matchingWindows(in account: AccountQuota) -> [QuotaWindow] {
        guard let usage = account.usage else { return [] }
        let providerKey = ProviderCatalog.info(for: account.account.normalizedProvider).key
        guard Self.metrics(for: providerKey).contains(self) else { return [] }

        switch self {
        case .codexFiveHour:
            return usage.primary.map { [$0] } ?? []
        case .codexSevenDay:
            guard let weekly = usage.weekly, !Self.isMonthly(weekly) else { return [] }
            return [weekly]
        case .claudeFiveHour:
            return usage.additionalWindows.filter { $0.id == "claude-five-hour" }
        case .claudeSevenDay:
            return usage.additionalWindows.filter { $0.id == "claude-seven-day" }
        case .xaiWeekly:
            return usage.additionalWindows.filter { $0.id == "xai-weekly-credits" }
        case .xaiMonthly:
            return usage.additionalWindows.filter { $0.id == "xai-monthly-credits" }
        case .antigravityGeminiFiveHour:
            return Self.antigravityWindows(in: usage, family: .gemini, period: .fiveHour)
        case .antigravityGeminiSevenDay:
            return Self.antigravityWindows(in: usage, family: .gemini, period: .sevenDay)
        case .antigravityClaudeGPTFiveHour:
            return Self.antigravityWindows(in: usage, family: .claudeGPT, period: .fiveHour)
        case .antigravityClaudeGPTSevenDay:
            return Self.antigravityWindows(in: usage, family: .claudeGPT, period: .sevenDay)
        }
    }

    public func remainingPercent(in account: AccountQuota) -> Double? {
        let values = matchingWindows(in: account).compactMap(\.remainingPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public func averagedWindow(in account: AccountQuota) -> QuotaWindow? {
        let windows = matchingWindows(in: account)
        guard let remainingPercent = remainingPercent(in: account) else { return nil }
        let resetAt = windows.compactMap(\.resetAt).min()
        let resetAfter = windows.compactMap(\.resetAfterSeconds).min()
        let details = uniqueStrings(windows.compactMap(\.detailText))
        return QuotaWindow(
            id: "dashboard-\(rawValue)",
            label: cardLabel,
            usedPercent: max(0, min(100, 100 - remainingPercent)),
            remainingPercent: max(0, min(100, remainingPercent)),
            resetAfterSeconds: resetAfter,
            resetAt: resetAt,
            displayValue: displayPercent(remainingPercent),
            amountText: nil,
            detailText: details.count == 1 ? details[0] : nil,
            isUsable: remainingPercent > 0
        )
    }

    private enum AntigravityFamily {
        case gemini
        case claudeGPT
    }

    private enum QuotaPeriod {
        case fiveHour
        case sevenDay
    }

    private static func antigravityWindows(
        in usage: UsageSnapshot,
        family: AntigravityFamily,
        period: QuotaPeriod
    ) -> [QuotaWindow] {
        usage.additionalWindows.filter { window in
            let text = [window.id, window.label, window.detailText ?? ""]
                .joined(separator: " ")
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")

            let familyMatches: Bool
            switch family {
            case .gemini:
                familyMatches = text.contains("gemini")
            case .claudeGPT:
                familyMatches = text.contains("claude") || text.contains("gpt")
            }
            guard familyMatches else { return false }

            switch period {
            case .fiveHour:
                return ["5h", "5 hour", "5-hour", "five hour", "five-hour"]
                    .contains { text.contains($0) }
            case .sevenDay:
                return ["7d", "7 day", "7-day", "seven day", "seven-day", "weekly", "week"]
                    .contains { text.contains($0) }
            }
        }
    }

    private static func isMonthly(_ window: QuotaWindow) -> Bool {
        let text = "\(window.id) \(window.label)".lowercased()
        return text.contains("month") || text.contains("月")
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

public struct ProviderQuotaAverage: Equatable, Sendable {
    public let kind: ProviderQuotaMetricKind
    public let remainingPercent: Double?
    public let contributingAccounts: Int

    public init(kind: ProviderQuotaMetricKind, remainingPercent: Double?, contributingAccounts: Int) {
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.contributingAccounts = contributingAccounts
    }
}

public enum DashboardMetrics {
    public static func quotaAverages(
        providerKey: String,
        accounts: [AccountQuota]
    ) -> [ProviderQuotaAverage] {
        ProviderQuotaMetricKind.metrics(for: providerKey).map { kind in
            let values = accounts.compactMap { kind.remainingPercent(in: $0) }
            return ProviderQuotaAverage(
                kind: kind,
                remainingPercent: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                contributingAccounts: values.count
            )
        }
    }
}
