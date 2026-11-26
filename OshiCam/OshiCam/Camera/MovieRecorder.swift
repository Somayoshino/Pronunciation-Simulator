import AVFoundation

/// 切り出した映像（＋マイク音声）を HEVC の .mov に書き出す。
/// 生成・追記・終了はすべて同じキュー（CameraEngine の videoQueue）から呼ぶこと。
final class MovieRecorder {
    enum RecorderError: LocalizedError {
        case cannotAddInput
        case cannotStart
        case noFrames
        case notRecording
        case failed

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "録画の準備に失敗しました"
            case .cannotStart: return "録画を開始できませんでした"
            case .noFrames: return "映像が記録されていません"
            case .notRecording: return "録画していません"
            case .failed: return "書き出しに失敗しました"
            }
        }
    }

    let url: URL
    let size: CGSize

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false

    init(url: URL, size: CGSize, audioSettings: [String: Any]?) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(size.width)
        let height = Int(size.height)

        let compression: [String: Any] = [
            // ライブの照明・動きはビットレートを食うので多めに（1080p で約 12Mbps）
            AVVideoAverageBitRateKey: width * height * 6,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 30,
        ]
        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorProperties,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStart }

        self.url = url
        self.size = size
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        if videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // 映像の最初のフレームより前の音声は捨てる
        guard sessionStarted, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard sessionStarted, writer.status == .writing else {
            let error = writer.error ?? RecorderError.noFrames
            if writer.status == .writing {
                writer.cancelWriting()
            }
            completion(.failure(error))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(writer.error ?? RecorderError.failed))
            }
        }
    }
}
