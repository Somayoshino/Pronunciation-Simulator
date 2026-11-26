import SwiftUI

// MARK: - ステータス表示

struct StatusChip: View {
    let status: TrackingStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.footnote.weight(.semibold))
        }
        .chipStyle()
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var text: String {
        switch status {
        case .idle: return "推しをタップでロック（なぞって範囲指定もOK）"
        case .tracking: return "追尾中"
        case .searching: return "見失いました…探しています"
        }
    }

    private var color: Color {
        switch status {
        case .idle: return .white
        case .tracking: return .green
        case .searching: return .orange
        }
    }
}

struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(start)))
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
                    .font(.footnote.monospacedDigit().weight(.semibold))
            }
            .chipStyle()
        }
    }
}

extension View {
    /// 半透明の黒い角丸チップ
    func chipStyle(tint: Color = .white) -> some View {
        self
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - 右側のボタン列

struct SideControls: View {
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 22) {
            CircleIconButton(systemName: "gearshape.fill", label: "設定") {
                showSettings = true
            }

            RecordButton(isRecording: model.isRecording) {
                model.toggleRecording()
            }

            if model.status == .idle {
                CircleIconButton(systemName: "scope", label: "中央の人をロック") {
                    model.lockAtCenter()
                }
            } else {
                CircleIconButton(systemName: "xmark", label: "ロック解除") {
                    model.releaseTarget()
                }
            }
        }
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 27)
                    .fill(Color.red)
                    .frame(width: isRecording ? 26 : 54, height: isRecording ? 26 : 54)
            }
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "録画停止" : "録画開始")
    }
}

struct CircleIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 下のバー

struct BottomBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal, showsIndicators: false) {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if let info = model.zoomInfo {
                LensButtons(info: info, current: model.zoomFactor) { factor in
                    model.setZoom(factor, animated: true)
                }
                divider
            }

            Segmented(options: OutputAspect.allCases, selection: $model.aspect) { $0.rawValue }
                .disabled(model.isRecording)
                .opacity(model.isRecording ? 0.45 : 1)

            divider

            Segmented(options: FramingMode.allCases, selection: $model.framingMode) { $0.label }

            if model.framingMode == .manual {
                HStack(spacing: 6) {
                    Image(systemName: "plus.magnifyingglass")
                    Slider(value: $model.manualZoom, in: 1...4)
                        .frame(width: 110)
                    Text(String(format: "%.1f×", model.manualZoom))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 36, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5), in: Capsule())
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.3))
            .frame(width: 1, height: 22)
    }
}

/// レンズ切り替え（0.5× / 1× / 3× など）。今のズームに一番近いボタンに実際の倍率を表示する。
struct LensButtons: View {
    let info: ZoomInfo
    let current: CGFloat
    let select: (CGFloat) -> Void

    var body: some View {
        let activeIndex = info.presets.lastIndex { $0 <= current + 0.01 } ?? 0
        HStack(spacing: 4) {
            ForEach(Array(info.presets.enumerated()), id: \.offset) { index, factor in
                let isActive = index == activeIndex
                Button {
                    select(factor)
                } label: {
                    Text(isActive ? info.label(for: current) + "×" : info.label(for: factor))
                        .font(.caption.weight(.bold))
                        .frame(width: 40, height: 32)
                        .background(Color.white.opacity(isActive ? 0.25 : 0.1), in: Circle())
                        .foregroundStyle(isActive ? Color.yellow : Color.white)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 小さなカプセル型のセグメントコントロール
struct Segmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.white : Color.clear, in: Capsule())
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.15), in: Capsule())
    }
}
