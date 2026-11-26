import CoreImage
import CoreVideo
import Vision

/// Vision を使って「推し」を追い続ける追尾器。
///
/// 1. タップ位置の人物を `VNDetectHumanRectanglesRequest` で見つけてロック
/// 2. 毎フレーム `VNTrackObjectRequest` で追尾
/// 3. 0.5 秒ごとに人物検出で枠を補正（ドリフト・サイズずれ対策）
/// 4. 見失ったら、人物検出 + 見た目の特徴量 (`VNGenerateImageFeaturePrintRequest`) で
///    「さっきまで追っていた人」を探し直して自動復帰
///
/// 重い処理は専用キューで非同期に行い、撮影・録画のフレームを止めない。
/// 処理中に来たフレームは捨てる（常に最新フレームだけを処理する）。
final class SubjectTracker {
    enum Command {
        /// 正規化座標（左上原点）の点にいる人をロック
        case lockPoint(CGPoint)
        /// 正規化座標（左上原点）の矩形をそのままロック
        case lockRect(CGRect)
        case release
    }

    private struct Shared {
        var busy = false
        var pending: Command?
        var snapshot = TrackerSnapshot()
    }

    private let queue = DispatchQueue(label: "oshicam.vision", qos: .userInitiated)
    private let shared = Locked(Shared())

    // MARK: vision キュー専用の状態（座標はすべて Vision の正規化座標＝左下原点）

    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackRequest: VNTrackObjectRequest?
    private var status: TrackingStatus = .idle
    private var lastBox = CGRect.zero
    private var lastBoxTime: Double = 0
    private var lowConfidenceCount = 0
    private var lastRefresh: Double = 0
    private var lastSearch: Double = 0
    private var lastCandidateScan: Double = 0
    private var lastGalleryAdd: Double = 0
    private var lostSince: Double?
    private var searchNearLastPosition = false
    private var velocity = CGVector.zero
    private var candidates: [CGRect] = []

    /// 推しの見た目の特徴量（ライティングや向きの変化に備えて数枚ためる）
    private var gallery: [VNFeaturePrintObservation] = []
    /// 追尾中の「本人どうしの特徴量距離」の平均。再識別のしきい値の基準にする。
    private var selfDistance = RunningMean()

    // MARK: - 公開 API（どのスレッドからでも呼べる）

    var snapshot: TrackerSnapshot {
        shared.withLock { $0.snapshot }
    }

    func send(_ command: Command) {
        shared.withLock { $0.pending = command }
    }

    /// 新しいフレームを渡す。前のフレームを処理中なら何もしない。
    func submit(_ pixelBuffer: CVPixelBuffer, time: Double) {
        let accepted: Bool = shared.withLock { state in
            if state.busy { return false }
            state.busy = true
            return true
        }
        guard accepted else { return }

        queue.async { [self] in
            let command: Command? = shared.withLock { state in
                let pending = state.pending
                state.pending = nil
                return pending
            }
            process(pixelBuffer, time: time, command: command)
            let snapshot = makeSnapshot()
            shared.withLock { state in
                state.snapshot = snapshot
                state.busy = false
            }
        }
    }

    // MARK: - メイン処理

    private func process(_ pixelBuffer: CVPixelBuffer, time: Double, command: Command?) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        if let command {
            switch command {
            case .release:
                resetToIdle()
            case .lockPoint(let point):
                lock(at: CGPoint(x: point.x, y: 1 - point.y), image: image, pixelBuffer: pixelBuffer, time: time)
                return
            case .lockRect(let rect):
                begin(box: rect.flippedNormalized.clampedToUnit(), image: image, pixelBuffer: pixelBuffer, time: time, newTarget: true)
                return
            }
        }

        switch status {
        case .idle:
            scanCandidates(image: image, time: time)
        case .tracking:
            track(pixelBuffer: pixelBuffer, image: image, time: time)
        case .searching:
            search(pixelBuffer: pixelBuffer, image: image, time: time)
        }
    }

    private func resetToIdle() {
        status = .idle
        trackRequest = nil
        sequenceHandler = VNSequenceRequestHandler()
        lostSince = nil
        gallery.removeAll()
        selfDistance.reset()
        velocity = .zero
        lastCandidateScan = 0
    }

    /// タップした点の人物をロックする
    private func lock(at point: CGPoint, image: CIImage, pixelBuffer: CVPixelBuffer, time: Double) {
        var humans = detectHumans(in: image)
        // 遠くの小さな人も拾えるよう、タップ周辺を拡大して検出し直す
        let roi = CGRect(x: point.x - 0.15, y: point.y - 0.25, width: 0.3, height: 0.5).clampedToUnit()
        humans += detectHumans(in: image, roi: roi)

        let containing = humans.filter { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) }
        let box: CGRect
        if let smallest = containing.min(by: { $0.width * $0.height < $1.width * $1.height }) {
            // 手前の観客より奥の推しのほうが小さく映るので、含まれる中で一番小さい枠を選ぶ
            box = smallest
        } else if let nearest = humans.min(by: { distance($0.center, point) < distance($1.center, point) }),
                  distance(nearest.center, point) < 0.08 {
            box = nearest
        } else {
            // 人物として検出できなかった（暗い・衣装など）→ タップ周辺をそのまま追う
            box = CGRect(x: point.x - 0.04, y: point.y - 0.1, width: 0.08, height: 0.2).clampedToUnit()
        }
        begin(box: box, image: image, pixelBuffer: pixelBuffer, time: time, newTarget: true)
    }

    private func begin(box: CGRect, image: CIImage, pixelBuffer: CVPixelBuffer, time: Double, newTarget: Bool) {
        guard box.width > 0.002, box.height > 0.002 else { return }
        startTracker(box: box, pixelBuffer: pixelBuffer)
        status = .tracking
        lastBox = box
        lastBoxTime = time
        lowConfidenceCount = 0
        lostSince = nil
        lastRefresh = time
        velocity = .zero
        candidates = []

        if newTarget {
            gallery.removeAll()
            selfDistance.reset()
            if let seed = featurePrint(of: box, in: image) {
                gallery.append(seed)
            }
            lastGalleryAdd = time
        }
    }

    /// 追尾器を（再）初期化する。古い追尾器はハンドラごと捨てる。
    private func startTracker(box: CGRect, pixelBuffer: CVPixelBuffer) {
        sequenceHandler = VNSequenceRequestHandler()
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        request.trackingLevel = .accurate
        // このフレームで初期化しておく
        try? sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
        if let observation = observations(request.results, as: VNDetectedObjectObservation.self).first {
            request.inputObservation = observation
        }
        trackRequest = request
    }

    private func track(pixelBuffer: CVPixelBuffer, image: CIImage, time: Double) {
        guard let request = trackRequest else {
            enterSearching(time: time)
            return
        }
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            enterSearching(time: time)
            return
        }
        guard let observation = observations(request.results, as: VNDetectedObjectObservation.self).first else {
            enterSearching(time: time)
            return
        }
        request.inputObservation = observation

        let trackedBox = observation.boundingBox
        let confidence = observation.confidence
        let sizeIsSane = trackedBox.width > 0.003 && trackedBox.height > 0.003
            && trackedBox.width < 0.95 && trackedBox.height < 0.98
        guard confidence >= 0.3, sizeIsSane else {
            lowConfidenceCount += 1
            if lowConfidenceCount >= 4 {
                enterSearching(time: time)
            }
            return
        }
        lowConfidenceCount = 0
        updateVelocity(newBox: trackedBox, time: time)

        var box = trackedBox
        if time - lastRefresh >= 0.5 {
            lastRefresh = time
            // 追尾枠の周辺で人物検出し、重なる人がひとりだけなら枠を補正
            let roi = box.insetBy(dx: -box.width, dy: -box.height * 0.5).clampedToUnit()
            let overlapping = detectHumans(in: image, roi: roi)
                .map { (box: $0, iou: $0.iou(trackedBox)) }
                .filter { $0.iou > 0.2 }
            if overlapping.count == 1, let match = overlapping.first, match.iou > 0.35 {
                box = trackedBox.lerp(to: match.box, 0.6)
                startTracker(box: box, pixelBuffer: pixelBuffer)
                if confidence > 0.5, time - lastGalleryAdd > 2.0 {
                    addToGallery(box: box, image: image)
                    lastGalleryAdd = time
                }
            }
        }

        lastBox = box
        lastBoxTime = time
    }

    private func enterSearching(time: Double) {
        status = .searching
        lostSince = time
        trackRequest = nil
        lastSearch = 0
        velocity = .zero
    }

    /// 見失った推しを探す
    private func search(pixelBuffer: CVPixelBuffer, image: CIImage, time: Double) {
        guard time - lastSearch >= 0.2 else { return }
        lastSearch = time
        let lostFor = time - (lostSince ?? time)

        // 「最後にいた辺りを拡大して探す」と「全体を探す」を交互に
        searchNearLastPosition.toggle()
        let humans: [CGRect]
        if searchNearLastPosition, lostFor < 5 {
            let roi = lastBox.insetBy(dx: -lastBox.width * 2, dy: -lastBox.height * 0.75).clampedToUnit()
            humans = detectHumans(in: image, roi: roi)
        } else {
            humans = detectHumans(in: image)
        }
        guard !humans.isEmpty else { return }

        let lastCenter = lastBox.center
        let nearestFirst = humans.sorted { distance($0.center, lastCenter) < distance($1.center, lastCenter) }

        var scored: [(box: CGRect, feature: Float, spatial: CGFloat)] = []
        for box in nearestFirst.prefix(5) {
            let feature: Float
            if gallery.isEmpty {
                feature = 0
            } else {
                guard let sample = featurePrint(of: box, in: image), let d = minGalleryDistance(sample) else { continue }
                feature = d
            }
            scored.append((box: box, feature: feature, spatial: distance(box.center, lastCenter)))
        }
        guard !scored.isEmpty else { return }

        // 見た目の近さ + 位置の近さ（時間が経つほど位置は重視しない）
        let spatialWeight = max(0.15, 1.2 - CGFloat(lostFor) * 0.25)
        let minFeature = scored.map { $0.feature }.min() ?? 1
        let scale: Float = selfDistance.count > 0 ? max(selfDistance.mean, 1e-3) : max(minFeature, 1e-3)
        scored.sort {
            ($0.feature / scale) + Float($0.spatial * spatialWeight) < ($1.feature / scale) + Float($1.spatial * spatialWeight)
        }

        let best = scored[0]
        let runnerUp = scored.dropFirst().map { $0.feature }.min()
        let isDistinctive = runnerUp.map { best.feature < $0 * 0.85 } ?? true

        var accept: Bool
        if !gallery.isEmpty, selfDistance.count > 0 {
            accept = isDistinctive && best.feature <= selfDistance.mean * 2.2
        } else {
            accept = isDistinctive && best.spatial < 0.2
        }
        // しばらく見つからず、候補がひとりだけで近くにいるなら復帰を試みる
        if !accept, lostFor > 2.0, scored.count == 1, best.spatial < 0.3 {
            accept = true
        }

        if accept {
            begin(box: best.box, image: image, pixelBuffer: pixelBuffer, time: time, newTarget: false)
        }
    }

    /// 未ロック時: タップしやすいよう人物候補を表示する
    private func scanCandidates(image: CIImage, time: Double) {
        guard time - lastCandidateScan >= 0.4 else { return }
        lastCandidateScan = time
        candidates = detectHumans(in: image)
    }

    private func updateVelocity(newBox: CGRect, time: Double) {
        let dt = time - lastBoxTime
        guard dt > 0.001, dt < 0.5 else { return }
        let vx = (newBox.midX - lastBox.midX) / CGFloat(dt)
        let vy = (newBox.midY - lastBox.midY) / CGFloat(dt)
        let alpha: CGFloat = 0.3
        velocity = CGVector(
            dx: (velocity.dx * (1 - alpha) + vx * alpha).clamped(to: -1.5...1.5),
            dy: (velocity.dy * (1 - alpha) + vy * alpha).clamped(to: -1.5...1.5)
        )
    }

    private func makeSnapshot() -> TrackerSnapshot {
        var snapshot = TrackerSnapshot()
        snapshot.status = status
        snapshot.box = status == .idle ? nil : lastBox.flippedNormalized
        snapshot.boxTime = lastBoxTime
        snapshot.velocity = CGVector(dx: velocity.dx, dy: -velocity.dy)
        snapshot.lostSince = lostSince
        snapshot.candidates = status == .idle ? candidates.map { $0.flippedNormalized } : []
        return snapshot
    }

    // MARK: - Vision ヘルパー

    /// 人物検出。roi を指定するとその範囲を切り出して検出する（小さく映る人に強くなる）。
    /// 戻り値はフレーム全体に対する Vision 正規化座標。
    private func detectHumans(in image: CIImage, roi: CGRect? = nil) -> [CGRect] {
        var input = image
        var region = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let roi {
            guard let cropped = crop(image, to: roi) else { return [] }
            input = cropped.image
            region = cropped.region
        }

        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(ciImage: input, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return observations(request.results, as: VNDetectedObjectObservation.self)
            .filter { $0.confidence >= 0.25 }
            .map { (observation: VNDetectedObjectObservation) -> CGRect in
                let r = observation.boundingBox
                return CGRect(
                    x: region.minX + r.minX * region.width,
                    y: region.minY + r.minY * region.height,
                    width: r.width * region.width,
                    height: r.height * region.height
                )
            }
    }

    private func featurePrint(of box: CGRect, in image: CIImage) -> VNFeaturePrintObservation? {
        guard let cropped = crop(image, to: box) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(ciImage: cropped.image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return observations(request.results, as: VNFeaturePrintObservation.self).first
    }

    private func addToGallery(box: CGRect, image: CIImage) {
        guard let sample = featurePrint(of: box, in: image) else { return }
        if let d = minGalleryDistance(sample) {
            selfDistance.add(d)
        }
        gallery.append(sample)
        if gallery.count > 8 {
            // 最初にロックしたときの見た目 (index 0) は残す
            gallery.remove(at: 1)
        }
    }

    private func minGalleryDistance(_ sample: VNFeaturePrintObservation) -> Float? {
        var best: Float?
        for reference in gallery {
            var d: Float = 0
            if (try? sample.computeDistance(&d, to: reference)) != nil {
                best = min(best ?? .greatestFiniteMagnitude, d)
            }
        }
        return best
    }

    /// Vision 正規化座標の矩形で CIImage を切り出し、原点に移動したものを返す。
    private func crop(_ image: CIImage, to normalized: CGRect) -> (image: CIImage, region: CGRect)? {
        let extent = image.extent
        let pixelRect = CGRect(
            x: extent.minX + normalized.minX * extent.width,
            y: extent.minY + normalized.minY * extent.height,
            width: normalized.width * extent.width,
            height: normalized.height * extent.height
        ).integral.intersection(extent)
        guard !pixelRect.isNull, pixelRect.width >= 24, pixelRect.height >= 24 else { return nil }

        let region = CGRect(
            x: (pixelRect.minX - extent.minX) / extent.width,
            y: (pixelRect.minY - extent.minY) / extent.height,
            width: pixelRect.width / extent.width,
            height: pixelRect.height / extent.height
        )
        let cropped = image
            .cropped(to: pixelRect)
            .transformed(by: CGAffineTransform(translationX: -pixelRect.minX, y: -pixelRect.minY))
        return (cropped, region)
    }

    /// SDK によって results の型付けが異なっても動くように取り出す
    private func observations<T>(_ results: [Any]?, as type: T.Type) -> [T] {
        (results ?? []).compactMap { $0 as? T }
    }
}

/// 直近 20 件程度に重みを置いた平均
struct RunningMean {
    private(set) var count = 0
    private(set) var mean: Float = 0

    mutating func add(_ value: Float) {
        count += 1
        let n = Float(min(count, 20))
        mean += (value - mean) / n
    }

    mutating func reset() {
        count = 0
        mean = 0
    }
}
