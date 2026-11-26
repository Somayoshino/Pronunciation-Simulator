import AVFoundation
import SwiftUI
import UIKit

/// CVPixelBuffer をそのまま表示するビュー（AVSampleBufferDisplayLayer）。
/// 撮影フレームを GPU から直接流し込むので、SwiftUI の再描画とは無関係に 30fps で更新される。
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass で指定しているので必ずこの型
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SampleBufferViewRepresentable: UIViewRepresentable {
    let view: SampleBufferView

    func makeUIView(context: Context) -> SampleBufferView {
        view
    }

    func updateUIView(_ uiView: SampleBufferView, context: Context) {}
}
