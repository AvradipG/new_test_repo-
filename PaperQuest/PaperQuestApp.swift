import SwiftUI

@main
struct PaperQuestApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Palette.accent)
                .task { await store.checkForUpdate() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pull other devices' changes (and Claude's inbox) on open; push on the way out.
            if phase == .active || phase == .background {
                store.refreshDriveAccount()
                Task { await store.syncDrive() }
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Quests", systemImage: "checklist") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay { CelebrationOverlay() }
    }
}
