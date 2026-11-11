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
    @EnvironmentObject private var store: Store

    var body: some View {
        TabView(selection: $store.tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Quests", systemImage: "checklist") }
                .tag(AppTab.quests)
            NavigationStack { ManuscriptView() }
                .tabItem { Label("Manuscript", systemImage: "doc.richtext") }
                .tag(AppTab.manuscript)
            NavigationStack { ChatView() }
                .tabItem { Label("Ask", systemImage: "sparkles") }
                .tag(AppTab.ask)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .overlay { CelebrationOverlay() }
    }
}
