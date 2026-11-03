// ArkServer/Features/MusicVideo/Services/MusicVideoComposer.swift

import AVFoundation
import CoreGraphics
import Foundation

/// 完成映像の画面サイズとフレームレート。
nonisolated struct MusicVideoRenderSettings: Equatable, Sendable {
  var width: Int
  var height: Int
  var framesPerSecond: Int

  static let landscapeFullHD = MusicVideoRenderSettings(width: 1920, height: 1080, framesPerSecond: 30)
  static let landscapeHD = MusicVideoRenderSettings(width: 1280, height: 720, framesPerSecond: 30)
  static let portraitFullHD = MusicVideoRenderSettings(width: 1080, height: 1920, framesPerSecond: 30)
  static let portraitHD = MusicVideoRenderSettings(width: 720, height: 1280, framesPerSecond: 30)

  var size: CGSize { CGSize(width: width, height: height) }
}

nonisolated enum MusicVideoComposerError: LocalizedError {
  case emptyPlan
  case missingSource(UUID)
  case noVideoTrack(String)
  case noAudioTrack
  case cannotCreateTrack
  case cannotCreateExporter
  case exportFailed(String)
  case invalidOutput(String)

  var errorDescription: String? {
    switch self {
    case .emptyPlan:
      return "カット割りが空です．"
    case .missingSource:
      return "素材動画のファイルが見つかりません．"
    case .noVideoTrack(let name):
      return "素材動画に映像トラックがありません．（\(name)）"
    case .noAudioTrack:
      return "音楽ファイルに音声トラックがありません．"
    case .cannotCreateTrack:
      return "合成用のトラックを作成できませんでした．"
    case .cannotCreateExporter:
      return "書き出しを開始できませんでした．"
    case .exportFailed(let reason):
      return "書き出しに失敗しました．\(reason)"
    case .invalidOutput(let reason):
      return "書き出した動画が正しくありません．\(reason)"
    }
  }
}

/// プレビュー再生と書き出しの両方に使う、合成済みの映像。
nonisolated struct MusicVideoComposition: @unchecked Sendable {
  let composition: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
  /// 完成映像の長さ（秒）。
  let duration: Double
  /// 画面サイズとフレームレート。書き出しのビットレートの計算にも使う。
  let render: MusicVideoRenderSettings

  func makePlayerItem() -> AVPlayerItem {
    let item = AVPlayerItem(asset: composition)
    item.videoComposition = videoComposition
    return item
  }
}

/// `CutPlan` から1本の映像を組み立て、mp3 などの音楽を付けて書き出す。
///
/// 1拍ごとのカットだと数百カットになるので、映像トラックは1本を使い回し、
/// 画面いっぱいに拡大する変換だけをカットの切り替え時刻ごとに差し替える。
nonisolated struct MusicVideoComposer: Sendable {
  /// 時刻を丸める分解能。30/24/25fps のどれの1フレームも割り切れる値。
  private static let timescale: CMTimeScale = 600

  // MARK: - 合成

  func makeComposition(
    plan: CutPlan,
    sourceURLs: [UUID: URL],
    audioURL: URL,
    render: MusicVideoRenderSettings
  ) async throws -> MusicVideoComposition {
    guard !plan.cuts.isEmpty else { throw MusicVideoComposerError.emptyPlan }

    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(
      withMediaType: .video,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw MusicVideoComposerError.cannotCreateTrack
    }

    var sources: [UUID: SourceTrack] = [:]
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

    for cut in plan.cuts {
      try Task.checkCancellation()
      let source: SourceTrack
      if let known = sources[cut.videoID] {
        source = known
      } else {
        guard let url = sourceURLs[cut.videoID] else {
          throw MusicVideoComposerError.missingSource(cut.videoID)
        }
        source = try await loadSource(url: url)
        sources[cut.videoID] = source
      }

      // 開始・終了をそれぞれ丸めて差を長さにすることで、カット間に隙間やずれを作らない。
      let start = Self.time(cut.timelineStart)
      let end = Self.time(cut.timelineEnd)
      let length = CMTimeSubtract(end, start)
      guard length > .zero else { continue }

      var sourceStart = Self.time(cut.sourceStart)
      let sourceEnd = CMTimeAdd(sourceStart, length)
      // 素材の終わりを少しでも越えるなら、範囲に収まるまで手前にずらす。
      if sourceEnd > source.timeRange.end {
        sourceStart = max(source.timeRange.start, CMTimeSubtract(source.timeRange.end, length))
      }
      try videoTrack.insertTimeRange(
        CMTimeRange(start: sourceStart, duration: length),
        of: source.track,
        at: start
      )
      layerInstruction.setTransform(
        Self.fillTransform(for: source, renderSize: render.size),
        at: start
      )
    }

    let totalDuration = Self.time(plan.duration)
    try await addAudio(from: audioURL, to: composition, duration: totalDuration)

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
    instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
    instruction.layerInstructions = [layerInstruction]

    let videoComposition = AVMutableVideoComposition()
    videoComposition.instructions = [instruction]
    videoComposition.renderSize = render.size
    videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(render.framesPerSecond))
    // 色の扱いを BT.709 に固定する(書き出し側の指定と揃えて、色味が変わらないようにする)。
    videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    return MusicVideoComposition(
      composition: composition,
      videoComposition: videoComposition,
      duration: composition.duration.seconds,
      render: render
    )
  }

  private struct SourceTrack {
    /// トラックは元のアセットが解放されると使えなくなる(挿入時に -12780 で失敗する)ので、アセットも持ち続ける。
    let asset: AVURLAsset
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
  }

  private func loadSource(url: URL) async throws -> SourceTrack {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw MusicVideoComposerError.noVideoTrack(url.lastPathComponent)
    }
    let (timeRange, naturalSize, transform) = try await track.load(.timeRange, .naturalSize, .preferredTransform)
    return SourceTrack(
      asset: asset,
      track: track,
      timeRange: timeRange,
      naturalSize: naturalSize,
      preferredTransform: transform
    )
  }

  private func addAudio(
    from url: URL,
    to composition: AVMutableComposition,
    duration: CMTime
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw MusicVideoComposerError.noAudioTrack
    }
    guard let audioTrack = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw MusicVideoComposerError.cannotCreateTrack
    }
    let available = try await sourceTrack.load(.timeRange)
    let length = min(duration, available.duration)
    try audioTrack.insertTimeRange(
      CMTimeRange(start: available.start, duration: length),
      of: sourceTrack,
      at: .zero
    )
  }

  /// 素材を画面いっぱいに（はみ出す部分は切り落として）敷き詰める変換。向き（回転）も反映する。
  private static func fillTransform(for source: SourceTrack, renderSize: CGSize) -> CGAffineTransform {
    let rotated = source.naturalSize.applying(source.preferredTransform)
    let displaySize = CGSize(width: abs(rotated.width), height: abs(rotated.height))
    guard displaySize.width > 0, displaySize.height > 0 else { return .identity }

    let scale = max(renderSize.width / displaySize.width, renderSize.height / displaySize.height)
    let scaledSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    let translation = CGAffineTransform(
      translationX: (renderSize.width - scaledSize.width) / 2,
      y: (renderSize.height - scaledSize.height) / 2
    )
    return source.preferredTransform
      .concatenating(CGAffineTransform(scaleX: scale, y: scale))
      .concatenating(translation)
  }

  private static func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: timescale)
  }

  // MARK: - 書き出し

  /// 合成した映像を mp4(H.264 + AAC)に書き出す。`progress` には 0〜1 が渡される。
  /// 画面サイズは保ったまま、`quality` に応じた映像のビットレートで書き出す。
  func export(
    _ composed: MusicVideoComposition,
    to outputURL: URL,
    quality: MusicVideoExportQuality = .high,
    progress: @escaping @Sendable (Double) async -> Void = { _ in }
  ) async throws {
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let job = try ExportJob(composed: composed, outputURL: outputURL, quality: quality)
    do {
      try await withTaskCancellationHandler {
        try await job.run(progress: progress)
      } onCancel: {
        job.cancel()
      }
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: outputURL)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      if let known = error as? MusicVideoComposerError { throw known }
      throw MusicVideoComposerError.exportFailed(error.localizedDescription)
    }
    await progress(1)

    try await validateOutput(at: outputURL, expectedDuration: composed.duration)
  }

  /// 読み出し(合成済みの映像と音声)と書き込み(H.264 + AAC)をつなぎ、順に流し込む。
  private final class ExportJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    private let duration: Double
    /// 読み出しの開始(startReading)中に中止(cancelReading)を呼ぶと AVFoundation の内部で落ちるので、
    /// 開始中の取り消しは、開始が終わってから実行する。
    private enum Phase { case idle, starting, running }
    private let lock = NSLock()
    private var isCancelled = false
    private var phase: Phase = .idle

    init(composed: MusicVideoComposition, outputURL: URL, quality: MusicVideoExportQuality) throws {
      let render = composed.render
      duration = composed.duration
      reader = try AVAssetReader(asset: composed.composition)

      videoOutput = AVAssetReaderVideoCompositionOutput(
        videoTracks: composed.composition.tracks(withMediaType: .video),
        videoSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
      )
      videoOutput.videoComposition = composed.videoComposition
      videoOutput.alwaysCopiesSampleData = false
      guard reader.canAdd(videoOutput) else { throw MusicVideoComposerError.cannotCreateExporter }
      reader.add(videoOutput)

      let audioTracks = composed.composition.tracks(withMediaType: .audio)
      if audioTracks.isEmpty {
        audioOutput = nil
      } else {
        let output = AVAssetReaderAudioMixOutput(
          audioTracks: audioTracks,
          audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: MusicVideoExportQuality.audioSampleRate,
            AVNumberOfChannelsKey: 2
          ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicVideoComposerError.cannotCreateExporter }
        reader.add(output)
        audioOutput = output
      }

      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
      videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: render.width,
          AVVideoHeightKey: render.height,
          AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
          ],
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: quality.videoBitRate(for: render),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: render.framesPerSecond * 2,
            AVVideoExpectedSourceFrameRateKey: render.framesPerSecond
          ]
        ]
      )
      videoInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(videoInput) else { throw MusicVideoComposerError.cannotCreateExporter }
      writer.add(videoInput)

      if audioOutput != nil {
        let input = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MusicVideoExportQuality.audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: MusicVideoExportQuality.audioBitRate
          ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MusicVideoComposerError.cannotCreateExporter }
        writer.add(input)
        audioInput = input
      } else {
        audioInput = nil
      }
    }

    func cancel() {
      lock.lock()
      isCancelled = true
      let shouldCancelNow = phase == .running
      lock.unlock()
      // 読み出しを止めると、流し込みの側は終わりまで読んだものとして自然に閉じる。
      // まだ始まっていない/開始中なら、run() が開始後に止める。
      if shouldCancelNow { reader.cancelReading() }
    }

    private var wasCancelled: Bool {
      lock.lock(); defer { lock.unlock() }
      return isCancelled
    }

    func run(progress: @escaping @Sendable (Double) async -> Void) async throws {
      lock.lock()
      if isCancelled { lock.unlock(); throw CancellationError() }
      phase = .starting
      lock.unlock()

      let started = reader.startReading()

      lock.lock()
      phase = .running
      let cancelledWhileStarting = isCancelled
      lock.unlock()
      if cancelledWhileStarting {
        reader.cancelReading()
        throw CancellationError()
      }
      guard started else {
        throw MusicVideoComposerError.exportFailed(reader.error?.localizedDescription ?? "読み出しを開始できませんでした．")
      }
      guard writer.startWriting() else {
        reader.cancelReading()
        throw MusicVideoComposerError.exportFailed(writer.error?.localizedDescription ?? "書き込みを開始できませんでした．")
      }
      writer.startSession(atSourceTime: .zero)

      async let videoDone: Void = pump(videoInput, from: videoOutput, progress: progress)
      async let audioDone: Void = {
        if let audioInput, let audioOutput { await pump(audioInput, from: audioOutput, progress: nil) }
      }()
      _ = await (videoDone, audioDone)

      if wasCancelled {
        writer.cancelWriting()
        throw CancellationError()
      }
      if reader.status == .failed {
        writer.cancelWriting()
        throw MusicVideoComposerError.exportFailed(reader.error?.localizedDescription ?? "読み出しに失敗しました．")
      }
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw MusicVideoComposerError.exportFailed(writer.error?.localizedDescription ?? "書き込みに失敗しました．")
      }
    }

    /// 読み出し側から取り出したサンプルを、書き込み側が受け取れるたびに渡す。
    private func pump(
      _ input: AVAssetWriterInput,
      from output: AVAssetReaderOutput,
      progress: (@Sendable (Double) async -> Void)?
    ) async {
      let queue = DispatchQueue(label: "musicvideo.export.\(input.mediaType.rawValue)")
      let total = max(duration, 0.001)
      // 書き出し側は、閉じた後も「受け取れます」と呼び出し直してくることがある。
      // そのとき、解放済みの読み出し側に触らないよう、(1)終わったら何もしない (2)呼び出しが続く間は reader を保持する。
      let reader = self.reader
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var lastReported = -1.0
        var isFinished = false
        input.requestMediaDataWhenReady(on: queue) {
          withExtendedLifetime(reader) {
            guard !isFinished else { return }
            while input.isReadyForMoreMediaData {
              guard let buffer = output.copyNextSampleBuffer() else {
                isFinished = true
                input.markAsFinished()
                continuation.resume()
                return
              }
              if !input.append(buffer) {
                isFinished = true
                input.markAsFinished()
                continuation.resume()
                return
              }
              if let progress {
                let fraction = min(1, max(0, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / total))
                if fraction - lastReported >= 0.01 {
                  lastReported = fraction
                  Task { await progress(fraction) }
                }
              }
            }
          }
        }
      }
    }
  }

  /// 書き出したファイルに映像と音声があり、長さが想定と大きくずれていないことを確かめる。
  private func validateOutput(at url: URL, expectedDuration: Double) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
    let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
    guard hasVideo else {
      try? FileManager.default.removeItem(at: url)
      throw MusicVideoComposerError.invalidOutput("映像がありません．")
    }
    guard hasAudio else {
      try? FileManager.default.removeItem(at: url)
      throw MusicVideoComposerError.invalidOutput("音声がありません．")
    }
    guard abs(duration - expectedDuration) < 1.0 else {
      try? FileManager.default.removeItem(at: url)
      throw MusicVideoComposerError.invalidOutput("長さが想定（\(Int(expectedDuration))秒）と合いません．")
    }
  }
}
