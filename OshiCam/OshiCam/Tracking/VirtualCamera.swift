import CoreGraphics
import Foundation

/// 追尾結果をもとに「4K フレームのどこを切り出すか」を決める、バーチャルなカメラマン。
///
/// - 位置とズームはそれぞれ臨界減衰バネで追従させる（オーバーシュートしない・カクつかない）
/// - デッドゾーン＋ヒステリシスで、推しが少し動いたくらいでは画を揺らさない
/// - 追尾の遅れを、推しの速度から少し先を予測して補う
/// - 見失ったらしばらくその場で待ち、その後ゆっくり引きの画に戻す
///
/// すべてソースフレームのピクセル座標（左上原点）で計算する。
final class VirtualCamera {
    /// 撮影フレームに対するデジタルズームの上限
    static let maxDigitalZoom: CGFloat = 4
    /// 見失ってから最後の位置で粘る時間（秒）
    static let holdDuration: Double = 1.2
    /// 追尾の遅れを補うための先読み時間（秒）
    private static let leadTime: CGFloat = 0.12
    /// パン速度の上限（出力フレームの長辺 / 秒）
    private static let maxPanSpeed: CGFloat = 2.0
    /// 推しの移動速度をどれだけカメラの動きに上乗せするか（追従遅れを打ち消す）
    private static let velocityFeedForward: CGFloat = 0.85

    private var sourceSize = CGSize.zero
    private var center = CGPoint.zero
    private var velocity = CGVector.zero
    /// 切り出し高さの対数（ズームを対数空間で動かすと自然に見える）
    private var logHeight: CGFloat = 0
    private var logHeightVelocity: CGFloat = 0
    private var zoomTarget: CGFloat?
    private var recentering = false

    /// 指定した縦横比で、ソースから切り出せる最大サイズ
    static func maxCropSize(source: CGSize, aspect: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0, aspect > 0 else { return .zero }
        if source.width / source.height > aspect {
            return CGSize(width: source.height * aspect, height: source.height)
        } else {
            return CGSize(width: source.width, height: source.width / aspect)
        }
    }

    /// 1フレーム進めて、切り出し矩形（ソースのピクセル座標・左上原点）を返す。
    func update(
        source: CGSize,
        subject: CGRect?,
        subjectVelocity: CGVector,
        status: TrackingStatus,
        lostDuration: Double,
        settings: FramingSettings,
        dt rawDt: Double
    ) -> CGRect {
        let dt = CGFloat(rawDt.clamped(to: 0...0.1))
        let aspect = settings.aspect.ratio
        let maxSize = Self.maxCropSize(source: source, aspect: aspect)
        guard maxSize.height > 1 else { return CGRect(origin: .zero, size: source) }

        let maxLog = log(maxSize.height)
        let minLog = log(maxSize.height / Self.maxDigitalZoom)
        let manualLog = log(maxSize.height / settings.manualZoom.clamped(to: 1...Self.maxDigitalZoom))
        let frameCenter = CGPoint(x: source.width / 2, y: source.height / 2)

        if source != sourceSize {
            sourceSize = source
            center = frameCenter
            velocity = .zero
            logHeight = maxLog
            logHeightVelocity = 0
            zoomTarget = nil
            recentering = false
        }

        var targetCenter = center
        var targetVelocity = CGVector.zero
        var desiredLog: CGFloat
        var omega = settings.speed.omega
        var zoomOmega: CGFloat = 1.8
        var useZoomHysteresis = false

        let isFollowing = status == .tracking
            || (status == .searching && lostDuration < Self.holdDuration)

        if isFollowing, let box = subject {
            let framed = framing(for: box, mode: settings.mode, manualLog: manualLog)
            desiredLog = framed.logHeight
            useZoomHysteresis = settings.mode != .manual

            var aim = framed.focus
            if status == .tracking {
                aim.x += subjectVelocity.dx * Self.leadTime
                aim.y += subjectVelocity.dy * Self.leadTime
            } else {
                // 見失い直後は慎重に
                omega *= 0.5
            }

            // デッドゾーン（ヒステリシス付き）: 大きくずれたら動き出し、ほぼ中央に戻るまで動き続ける
            let h = exp(logHeight)
            let w = h * aspect
            let offset = max(abs(aim.x - center.x) / w, abs(aim.y - center.y) / h)
            if offset > settings.deadZone {
                recentering = true
            } else if offset < settings.deadZone * 0.3 {
                recentering = false
            }
            if recentering {
                targetCenter = aim
                if status == .tracking {
                    // 等速で動く推しに遅れずついていけるよう、速度もバネの目標にする
                    targetVelocity = CGVector(
                        dx: subjectVelocity.dx * Self.velocityFeedForward,
                        dy: subjectVelocity.dy * Self.velocityFeedForward
                    )
                }
            }
        } else if status == .idle {
            desiredLog = settings.mode == .manual ? manualLog : maxLog
            targetCenter = frameCenter
            omega = 2.0
            recentering = false
        } else {
            // 見失ってしばらく経った → ゆっくり引きの画に戻して、とりあえずステージ全体を残す
            desiredLog = maxLog
            targetCenter = frameCenter
            omega = 0.8
            zoomOmega = 0.8
            recentering = false
        }

        // ズーム: 小さなサイズ変化は無視して「ズームの呼吸」を防ぐ
        desiredLog = desiredLog.clamped(to: minLog...maxLog)
        if useZoomHysteresis, let current = zoomTarget, abs(desiredLog - current) < 0.1 {
            // 現在の目標を維持
        } else {
            zoomTarget = desiredLog
        }
        let zoomGoal = (zoomTarget ?? desiredLog).clamped(to: minLog...maxLog)
        (logHeight, logHeightVelocity) = Self.spring(
            logHeight, logHeightVelocity, target: zoomGoal, omega: zoomOmega, dt: dt
        )
        logHeight = logHeight.clamped(to: minLog...maxLog)

        // 位置
        let previous = center
        (center.x, velocity.dx) = Self.spring(
            center.x, velocity.dx, target: targetCenter.x, targetVelocity: targetVelocity.dx, omega: omega, dt: dt
        )
        (center.y, velocity.dy) = Self.spring(
            center.y, velocity.dy, target: targetCenter.y, targetVelocity: targetVelocity.dy, omega: omega, dt: dt
        )

        let h = exp(logHeight)
        let w = h * aspect

        // パン速度の上限（急に別の場所へ飛んでもブン回さない）
        let maxStep = max(w, h) * Self.maxPanSpeed * dt
        let step = hypot(center.x - previous.x, center.y - previous.y)
        if step > maxStep, step > 0 {
            let s = maxStep / step
            center = CGPoint(
                x: previous.x + (center.x - previous.x) * s,
                y: previous.y + (center.y - previous.y) * s
            )
            velocity = CGVector(dx: velocity.dx * s, dy: velocity.dy * s)
        }

        // フレームからはみ出さないように
        let halfW = w / 2
        let halfH = h / 2
        if center.x < halfW { center.x = halfW; velocity.dx = 0 }
        if center.x > source.width - halfW { center.x = source.width - halfW; velocity.dx = 0 }
        if center.y < halfH { center.y = halfH; velocity.dy = 0 }
        if center.y > source.height - halfH { center.y = source.height - halfH; velocity.dy = 0 }

        return CGRect(x: center.x - halfW, y: center.y - halfH, width: w, height: h)
    }

    /// フレーミングモードごとの「狙う点」と「切り出し高さ(log)」
    private func framing(for box: CGRect, mode: FramingMode, manualLog: CGFloat) -> (focus: CGPoint, logHeight: CGFloat) {
        let boxHeight = max(box.height, 1)
        switch mode {
        case .fullBody:
            // 全身が画面の約 78% に収まるように
            return (CGPoint(x: box.midX, y: box.midY), log(boxHeight / 0.78))
        case .upperBody:
            // 頭〜腰あたり。顔が上 1/3 に来るように少し上を狙う
            return (CGPoint(x: box.midX, y: box.minY + boxHeight * 0.3), log(boxHeight * 0.62))
        case .manual:
            return (CGPoint(x: box.midX, y: box.minY + boxHeight * 0.4), manualLog)
        }
    }

    /// 臨界減衰バネ（陰的オイラー法）。どんな dt でも発散しない。
    ///
    /// x'' = ω²(target − x) + 2ω(targetVelocity − x')
    /// 目標の速度も与えると、等速で動く目標に遅れなく追従する。
    static func spring(
        _ x: CGFloat,
        _ v: CGFloat,
        target: CGFloat,
        targetVelocity: CGFloat = 0,
        omega: CGFloat,
        dt: CGFloat
    ) -> (CGFloat, CGFloat) {
        guard dt > 0 else { return (x, v) }
        let f = 1 + 2 * dt * omega
        let hoo = dt * omega * omega
        let hhoo = dt * hoo
        let newV = (v + hoo * (target - x) + 2 * omega * dt * targetVelocity) / (f + hhoo)
        return (x + dt * newV, newV)
    }
}
