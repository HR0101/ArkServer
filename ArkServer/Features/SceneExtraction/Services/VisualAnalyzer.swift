// ArkServer/Features/SceneExtraction/Services/VisualAnalyzer.swift

import Accelerate
import AVFoundation
import CoreVideo
import Foundation

nonisolated enum VisualAnalyzerError: LocalizedError {
  case missingVideoTrack
  case cannotCreateReader
  case cannotAddOutput
  case unsupportedPixelBuffer
  case readerFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingVideoTrack:
      return "映像解析に使用できる動画トラックがありません．"
    case .cannotCreateReader:
      return "映像解析用のAVAssetReaderを作成できませんでした．"
    case .cannotAddOutput:
      return "映像フレーム出力をAVAssetReaderへ追加できませんでした．"
    case .unsupportedPixelBuffer:
      return "映像フレームをBGRA形式で取得できませんでした．"
    case .readerFailed(let reason):
      return "映像の読み取りに失敗しました．\(reason)"
    }
  }
}

nonisolated struct VisualAnalyzer: Sendable {
  private let analysisWidth = 160
  private let analysisHeight = 90
  private let minimumStandardDeviation = 0.000_000_1
  private let luminanceWeight = 0.8
  private let edgeWeight = 0.2

  /// - Parameter timeRange: 解析する区間（秒）。nil なら動画全体。長い動画の一部だけを調べたいときに使う。
  func analyze(
    url: URL,
    settings: AnalysisSettings,
    timeRange: ClosedRange<Double>? = nil
  ) async throws -> [VisualFeaturePoint] {
    let asset = AVURLAsset(url: url)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw VisualAnalyzerError.missingVideoTrack
    }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw VisualAnalyzerError.cannotCreateReader
    }

    let outputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw VisualAnalyzerError.cannotAddOutput
    }
    reader.add(output)
    if let timeRange {
      reader.timeRange = CMTimeRange(
        start: CMTime(seconds: timeRange.lowerBound, preferredTimescale: 600),
        duration: CMTime(seconds: timeRange.upperBound - timeRange.lowerBound, preferredTimescale: 600)
      )
    }

    guard reader.startReading() else {
      throw VisualAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "開始できませんでした．")
    }

    let sampleInterval = 1 / max(1, settings.analysisFramesPerSecond)
    var nextSampleTime = 0.0
    var previousLuminance: [Float]?
    var previousEdges: [Float]?
    var previousFrameDiff = 0.0
    var rawPoints: [RawVisualPoint] = []

    while let sampleBuffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
      guard presentationTime.isFinite, presentationTime + 0.000_001 >= nextSampleTime else {
        continue
      }
      nextSampleTime = presentationTime + sampleInterval

      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        continue
      }
      let frame = try makeLuminanceFrame(from: pixelBuffer)
      let edges = makeEdges(from: frame.values, width: frame.width, height: frame.height)
      let luminanceDiff = meanAbsoluteDifference(frame.values, previousLuminance)
      let edgeDiff = meanAbsoluteDifference(edges, previousEdges)
      let frameDiff = luminanceWeight * luminanceDiff + edgeWeight * edgeDiff
      let motionDelta = frameDiff - previousFrameDiff

      rawPoints.append(
        RawVisualPoint(
          time: max(0, presentationTime),
          frameDiff: frameDiff,
          meanLuminance: frame.meanLuminance,
          luminanceDiff: luminanceDiff,
          edgeDiff: edgeDiff,
          motionSpike: max(0, motionDelta),
          motionDrop: max(0, -motionDelta)
        )
      )
      previousLuminance = frame.values
      previousEdges = edges
      previousFrameDiff = frameDiff
    }

    if reader.status == .failed {
      throw VisualAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "原因不明です．")
    }
    return makeFeaturePoints(from: rawPoints)
  }

  private func makeLuminanceFrame(from pixelBuffer: CVPixelBuffer) throws -> LuminanceFrame {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      throw VisualAnalyzerError.unsupportedPixelBuffer
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw VisualAnalyzerError.unsupportedPixelBuffer
    }

    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let targetWidth = min(analysisWidth, sourceWidth)
    let targetHeight = min(analysisHeight, sourceHeight)
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var luminance = [Float](repeating: 0, count: targetWidth * targetHeight)

    for targetY in 0..<targetHeight {
      let sourceY = targetY * sourceHeight / targetHeight
      let sourceRow = bytes.advanced(by: sourceY * bytesPerRow)
      for targetX in 0..<targetWidth {
        let sourceX = targetX * sourceWidth / targetWidth
        let pixel = sourceRow.advanced(by: sourceX * 4)
        let blue = Float(pixel[0])
        let green = Float(pixel[1])
        let red = Float(pixel[2])
        // Rec.709係数でRGBを知覚輝度へ変換します．
        luminance[targetY * targetWidth + targetX] = (
          0.2126 * red + 0.7152 * green + 0.0722 * blue
        ) / 255
      }
    }

    var meanLuminance: Float = 0
    vDSP_meanv(luminance, 1, &meanLuminance, vDSP_Length(luminance.count))
    return LuminanceFrame(
      values: luminance,
      width: targetWidth,
      height: targetHeight,
      meanLuminance: Double(meanLuminance)
    )
  }

  private func makeEdges(from luminance: [Float], width: Int, height: Int) -> [Float] {
    guard width > 2, height > 2 else { return [] }
    var edges = [Float]()
    edges.reserveCapacity((width - 2) * (height - 2))

    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let horizontal = abs(luminance[y * width + x + 1] - luminance[y * width + x - 1])
        let vertical = abs(luminance[(y + 1) * width + x] - luminance[(y - 1) * width + x])
        edges.append((horizontal + vertical) * 0.5)
      }
    }
    return edges
  }

  private func meanAbsoluteDifference(_ current: [Float], _ previous: [Float]?) -> Double {
    guard let previous, current.count == previous.count, !current.isEmpty else { return 0 }
    var difference = [Float](repeating: 0, count: current.count)
    vDSP_vsub(previous, 1, current, 1, &difference, 1, vDSP_Length(current.count))
    vDSP_vabs(difference, 1, &difference, 1, vDSP_Length(difference.count))
    var mean: Float = 0
    vDSP_meanv(difference, 1, &mean, vDSP_Length(difference.count))
    return Double(mean)
  }

  private func makeFeaturePoints(from rawPoints: [RawVisualPoint]) -> [VisualFeaturePoint] {
    guard !rawPoints.isEmpty else { return [] }
    let values = rawPoints.map(\.frameDiff)
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { partial, value in
      partial + pow(value - mean, 2)
    } / Double(values.count)
    let standardDeviation = max(minimumStandardDeviation, sqrt(variance))

    return rawPoints.map { point in
      VisualFeaturePoint(
        time: point.time,
        frameDiff: point.frameDiff,
        meanLuminance: point.meanLuminance,
        luminanceDiff: point.luminanceDiff,
        edgeDiff: point.edgeDiff,
        motionSpike: point.motionSpike,
        motionDrop: point.motionDrop,
        zScore: (point.frameDiff - mean) / standardDeviation
      )
    }
  }
}

private nonisolated struct LuminanceFrame: Sendable {
  let values: [Float]
  let width: Int
  let height: Int
  let meanLuminance: Double
}

private nonisolated struct RawVisualPoint: Sendable {
  let time: Double
  let frameDiff: Double
  let meanLuminance: Double
  let luminanceDiff: Double
  let edgeDiff: Double
  let motionSpike: Double
  let motionDrop: Double
}
