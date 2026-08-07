import SwiftUI

@main
struct DiskTidyApp: App {
    @StateObject private var navState = AppNavigationState()
    @StateObject private var storageMonitor = StorageMonitor()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(navState)
                .environmentObject(storageMonitor)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(storageMonitor)
        } label: {
            Text("💾 \(storageMonitor.percentUsedText)")
        }
        .menuBarExtraStyle(.window)
    }
}
