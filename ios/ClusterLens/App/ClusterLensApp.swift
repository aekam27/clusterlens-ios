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
        VStack(spacing: 0) {
            if model.isSyntheticUI {
                Text("SYNTHETIC QA · No database · Writes disabled")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(6)
                    .background(.yellow.opacity(0.2))
            }
            Group {
                if model.isBootstrapping {
                    LaunchView()
                } else if model.profiles.isEmpty {
                    SetupView()
                } else {
                    MainTabView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.activeProfileID)
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
