import SwiftData
import SwiftUI

@main
struct TidyAtlasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.organizer)
                .environmentObject(router)
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
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Spaces", systemImage: "square.grid.2x2") }
                .tag(0)
            NavigationStack { MapTab() }
                .tabItem { Label("Map", systemImage: "map") }
                .tag(1)
            NavigationStack { FindView() }
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(2)
            NavigationStack { ShoppingView() }
                .tabItem { Label("Shopping", systemImage: "cart") }
                .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
    }
}
