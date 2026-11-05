import SwiftData
import SwiftUI

@main
struct TidyAtlasApp: App {
    @StateObject private var organizer = Organizer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(organizer)
                .tint(Palette.teal)
                .task { await organizer.checkForUpdate() }
        }
        .modelContainer(for: [Place.self, Room.self, Zone.self, Item.self, TidyStep.self, Capture.self])
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
