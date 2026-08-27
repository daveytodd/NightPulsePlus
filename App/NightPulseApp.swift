import SwiftUI

@main
struct NightPulseApp: App {
    @StateObject private var accessManager = AccessManager.shared
    @State private var migrationResult: Bool?
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environmentObject(accessManager)
                .onOpenURL { url in migrationResult = accessManager.redeem(url: url) }
                .sheet(isPresented: Binding(get: { migrationResult != nil }, set: { if !$0 { migrationResult = nil } })) {
                    MigrationResultView(didUnlock: migrationResult ?? false)
                }
        }
    }
}
