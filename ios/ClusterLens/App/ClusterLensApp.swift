import SwiftUI

@main
struct ClusterLensApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.lockWrites()
            }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isBootstrapping {
                LaunchView()
            } else if model.profile == nil {
                SetupView()
            } else {
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.profile?.id)
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                AppMark(size: 64)
                ProgressView()
                    .tint(.accentColor)
            }
        }
    }
}
