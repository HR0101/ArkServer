// ArkServerTests/MusicVideoTests.swift

import AVFoundation
import Foundation
import Testing
@testable import ArkServer

// MARK: - 合成音声

let testSampleRate = 22_050.0

/// 指定した時刻にクリック音(減衰する1.5kHzの短い音)を置いた音声を作る。
func clickTrack(duration: Double, clicks: [(time: Double, amplitude: Float)]) -> [Float] {
  var samples = [Float](repeating: 0, count: Int(duration * testSampleRate))
  let burstLength = Int(0.03 * testSampleRate)
  for click in clicks {
    let start = Int(click.time * testSampleRate)
    for offset in 0..<burstLength where start + offset < samples.count {
      let t = Double(offset) / testSampleRate
      samples[start + offset] += click.amplitude * Float(exp(-t / 0.008) * sin(2 * Double.pi * 1_500 * t))
    }
  }
  return samples
}

/// 一定間隔(`interval` 秒)のクリックの時刻。
func evenClicks(from first: Double, interval: Double, until end: Double) -> [Double] {
  Array(stride(from: first, to: end, by: interval))
}

private func nearestDistance(to time: Double, in times: [Double]) -> Double {
  times.map { abs($0 - time) }.min() ?? .infinity
}

// MARK: - 合成動画

/// 単色のフレームだけからなる小さな動画を書き出す。`brightness` でフレームごとの明るさを決める。
func makeTestVideo(
  at url: URL,
  duration: Double,
  size: (width: Int, height: Int) = (160, 90),
  framesPerSecond: Int32 = 30,
  /// 向きの情報(スマートフォンで縦に撮った動画のように、画素は横長のまま回転だけを持たせる)。
  transform: CGAffineTransform = .identity,
  brightness: (Int) -> UInt8
) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: size.width,
      AVVideoHeightKey: size.height
    ]
  )
  input.transform = transform
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: size.width,
      kCVPixelBufferHeightKey as String: size.height
    ]
  )
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)

  for frameIndex in 0..<Int(duration * Double(framesPerSecond)) {
    // 書き込みが失敗すると、受け付け可能(isReadyForMoreMediaData)には二度とならない。
    // 失敗したとき、または進まないまま長く待ったときは、理由をつけて失敗させる(待ち続けて、テスト全体を止めない)。
    let deadline = Date().addingTimeInterval(60)
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      if writer.status == .failed || writer.status == .cancelled {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
      if Date() > deadline {
        writer.cancelWriting()
        throw TestVideoWriteStalled(frame: frameIndex, status: writer.status.rawValue)
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(baseAddress, Int32(brightness(frameIndex)), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    // 追加できなかったとき(エンコーダーの失敗など)は、続けても受け付け可能にならないので、そこで失敗させる。
    guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)) else {
      throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

/// 動画の書き込みが、進まないまま長く待たされたことを表す。
nonisolated struct TestVideoWriteStalled: Error, CustomStringConvertible {
  let frame: Int
  let status: Int
  var description: String { "動画の書き込みが 60 秒進まなかった(フレーム \(frame)、書き込みの状態 \(status))" }
}

func temporaryDirectory(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// CI(GitHub Actions)か、仮想マシンの中かどうか。
/// 画面のない仮想環境では、ウィンドウの全画面化や前面化といった画面の操作が終わらず、テスト全体が固まることがある。
/// そのため、実際のウィンドウを使うテストは、この環境では飛ばす(手元の Mac では実行する)。
/// CI は、環境変数 `CI`(ワークフローで `TEST_RUNNER_CI` として渡す)と、仮想マシンかどうか(`kern.hv_vmm_present`)の両方で見分ける。
nonisolated func isRunningOnCIOrInVirtualMachine() -> Bool {
  if ProcessInfo.processInfo.environment["CI"] != nil { return true }
  var value: Int32 = 0
  var size = MemoryLayout<Int32>.size
  return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

// MARK: - ビート解析

@Suite(.serialized)
struct BeatAnalyzerTests {
  @Test
  func detectsTempoAndBeatPositionsOfClickTrack() {
    let clicks = evenClicks(from: 0.25, interval: 0.5, until: 20)
    let samples = clickTrack(duration: 20, clicks: clicks.map { ($0, 0.8) })

    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)

    #expect(abs(analysis.tempo - 120) < 2)
    #expect(abs(analysis.duration - 20) < 0.01)
    #expect(analysis.beats.count >= 30)
    let aligned = analysis.beats.filter { nearestDistance(to: $0, in: clicks) < 0.03 }
    #expect(Double(aligned.count) / Double(analysis.beats.count) >= 0.9)
  }

  @Test
  func detectsDifferentTempo() {
    let clicks = evenClicks(from: 0.2, interval: 60.0 / 90.0, until: 24)
    let samples = clickTrack(duration: 24, clicks: clicks.map { ($0, 0.8) })

    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)

    #expect(abs(analysis.tempo - 90) < 2)
  }

  @Test
  func separatesQuietAndLoudSections() {
    // 前半は小さい音でまばら、後半は大きい音で密(ノイズの下地つき)。
    var clicks: [(time: Double, amplitude: Float)] = []
    clicks += evenClicks(from: 0.5, interval: 1.0, until: 10).map { ($0, 0.05) }
    clicks += evenClicks(from: 10.25, interval: 0.5, until: 20).map { ($0, 0.8) }
    var samples = clickTrack(duration: 20, clicks: clicks)
    var generator = SeededGenerator(seed: 7)
    for index in Int(10 * testSampleRate)..<samples.count {
      samples[index] += Float.random(in: -1...1, using: &generator) * 0.15
    }

    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)

    #expect(analysis.intensity(at: 4) == .calm)
    #expect(analysis.intensity(at: 16) == .intense)
    #expect(analysis.energy(at: 4) < analysis.energy(at: 16))
  }

  @Test
  func handlesVeryShortAndSilentInput() {
    let analyzer = BeatAnalyzer()
    let tiny = analyzer.analyze(samples: [Float](repeating: 0.1, count: 500), sampleRate: testSampleRate)
    #expect(tiny.beats.isEmpty)
    #expect(tiny.intensity.count == tiny.energy.count)

    let silent = analyzer.analyze(samples: [Float](repeating: 0, count: Int(8 * testSampleRate)), sampleRate: testSampleRate)
    #expect(silent.tempo > 0)
    #expect(silent.intensity.count == silent.energy.count)
  }

  @Test
  func readsAudioFileAndConvertsSampleRate() async throws {
    let clicks = evenClicks(from: 0.25, interval: 0.5, until: 14)
    let samples = clickTrack(duration: 14, clicks: clicks.map { ($0, 0.8) })
    // 解析用とは別の標本化周波数・ステレオで書き出し、読み込み側の変換も確かめる。
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("beat-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeStereoWAV(samples: samples, sampleRate: testSampleRate, to: url)

    let analysis = try await BeatAnalyzer().analyze(url: url)

    #expect(abs(analysis.tempo - 120) < 2)
    #expect(abs(analysis.duration - 14) < 0.1)
  }

  private func writeStereoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
    let ratio = 44_100 / sampleRate
    let frameCount = AVAudioFrameCount(Double(samples.count) * ratio)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let left = try #require(buffer.floatChannelData?[0])
    let right = try #require(buffer.floatChannelData?[1])
    for frame in 0..<Int(frameCount) {
      let source = min(samples.count - 1, Int(Double(frame) / ratio))
      left[frame] = samples[source]
      right[frame] = samples[source]
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }
}

// MARK: - カット割り

@Suite(.serialized)
struct CutPlannerTests {
  private let duration = 60.0

  /// 0.5秒ごとの拍(最初の拍は0.5秒)。0〜20秒は静か、20〜40秒は盛り上がり、40〜60秒は中。
  private func makeAnalysis(beatInterval: Double = 0.5) -> MusicAnalysis {
    let beats = Array(stride(from: 0.5, to: duration - 0.1, by: beatInterval))
    var energy: [Double] = []
    var intensity: [MusicIntensity] = []
    for second in 0..<Int(duration) {
      switch second {
      case ..<20: energy.append(0.1); intensity.append(.calm)
      case ..<40: energy.append(0.9); intensity.append(.intense)
      default: energy.append(0.5); intensity.append(.medium)
      }
    }
    return MusicAnalysis(
      duration: duration,
      tempo: 60 / beatInterval,
      beats: beats,
      energy: energy,
      intensity: intensity,
      energyHop: 1.0
    )
  }

  private func profile(_ id: UUID = UUID(), duration: Double = 120, motion: Double) -> SourceMotionProfile {
    SourceMotionProfile(
      videoID: id,
      duration: duration,
      hop: 0.5,
      values: [Double](repeating: motion, count: Int(duration / 0.5))
    )
  }

  @Test
  func cutLengthFollowsIntensityAndBoundariesStayOnBeats() throws {
    let analysis = makeAnalysis()
    let pool = [profile(motion: 0.5), profile(motion: 0.5), profile(motion: 0.5)]

    let plan = try CutPlanner().plan(analysis: analysis, pool: pool, seed: 1)

    // 標準: 静か=4拍(2秒)、中=2拍(1秒)、盛り上がり=1拍(0.5秒)
    for cut in plan.cuts where cut.timelineStart >= 0.5 && cut.timelineStart < 19 {
      #expect(abs(cut.duration - 2.0) < 1e-9)
    }
    for cut in plan.cuts where cut.timelineStart >= 21 && cut.timelineStart < 39 {
      #expect(abs(cut.duration - 0.5) < 1e-9)
    }
    for cut in plan.cuts where cut.timelineStart >= 41 && cut.timelineStart < 58 {
      #expect(abs(cut.duration - 1.0) < 1e-9)
    }
    // すべての境界は拍の上(または曲の終わり)
    for cut in plan.cuts {
      let end = cut.timelineEnd
      let onBeat = analysis.beats.contains { abs($0 - end) < 1e-9 } || abs(end - duration) < 1e-9
      #expect(onBeat)
    }
  }

  @Test
  func cutsAreContiguousAndCoverTheWholeTrack() throws {
    let plan = try CutPlanner().plan(
      analysis: makeAnalysis(),
      pool: [profile(motion: 0.3), profile(motion: 0.6)],
      seed: 5
    )

    #expect(plan.cuts.first?.timelineStart == 0)
    for (previous, next) in zip(plan.cuts, plan.cuts.dropFirst()) {
      #expect(abs(previous.timelineEnd - next.timelineStart) < 1e-9)
    }
    #expect(abs((plan.cuts.last?.timelineEnd ?? 0) - duration) < 1e-9)
    #expect(abs(plan.cuts.reduce(0) { $0 + $1.duration } - duration) < 1e-6)
  }

  @Test
  func neverUsesTheSameVideoTwiceInARow() throws {
    let pool = (0..<4).map { _ in profile(motion: 0.5) }
    let plan = try CutPlanner().plan(analysis: makeAnalysis(), pool: pool, seed: 3)

    for (previous, next) in zip(plan.cuts, plan.cuts.dropFirst()) {
      #expect(previous.videoID != next.videoID)
    }
  }

  @Test
  func prefersCalmVideosForQuietPartsAndActiveVideosForLoudParts() throws {
    let calmVideos = [profile(motion: 0.1), profile(motion: 0.1)]
    let activeVideos = [profile(motion: 0.9), profile(motion: 0.9)]
    let calmIDs = Set(calmVideos.map(\.videoID))
    let activeIDs = Set(activeVideos.map(\.videoID))

    let plan = try CutPlanner().plan(
      analysis: makeAnalysis(),
      pool: calmVideos + activeVideos,
      seed: 11
    )

    let quiet = plan.cuts.filter { $0.timelineStart >= 0.5 && $0.timelineStart < 19 }
    let loud = plan.cuts.filter { $0.timelineStart >= 21 && $0.timelineStart < 39 }
    let quietShare = Double(quiet.filter { calmIDs.contains($0.videoID) }.count) / Double(quiet.count)
    let loudShare = Double(loud.filter { activeIDs.contains($0.videoID) }.count) / Double(loud.count)
    #expect(quietShare >= 0.8)
    #expect(loudShare >= 0.8)
  }

  @Test
  func sourceRangesStayInsideEachVideoAndSkipTooShortVideos() throws {
    let tooShort = profile(duration: 0.3, motion: 0.5)
    let pool = [tooShort, profile(duration: 30, motion: 0.4), profile(duration: 9, motion: 0.7)]
    let durations = Dictionary(uniqueKeysWithValues: pool.map { ($0.videoID, $0.duration) })

    let plan = try CutPlanner().plan(analysis: makeAnalysis(), pool: pool, seed: 2)

    for cut in plan.cuts {
      #expect(cut.videoID != tooShort.videoID)
      #expect(cut.sourceStart >= 0)
      #expect(cut.sourceStart + cut.duration <= durations[cut.videoID]! + 1e-9)
    }
  }

  @Test
  func cutsStayInsideTheAnalyzedWindowsOfALongVideo() throws {
    // 長い動画は離れた複数の窓だけを解析する。カットはその窓の内側(動画全体での位置)から選ばれる。
    let longVideo = UUID()
    let windows = [
      SourceMotionProfile(videoID: longVideo, offset: 10, duration: 15, hop: 0.5, values: [Double](repeating: 0.5, count: 30)),
      SourceMotionProfile(videoID: longVideo, offset: 200, duration: 15, hop: 0.5, values: [Double](repeating: 0.5, count: 30))
    ]
    let other = UUID()
    let otherWindow = SourceMotionProfile(videoID: other, offset: 60, duration: 15, hop: 0.5, values: [Double](repeating: 0.5, count: 30))

    let plan = try CutPlanner().plan(analysis: makeAnalysis(), pool: windows + [otherWindow], seed: 8)

    #expect(!plan.cuts.isEmpty)
    for cut in plan.cuts {
      let inside = (windows + [otherWindow]).contains { window in
        window.videoID == cut.videoID
          && cut.sourceStart >= window.offset - 1e-9
          && cut.sourceStart + cut.duration <= window.offset + window.duration + 1e-9
      }
      #expect(inside, "カット \(cut.timelineStart)s は解析した窓の外(元動画の \(cut.sourceStart)s)を指している")
    }
  }

  @Test
  func isDeterministicForTheSameSeed() throws {
    let pool = (0..<5).map { index in profile(motion: Double(index) / 4) }
    let planner = CutPlanner()
    let first = try planner.plan(analysis: makeAnalysis(), pool: pool, seed: 99)
    let second = try planner.plan(analysis: makeAnalysis(), pool: pool, seed: 99)
    let other = try planner.plan(analysis: makeAnalysis(), pool: pool, seed: 100)

    #expect(first == second)
    #expect(first != other)
  }

  @Test
  func doublesCutLengthWhenBeatsAreTooFast() throws {
    // 0.25秒間隔の拍。最短カットは0.3秒なので、1拍ごとの切り替えは2拍(0.5秒)になる。
    let analysis = makeAnalysis(beatInterval: 0.25)
    let plan = try CutPlanner().plan(analysis: analysis, pool: [profile(motion: 0.5), profile(motion: 0.5)], seed: 4)

    for cut in plan.cuts {
      #expect(cut.duration >= 0.3 - 1e-9)
    }
  }

  @Test
  func cutStyleChangesHowOftenTheVideoSwitches() throws {
    let pool = [profile(motion: 0.5), profile(motion: 0.5), profile(motion: 0.5)]
    var relaxed = CutPlanner()
    relaxed.style = .relaxed
    var energetic = CutPlanner()
    energetic.style = .energetic

    let relaxedPlan = try relaxed.plan(analysis: makeAnalysis(), pool: pool, seed: 1)
    let energeticPlan = try energetic.plan(analysis: makeAnalysis(), pool: pool, seed: 1)

    #expect(relaxedPlan.cuts.count < energeticPlan.cuts.count)
  }

  @Test
  func reportsClearErrors() {
    let planner = CutPlanner()
    let analysis = makeAnalysis()
    #expect(throws: CutPlannerError.emptyPool) {
      try planner.plan(analysis: analysis, pool: [], seed: 1)
    }
    var noBeats = analysis
    noBeats.beats = []
    #expect(throws: CutPlannerError.noBeats) {
      try planner.plan(analysis: noBeats, pool: [profile(motion: 0.5)], seed: 1)
    }
    #expect(throws: CutPlannerError.noClipLongEnough) {
      try planner.plan(analysis: analysis, pool: [profile(duration: 0.2, motion: 0.5)], seed: 1)
    }
  }

  @Test
  func motionProfileAveragesAndSurvivesEncoding() throws {
    let source = SourceMotionProfile(
      videoID: UUID(),
      duration: 4,
      hop: 1,
      values: [0, 0.5, 1, 1]
    )
    #expect(abs(source.meanMotion(start: 0, length: 2) - 0.25) < 1e-9)
    #expect(abs(source.meanMotion(start: 2, length: 2) - 1.0) < 1e-9)

    let decoded = try JSONDecoder().decode(SourceMotionProfile.self, from: JSONEncoder().encode(source))
    #expect(decoded == source)
    #expect(abs(decoded.meanMotion(start: 1, length: 2) - 0.75) < 1e-9)
  }
}


// MARK: - 素材の動きの解析

@Suite(.serialized)
struct ClipPoolBuilderTests {
  private func point(_ time: Double, _ frameDiff: Double) -> VisualFeaturePoint {
    VisualFeaturePoint(
      time: time, frameDiff: frameDiff, meanLuminance: 0.5, luminanceDiff: 0,
      edgeDiff: 0, motionSpike: 0, motionDrop: 0, zScore: 0
    )
  }

  @Test
  func placesWindowsInsideTheVideoWithoutOverlap() {
    let builder = ClipPoolBuilder()

    #expect(builder.windowRanges(forDuration: 0).isEmpty)
    let short = builder.windowRanges(forDuration: 10)
    #expect(short.count == 1 && short[0].offset == 0 && short[0].length == 10)

    for duration in [20.0, 45, 100, 600, 7_200] {
      let windows = builder.windowRanges(forDuration: duration)
      #expect(!windows.isEmpty)
      #expect(windows.count <= builder.maxWindowsPerVideo)
      for window in windows {
        #expect(window.offset >= 0)
        #expect(window.offset + window.length <= duration + 1e-9)
      }
      for (previous, next) in zip(windows, windows.dropFirst()) {
        #expect(previous.offset + previous.length <= next.offset + 1e-9)
      }
    }
    #expect(builder.windowRanges(forDuration: 600).count == builder.maxWindowsPerVideo)
  }

  @Test
  func limitsVideoCountDeterministically() {
    var builder = ClipPoolBuilder()
    builder.maxVideos = 5
    let sources = (0..<20).map { _ in ClipPoolSource(videoID: UUID(), url: URL(fileURLWithPath: "/dev/null"), duration: 60) }

    let first = builder.select(sources, seed: 1).map(\.videoID)
    let again = builder.select(sources, seed: 1).map(\.videoID)
    let other = builder.select(sources, seed: 2).map(\.videoID)

    #expect(first.count == 5)
    #expect(first == again)
    #expect(first != other)
    #expect(builder.select(Array(sources.prefix(3)), seed: 1).count == 3)
  }

  @Test
  func resamplesPointsOntoAnEvenGridAndFillsGaps() {
    // 窓は10〜12秒、間隔0.5秒。先頭の点(差が0)は捨てる。10.5〜11の区間には点が無いので直前の値で埋める。
    let points = [point(10.0, 0), point(10.25, 0.2), point(10.5, 0.4), point(11.5, 0.8)]

    let values = ClipPoolBuilder.resample(points: points, offset: 10, length: 2, hop: 0.5)

    #expect(values.count == 4)
    #expect(values[0] == 0.2)
    #expect(abs(values[1] - 0.4) < 1e-9)
    #expect(abs(values[2] - 0.4) < 1e-9)
    #expect(abs(values[3] - 0.8) < 1e-9)
    #expect(ClipPoolBuilder.resample(points: [point(0, 0)], offset: 0, length: 2, hop: 0.5).isEmpty)
  }

  @Test
  func normalizesAcrossAllVideosNotPerVideo() {
    let quiet = ClipPoolSource(videoID: UUID(), url: URL(fileURLWithPath: "/dev/null"), duration: 10)
    let busy = ClipPoolSource(videoID: UUID(), url: URL(fileURLWithPath: "/dev/null"), duration: 10)
    let quietWindow = RawMotionWindow(offset: 0, duration: 10, hop: 0.5, values: (0..<20).map { 0.01 + Double($0) * 0.0005 })
    let busyWindow = RawMotionWindow(offset: 5, duration: 10, hop: 0.5, values: (0..<20).map { 0.20 + Double($0) * 0.005 })

    let profiles = ClipPoolBuilder.normalizedProfiles(from: [(quiet, [quietWindow]), (busy, [busyWindow])])

    #expect(profiles.count == 2)
    let quietMean = profiles[0].meanMotion(start: 0, length: 10)
    let busyMean = profiles[1].meanMotion(start: 0, length: 10)
    #expect(quietMean < 0.2)
    #expect(busyMean > 0.8)
    #expect(profiles[1].offset == 5)
    for profile in profiles {
      #expect(profile.values.allSatisfy { (0...1).contains($0) })
    }
  }

  @Test
  func measuresRealVideosAndReusesTheCache() async throws {
    let directory = try temporaryDirectory("clip-pool")
    defer { try? FileManager.default.removeItem(at: directory) }
    let activeURL = directory.appendingPathComponent("active.mp4")
    let calmURL = directory.appendingPathComponent("calm.mp4")
    // 明滅を繰り返す動画と、変化のない動画。
    try await makeTestVideo(at: activeURL, duration: 6) { ($0 / 3) % 2 == 0 ? 40 : 220 }
    try await makeTestVideo(at: calmURL, duration: 6) { _ in 128 }

    let active = ClipPoolSource(videoID: UUID(), url: activeURL, duration: 6)
    let calm = ClipPoolSource(videoID: UUID(), url: calmURL, duration: 6)
    var builder = ClipPoolBuilder()
    builder.cacheDirectory = directory.appendingPathComponent("cache")
    let reported = LockedCounter()

    let profiles = try await builder.build(sources: [active, calm], seed: 1) { completed, total in
      reported.record(completed, of: total)
    }

    let activeProfile = try #require(profiles.first { $0.videoID == active.videoID })
    let calmProfile = try #require(profiles.first { $0.videoID == calm.videoID })
    #expect(activeProfile.meanMotion(start: 0, length: 5) > calmProfile.meanMotion(start: 0, length: 5) + 0.5)
    #expect(reported.last == (2, 2))

    let cached = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("cache").path)
    #expect(cached.count == 2)
    let again = try await builder.build(sources: [active, calm], seed: 1)
    #expect(again == profiles)
  }

  @Test
  func skipsUnreadableVideosButFailsWhenNoneWork() async throws {
    let directory = try temporaryDirectory("clip-pool-missing")
    defer { try? FileManager.default.removeItem(at: directory) }
    let goodURL = directory.appendingPathComponent("good.mp4")
    try await makeTestVideo(at: goodURL, duration: 3) { _ in 100 }
    let good = ClipPoolSource(videoID: UUID(), url: goodURL, duration: 3)
    let missing = ClipPoolSource(videoID: UUID(), url: directory.appendingPathComponent("missing.mp4"), duration: 3)

    let profiles = try await ClipPoolBuilder().build(sources: [missing, good], seed: 1)
    #expect(Set(profiles.map(\.videoID)) == [good.videoID])

    await #expect(throws: ClipPoolError.self) {
      try await ClipPoolBuilder().build(sources: [missing], seed: 1)
    }
    await #expect(throws: ClipPoolError.self) {
      try await ClipPoolBuilder().build(sources: [], seed: 1)
    }
  }
}

/// 進捗コールバックから呼ばれるので、ロックで守った記録用の入れ物。
private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (Int, Int) = (-1, -1)

  func record(_ completed: Int, of total: Int) {
    lock.lock(); defer { lock.unlock() }
    value = (completed, total)
  }

  var last: (Int, Int) {
    lock.lock(); defer { lock.unlock() }
    return value
  }
}

// MARK: - 合成と書き出し

/// 画像を `columns`×`rows` に区切り、各区画の平均の明るさ(0〜255)を返す。
func lumaGrid(_ image: CGImage, columns: Int = 4, rows: Int = 4) -> [Double] {
  let width = 64, height = 64
  var pixels = [UInt8](repeating: 0, count: width * height)
  pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(
      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  var result: [Double] = []
  let cellWidth = width / columns, cellHeight = height / rows
  for row in 0..<rows {
    for column in 0..<columns {
      var sum = 0.0
      for y in (row * cellHeight)..<((row + 1) * cellHeight) {
        for x in (column * cellWidth)..<((column + 1) * cellWidth) {
          sum += Double(pixels[y * width + x])
        }
      }
      result.append(sum / Double(cellWidth * cellHeight))
    }
  }
  return result
}

func writeSineWAV(to url: URL, duration: Double) throws {
  let sampleRate = 44_100.0
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
  let frames = AVAudioFrameCount(duration * sampleRate)
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
  buffer.frameLength = frames
  let data = try #require(buffer.floatChannelData?[0])
  for index in 0..<Int(frames) {
    data[index] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate))
  }
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  try file.write(from: buffer)
}

/// 段階の名前つきで実行し、失敗したときはどの段階かを記録してから投げ直す。
func step<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
  do {
    return try await body()
  } catch {
    Issue.record("[\(label)] \(error)")
    throw error
  }
}

@Suite(.serialized, .timeLimit(.minutes(3)))
struct MusicVideoComposerTests {
  private func cut(_ video: UUID, from sourceStart: Double, at start: Double, length: Double) -> PlannedCut {
    PlannedCut(videoID: video, sourceStart: sourceStart, duration: length, timelineStart: start, intensity: .medium)
  }

  @Test
  func composesCutsAtTheRightTimesAndExportsPlayableMP4() async throws {
    let directory = try temporaryDirectory("composer")
    defer { try? FileManager.default.removeItem(at: directory) }
    let darkURL = directory.appendingPathComponent("dark.mp4")
    let brightURL = directory.appendingPathComponent("bright.mp4")
    let portraitURL = directory.appendingPathComponent("portrait.mp4")
    let musicURL = directory.appendingPathComponent("music.wav")
    try await step("dark video") { try await makeTestVideo(at: darkURL, duration: 6) { _ in 30 } }
    try await step("bright video") { try await makeTestVideo(at: brightURL, duration: 6) { _ in 230 } }
    try await step("portrait video") { try await makeTestVideo(at: portraitURL, duration: 6, size: (90, 160)) { _ in 128 } }
    try await step("audio") { try writeSineWAV(to: musicURL, duration: 6) }

    let dark = UUID(), bright = UUID(), portrait = UUID()
    let plan = CutPlan(
      cuts: [
        cut(dark, from: 0, at: 0, length: 1),
        cut(bright, from: 2, at: 1, length: 1),
        cut(dark, from: 3.5, at: 2, length: 1),
        cut(portrait, from: 1, at: 3, length: 1),
        cut(bright, from: 5, at: 4, length: 1)
      ],
      duration: 5
    )
    let render = MusicVideoRenderSettings(width: 320, height: 180, framesPerSecond: 30)
    let composer = MusicVideoComposer()

    let composed = try await step("compose") {
      try await composer.makeComposition(
        plan: plan,
        sourceURLs: [dark: darkURL, bright: brightURL, portrait: portraitURL],
        audioURL: musicURL,
        render: render
      )
    }

    #expect(abs(composed.duration - 5) < 0.02)
    #expect(composed.composition.tracks(withMediaType: .video).count == 1)
    #expect(composed.composition.tracks(withMediaType: .audio).count == 1)
    #expect(composed.videoComposition.renderSize == render.size)

    let outputURL = directory.appendingPathComponent("out/result.mp4")
    let progress = LockedCounter()
    try await step("export") {
      try await composer.export(composed, to: outputURL) { fraction in
        progress.record(Int(fraction * 100), of: 100)
      }
    }

    let output = AVURLAsset(url: outputURL)
    let videoTrack = try #require(try await output.loadTracks(withMediaType: .video).first)
    #expect(try await output.loadTracks(withMediaType: .audio).count == 1)
    #expect(abs(try await output.load(.duration).seconds - 5) < 0.2)
    let size = try await videoTrack.load(.naturalSize)
    #expect(Int(size.width) == 320 && Int(size.height) == 180)
    #expect(progress.last.0 == 100)

    // 各カットの真ん中のフレームの明るさが、計画した素材と一致する。
    let generator = AVAssetImageGenerator(asset: output)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    func frame(at seconds: Double) async throws -> [Double] {
      try await step("frame at \(seconds)s") {
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return lumaGrid(image)
      }
    }
    #expect(try await frame(at: 0.5).allSatisfy { $0 < 80 })
    #expect(try await frame(at: 1.5).allSatisfy { $0 > 170 })
    #expect(try await frame(at: 2.5).allSatisfy { $0 < 80 })
    // 縦長の素材は画面いっぱいに拡大され、四隅まで黒帯にならない。
    #expect(try await frame(at: 3.5).allSatisfy { $0 > 90 && $0 < 170 })
    #expect(try await frame(at: 4.5).allSatisfy { $0 > 170 })
  }

  @Test
  func rejectsEmptyPlansAndMissingSources() async throws {
    let directory = try temporaryDirectory("composer-errors")
    defer { try? FileManager.default.removeItem(at: directory) }
    let musicURL = directory.appendingPathComponent("music.wav")
    try writeSineWAV(to: musicURL, duration: 2)
    let composer = MusicVideoComposer()

    await #expect(throws: MusicVideoComposerError.self) {
      try await composer.makeComposition(
        plan: CutPlan(cuts: [], duration: 2), sourceURLs: [:], audioURL: musicURL, render: .landscapeHD
      )
    }
    let unknown = UUID()
    await #expect(throws: MusicVideoComposerError.self) {
      try await composer.makeComposition(
        plan: CutPlan(cuts: [cut(unknown, from: 0, at: 0, length: 2)], duration: 2),
        sourceURLs: [:], audioURL: musicURL, render: .landscapeHD
      )
    }
  }
}

// MARK: - 曲の解析から書き出しまで通した確認

func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
  buffer.frameLength = AVAudioFrameCount(samples.count)
  let data = try #require(buffer.floatChannelData?[0])
  for (index, sample) in samples.enumerated() { data[index] = sample }
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  try file.write(from: buffer)
}

@Suite(.serialized, .timeLimit(.minutes(3)))
struct MusicVideoPipelineTests {
  /// 曲の解析 → 素材の解析 → カット割り → 合成 → 書き出し を通しで動かし、
  /// 完成映像の各カットが、計画した素材の「その時刻」の絵になっていることを確かめる。
  /// 素材の明るさを元動画の時刻に対応させてあるので、位置の取り違えは明るさのずれとして現れる。
  @Test
  func exportedFramesMatchThePlannedSourcePositions() async throws {
    let directory = try temporaryDirectory("pipeline")
    defer { try? FileManager.default.removeItem(at: directory) }

    // 曲: 120BPMのクリック(16秒)。
    let musicURL = directory.appendingPathComponent("music.wav")
    let clicks = evenClicks(from: 0.25, interval: 0.5, until: 16)
    try writeMonoWAV(
      samples: clickTrack(duration: 16, clicks: clicks.map { ($0, 0.8) }),
      sampleRate: testSampleRate,
      to: musicURL
    )

    // 素材: 40秒の動画3本。明るさが時刻に比例して上がる(A, C)ものと下がる(B)もの。
    let rampUp: (Int) -> UInt8 = { frame in UInt8(min(250, 20 + 5 * Double(frame) / 30)) }
    let rampDown: (Int) -> UInt8 = { frame in UInt8(max(5, 230 - 5 * Double(frame) / 30)) }
    let kinds: [(name: String, brightness: (Int) -> UInt8, rises: Bool)] = [
      ("a", rampUp, true), ("b", rampDown, false), ("c", rampUp, true)
    ]
    var sources: [ClipPoolSource] = []
    var rises: [UUID: Bool] = [:]
    for kind in kinds {
      let url = directory.appendingPathComponent("\(kind.name).mp4")
      try await makeTestVideo(at: url, duration: 40, brightness: kind.brightness)
      let source = ClipPoolSource(videoID: UUID(), url: url, duration: 40)
      sources.append(source)
      rises[source.videoID] = kind.rises
    }

    let analysis = try await BeatAnalyzer().analyze(url: musicURL)
    #expect(abs(analysis.tempo - 120) < 2)

    let pool = try await ClipPoolBuilder().build(sources: sources, seed: 1)
    // 40秒の動画は、冒頭・末尾を避けた2つの窓に分かれる(窓の開始位置が0でない)。
    #expect(pool.contains { $0.offset > 1 })

    var planner = CutPlanner()
    planner.style = .relaxed
    let plan = try planner.plan(analysis: analysis, pool: pool, seed: 3)
    #expect(plan.cuts.count >= 3)
    // 計画した位置は、すべて解析した窓の内側にある。
    for cut in plan.cuts {
      #expect(pool.contains { window in
        window.videoID == cut.videoID
          && cut.sourceStart >= window.offset - 1e-6
          && cut.sourceStart + cut.duration <= window.offset + window.duration + 1e-6
      })
    }

    let render = MusicVideoRenderSettings(width: 320, height: 180, framesPerSecond: 30)
    let composer = MusicVideoComposer()
    let composed = try await composer.makeComposition(
      plan: plan,
      sourceURLs: Dictionary(uniqueKeysWithValues: sources.map { ($0.videoID, $0.url) }),
      audioURL: musicURL,
      render: render
    )
    let outputURL = directory.appendingPathComponent("result.mp4")
    try await composer.export(composed, to: outputURL)

    let output = AVURLAsset(url: outputURL)
    #expect(abs(try await output.load(.duration).seconds - analysis.duration) < 0.3)

    let generator = AVAssetImageGenerator(asset: output)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    for cut in plan.cuts {
      let middle = cut.timelineStart + cut.duration / 2
      let (image, _) = try await generator.image(at: CMTime(seconds: middle, preferredTimescale: 600))
      let actual = lumaGrid(image).reduce(0, +) / 16
      let sourceTime = cut.sourceStart + cut.duration / 2
      let expected = (rises[cut.videoID] ?? true) ? 20 + 5 * sourceTime : 230 - 5 * sourceTime
      #expect(abs(actual - expected) < 25, "t=\(middle) 期待 \(expected) 実際 \(actual)")
    }
  }
}

// MARK: - 素材の選び方と設定の保存

@Suite(.serialized)
struct MusicVideoSelectionTests {
  @MainActor
  private func video(
    _ id: UUID = UUID(), duration: Double = 30, type: MediaType = .video,
    favorite: Bool = false, trashed: Bool = false
  ) -> VideoItem {
    VideoItem(
      id: id, originalFilename: "\(id.uuidString).mp4", internalFilename: "", duration: duration,
      importDate: Date(), creationDate: nil, fileHash: "", mediaType: type,
      isFavorite: favorite, isInTrash: trashed
    )
  }

  @Test @MainActor
  func combinesAlbumsIndividualVideosAndFavoritesWithoutDuplicates() {
    let (a, b, c, d, e, f) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
    let videos = [video(a), video(b), video(c), video(d), video(e, favorite: true), video(f)]
    let albums = [
      Album(id: UUID(), name: "one", videoIDs: [a, b], type: .video),
      Album(id: UUID(), name: "two", videoIDs: [b, c], type: .video),
      Album(id: UUID(), name: "unselected", videoIDs: [f], type: .video)
    ]

    let ids = MusicVideoSourceSelection.candidateIDs(
      videos: videos, albums: albums,
      selectedAlbumIDs: [albums[0].id, albums[1].id],
      selectedVideoIDs: [d],
      includeFavorites: true
    )

    // ライブラリの並び順のまま、重複なし。選ばれていない f は入らない。
    #expect(ids == [a, b, c, d, e])
  }

  @Test @MainActor
  func excludesTrashPhotosAndTooShortVideos() {
    let (ok, trashed, photo, tiny) = (UUID(), UUID(), UUID(), UUID())
    let videos = [
      video(ok), video(trashed, trashed: true), video(photo, type: .photo), video(tiny, duration: 0.4)
    ]
    let album = Album(id: UUID(), name: "all", videoIDs: [ok, trashed, photo, tiny], type: .mixed)

    let ids = MusicVideoSourceSelection.candidateIDs(
      videos: videos, albums: [album], selectedAlbumIDs: [album.id], selectedVideoIDs: [], includeFavorites: false
    )

    #expect(ids == [ok])
  }

  @Test @MainActor
  func favoritesOnlyCountWhenTheToggleIsOn() {
    let favorite = UUID()
    let videos = [video(favorite, favorite: true), video()]

    let off = MusicVideoSourceSelection.candidateIDs(
      videos: videos, albums: [], selectedAlbumIDs: [], selectedVideoIDs: [], includeFavorites: false
    )
    let on = MusicVideoSourceSelection.candidateIDs(
      videos: videos, albums: [], selectedAlbumIDs: [], selectedVideoIDs: [], includeFavorites: true
    )

    #expect(off.isEmpty)
    #expect(on == [favorite])
  }

  @Test
  func preferencesRoundTripThroughUserDefaults() throws {
    let suite = "musicvideo-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MusicVideoPreferencesStore(defaults: defaults)
    #expect(store.load() == MusicVideoPreferences())

    var preferences = MusicVideoPreferences()
    preferences.cutStyle = .energetic
    preferences.renderPreset = .portraitHD
    preferences.exportQuality = .compact
    preferences.selectedAlbumIDs = [UUID(), UUID()]
    preferences.selectedVideoIDs = [UUID()]
    preferences.includeFavorites = true
    preferences.musicFolderPath = "/Users/example/Music"
    preferences.recordRecentMusic("/Users/example/Music/a.mp3")
    store.save(preferences)

    #expect(store.load() == preferences)
  }

  @Test
  func brokenOrOldPreferencesFallBackToDefaults() throws {
    let suite = "musicvideo-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MusicVideoPreferencesStore(defaults: defaults)

    defaults.set(Data("not json".utf8), forKey: store.key)
    #expect(store.load() == MusicVideoPreferences())

    // 項目が足りない古い保存データでも、読めた分は使い、残りは既定値になる。
    defaults.set(Data(#"{"cutStyle":"relaxed"}"#.utf8), forKey: store.key)
    let loaded = store.load()
    #expect(loaded.cutStyle == .relaxed)
    #expect(loaded.renderPreset == .landscapeFullHD)
    #expect(loaded.exportQuality == .high)
    #expect(loaded.selectedAlbumIDs.isEmpty)
  }

  @Test
  func recentMusicKeepsNewestFirstWithoutDuplicatesUpToTheLimit() {
    var preferences = MusicVideoPreferences()
    for index in 0..<12 { preferences.recordRecentMusic("/m/\(index).mp3") }
    preferences.recordRecentMusic("/m/5.mp3")

    #expect(preferences.recentMusicPaths.count == MusicVideoPreferences.recentMusicLimit)
    #expect(preferences.recentMusicPaths.first == "/m/5.mp3")
    #expect(Set(preferences.recentMusicPaths).count == preferences.recentMusicPaths.count)
    #expect(!preferences.recentMusicPaths.contains("/m/0.mp3"))
  }

  @Test
  func prunedDropsSelectionsThatNoLongerExistInTheLibrary() {
    let (keptAlbum, goneAlbum, keptVideo, goneVideo) = (UUID(), UUID(), UUID(), UUID())
    var preferences = MusicVideoPreferences()
    preferences.selectedAlbumIDs = [keptAlbum, goneAlbum]
    preferences.selectedVideoIDs = [goneVideo, keptVideo]

    let pruned = preferences.pruned(validAlbumIDs: [keptAlbum], validVideoIDs: [keptVideo])

    #expect(pruned.selectedAlbumIDs == [keptAlbum])
    #expect(pruned.selectedVideoIDs == [keptVideo])
  }
}

// MARK: - カット単位の差し替え

@Suite(.serialized)
struct CutEditingTests {
  private let duration = 60.0

  private func makeAnalysis() -> MusicAnalysis {
    let beats = Array(stride(from: 0.5, to: duration - 0.1, by: 0.5))
    let energy = [Double](repeating: 0.6, count: Int(duration))
    let intensity = [MusicIntensity](repeating: .medium, count: Int(duration))
    return MusicAnalysis(duration: duration, tempo: 120, beats: beats, energy: energy, intensity: intensity, energyHop: 1)
  }

  /// 長さ60秒の窓を1つ持つ動画。`motion` は一定。
  private func window(_ id: UUID = UUID(), offset: Double = 0, length: Double = 60, motion: Double = 0.5) -> SourceMotionProfile {
    SourceMotionProfile(videoID: id, offset: offset, duration: length, hop: 0.5, values: [Double](repeating: motion, count: Int(length / 0.5)))
  }

  private func makePlan(pool: [SourceMotionProfile], seed: UInt64 = 1) throws -> CutPlan {
    try CutPlanner().plan(analysis: makeAnalysis(), pool: pool, seed: seed)
  }

  private func range(of cut: PlannedCut) -> Range<Double> { cut.sourceStart..<(cut.sourceStart + cut.duration) }

  @Test
  func replacingACutKeepsItsSlotAndLeavesOtherCutsUntouched() throws {
    let pool = (0..<5).map { _ in window() }
    let plan = try makePlan(pool: pool)
    let index = plan.cuts.count / 2

    let edited = try CutPlanner().replaceCut(at: index, in: plan, analysis: makeAnalysis(), pool: pool, seed: 7)

    #expect(edited.cuts.count == plan.cuts.count)
    #expect(edited.duration == plan.duration)
    let before = plan.cuts[index], after = edited.cuts[index]
    #expect(after.timelineStart == before.timelineStart)
    #expect(after.duration == before.duration)
    #expect(after.intensity == before.intensity)
    // 元の区間とは重ならない別の位置(動画が変わるか、同じ動画なら別の場所)になる。
    #expect(after.videoID != before.videoID || !range(of: after).overlaps(range(of: before)))
    for other in plan.cuts.indices where other != index {
      #expect(edited.cuts[other] == plan.cuts[other])
    }
  }

  @Test
  func replacementAvoidsTheNeighboursVideoWhenOthersExist() throws {
    let pool = (0..<5).map { _ in window() }
    let plan = try makePlan(pool: pool)

    for index in [1, plan.cuts.count / 2, plan.cuts.count - 2] {
      for seed in UInt64(1)...UInt64(5) {
        let edited = try CutPlanner().replaceCut(at: index, in: plan, analysis: makeAnalysis(), pool: pool, seed: seed)
        #expect(edited.cuts[index].videoID != plan.cuts[index - 1].videoID)
        #expect(edited.cuts[index].videoID != plan.cuts[index + 1].videoID)
      }
    }
  }

  @Test
  func exclusionAndForcedVideoAreHonoured() throws {
    let target = UUID()
    let pool = [window(target), window(), window(), window()]
    let plan = try makePlan(pool: pool)
    let planner = CutPlanner()
    let analysis = makeAnalysis()

    for index in plan.cuts.indices.prefix(20) {
      let excluded = try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: 3, excluding: [target])
      #expect(excluded.cuts[index].videoID != target)

      let forced = try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: 3, forcing: target)
      #expect(forced.cuts[index].videoID == target)
    }
  }

  @Test
  func replacementStaysInsideTheAnalyzedWindows() throws {
    let video = UUID()
    let pool = [
      window(video, offset: 10, length: 15),
      window(video, offset: 200, length: 15),
      window(offset: 50, length: 15)
    ]
    let plan = try makePlan(pool: pool)

    for index in plan.cuts.indices.prefix(30) {
      let edited = try CutPlanner().replaceCut(at: index, in: plan, analysis: makeAnalysis(), pool: pool, seed: 11)
      let cut = edited.cuts[index]
      #expect(pool.contains { window in
        window.videoID == cut.videoID
          && cut.sourceStart >= window.offset - 1e-9
          && cut.sourceStart + cut.duration <= window.offset + window.duration + 1e-9
      })
    }
  }

  @Test
  func isDeterministicAndVariesWithTheSeed() throws {
    let pool = (0..<6).map { _ in window() }
    let plan = try makePlan(pool: pool)
    let planner = CutPlanner()
    let analysis = makeAnalysis()
    let index = 10

    let first = try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: 21)
    let again = try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: 21)
    #expect(first == again)

    let results = try (1...12).map { seed in
      try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: UInt64(seed)).cuts[index]
    }
    #expect(Set(results.map { "\($0.videoID)-\($0.sourceStart)" }).count > 1)
  }

  @Test
  func replacingEveryUseOfAVideoRemovesItEverywhere() throws {
    let unwanted = UUID()
    let pool = [window(unwanted), window(), window(), window()]
    let plan = try makePlan(pool: pool)
    #expect(plan.cuts.contains { $0.videoID == unwanted })

    let edited = try CutPlanner().replaceAllCuts(usingVideo: unwanted, in: plan, analysis: makeAnalysis(), pool: pool, seed: 5)

    #expect(!edited.cuts.contains { $0.videoID == unwanted })
    #expect(edited.cuts.map(\.timelineStart) == plan.cuts.map(\.timelineStart))
    #expect(edited.cuts.map(\.duration) == plan.cuts.map(\.duration))
    // 他の動画を使っていたカットはそのまま。
    for index in plan.cuts.indices where plan.cuts[index].videoID != unwanted {
      #expect(edited.cuts[index] == plan.cuts[index])
    }
  }

  @Test
  func reportsAProblemInsteadOfCrashingWhenNothingCanBeUsed() throws {
    let only = UUID()
    let pool = [window(only)]
    let plan = try makePlan(pool: pool)
    let planner = CutPlanner()
    let analysis = makeAnalysis()

    // 動画が1本だけでも、別の位置を選べる。
    let edited = try planner.replaceCut(at: 3, in: plan, analysis: analysis, pool: pool, seed: 1)
    #expect(edited.cuts[3].videoID == only)

    // 候補をすべて除外すると、エラーになる。
    #expect(throws: CutPlannerError.emptyPool) {
      try planner.replaceCut(at: 3, in: plan, analysis: analysis, pool: pool, seed: 1, excluding: [only])
    }
    // 指定した動画に、カットの長さを満たす窓がなければエラー。
    let tooShort = window(UUID(), length: 0.2)
    #expect(throws: CutPlannerError.noClipLongEnough) {
      try planner.replaceCut(at: 3, in: plan, analysis: analysis, pool: pool + [tooShort], seed: 1, forcing: tooShort.videoID)
    }
    // 範囲外の番号は何も変えない。
    #expect(try planner.replaceCut(at: 9_999, in: plan, analysis: analysis, pool: pool, seed: 1) == plan)
  }

  @Test
  func findsTheCutAtAGivenTime() throws {
    let plan = try makePlan(pool: [window(), window()])

    #expect(plan.cutIndex(at: 0) == 0)
    #expect(plan.cutIndex(at: -5) == 0)
    #expect(plan.cutIndex(at: plan.duration + 100) == plan.cuts.count - 1)
    for index in plan.cuts.indices {
      let cut = plan.cuts[index]
      #expect(plan.cutIndex(at: cut.timelineStart) == index)
      #expect(plan.cutIndex(at: cut.timelineStart + cut.duration / 2) == index)
    }
    #expect(CutPlan(cuts: [], duration: 0).cutIndex(at: 1) == nil)
  }
}


// MARK: - 書き出しの画質

/// 動きのある模様の動画(単色だとビットレートの差が出ないため)。
private func makePatternVideo(at url: URL, duration: Double, width: Int = 640, height: Int = 360) async throws {
  let framesPerSecond: Int32 = 30
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
    ]
  )
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
    ]
  )
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  for frame in 0..<Int(duration * Double(framesPerSecond)) {
    // 書き込みが失敗したとき、または進まないまま長く待ったときは、理由をつけて失敗させる(待ち続けない)。
    let deadline = Date().addingTimeInterval(60)
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      if writer.status == .failed || writer.status == .cancelled {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
      if Date() > deadline {
        writer.cancelWriting()
        throw TestVideoWriteStalled(frame: frame, status: writer.status.rawValue)
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
      let row = base + y * stride
      for x in 0..<width {
        let v = UInt8(truncatingIfNeeded: ((x / 3) + frame * 5) ^ ((y / 3) + frame * 2))
        row[x * 4] = v; row[x * 4 + 1] = v &* 3; row[x * 4 + 2] = 255 &- v; row[x * 4 + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)) else {
      throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

@Suite(.serialized, .timeLimit(.minutes(3)))
struct MusicVideoExportQualityTests {
  @Test
  func bitrateScalesWithQualityAndScreenSize() {
    let full = MusicVideoRenderSettings.landscapeFullHD
    let hd = MusicVideoRenderSettings.landscapeHD

    let high = MusicVideoExportQuality.high.videoBitRate(for: full)
    let standard = MusicVideoExportQuality.standard.videoBitRate(for: full)
    let compact = MusicVideoExportQuality.compact.videoBitRate(for: full)
    #expect(high > standard && standard > compact)
    #expect(MusicVideoExportQuality.high.videoBitRate(for: hd) < high)
    // 縦向きでも画素数が同じなら同じビットレート。
    #expect(MusicVideoExportQuality.high.videoBitRate(for: .portraitFullHD) == high)
    // 1080pの「高画質」は、実測した従来の書き出し(約10Mbps)とほぼ同じ。
    #expect(abs(Double(high) - 10_000_000) < 500_000)
    #expect(MusicVideoExportQuality.compact.estimatedMegabytesPerMinute(for: full) < MusicVideoExportQuality.high.estimatedMegabytesPerMinute(for: full))
  }

  @Test
  func lowerQualityMakesSmallerFilesThatStillPlayCorrectly() async throws {
    let directory = try temporaryDirectory("export-quality")
    defer { try? FileManager.default.removeItem(at: directory) }
    let videoURL = directory.appendingPathComponent("pattern.mp4")
    let musicURL = directory.appendingPathComponent("music.wav")
    try await makePatternVideo(at: videoURL, duration: 8)
    try writeSineWAV(to: musicURL, duration: 6)

    let video = UUID()
    let plan = CutPlan(
      cuts: (0..<6).map { index in
        PlannedCut(videoID: video, sourceStart: Double(index), duration: 1, timelineStart: Double(index), intensity: .medium)
      },
      duration: 6
    )
    let render = MusicVideoRenderSettings(width: 640, height: 360, framesPerSecond: 30)
    let composer = MusicVideoComposer()
    let composed = try await composer.makeComposition(plan: plan, sourceURLs: [video: videoURL], audioURL: musicURL, render: render)

    var sizes: [MusicVideoExportQuality: Int] = [:]
    for quality in MusicVideoExportQuality.allCases {
      let outputURL = directory.appendingPathComponent("out-\(quality.rawValue).mp4")
      try await composer.export(composed, to: outputURL, quality: quality)
      sizes[quality] = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0

      // どの画質でも、画面サイズ・長さ・音声は変わらない。
      let asset = AVURLAsset(url: outputURL)
      let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
      let size = try await track.load(.naturalSize)
      #expect(Int(size.width) == 640 && Int(size.height) == 360)
      #expect(abs(try await asset.load(.duration).seconds - 6) < 0.2)
      #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    let high = try #require(sizes[.high]), standard = try #require(sizes[.standard]), compact = try #require(sizes[.compact])
    #expect(high > standard, "高画質 \(high) 標準 \(standard)")
    #expect(standard > compact, "標準 \(standard) 小さめ \(compact)")
  }

  @Test
  func cancellingAnExportLeavesNoFile() async throws {
    let directory = try temporaryDirectory("export-cancel")
    defer { try? FileManager.default.removeItem(at: directory) }
    let videoURL = directory.appendingPathComponent("pattern.mp4")
    let musicURL = directory.appendingPathComponent("music.wav")
    try await makePatternVideo(at: videoURL, duration: 12)
    try writeSineWAV(to: musicURL, duration: 10)
    let video = UUID()
    let plan = CutPlan(
      cuts: (0..<10).map { PlannedCut(videoID: video, sourceStart: Double($0), duration: 1, timelineStart: Double($0), intensity: .medium) },
      duration: 10
    )
    let composer = MusicVideoComposer()
    let composed = try await composer.makeComposition(
      plan: plan, sourceURLs: [video: videoURL], audioURL: musicURL,
      render: MusicVideoRenderSettings(width: 640, height: 360, framesPerSecond: 30)
    )
    // 取り消すタイミングを変えて何度も試す(開始前・読み出し中・終わりぎわ)。
    for (attempt, delay) in [0, 5, 20, 50, 100, 150, 250, 400, 700].enumerated() {
      let outputURL = directory.appendingPathComponent("cancelled-\(attempt).mp4")
      let task = Task { try await composer.export(composed, to: outputURL, quality: .high) }
      try await Task.sleep(for: .milliseconds(delay))
      task.cancel()
      let result = await task.result

      switch result {
      case .success:
        // 取り消しより先に終わった場合は、完成したファイルがあればよい。
        #expect(FileManager.default.fileExists(atPath: outputURL.path), "試行\(attempt)")
      case .failure(let error):
        #expect(error is CancellationError, "試行\(attempt): \(error)")
        #expect(!FileManager.default.fileExists(atPath: outputURL.path), "試行\(attempt)")
      }
    }
  }

  @Test @MainActor
  func outputFileNamesAreSafeAndStamped() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let name = MusicVideoViewModel.outputFileName(musicTitle: "a/b:c*d?e", date: date)
    #expect(name.hasPrefix("MusicVideo_a_b_c_d_e_"))
    #expect(name.hasSuffix(".mp4"))
    #expect(!name.dropFirst(4).contains("/"))
  }
}
