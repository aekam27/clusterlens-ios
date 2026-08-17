import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            BrowseView()
                .id(model.activeProfileID)
                .tabItem { Label("Browse", systemImage: "cylinder.split.1x2") }

            HistoryView()
                .id(model.activeProfileID)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
