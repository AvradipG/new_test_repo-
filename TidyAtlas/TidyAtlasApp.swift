import SwiftData
import SwiftUI

@main
struct TidyAtlasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.organizer)
                .tint(Palette.teal)
                .task { await delegate.organizer.checkForUpdate() }
        }
        .modelContainer(delegate.container)
        .onChange(of: scenePhase) { _, phase in
            // Back up to Google Drive whenever the app opens or goes to the background.
            if phase == .active || phase == .background {
                delegate.organizer.refreshDriveAccount()
                Task { await delegate.organizer.syncDrive() }
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Spaces", systemImage: "map") }
            NavigationStack { FindView() }
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
