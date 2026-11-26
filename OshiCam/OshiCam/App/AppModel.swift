import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 画面の状態を持ち、UI の操作を CameraEngine に伝える。
@MainActor
final class AppModel: ObservableObject {
    enum Permission {
        case unknown
        case granted
        case denied
    }

    private enum Keys {
        static let aspect = "aspect"
        static let framing = "framingMode"
        static let manualZoom = "manualZoom"
        static let speed = "followSpeed"
        static let deadZone = "deadZone"
        static let followExposure = "followExposure"
        static let showCandidates = "showCandidates"
        static let stabilization = "stabilization"
    }

    // MARK: 表示用の状態

    @Published private(set) var permission: Permission = .unknown
    @Published private(set) var status: TrackingStatus = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isSaving = false
    @Published private(set) var zoomInfo: ZoomInfo?
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var toast: String?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState

    // MARK: ユーザー設定

    @Published var swapped = false { didSet { pushSettings() } }
    @Published var aspect: OutputAspect { didSet { pushSettings(); save() } }
    @Published var framingMode: FramingMode { didSet { pushSettings(); save() } }
    @Published var manualZoom: Double { didSet { pushSettings(); save() } }
    @Published var speed: FollowSpeed { didSet { pushSettings(); save() } }
    @Published var deadZone: Double { didSet { pushSettings(); save() } }
    @Published var followExposure: Bool { didSet { pushSettings(); save() } }
    @Published var showCandidates: Bool { didSet { save() } }
    @Published var stabilization: Bool { didSet { engine.setStabilization(stabilization); save() } }
    @Published var exposureBias: Double = 0 { didSet { engine.setExposureBias(Float(exposureBias)) } }

    /// 撮影フレームの縦横比（4K / 1080p とも 16:9）
    let sourceAspect: CGFloat = 16.0 / 9.0

    let overlay = OverlayState()
    let mainView = SampleBufferView()
    let pipView = SampleBufferView()

    private let engine = CameraEngine()
    private let haptics = UINotificationFeedbackGenerator()
    private var started = false
    private var toastTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        aspect = OutputAspect(rawValue: defaults.string(forKey: Keys.aspect) ?? "") ?? .landscape
        framingMode = FramingMode(rawValue: defaults.string(forKey: Keys.framing) ?? "") ?? .fullBody
        manualZoom = defaults.object(forKey: Keys.manualZoom) as? Double ?? 1.5
        speed = FollowSpeed(rawValue: defaults.string(forKey: Keys.speed) ?? "") ?? .normal
        deadZone = defaults.object(forKey: Keys.deadZone) as? Double ?? 0.10
        followExposure = defaults.object(forKey: Keys.followExposure) as? Bool ?? true
        showCandidates = defaults.object(forKey: Keys.showCandidates) as? Bool ?? true
        stabilization = defaults.object(forKey: Keys.stabilization) as? Bool ?? true

        // videoQueue から呼ばれるので、MainActor に乗り換えてから反映する
        engine.onOverlay = { @Sendable [weak self] snapshot in
            guard let self else { return }
            Task { @MainActor in
                self.apply(snapshot)
            }
        }
        engine.setRenderers(
            main: mainView.displayLayer.sampleBufferRenderer,
            pip: pipView.displayLayer.sampleBufferRenderer
        )
        pushSettings()
    }

    // MARK: - ライフサイクル

    func start() async {
        guard !started else { return }
        started = true

        let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard videoGranted else {
            permission = .denied
            return
        }
        permission = .granted

        engine.setStabilization(stabilization)
        let info = await engine.configureAndStart()
        zoomInfo = info
        if let info {
            zoomFactor = info.defaultFactor
        } else {
            showToast("カメラを起動できませんでした")
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard permission == .granted else { return }
        switch phase {
        case .active:
            engine.startSession()
            UIApplication.shared.isIdleTimerDisabled = true
        case .background:
            if isRecording {
                stopRecording()
            }
            engine.stopSession()
        default:
            break
        }
    }

    func refreshThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
    }

    // MARK: - 推しのロック

    /// 正規化座標（左上原点）の点にいる人をロック
    func lockTarget(at point: CGPoint) {
        engine.lockTarget(at: point)
    }

    /// 正規化座標（左上原点）の矩形をそのままロック
    func lockTarget(in rect: CGRect) {
        engine.lockTarget(rect: rect)
    }

    /// いま切り出している範囲の中央にいる人をロック
    func lockAtCenter() {
        let crop = overlay.snapshot.crop
        engine.lockTarget(at: CGPoint(x: crop.midX, y: crop.midY))
    }

    func releaseTarget() {
        engine.releaseTarget()
    }

    // MARK: - ズーム

    func setZoom(_ factor: CGFloat, animated: Bool) {
        guard let info = zoomInfo else { return }
        let value = factor.clamped(to: info.minFactor...info.maxFactor)
        zoomFactor = value
        engine.setZoom(value, animated: animated)
    }

    // MARK: - 録画

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingStartedAt = Date()
        Task {
            let ok = await self.engine.startRecording()
            if !ok {
                self.isRecording = false
                self.recordingStartedAt = nil
                self.showToast("録画を開始できませんでした")
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingStartedAt = nil
        isSaving = true
        Task {
            do {
                let url = try await self.engine.stopRecording()
                await self.saveToPhotos(url)
            } catch {
                self.showToast("録画の保存に失敗しました: \(error.localizedDescription)")
            }
            self.isSaving = false
        }
    }

    private func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            showToast("写真への保存が許可されていません（設定アプリで許可してください）")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }
            showToast("写真に保存しました")
        } catch {
            showToast("写真への保存に失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - 内部

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                self.toast = nil
            }
        }
    }

    private func apply(_ snapshot: OverlaySnapshot) {
        overlay.snapshot = snapshot
        guard snapshot.status != status else { return }
        let previous = status
        status = snapshot.status
        switch (previous, snapshot.status) {
        case (_, .tracking):
            haptics.notificationOccurred(.success)
        case (.tracking, .searching):
            haptics.notificationOccurred(.warning)
        default:
            break
        }
    }

    private func pushSettings() {
        var settings = EngineSettings()
        settings.framing = FramingSettings(
            aspect: aspect,
            mode: framingMode,
            manualZoom: CGFloat(manualZoom),
            speed: speed,
            deadZone: CGFloat(deadZone)
        )
        settings.swapped = swapped
        settings.followExposure = followExposure
        engine.updateSettings(settings)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(aspect.rawValue, forKey: Keys.aspect)
        defaults.set(framingMode.rawValue, forKey: Keys.framing)
        defaults.set(manualZoom, forKey: Keys.manualZoom)
        defaults.set(speed.rawValue, forKey: Keys.speed)
        defaults.set(deadZone, forKey: Keys.deadZone)
        defaults.set(followExposure, forKey: Keys.followExposure)
        defaults.set(showCandidates, forKey: Keys.showCandidates)
        defaults.set(stabilization, forKey: Keys.stabilization)
    }
}

/// オーバーレイだけを 30fps で更新するための軽い ObservableObject
/// （画面全体を毎フレーム再描画しないように分けている）
@MainActor
final class OverlayState: ObservableObject {
    @Published var snapshot = OverlaySnapshot()
}
