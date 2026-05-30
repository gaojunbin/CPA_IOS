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

/// Shared corner-radius scale so every surface uses the same soft, continuous curve.
enum CPALayout {
    /// Primary elevated cards (sections, rows, metric tiles).
    static let cardRadius: CGFloat = 20
    /// Nested rows, callouts and tinted insets within a card.
    static let innerRadius: CGFloat = 14
    /// Text-input surfaces.
    static let fieldRadius: CGFloat = 14
    /// Small square provider/icon chips.
    static let chipRadius: CGFloat = 11
}

extension View {
    /// Primary elevated surface: translucent material, soft continuous corners,
    /// a hairline border for definition, and a restrained drop shadow for depth.
    func cpaCard(cornerRadius: CGFloat = CPALayout.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.05), radius: 9, x: 0, y: 4)
    }

    /// Tinted inset surface for nested rows, banners and callouts inside a card.
    func cpaInset(_ fill: Color, cornerRadius: CGFloat = CPALayout.innerRadius) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Text-input surface that adapts to light/dark like a system field.
    func cpaFieldSurface(cornerRadius: CGFloat = CPALayout.fieldRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.background, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

extension View {
    @ViewBuilder
    func onScenePhaseChange(
        _ phase: ScenePhase,
        perform action: @escaping (ScenePhase) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            onChange(of: phase) { _, newPhase in
                action(newPhase)
            }
        } else {
            onChange(of: phase) { newPhase in
                action(newPhase)
            }
        }
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

func providerIcon(_ provider: String) -> String {
    if provider == "all" {
        return "circle.grid.2x2"
    }
    return ProviderCatalog.info(for: provider).symbolName
}

func providerTint(_ provider: String) -> Color {
    if provider == "all" {
        return .secondary
    }
    return providerAccentColor(ProviderCatalog.info(for: provider).accentName)
}

private func providerAccentColor(_ accentName: String) -> Color {
    switch accentName {
    case "teal":
        return .teal
    case "mint":
        return .mint
    case "orange":
        return .orange
    case "blue":
        return .blue
    case "indigo":
        return .indigo
    case "purple":
        return .purple
    case "gray":
        return .gray
    case "pink":
        return .pink
    case "green":
        return .green
    case "red":
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

func quotaTint(_ percent: Double?, isUsable: Bool? = nil) -> Color {
    if isUsable == false {
        return .red
    }
    guard let percent, percent.isFinite else {
        return .secondary
    }
    if percent <= 15 {
        return .red
    }
    if percent <= 35 {
        return .orange
    }
    return .green
}

func quotaResetText(_ window: QuotaWindow) -> String? {
    if let detail = normalizedQuotaResetDetail(window.detailText) {
        return detail
    }
    if let seconds = window.resetAfterSeconds {
        return normalizedQuotaResetDetail(displayDuration(seconds: seconds))
    }
    if let resetAt = window.resetAt {
        let remaining = resetAt.timeIntervalSinceNow
        return remaining > 0 ? displayDuration(seconds: remaining) : "现在"
    }
    return nil
}

private func normalizedQuotaResetDetail(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
        return nil
    }
    let normalized = trimmed.lowercased()
    guard normalized != "-" && normalized != "--" && normalized != "unknown" && normalized != "none" else {
        return nil
    }
    return trimmed
}

struct QuotaWindowMetadataLabels: View {
    let window: QuotaWindow
    let font: Font

    var body: some View {
        if hasMetadata {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    labels
                }

                VStack(alignment: .leading, spacing: 4) {
                    labels
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private var hasMetadata: Bool {
        let hasAmount = window.amountText?.isEmpty == false
        let hasReset = resetText?.isEmpty == false
        return hasAmount || hasReset
    }

    private var resetText: String? {
        quotaResetText(window)
    }

    @ViewBuilder
    private var labels: some View {
        if let amountText = window.amountText, !amountText.isEmpty {
            Label(amountText, systemImage: "number")
        }
        if let resetText, !resetText.isEmpty {
            Label(resetText, systemImage: "clock")
        }
    }
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
