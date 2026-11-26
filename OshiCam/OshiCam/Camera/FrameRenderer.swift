import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Core Image（GPU）で撮影フレームを切り出し・拡大縮小して新しいピクセルバッファを作る。
/// videoQueue からのみ呼ぶこと。
final class FrameRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private var pools: [String: CVPixelBufferPool] = [:]

    /// - Parameters:
    ///   - crop: ソースのピクセル座標（左上原点）。小数でもよい（サブピクセルで滑らかに動く）
    ///   - highQuality: true なら Lanczos で拡大縮小（録画用）、false ならバイリニア（プレビュー・解析用）
    func render(_ source: CVPixelBuffer, crop: CGRect, outputSize: CGSize, highQuality: Bool) -> CVPixelBuffer? {
        guard crop.width >= 1, crop.height >= 1, outputSize.width >= 1, outputSize.height >= 1,
              let output = makeBuffer(size: outputSize) else { return nil }

        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        // Core Image は左下原点なので上下を反転した矩形にする
        let ciCrop = CGRect(x: crop.minX, y: sourceHeight - crop.maxY, width: crop.width, height: crop.height)
        let sx = outputSize.width / ciCrop.width
        let sy = outputSize.height / ciCrop.height

        // 端のピクセルを伸ばしてから少し広めに切り出す（縁が黒くならないように）
        var image = CIImage(cvPixelBuffer: source)
            .clampedToExtent()
            .cropped(to: ciCrop.insetBy(dx: -4, dy: -4))
            .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))

        if highQuality {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(sy)
            filter.aspectRatio = Float(sx / sy)
            image = filter.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        } else {
            image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let bounds = CGRect(origin: .zero, size: outputSize)
        context.render(image.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
        return output
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let key = "\(width)x\(height)"

        if pools[key] == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }
}
