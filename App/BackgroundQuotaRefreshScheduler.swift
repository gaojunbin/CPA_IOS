import Foundation

#if os(iOS)
@preconcurrency import BackgroundTasks

@MainActor
enum BackgroundQuotaRefreshScheduler {
    static let taskIdentifier = "com.rootclaw.CPAPanel.quota-refresh"

    private static let minimumRefreshInterval: TimeInterval = 15 * 60
    private static let maximumRefreshInterval: TimeInterval = 6 * 60 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: DispatchQueue.main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func reschedule(for connection: SavedConnection?) {
        cancel()
        guard let connection, connection.quotaAlertsEnabled else {
            return
        }
        schedule(after: connection.refreshIntervalSeconds)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let connection = ConnectionStore.loadSavedConnectionFromStorage()
        reschedule(for: connection)

        guard let connection, connection.quotaAlertsEnabled else {
            task.setTaskCompleted(success: true)
            return
        }

        let refreshTask = Task {
            await refreshAndNotify(using: connection)
        }
        task.expirationHandler = {
            refreshTask.cancel()
        }
        Task {
            let success = await refreshTask.value
            task.setTaskCompleted(success: success)
        }
    }

    private static func schedule(after interval: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: boundedRefreshInterval(interval))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The system may reject scheduling when Background App Refresh is disabled.
        }
    }

    private static func boundedRefreshInterval(_ interval: TimeInterval) -> TimeInterval {
        max(minimumRefreshInterval, min(interval, maximumRefreshInterval))
    }

    private static func refreshAndNotify(using connection: SavedConnection) async -> Bool {
        guard await QuotaAlertNotifier.canSendAlerts() else {
            ConnectionStorage.disableQuotaAlerts()
            QuotaAlertNotifier.resetAlertHistory()
            cancel()
            return true
        }

        let client = CPAClient(baseURL: connection.baseURL, managementKey: connection.managementKey)
        do {
            let dashboard = try await client.fetchDashboard(includeLiveUsage: true)
            guard !Task.isCancelled else {
                return false
            }
            await QuotaAlertNotifier.notifyIfNeeded(
                accounts: dashboard.accountQuotas,
                threshold: connection.quotaAlertThreshold,
                source: connection.baseURL.host ?? connection.baseURL.absoluteString,
                showsAccountNames: connection.quotaAlertShowsAccountNames
            )
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch {
            return false
        }
    }
}
#endif
