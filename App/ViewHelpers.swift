import Foundation
import SwiftUI

extension Color {
    static var cpaSystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var cpaSecondaryBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

extension CPAStatusKind {
    var tint: Color {
        switch self {
        case .all:
            return .teal
        case .available:
            return .green
        case .cooling:
            return .orange
        case .pending:
            return .blue
        case .error:
            return .red
        case .disabled:
            return .gray
        case .unknown:
            return .secondary
        }
    }
}

extension CPAAccount {
    var quotaLine: String {
        switch statusKind {
        case .available:
            if let credits = antigravityCredits, credits.known {
                return credits.available ? "Credits \(compactNumber(credits.creditAmount))" : "Credits 不足"
            }
            return "额度可用"
        case .cooling:
            if let credits = antigravityCredits, credits.known, !credits.available {
                return "Credits 不足"
            }
            if let nextRecoveryDate {
                return "冷却至 \(shortTime(nextRecoveryDate))"
            }
            return quota?.reason ?? "额度受限"
        case .pending:
            return "刷新中"
        case .error:
            return statusMessage ?? lastError?.message ?? "异常"
        case .disabled:
            return "已停用"
        case .unknown:
            return "未知"
        case .all:
            return ""
        }
    }
}

func providerIcon(_ provider: String) -> String {
    switch provider.lowercased() {
    case "gemini", "gemini-cli", "antigravity", "vertex":
        return "sparkles"
    case "codex", "openai":
        return "curlybraces.square.fill"
    case "claude", "anthropic":
        return "text.bubble.fill"
    case "kimi":
        return "moon.stars.fill"
    case "xai":
        return "xmark.seal.fill"
    case "all":
        return "circle.grid.2x2"
    default:
        return "key.fill"
    }
}

func providerTint(_ provider: String) -> Color {
    switch provider.lowercased() {
    case "gemini", "gemini-cli", "antigravity", "vertex":
        return .teal
    case "codex", "openai":
        return .green
    case "claude", "anthropic":
        return .indigo
    case "kimi":
        return .purple
    case "xai":
        return .red
    default:
        return .secondary
    }
}

func percent(_ value: Double) -> String {
    guard value.isFinite else {
        return "0%"
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .percent
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "0%"
}

func shortTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func absoluteTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

func compactNumber(_ value: Double?) -> String {
    guard let value else {
        return "-"
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = value >= 100 ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func creditsLine(_ credits: AntigravityCredits) -> String {
    let amount = compactNumber(credits.creditAmount)
    let minimum = compactNumber(credits.minCreditAmount)
    let state = credits.available ? "可用" : "不足"
    if let tier = credits.paidTierID, !tier.isEmpty {
        return "\(state) · \(amount) / \(minimum) · \(tier)"
    }
    return "\(state) · \(amount) / \(minimum)"
}
