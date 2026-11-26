import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.permission {
            case .unknown:
                ProgressView()
                    .tint(.white)
            case .denied:
                PermissionView()
            case .granted:
                CameraScreen(model: model)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            model.refreshThermalState()
        }
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
            Text("カメラへのアクセスが必要です")
                .font(.headline)
            Text("設定アプリで「推しカメ」のカメラとマイクを許可してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding()
    }
}
