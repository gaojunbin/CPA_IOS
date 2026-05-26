import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: ManagementDashboard?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedStatus: CPAStatusKind = .all
    @Published var selectedProvider = "all"

    func refresh(using connection: SavedConnection) async {
        isLoading = true
        errorMessage = nil
        do {
            let client = CPAClient(baseURL: connection.baseURL, managementKey: connection.managementKey)
            snapshot = try await client.fetchDashboard()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var accounts: [CPAAccount] {
        snapshot?.accounts ?? []
    }

    var providers: [String] {
        let values = Set(accounts.map { $0.providerName.lowercased() })
        return ["all"] + values.sorted()
    }

    var filteredAccounts: [CPAAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return accounts.filter { account in
            let matchesProvider = selectedProvider == "all" || account.providerName.lowercased() == selectedProvider
            let matchesStatus = selectedStatus == .all || account.statusKind == selectedStatus
            let matchesQuery = query.isEmpty ||
                account.displayName.lowercased().contains(query) ||
                account.providerName.lowercased().contains(query) ||
                (account.email?.lowercased().contains(query) ?? false) ||
                (account.projectID?.lowercased().contains(query) ?? false) ||
                (account.account?.lowercased().contains(query) ?? false)
            return matchesProvider && matchesStatus && matchesQuery
        }
        .sorted { lhs, rhs in
            if lhs.statusKind != rhs.statusKind {
                return lhs.statusKind.sortOrder < rhs.statusKind.sortOrder
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var summary: DashboardSummary {
        DashboardSummary(accounts: accounts)
    }
}

struct DashboardSummary: Equatable {
    let total: Int
    let available: Int
    let cooling: Int
    let disabled: Int
    let error: Int
    let success: Int64
    let failed: Int64

    init(accounts: [CPAAccount]) {
        total = accounts.count
        available = accounts.filter { $0.statusKind == .available }.count
        cooling = accounts.filter { $0.statusKind == .cooling }.count
        disabled = accounts.filter { $0.statusKind == .disabled }.count
        error = accounts.filter { $0.statusKind == .error }.count
        success = accounts.reduce(0) { $0 + $1.success }
        failed = accounts.reduce(0) { $0 + $1.failed }
    }

    var totalRequests: Int64 {
        success + failed
    }

    var successRate: Double {
        guard totalRequests > 0 else {
            return 0
        }
        return Double(success) / Double(totalRequests)
    }
}

extension CPAStatusKind {
    var title: String {
        switch self {
        case .all:
            return "全部"
        case .available:
            return "可用"
        case .cooling:
            return "冷却"
        case .pending:
            return "处理中"
        case .error:
            return "异常"
        case .disabled:
            return "停用"
        case .unknown:
            return "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "circle.grid.2x2"
        case .available:
            return "checkmark.seal.fill"
        case .cooling:
            return "hourglass"
        case .pending:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "pause.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var sortOrder: Int {
        switch self {
        case .cooling:
            return 0
        case .error:
            return 1
        case .pending:
            return 2
        case .available:
            return 3
        case .unknown:
            return 4
        case .disabled:
            return 5
        case .all:
            return 6
        }
    }
}
