import CoreGraphics
import Foundation

// MARK: - 座標系のルール
//
// アプリ内部で扱う矩形・点は、特に断りがない限り
// 「撮影フレーム全体を 0...1 に正規化し、左上を原点とした座標」で表す。
// (カメラは横向き・回転なし = UIInterfaceOrientation.landscapeRight で固定)
// Vision と Core Image は左下原点なので、境界で `flippedNormalized` を使って変換する。

enum TrackingStatus: Equatable {
    /// まだ誰もロックしていない
    case idle
    /// 追尾中
    case tracking
    /// 見失って探索中
    case searching
}

/// 出力（録画）する動画の縦横比
enum OutputAspect: String, CaseIterable, Identifiable {
    case landscape = "16:9"
    case portrait = "9:16"
    case square = "1:1"

    var id: String { rawValue }

    /// 幅 / 高さ
    var ratio: CGFloat {
        switch self {
        case .landscape: return 16.0 / 9.0
        case .portrait: return 9.0 / 16.0
        case .square: return 1.0
        }
    }

    /// 書き出す動画のピクセルサイズ
    var outputSize: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

/// 推しをどのくらいの大きさで切り出すか
enum FramingMode: String, CaseIterable, Identifiable {
    case fullBody
    case upperBody
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullBody: return "全身"
        case .upperBody: return "上半身"
        case .manual: return "手動"
        }
    }
}

/// バーチャルカメラの追従のキビキビ感
enum FollowSpeed: String, CaseIterable, Identifiable {
    case gentle
    case normal
    case quick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: return "ゆったり"
        case .normal: return "標準"
        case .quick: return "キビキビ"
        }
    }

    /// 臨界減衰バネの角周波数 (rad/s)。大きいほど速く追いつく。
    var omega: CGFloat {
        switch self {
        case .gentle: return 2.2
        case .normal: return 3.6
        case .quick: return 6.0
        }
    }
}

struct FramingSettings: Equatable {
    var aspect: OutputAspect = .landscape
    var mode: FramingMode = .fullBody
    /// 手動モード時のデジタルズーム倍率 (1 = 撮影フレームいっぱい)
    var manualZoom: CGFloat = 1.5
    var speed: FollowSpeed = .normal
    /// 被写体がこの割合以上ずれたらカメラを動かし始める（出力フレーム比）
    var deadZone: CGFloat = 0.10
}

/// UI → カメラエンジンへ渡す設定一式
struct EngineSettings {
    var framing = FramingSettings()
    /// true のときメイン画面に「出力」、小窓に「全体」を表示
    var swapped = false
    /// 露出・ピントを推しに合わせ続ける
    var followExposure = true
}

/// 追尾器が公開する最新状態
struct TrackerSnapshot {
    var status: TrackingStatus = .idle
    /// 推しの位置（正規化・左上原点）。探索中は最後に見えた位置。
    var box: CGRect?
    /// box を計測したフレームの時刻（秒）
    var boxTime: Double = 0
    /// 推しの移動速度（正規化座標 / 秒）
    var velocity: CGVector = .zero
    /// 見失い始めた時刻
    var lostSince: Double?
    /// 未ロック時に検出された人物候補（正規化・左上原点）
    var candidates: [CGRect] = []
}

/// 画面のオーバーレイ描画用スナップショット
struct OverlaySnapshot {
    var status: TrackingStatus = .idle
    var target: CGRect?
    /// 出力として切り出している範囲（正規化・左上原点）
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var candidates: [CGRect] = []
    /// 撮影フレームの縦横比（幅 / 高さ）
    var sourceAspect: CGFloat = 16.0 / 9.0
    /// 出力フレームの縦横比（幅 / 高さ）
    var outputAspect: CGFloat = 16.0 / 9.0
}

/// レンズ / ズームの情報
struct ZoomInfo: Equatable {
    var minFactor: CGFloat
    var maxFactor: CGFloat
    /// 表示倍率 = videoZoomFactor × displayMultiplier（超広角がある機種では 0.5）
    var displayMultiplier: CGFloat
    /// レンズ切り替えボタンに出す videoZoomFactor の一覧
    var presets: [CGFloat]
    /// 起動時のズーム（いわゆる 1×）
    var defaultFactor: CGFloat

    func label(for factor: CGFloat) -> String {
        let value = factor * displayMultiplier
        if abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - 小さなユーティリティ

/// NSLock で守られた値。複数スレッドから安全に読み書きする。
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value {
        withLock { $0 }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CGRect {
    /// 正規化座標の上下反転（Vision / Core Image の左下原点 ⇄ 左上原点）
    var flippedNormalized: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    /// 0...1 の範囲に収める。はみ出し切っている場合は .zero
    func clampedToUnit() -> CGRect {
        let r = intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull ? .zero : r
    }

    /// Intersection over Union
    func iou(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let inter = i.width * i.height
        let union = width * height + other.width * other.height - inter
        return union > 0 ? inter / union : 0
    }

    /// 2つの矩形を線形補間
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: minX + (other.minX - minX) * t,
            y: minY + (other.minY - minY) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}
