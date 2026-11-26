import AVFoundation
import CoreImage
import QuartzCore

/// 撮影 → 追尾 → バーチャルカメラ → 切り出し → 表示・録画 までのパイプライン。
///
/// ```
///  カメラ(4K) ──┬─▶ 縮小(1080p) ──▶ 全体プレビュー / SubjectTracker（非同期）
///               │                              │ 推しの位置
///               │                              ▼
///               └─▶ 切り出し(GPU) ◀── VirtualCamera（滑らかな追従）
///                       │
///                       ├─▶ 出力プレビュー
///                       └─▶ MovieRecorder（HEVC .mov）
/// ```
///
/// - sessionQueue: AVCaptureSession / AVCaptureDevice の設定変更
/// - videoQueue: フレーム処理と録画（映像・音声とも同じキューで直列に処理）
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum EngineError: Error {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
    }

    /// videoQueue から毎フレーム呼ばれる
    var onOverlay: (@Sendable (OverlaySnapshot) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "oshicam.session")
    private let videoQueue = DispatchQueue(label: "oshicam.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let settingsBox = Locked(EngineSettings())

    // sessionQueue 専用
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var zoomInfo: ZoomInfo?
    private var stabilizationEnabled = true
    private var hasAudio = false

    // videoQueue 専用
    private let frameRenderer = FrameRenderer()
    private let tracker = SubjectTracker()
    private let virtualCamera = VirtualCamera()
    private var recorder: MovieRecorder?
    private var recordingAspect: OutputAspect?
    private var mainRenderer: AVSampleBufferVideoRenderer?
    private var pipRenderer: AVSampleBufferVideoRenderer?
    private var lastFrameTime: Double?
    private var lastPOI: CGPoint?
    private var lastPOITime: Double = 0

    // MARK: - セッション

    /// セッションを構成して開始する。戻り値はレンズ情報（失敗時 nil）。
    func configureAndStart() async -> ZoomInfo? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ZoomInfo?, Never>) in
            sessionQueue.async {
                if !self.isConfigured {
                    do {
                        try self.configureSession()
                        self.isConfigured = true
                    } catch {
                        print("[OshiCam] カメラの構成に失敗: \(error)")
                        continuation.resume(returning: nil)
                        return
                    }
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume(returning: self.zoomInfo)
            }
        }
    }

    func startSession() {
        sessionQueue.async {
            if self.isConfigured, !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let camera = Self.bestBackCamera() else { throw EngineError.noCamera }
        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(videoInput) else { throw EngineError.cannotAddInput }
        session.addInput(videoInput)
        device = camera

        // 4K で撮って、そこから推しを切り出す
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            hasAudio = true
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw EngineError.cannotAddOutput }
        session.addOutput(videoOutput)

        if hasAudio {
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                hasAudio = false
            }
        }

        if let connection = videoOutput.connection(with: .video) {
            // 画面は landscapeRight 固定 → センサーの向きそのまま（回転 0°）
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilizationEnabled ? .standard : .off
            }
        }

        let info = Self.makeZoomInfo(for: camera)
        try camera.lockForConfiguration()
        if camera.isLowLightBoostSupported {
            camera.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        camera.videoZoomFactor = info.defaultFactor.clamped(to: camera.minAvailableVideoZoomFactor...camera.maxAvailableVideoZoomFactor)
        camera.unlockForConfiguration()
        zoomInfo = info
    }

    private static func bestBackCamera() -> AVCaptureDevice? {
        // 複数レンズを持つ仮想デバイスなら、ズームに応じてレンズを自動で切り替えてくれる
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    private static func makeZoomInfo(for device: AVCaptureDevice) -> ZoomInfo {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let firstSwitch = switchOvers.first ?? 1
        let multiplier: CGFloat = hasUltraWide ? 1 / firstSwitch : 1
        let presets = [CGFloat(1)] + switchOvers
        let defaultFactor: CGFloat = hasUltraWide ? firstSwitch : 1
        let minFactor = device.minAvailableVideoZoomFactor
        // 望遠レンズの 3 倍くらいまで（それ以上はデジタルズームで画質が落ちすぎる）
        let maxFactor = max(minFactor, min(device.maxAvailableVideoZoomFactor, (presets.last ?? 1) * 3))
        return ZoomInfo(
            minFactor: minFactor,
            maxFactor: maxFactor,
            displayMultiplier: multiplier,
            presets: presets,
            defaultFactor: defaultFactor.clamped(to: minFactor...maxFactor)
        )
    }

    // MARK: - 設定・操作（どのスレッドからでも呼べる）

    func updateSettings(_ settings: EngineSettings) {
        settingsBox.withLock { $0 = settings }
    }

    func setRenderers(main: AVSampleBufferVideoRenderer, pip: AVSampleBufferVideoRenderer) {
        videoQueue.async {
            self.mainRenderer = main
            self.pipRenderer = pip
        }
    }

    func lockTarget(at point: CGPoint) {
        tracker.send(.lockPoint(point))
    }

    func lockTarget(rect: CGRect) {
        tracker.send(.lockRect(rect))
    }

    func releaseTarget() {
        tracker.send(.release)
    }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        sessionQueue.async {
            guard let device = self.device else { return }
            let target = factor.clamped(to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor)
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: target, withRate: 4)
                } else {
                    if device.isRampingVideoZoom {
                        device.cancelVideoZoomRamp()
                    }
                    device.videoZoomFactor = target
                }
                device.unlockForConfiguration()
            } catch {
                print("[OshiCam] ズーム変更に失敗: \(error)")
            }
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async {
            guard let device = self.device else { return }
            let value = bias.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(value, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                print("[OshiCam] 露出補正に失敗: \(error)")
            }
        }
    }

    func setStabilization(_ enabled: Bool) {
        sessionQueue.async {
            self.stabilizationEnabled = enabled
            guard let connection = self.videoOutput.connection(with: .video),
                  connection.isVideoStabilizationSupported else { return }
            connection.preferredVideoStabilizationMode = enabled ? .standard : .off
        }
    }

    /// 露出とピントの基準点（正規化・左上原点）
    private func setPointOfInterest(_ point: CGPoint) {
        sessionQueue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                print("[OshiCam] 露出点の変更に失敗: \(error)")
            }
        }
    }

    // MARK: - 録画

    func startRecording() async -> Bool {
        let wantsAudio: Bool = await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume(returning: self.hasAudio) }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            videoQueue.async {
                guard self.recorder == nil else {
                    continuation.resume(returning: false)
                    return
                }
                let aspect = self.settingsBox.current.framing.aspect
                let audioSettings = wantsAudio
                    ? self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                    : nil
                do {
                    self.recorder = try MovieRecorder(
                        url: Self.makeRecordingURL(),
                        size: aspect.outputSize,
                        audioSettings: audioSettings
                    )
                    self.recordingAspect = aspect
                    continuation.resume(returning: true)
                } catch {
                    print("[OshiCam] 録画開始に失敗: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            videoQueue.async {
                guard let recorder = self.recorder else {
                    continuation.resume(throwing: MovieRecorder.RecorderError.notRecording)
                    return
                }
                self.recorder = nil
                self.recordingAspect = nil
                recorder.finish { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private static func makeRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "OshiCam_\(formatter.string(from: Date())).mov"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    // MARK: - フレーム処理（videoQueue）

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        processVideo(sampleBuffer)
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let time = CMTimeGetSeconds(pts)
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        var settings = settingsBox.current
        if let recordingAspect {
            // 録画中は縦横比を固定
            settings.framing.aspect = recordingAspect
        }

        // 1) 全体プレビュー兼、追尾用の縮小フレーム（カメラのバッファをすぐ返すためにもコピーする）
        let proxy = frameRenderer.render(
            source,
            crop: CGRect(origin: .zero, size: sourceSize),
            outputSize: Self.proxySize(for: sourceSize),
            highQuality: false
        )
        if let proxy {
            tracker.submit(proxy, time: time)
        }

        // 2) 追尾結果 → バーチャルカメラ
        let snapshot = tracker.snapshot
        var subjectPixels: CGRect?
        var velocityPixels = CGVector.zero
        if let box = snapshot.box {
            // 追尾は数フレーム遅れて届くので、その分だけ先に進めておく
            let lag = CGFloat((time - snapshot.boxTime).clamped(to: 0...0.25))
            let predicted = snapshot.status == .tracking
                ? box.offsetBy(dx: snapshot.velocity.dx * lag, dy: snapshot.velocity.dy * lag)
                : box
            subjectPixels = CGRect(
                x: predicted.minX * sourceSize.width,
                y: predicted.minY * sourceSize.height,
                width: predicted.width * sourceSize.width,
                height: predicted.height * sourceSize.height
            )
            velocityPixels = CGVector(
                dx: snapshot.velocity.dx * sourceSize.width,
                dy: snapshot.velocity.dy * sourceSize.height
            )
        }
        let dt = lastFrameTime.map { time - $0 } ?? (1.0 / 30.0)
        lastFrameTime = time
        let lostDuration = snapshot.lostSince.map { time - $0 } ?? 0
        let crop = virtualCamera.update(
            source: sourceSize,
            subject: subjectPixels,
            subjectVelocity: velocityPixels,
            status: snapshot.status,
            lostDuration: lostDuration,
            settings: settings.framing,
            dt: dt
        )

        // 3) 出力フレームを切り出して録画
        let output = frameRenderer.render(source, crop: crop, outputSize: settings.framing.aspect.outputSize, highQuality: true)
        if let output, let recorder {
            recorder.appendVideo(output, at: pts)
        }

        // 4) 画面表示
        enqueue(settings.swapped ? output : proxy, to: mainRenderer, at: pts)
        enqueue(settings.swapped ? proxy : output, to: pipRenderer, at: pts)

        // 5) UI オーバーレイ
        let normalizedCrop = CGRect(
            x: crop.minX / sourceSize.width,
            y: crop.minY / sourceSize.height,
            width: crop.width / sourceSize.width,
            height: crop.height / sourceSize.height
        )
        onOverlay?(OverlaySnapshot(
            status: snapshot.status,
            target: snapshot.box,
            crop: normalizedCrop,
            candidates: snapshot.candidates,
            sourceAspect: sourceSize.width / sourceSize.height,
            outputAspect: settings.framing.aspect.ratio
        ))

        // 6) 露出・ピントを推しに合わせる
        updatePointOfInterest(snapshot: snapshot, settings: settings, time: time)
    }

    private func updatePointOfInterest(snapshot: TrackerSnapshot, settings: EngineSettings, time: Double) {
        if settings.followExposure, snapshot.status == .tracking, let box = snapshot.box {
            guard time - lastPOITime > 0.5 else { return }
            // 顔〜胸のあたりを基準にする（スポットライトで白飛びしにくくなる）
            let yRatio: CGFloat = settings.framing.mode == .upperBody ? 0.2 : 0.3
            let point = CGPoint(x: box.midX, y: box.minY + box.height * yRatio).clampedToUnitPoint()
            if let last = lastPOI, distance(point, last) < 0.02 { return }
            lastPOI = point
            lastPOITime = time
            setPointOfInterest(point)
        } else if (snapshot.status == .idle || !settings.followExposure), lastPOI != nil {
            lastPOI = nil
            setPointOfInterest(CGPoint(x: 0.5, y: 0.5))
        }
    }

    private static func proxySize(for source: CGSize) -> CGSize {
        let maxWidth: CGFloat = 1920
        guard source.width > maxWidth else { return source }
        return CGSize(width: maxWidth, height: (source.height * maxWidth / source.width).rounded())
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer?, to renderer: AVSampleBufferVideoRenderer?, at time: CMTime) {
        guard let pixelBuffer, let renderer, let sampleBuffer = Self.makeSampleBuffer(pixelBuffer, time: time) else { return }
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == 0, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == 0, let sampleBuffer else { return nil }

        // 時刻合わせをせず、届いたらすぐ表示する
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

private extension CGPoint {
    func clampedToUnitPoint() -> CGPoint {
        CGPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
    }
}
