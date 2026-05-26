import SwiftUI

@main
struct CPAIOSApp: App {
    @StateObject private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connectionStore)
        }
    }
}
