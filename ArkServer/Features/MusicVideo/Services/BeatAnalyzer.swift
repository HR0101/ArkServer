// ArkServer/Features/MusicVideo/Services/BeatAnalyzer.swift

import Accelerate
import AVFoundation
import Foundation

nonisolated enum BeatAnalyzerError: LocalizedError {
  case noAudioTrack
  case cannotCreateReader
  case cannotAddOutput
  case readerFailed(String)
  case tooShort

  var errorDescription: String? {
    switch self {
    case .noAudioTrack:
      return "音声トラックが見つかりませんでした．"
    case .cannotCreateReader:
      return "音声解析用のAVAssetReaderを作成できませんでした．"
    case .cannotAddOutput:
      return "音声PCM出力をAVAssetReaderへ追加できませんでした．"
    case .readerFailed(let reason):
      return "音声の読み取りに失敗しました．\(reason)"
    case .tooShort:
      return "音声が短すぎて解析できません．"
    }
  }
}

/// 曲から拍の位置と盛り上がりを求める。
///
/// 手順: スペクトルフラックスで音の立ち上がり(onset)を求め → 自己相関でテンポを推定し →
/// 動的計画法(Ellis 2007)で拍を並べる。盛り上がりは音量と onset の密度を平滑化して3段階に分ける。
nonisolated struct BeatAnalyzer: Sendable {
  /// ファイルを読むときに変換する標本化周波数。拍の解析には十分で、処理が軽くなる。
  static let analysisSampleRate = 22_050.0

  private let frameSize = 1024
  private let hopSize = 256
  private let minimumTempo = 60.0
  private let maximumTempo = 200.0
  private let preferredTempo = 120.0
  /// 盛り上がりを求める間隔（秒）。
  private let energyHop = 0.1

  // MARK: - ファイルからの解析

  func analyze(url: URL) async throws -> MusicAnalysis {
    let samples = try await readMonoSamples(url: url)
    try Task.checkCancellation()
    guard samples.count >= frameSize * 8 else { throw BeatAnalyzerError.tooShort }
    return analyze(samples: samples, sampleRate: Self.analysisSampleRate)
  }

  private func readMonoSamples(url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw BeatAnalyzerError.noAudioTrack
    }
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw BeatAnalyzerError.cannotCreateReader
    }
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: Self.analysisSampleRate
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw BeatAnalyzerError.cannotAddOutput }
    reader.add(output)
    guard reader.startReading() else {
      throw BeatAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "開始できませんでした．")
    }

    var samples: [Float] = []
    while let sampleBuffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteCount = CMBlockBufferGetDataLength(dataBuffer)
      guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) else { continue }
      var chunk = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
      let status = chunk.withUnsafeMutableBytes { destination in
        CMBlockBufferCopyDataBytes(
          dataBuffer,
          atOffset: 0,
          dataLength: byteCount,
          destination: destination.baseAddress!
        )
      }
      guard status == kCMBlockBufferNoErr else {
        throw BeatAnalyzerError.readerFailed("PCMバッファをコピーできませんでした．")
      }
      samples.append(contentsOf: chunk)
    }
    if reader.status == .failed {
      throw BeatAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "原因不明です．")
    }
    return samples
  }

  // MARK: - 解析本体(ファイル非依存。単体テストはここを直接呼ぶ)

  func analyze(samples: [Float], sampleRate: Double) -> MusicAnalysis {
    let duration = Double(samples.count) / sampleRate
    let features = extractFrameFeatures(samples: samples, sampleRate: sampleRate)
    let framesPerSecond = sampleRate / Double(hopSize)

    let onset = makeOnsetEnvelope(flux: features.flux, framesPerSecond: framesPerSecond)
    let period = estimateBeatPeriod(onset: onset, framesPerSecond: framesPerSecond)
    var beatFrames = trackBeats(onset: onset, period: period)

    // フラックスが最大になるのは、音の立ち上がりが窓の後ろ寄り(約3/4)に入ったとき。
    // フレームの先頭からその位置までを足して、実際の音のタイミングに合わせる。
    let onsetOffset = 0.75 * Double(frameSize) / sampleRate
    var beats = beatFrames.map { Double($0) / framesPerSecond + onsetOffset }
    beats = beats.filter { $0 >= 0 && $0 < duration }

    var tempo = 60 * framesPerSecond / period
    if beats.count >= 4 {
      let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
      let median = intervals[intervals.count / 2]
      if median > 0 { tempo = 60 / median }
    }
    // 拍がほとんど取れなかったときは、推定したテンポで等間隔に並べる。
    if beats.count < 2 {
      let interval = 60 / max(1, tempo)
      beats = Array(stride(from: interval, to: max(interval, duration - 0.05), by: interval))
      beatFrames = []
    }

    let (energy, intensity) = makeEnergyAndIntensity(
      loudness: features.loudness,
      onset: onset,
      framesPerSecond: framesPerSecond
    )
    var analysis = MusicAnalysis(
      duration: duration,
      tempo: tempo,
      beats: beats,
      energy: energy,
      intensity: intensity,
      energyHop: energyHop
    )

    // 映像の動きを曲に細かく合わせるための情報: 拍の強さ・小節の頭・構造の境目・細かい onset。
    let structure = MusicStructureAnalyzer.analyze(
      onset: onset,
      framesPerSecond: framesPerSecond,
      onsetOffset: onsetOffset,
      beats: beats,
      structureFeature: makeStructureFeature(loudness: features.loudness, onset: onset, framesPerSecond: framesPerSecond),
      featureHop: energyHop,
      duration: duration
    )
    analysis.beatAccents = structure.beatAccents
    analysis.beatsPerBar = structure.beatsPerBar
    analysis.downbeatPhase = structure.downbeatPhase
    analysis.onsetEnvelope = structure.onsetEnvelope
    analysis.onsetHop = structure.onsetHop
    analysis.sectionBoundaries = structure.sectionBoundaries
    return analysis
  }

  // MARK: - フレームごとの特徴

  private struct FrameFeatures {
    var flux: [Double]
    var loudness: [Double]
  }

  /// フレームごとのスペクトルフラックス(音の立ち上がり)と音量(dB)を求める。
  private func extractFrameFeatures(samples: [Float], sampleRate: Double) -> FrameFeatures {
    guard samples.count >= frameSize else { return FrameFeatures(flux: [], loudness: []) }
    let frameCount = (samples.count - frameSize) / hopSize + 1
    let halfLength = frameSize / 2
    let log2Length = vDSP_Length(log2(Double(frameSize)))
    guard let fftSetup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2)) else {
      return FrameFeatures(
        flux: [Double](repeating: 0, count: frameCount),
        loudness: [Double](repeating: -60, count: frameCount)
      )
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    var hann = [Float](repeating: 0, count: frameSize)
    vDSP_hann_window(&hann, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

    var windowed = [Float](repeating: 0, count: frameSize)
    var real = [Float](repeating: 0, count: halfLength)
    var imaginary = [Float](repeating: 0, count: halfLength)
    var power = [Float](repeating: 0, count: halfLength)
    var previous = [Float](repeating: 0, count: halfLength)
    var current = [Float](repeating: 0, count: halfLength)
    var flux = [Double](repeating: 0, count: frameCount)
    var loudness = [Double](repeating: -60, count: frameCount)
    let magnitudeScale = 1000 / Float(frameSize)

    samples.withUnsafeBufferPointer { sampleBuffer in
      for frame in 0..<frameCount {
        let start = frame * hopSize
        let slice = sampleBuffer.baseAddress! + start

        var rms: Float = 0
        vDSP_rmsqv(slice, 1, &rms, vDSP_Length(frameSize))
        loudness[frame] = max(-60, 20 * Double(log10(max(rms, 1e-6))))

        vDSP_vmul(slice, 1, hann, 1, &windowed, 1, vDSP_Length(frameSize))
        real.withUnsafeMutableBufferPointer { realBuffer in
          imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
            var split = DSPSplitComplex(
              realp: realBuffer.baseAddress!,
              imagp: imaginaryBuffer.baseAddress!
            )
            windowed.withUnsafeBufferPointer { windowedBuffer in
              windowedBuffer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: halfLength
              ) { complexBuffer in
                vDSP_ctoz(complexBuffer, 2, &split, 1, vDSP_Length(halfLength))
              }
            }
            vDSP_fft_zrip(fftSetup, &split, 1, log2Length, FFTDirection(kFFTDirection_Forward))
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfLength))
          }
        }

        // 振幅を対数で圧縮してから、前のフレームより増えた分だけを足す(ビン0はDCとナイキストが入るので除く)。
        var frameFlux: Float = 0
        for bin in 1..<halfLength {
          let value = log1p(power[bin].squareRoot() * magnitudeScale)
          current[bin] = value
          let rise = value - previous[bin]
          if rise > 0 { frameFlux += rise }
        }
        flux[frame] = frame == 0 ? 0 : Double(frameFlux)
        swap(&previous, &current)
      }
    }
    return FrameFeatures(flux: flux, loudness: loudness)
  }

  // MARK: - onset の整形

  /// フラックスから局所平均を引いて正の部分だけを残し、標準偏差で規格化する。
  private func makeOnsetEnvelope(flux: [Double], framesPerSecond: Double) -> [Double] {
    guard !flux.isEmpty else { return [] }
    let radius = max(1, Int(framesPerSecond * 0.5))
    let mean = movingAverage(flux, radius: radius)
    var onset = zip(flux, mean).map { max(0, $0 - $1) }
    let count = Double(onset.count)
    let average = onset.reduce(0, +) / count
    let variance = onset.reduce(0) { $0 + ($1 - average) * ($1 - average) } / count
    let deviation = variance.squareRoot()
    if deviation > 1e-9 {
      onset = onset.map { $0 / deviation }
    }
    return onset
  }

  // MARK: - テンポ(拍の間隔)の推定

  /// onset の自己相関から、拍の間隔(フレーム数)を求める。
  private func estimateBeatPeriod(onset: [Double], framesPerSecond: Double) -> Double {
    let fallback = framesPerSecond * 60 / preferredTempo
    let minLag = max(2, Int((framesPerSecond * 60 / maximumTempo).rounded(.down)))
    let maxLag = Int((framesPerSecond * 60 / minimumTempo).rounded(.up))
    // 2倍・4倍の周期にも山が出るので、それも足して基本周期を強調する。
    let longestLag = maxLag * 4
    guard onset.count > longestLag * 2 else { return fallback }

    let signal = onset.map { Float($0) }
    var correlation = [Double](repeating: 0, count: longestLag + 2)
    signal.withUnsafeBufferPointer { buffer in
      for lag in minLag...longestLag {
        var dot: Float = 0
        let length = vDSP_Length(buffer.count - lag)
        vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1, &dot, length)
        correlation[lag] = Double(dot) / Double(length)
      }
    }
    guard correlation.contains(where: { $0 > 0 }) else { return fallback }

    var bestLag = minLag
    var bestScore = -Double.infinity
    var scores = [Double](repeating: 0, count: maxLag + 2)
    for lag in minLag...maxLag {
      var score = correlation[lag]
      if lag * 2 <= longestLag { score += 0.5 * correlation[lag * 2] }
      if lag * 4 <= longestLag { score += 0.25 * correlation[lag * 4] }
      // 120BPM付近を好む事前分布(オクターブ違いの取り違えを減らす)。
      let tempo = framesPerSecond * 60 / Double(lag)
      let octaves = log2(tempo / preferredTempo)
      score *= exp(-0.5 * octaves * octaves)
      scores[lag] = score
      if score > bestScore {
        bestScore = score
        bestLag = lag
      }
    }

    // 放物線補間で、フレーム間隔より細かい周期を求める。
    var refined = Double(bestLag)
    if bestLag > minLag, bestLag < maxLag {
      let left = scores[bestLag - 1]
      let center = scores[bestLag]
      let right = scores[bestLag + 1]
      let denominator = left - 2 * center + right
      if abs(denominator) > 1e-12 {
        refined += 0.5 * (left - right) / denominator
      }
    }
    return refined
  }

  // MARK: - 拍の追跡(Ellis 2007 の動的計画法)

  /// 拍のフレーム番号を昇順で返す。
  private func trackBeats(onset: [Double], period: Double) -> [Int] {
    let count = onset.count
    guard count > 0, period >= 2 else { return [] }
    let minGap = max(1, Int((period / 2).rounded()))
    let maxGap = max(minGap + 1, Int((period * 2).rounded()))
    let tightness = 100.0

    var penalty = [Double](repeating: 0, count: maxGap + 1)
    for gap in minGap...maxGap {
      let ratio = log(Double(gap) / period)
      penalty[gap] = tightness * ratio * ratio
    }

    var cumulative = onset
    var backlink = [Int](repeating: -1, count: count)
    for frame in 0..<count {
      let lowest = max(0, frame - maxGap)
      let highest = frame - minGap
      guard highest >= lowest else { continue }
      var bestScore = -Double.infinity
      var bestPrevious = -1
      for previous in lowest...highest {
        let score = cumulative[previous] - penalty[frame - previous]
        if score > bestScore {
          bestScore = score
          bestPrevious = previous
        }
      }
      if bestPrevious >= 0, bestScore > 0 {
        cumulative[frame] = onset[frame] + bestScore
        backlink[frame] = bestPrevious
      }
    }

    let tailStart = max(0, count - maxGap)
    var last = tailStart
    for frame in tailStart..<count where cumulative[frame] > cumulative[last] {
      last = frame
    }
    var beats: [Int] = []
    var frame = last
    while frame >= 0 {
      beats.append(frame)
      frame = backlink[frame]
    }
    return beats.reversed()
  }

  // MARK: - 盛り上がり

  /// 音量と onset を、`energyHop` 秒ごとの平均にまとめる。
  private func blockAverages(
    loudness: [Double],
    onset: [Double],
    framesPerSecond: Double
  ) -> (loud: [Double], onset: [Double]) {
    let blockFrames = max(1, Int((framesPerSecond * energyHop).rounded()))
    let blockCount = max(1, min(loudness.count, onset.count) / blockFrames)
    var loudBlocks = [Double](repeating: 0, count: blockCount)
    var onsetBlocks = [Double](repeating: 0, count: blockCount)
    for block in 0..<blockCount {
      let range = (block * blockFrames)..<min(loudness.count, (block + 1) * blockFrames)
      guard !range.isEmpty else { continue }
      loudBlocks[block] = range.reduce(0) { $0 + loudness[$1] } / Double(range.count)
      let onsetRange = range.clamped(to: 0..<onset.count)
      if !onsetRange.isEmpty {
        onsetBlocks[block] = onsetRange.reduce(0) { $0 + onset[$1] } / Double(onsetRange.count)
      }
    }
    return (loudBlocks, onsetBlocks)
  }

  /// 曲の構造(サビ・ドロップなど)を見るための盛り上がり。`makeEnergyAndIntensity` より短い(0.4秒前後)平滑化にして、
  /// 変わり目の位置がぼやけないようにする。
  private func makeStructureFeature(loudness: [Double], onset: [Double], framesPerSecond: Double) -> [Double] {
    let (loudBlocks, onsetBlocks) = blockAverages(loudness: loudness, onset: onset, framesPerSecond: framesPerSecond)
    let radius = max(1, Int(0.4 / energyHop))
    let loud = normalizedByPercentiles(movingAverage(loudBlocks, radius: radius))
    let rhythmic = normalizedByPercentiles(movingAverage(onsetBlocks, radius: radius))
    return normalizedByPercentiles(zip(loud, rhythmic).map { 0.6 * $0 + 0.4 * $1 })
  }

  private func makeEnergyAndIntensity(
    loudness: [Double],
    onset: [Double],
    framesPerSecond: Double
  ) -> (energy: [Double], intensity: [MusicIntensity]) {
    let (loudBlocks, onsetBlocks) = blockAverages(loudness: loudness, onset: onset, framesPerSecond: framesPerSecond)

    // 1.5秒前後で平滑化して、短い揺れで段階が変わらないようにする。
    let smoothingRadius = max(1, Int(1.5 / energyHop))
    let loud = normalizedByPercentiles(movingAverage(loudBlocks, radius: smoothingRadius))
    let rhythmic = normalizedByPercentiles(movingAverage(onsetBlocks, radius: smoothingRadius))
    let combined = zip(loud, rhythmic).map { 0.6 * $0 + 0.4 * $1 }
    let energy = normalizedByPercentiles(combined)
    return (energy, classify(energy))
  }

  /// 下位10%を0、上位10%を1として規格化する。幅が小さすぎる(平坦な)ときは0.5にする。
  private func normalizedByPercentiles(_ values: [Double]) -> [Double] {
    guard values.count > 1 else { return values.map { _ in 0.5 } }
    let sorted = values.sorted()
    let low = sorted[Int(Double(sorted.count - 1) * 0.1)]
    let high = sorted[Int(Double(sorted.count - 1) * 0.9)]
    guard high - low > 1e-9 else { return values.map { _ in 0.5 } }
    return values.map { min(1, max(0, ($0 - low) / (high - low))) }
  }

  /// ヒステリシス付きで3段階に分け、短すぎる区間は前後に吸収する。
  private func classify(_ energy: [Double]) -> [MusicIntensity] {
    guard let first = energy.first else { return [] }
    let calmBoundary = 0.35
    let intenseBoundary = 0.65
    let margin = 0.05

    var level: MusicIntensity = first < calmBoundary ? .calm : (first > intenseBoundary ? .intense : .medium)
    var levels: [MusicIntensity] = []
    levels.reserveCapacity(energy.count)
    for value in energy {
      switch level {
      case .calm:
        if value > calmBoundary + margin {
          level = value > intenseBoundary + margin ? .intense : .medium
        }
      case .medium:
        if value < calmBoundary - margin {
          level = .calm
        } else if value > intenseBoundary + margin {
          level = .intense
        }
      case .intense:
        if value < intenseBoundary - margin {
          level = value < calmBoundary - margin ? .calm : .medium
        }
      }
      levels.append(level)
    }
    return mergeShortRuns(levels, minimumRun: max(1, Int(2.0 / energyHop)))
  }

  private func mergeShortRuns(_ levels: [MusicIntensity], minimumRun: Int) -> [MusicIntensity] {
    guard !levels.isEmpty else { return levels }
    var result = levels
    // 短い区間を消すと別の短い区間ができることがあるので、数回繰り返す。
    for _ in 0..<3 {
      var runs: [(level: MusicIntensity, range: Range<Int>)] = []
      var start = 0
      for index in 1...result.count where index == result.count || result[index] != result[start] {
        runs.append((result[start], start..<index))
        start = index
      }
      var changed = false
      for (runIndex, run) in runs.enumerated() where run.range.count < minimumRun && runs.count > 1 {
        let neighbor = runIndex > 0 ? runs[runIndex - 1].level : runs[runIndex + 1].level
        for index in run.range { result[index] = neighbor }
        changed = true
      }
      if !changed { break }
    }
    return result
  }

  // MARK: - 補助

  /// 前後 `radius` 要素の単純移動平均(端は範囲を狭めて計算)。
  private func movingAverage(_ values: [Double], radius: Int) -> [Double] {
    guard !values.isEmpty else { return [] }
    var prefix = [Double](repeating: 0, count: values.count + 1)
    for (index, value) in values.enumerated() {
      prefix[index + 1] = prefix[index] + value
    }
    return values.indices.map { index in
      let lower = max(0, index - radius)
      let upper = min(values.count, index + radius + 1)
      return (prefix[upper] - prefix[lower]) / Double(upper - lower)
    }
  }
}
