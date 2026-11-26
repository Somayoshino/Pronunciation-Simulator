import SwiftUI

/// 撮影画面（横向き）
///
/// ┌───────────────────────────────────────────┬──────┐
/// │ ● 追尾中                     ┌──────────┐ │  ⚙︎  │
/// │                              │ 出力(小窓)│ │      │
/// │        メイン（全体 or 出力）   └──────────┘ │  ⏺  │
/// │                                           │      │
/// │ [0.5 1 3] [16:9 9:16 1:1] [全身 上半身 手動] │  ✕   │
/// └───────────────────────────────────────────┴──────┘
struct CameraScreen: View {
    @ObservedObject var model: AppModel

    @State private var dragRect: CGRect?
    @State private var pinchBase: CGFloat?
    @State private var gestureSawPinch = false
    @State private var showSettings = false

    private let sideColumnWidth: CGFloat = 84

    var body: some View {
        ZStack {
            mainPane
                .ignoresSafeArea()
            hud
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }

    // MARK: - メイン映像

    private var mainRole: PaneRole {
        model.swapped ? .output : .source
    }

    private var mainPane: some View {
        GeometryReader { geo in
            ZStack {
                SampleBufferViewRepresentable(view: model.mainView)
                TrackingOverlay(
                    overlay: model.overlay,
                    role: mainRole,
                    showCandidates: model.showCandidates,
                    showCropGuide: true
                )
                if let dragRect {
                    Rectangle()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: dragRect.width, height: dragRect.height)
                        .position(x: dragRect.midX, y: dragRect.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(selectGesture(size: geo.size))
            .simultaneousGesture(zoomGesture)
        }
        .background(Color.black)
    }

    /// タップ = その人をロック / なぞる = 囲んだ範囲をロック
    private func selectGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pinchBase == nil, !gestureSawPinch else {
                    dragRect = nil
                    return
                }
                let dx = value.location.x - value.startLocation.x
                let dy = value.location.y - value.startLocation.y
                if hypot(dx, dy) > 16 {
                    dragRect = CGRect(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y),
                        width: abs(dx),
                        height: abs(dy)
                    )
                }
            }
            .onEnded { value in
                let drawn = dragRect
                dragRect = nil
                // ピンチ操作の一部だった場合はロックしない
                guard pinchBase == nil, !gestureSawPinch else {
                    gestureSawPinch = false
                    return
                }
                let mapper = FrameMapper(snapshot: model.overlay.snapshot, role: mainRole, size: size)
                if let drawn {
                    if let rect = mapper.normalizedRect(fromView: drawn), rect.width > 0.01, rect.height > 0.01 {
                        model.lockTarget(in: rect)
                    }
                } else if let point = mapper.normalizedPoint(fromView: value.location) {
                    model.lockTarget(at: point)
                }
            }
    }

    /// ピンチでカメラの光学 / デジタルズーム
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil {
                    pinchBase = model.zoomFactor
                    dragRect = nil
                }
                gestureSawPinch = true
                model.setZoom((pinchBase ?? 1) * value.magnification, animated: false)
            }
            .onEnded { _ in
                pinchBase = nil
            }
    }

    // MARK: - HUD

    private var hud: some View {
        GeometryReader { geo in
            ZStack {
                VStack(alignment: .leading, spacing: 8) {
                    StatusChip(status: model.status)
                    if let start = model.recordingStartedAt {
                        RecordingTimer(start: start)
                    }
                    if model.isSaving {
                        Label("保存中…", systemImage: "square.and.arrow.down")
                            .chipStyle()
                    }
                    if model.thermalState == .serious || model.thermalState == .critical {
                        Label(
                            model.thermalState == .critical ? "本体が高温です。録画を止めて冷ましてください" : "本体が熱くなっています",
                            systemImage: "thermometer.high"
                        )
                        .chipStyle(tint: model.thermalState == .critical ? .red : .orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                pip(in: geo.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, sideColumnWidth)

                SideControls(model: model, showSettings: $showSettings)
                    .frame(width: sideColumnWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                BottomBar(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.trailing, sideColumnWidth)

                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .animation(.easeInOut(duration: 0.2), value: model.toast)
        }
    }

    /// 小窓（タップでメインと入れ替え）
    private func pip(in size: CGSize) -> some View {
        let role: PaneRole = model.swapped ? .source : .output
        let aspect = role == .source ? model.sourceAspect : model.aspect.ratio
        let maxWidth = size.width * 0.26
        let maxHeight = size.height * 0.45
        let width = min(maxWidth, maxHeight * aspect)
        let height = width / aspect

        return ZStack(alignment: .bottomLeading) {
            SampleBufferViewRepresentable(view: model.pipView)
            TrackingOverlay(overlay: model.overlay, role: role, showCandidates: false, showCropGuide: true)
            Text(role == .output ? "出力" : "全体")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(model.isRecording ? Color.red : Color.white.opacity(0.85), lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.swapped.toggle()
        }
        .accessibilityLabel("表示を入れ替え")
    }
}
