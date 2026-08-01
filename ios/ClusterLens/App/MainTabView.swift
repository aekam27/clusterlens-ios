import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            BrowseView()
                .tabItem { Label("Browse", systemImage: "cylinder.split.1x2") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
