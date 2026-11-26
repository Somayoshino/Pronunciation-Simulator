import AVFoundation
import SwiftUI

/// そのペインに映っているもの
enum PaneRole {
    /// 撮影フレーム全体
    case source
    /// 切り出した出力
    case output
}

/// 正規化座標（撮影フレーム全体・左上原点）⇄ ビュー座標 の変換
struct FrameMapper {
    /// ビュー内で映像が実際に表示されている矩形（resizeAspect の余白を除く）
    let imageRect: CGRect
    /// そのペインが表示している範囲（正規化座標）。全体なら (0,0,1,1)、出力なら切り出し範囲。
    let viewport: CGRect

    init(snapshot: OverlaySnapshot, role: PaneRole, size: CGSize) {
        let aspect = role == .source ? snapshot.sourceAspect : snapshot.outputAspect
        if size.width > 0, size.height > 0, aspect > 0 {
            imageRect = AVMakeRect(
                aspectRatio: CGSize(width: aspect, height: 1),
                insideRect: CGRect(origin: .zero, size: size)
            )
        } else {
            imageRect = .zero
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        if role == .output, snapshot.crop.width > 0, snapshot.crop.height > 0 {
            viewport = snapshot.crop
        } else {
            viewport = unit
        }
    }

    var isValid: Bool {
        imageRect.width > 0 && imageRect.height > 0 && viewport.width > 0 && viewport.height > 0
    }

    func viewRect(_ r: CGRect) -> CGRect {
        guard isValid else { return .zero }
        return CGRect(
            x: imageRect.minX + (r.minX - viewport.minX) / viewport.width * imageRect.width,
            y: imageRect.minY + (r.minY - viewport.minY) / viewport.height * imageRect.height,
            width: r.width / viewport.width * imageRect.width,
            height: r.height / viewport.height * imageRect.height
        )
    }

    /// 映像の外をタップした場合は nil
    func normalizedPoint(fromView p: CGPoint) -> CGPoint? {
        guard isValid, imageRect.contains(p) else { return nil }
        return toNormalized(p)
    }

    func normalizedRect(fromView r: CGRect) -> CGRect? {
        guard isValid else { return nil }
        let clipped = r.intersection(imageRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let a = toNormalized(CGPoint(x: clipped.minX, y: clipped.minY))
        let b = toNormalized(CGPoint(x: clipped.maxX, y: clipped.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private func toNormalized(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: viewport.minX + (p.x - imageRect.minX) / imageRect.width * viewport.width,
            y: viewport.minY + (p.y - imageRect.minY) / imageRect.height * viewport.height
        )
    }
}

/// 追尾枠・候補・切り出し範囲を映像の上に描く
struct TrackingOverlay: View {
    @ObservedObject var overlay: OverlayState
    let role: PaneRole
    var showCandidates = true
    var showCropGuide = true

    var body: some View {
        let snapshot = overlay.snapshot
        Canvas { context, size in
            let mapper = FrameMapper(snapshot: snapshot, role: role, size: size)
            guard mapper.isValid else { return }
            context.clip(to: Path(mapper.imageRect))

            if role == .source {
                if showCropGuide {
                    // 録画される範囲の外側を暗くする
                    let crop = mapper.viewRect(snapshot.crop)
                    var dim = Path(mapper.imageRect)
                    dim.addRect(crop)
                    context.fill(dim, with: .color(.black.opacity(0.4)), style: FillStyle(eoFill: true))
                    context.stroke(Path(crop), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
                if showCandidates, snapshot.status == .idle {
                    for candidate in snapshot.candidates {
                        context.stroke(
                            Path(roundedRect: mapper.viewRect(candidate), cornerRadius: 4),
                            with: .color(.white.opacity(0.7)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                    }
                }
            }

            if let target = snapshot.target, snapshot.status != .idle {
                let rect = mapper.viewRect(target)
                let color: Color = snapshot.status == .tracking ? .green : .orange
                context.stroke(
                    Self.cornerBrackets(rect),
                    with: .color(color),
                    style: StrokeStyle(
                        lineWidth: role == .source ? 3 : 2,
                        lineCap: .round,
                        dash: snapshot.status == .searching ? [6, 5] : []
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// 四隅だけのカギ括弧型の枠
    static func cornerBrackets(_ r: CGRect) -> Path {
        let l = max(6, min(r.width, r.height) * 0.25)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))

        p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))

        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))

        p.move(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}
