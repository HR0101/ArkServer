// ArkServerTests/MusicVideoTuningTests.swift

import AVFoundation
import Foundation
import Testing
@testable import ArkServer

// MARK: - 共通の部品

/// 0.5秒ごとの拍。`intensityAt` が、秒ごとの盛り上がりの段階を決める。
private func makeAnalysis(
  duration: Double = 60,
  beatInterval: Double = 0.5,
  intensityAt: (Int) -> MusicIntensity = { second in
    switch second {
    case ..<20: return .calm
    case ..<40: return .intense
    default: return .medium
    }
  }
) -> MusicAnalysis {
  let beats = Array(stride(from: beatInterval, to: duration - 0.1, by: beatInterval))
  var energy: [Double] = []
  var intensity: [MusicIntensity] = []
  for second in 0..<Int(duration) {
    let level = intensityAt(second)
    intensity.append(level)
    energy.append(level == .calm ? 0.1 : (level == .intense ? 0.9 : 0.5))
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

private func motionProfile(_ id: UUID = UUID(), duration: Double = 120, motion: Double) -> SourceMotionProfile {
  SourceMotionProfile(
    videoID: id,
    duration: duration,
    hop: 0.5,
    values: [Double](repeating: motion, count: Int(duration / 0.5))
  )
}

private func plannedCut(_ video: UUID, from sourceStart: Double, at start: Double, length: Double) -> PlannedCut {
  PlannedCut(videoID: video, sourceStart: sourceStart, duration: length, timelineStart: start, intensity: .medium)
}

// MARK: - カット割りの調整項目

@Suite(.serialized)
struct CutTuningPlannerTests {
  private func plan(
    _ analysis: MusicAnalysis,
    pool: [SourceMotionProfile],
    style: MusicVideoCutStyle = .standard,
    tuning: MusicVideoCutTuning = MusicVideoCutTuning(),
    seed: UInt64 = 1
  ) throws -> CutPlan {
    try CutPlanner(style: style, tuning: tuning).plan(analysis: analysis, pool: pool, seed: seed)
  }

  @Test
  func effectiveBeatsFollowStyleMinimumAndMaximum() {
    // 標準: 静か=4拍。0.5秒間隔なら2.0秒。
    var planner = CutPlanner(style: .standard, tuning: MusicVideoCutTuning())
    #expect(planner.effectiveBeats(for: .calm, beatInterval: 0.5) == 4)
    #expect(planner.effectiveBeats(for: .intense, beatInterval: 0.5) == 1)

    // 最長 1.5秒 → 3拍まで。
    planner.maximumCutDuration = 1.5
    #expect(planner.effectiveBeats(for: .calm, beatInterval: 0.5) == 3)
    #expect(planner.effectiveBeats(for: .intense, beatInterval: 0.5) == 1)

    // 最短 3秒 → 1拍(0.5秒)は倍々にして 8拍(4秒)。最長は外す。
    planner.maximumCutDuration = nil
    planner.minimumCutDuration = 3
    #expect(planner.effectiveBeats(for: .intense, beatInterval: 0.5) == 8)
  }

  @Test
  func maximumCutDurationShortensLongCuts() throws {
    let analysis = makeAnalysis()
    let pool = [motionProfile(motion: 0.5), motionProfile(motion: 0.5), motionProfile(motion: 0.5)]

    // 控えめだと静かな所は8拍(4秒)。最長を決めなければ 1.5 秒を超えるカットがある。
    let unlimited = try plan(analysis, pool: pool, style: .relaxed)
    #expect(unlimited.cuts.contains { $0.duration > 1.5 + 1e-9 })

    var tuning = MusicVideoCutTuning()
    tuning.setMaximum(1.5)
    let limited = try plan(analysis, pool: pool, style: .relaxed, tuning: tuning)
    #expect(limited.cuts.allSatisfy { $0.duration <= 1.5 + 1e-9 })
    #expect(limited.cuts.count > unlimited.cuts.count)
    // 短くしても、曲の全体を隙間なく覆う。
    #expect(limited.cuts.first?.timelineStart == 0)
    #expect(abs((limited.cuts.last?.timelineEnd ?? 0) - analysis.duration) < 1e-9)
  }

  @Test
  func minimumCutDurationLengthensFastCuts() throws {
    // 0.25秒間隔(テンポ240)。標準の「盛り上がり」は1拍=0.25秒で、最短(0.3秒)に足りないので倍になる。
    let analysis = makeAnalysis(beatInterval: 0.25)
    let pool = [motionProfile(motion: 0.5), motionProfile(motion: 0.5), motionProfile(motion: 0.5)]

    var tuning = MusicVideoCutTuning()
    tuning.setMinimum(1.0)
    let result = try plan(analysis, pool: pool, tuning: tuning)

    // 最初(導入部)と最後(曲の終わり)を除き、1秒に満たないカットは無い。小節に揃える途中でも守られる。
    let inner = result.cuts.dropFirst().dropLast()
    #expect(!inner.isEmpty)
    #expect(inner.allSatisfy { $0.duration >= 1.0 - 1e-9 })

    let defaultPlan = try plan(analysis, pool: pool)
    #expect(result.cuts.count < defaultPlan.cuts.count)
  }

  @Test
  func minimumAndMaximumStayConsistent() {
    var tuning = MusicVideoCutTuning()
    tuning.setMaximum(2.0)
    tuning.setMinimum(3.0)
    #expect(tuning.maximumCutDuration == 3.0)  // 最短が最長を超えるなら、最長も延びる

    tuning.setMaximum(1.0)
    #expect(tuning.minimumCutDuration == 1.0)  // 最長が最短を下回るなら、最短も縮む

    tuning.setMaximum(nil)
    #expect(tuning.maximumCutDuration == nil)
    #expect(tuning.minimumCutDuration == 1.0)
  }

  @Test
  func freeAlignmentCutsExactlyTheChosenNumberOfBeats() throws {
    let analysis = makeAnalysis()
    let pool = [motionProfile(motion: 0.5), motionProfile(motion: 0.5), motionProfile(motion: 0.5)]

    var tuning = MusicVideoCutTuning()
    tuning.alignment = .free
    let free = try plan(analysis, pool: pool, tuning: tuning)
    let aligned = try plan(analysis, pool: pool)

    // 拍の数どおり: 標準は 静か=2.0秒・中=1.0秒・盛り上がり=0.5秒のどれかだけ(最初と最後を除く)。
    for cut in free.cuts.dropFirst().dropLast() {
      #expect([2.0, 1.0, 0.5].contains { abs($0 - cut.duration) < 1e-9 })
    }
    // 40秒で「盛り上がり」から「中」(2拍=1.0秒)に変わる。拍の数どおりなら、その 40.0 秒からぴったり1.0秒。
    func cut(at time: Double, in plan: CutPlan) -> PlannedCut? {
      plan.cuts.first { abs($0.timelineStart - time) < 1e-9 }
    }
    #expect(cut(at: 40.0, in: free)?.duration == 1.0)
    // 区切りにそろえると、2拍のカットは区切り(拍の偶数番目)から始めるので、40.0 秒は半端な0.5秒になり、
    // 1.0秒のカットはその次(40.5 秒)から始まる。
    #expect(cut(at: 40.0, in: aligned)?.duration == 0.5)
    #expect(cut(at: 40.5, in: aligned)?.duration == 1.0)
    #expect(free != aligned)
  }

  @Test
  func motionMatchingStrengthChangesHowCloselyMotionFollowsTheSong() throws {
    // 動きの少ない動画と、多い動画を同数。曲の真ん中は「盛り上がり」(狙いは動きが大きい)。
    let calmVideos = (0..<5).map { _ in motionProfile(motion: 0.1) }
    let busyVideos = (0..<5).map { _ in motionProfile(motion: 0.9) }
    let pool = calmVideos + busyVideos
    let analysis = makeAnalysis(intensityAt: { _ in .intense })

    func averageMatch(_ matching: MotionMatching) throws -> Double {
      var total = 0.0
      for seed in 1...5 as ClosedRange<UInt64> {
        var tuning = MusicVideoCutTuning()
        tuning.motionMatching = matching
        let result = try plan(analysis, pool: pool, tuning: tuning, seed: seed)
        total += try #require(MusicVideoPlanStats(plan: result, pool: pool, analysis: analysis).motionMatch)
      }
      return total / 5
    }

    let strong = try averageMatch(.strong)
    let standard = try averageMatch(.standard)
    let off = try averageMatch(.off)
    #expect(strong > 0.95)
    #expect(strong >= standard - 1e-9)
    // 合わせないと、動きの少ない動画も混ざるので一致度が下がる。
    #expect(off < strong - 0.2)
  }

  @Test
  func varietyChangesHowOftenTheSameVideosAreReused() throws {
    // 動きの大きさが少しずつ違う12本。動きを強く合わせる設定で、使い回しの差が出る。
    let pool = (0..<12).map { motionProfile(motion: Double($0) / 11) }
    let analysis = makeAnalysis(duration: 120)

    func usage(_ variety: VideoVariety) throws -> (distinct: Int, topShare: Double) {
      var distinctTotal = 0
      var topShareTotal = 0.0
      for seed in 1...6 as ClosedRange<UInt64> {
        var tuning = MusicVideoCutTuning()
        tuning.variety = variety
        tuning.motionMatching = .strong
        let result = try plan(analysis, pool: pool, tuning: tuning, seed: seed)
        var counts: [UUID: Int] = [:]
        for cut in result.cuts { counts[cut.videoID, default: 0] += 1 }
        distinctTotal += counts.count
        topShareTotal += Double(counts.values.max() ?? 0) / Double(result.cuts.count)
      }
      return (distinctTotal, topShareTotal / 6)
    }

    let wide = try usage(.wide)
    let standard = try usage(.standard)
    let repeating = try usage(.repeating)
    #expect(wide.distinct >= standard.distinct)
    #expect(standard.distinct >= repeating.distinct)
    #expect(wide.distinct > repeating.distinct)
    // 使い回しを許すと、よく使う動画に偏る。
    #expect(repeating.topShare > wide.topShare)
  }

  @Test
  func replacingACutHonoursTheSameTuning() throws {
    let analysis = makeAnalysis()
    let pool = (0..<6).map { motionProfile(motion: Double($0) / 5) }
    var tuning = MusicVideoCutTuning()
    tuning.variety = .wide
    let planner = CutPlanner(style: .standard, tuning: tuning)
    let original = try planner.plan(analysis: analysis, pool: pool, seed: 3)

    let replaced = try planner.replaceCut(at: 4, in: original, analysis: analysis, pool: pool, seed: 9)
    // 差し替えても、カットの枠(位置と長さ)は変わらない。
    #expect(replaced.cuts.count == original.cuts.count)
    #expect(replaced.cuts[4].timelineStart == original.cuts[4].timelineStart)
    #expect(replaced.cuts[4].duration == original.cuts[4].duration)
  }
}

// MARK: - 曲の範囲

struct MusicRangeTests {
  @Test
  func trimmingShiftsBeatsAndSlicesTheEnergy() {
    let analysis = makeAnalysis(duration: 60)  // 拍は 0.5, 1.0, … / 0〜20秒は静か、20〜40秒は盛り上がり
    let range = MusicRange(start: 18, end: 42)
    let trimmed = analysis.trimmed(to: range)

    #expect(trimmed.duration == 24)
    #expect(trimmed.tempo == analysis.tempo)
    // 拍は範囲の先頭が 0 秒になるようにずれ、範囲の外の拍は消える。
    #expect(trimmed.beats.first == 0)  // 元の 18.0 秒の拍
    #expect(trimmed.beats.allSatisfy { $0 >= 0 && $0 < 24 })
    #expect(trimmed.beats.count == 48)
    // 盛り上がりの段階も、範囲に合わせてずれる(18〜20秒は静か、20〜40秒は盛り上がり、40秒以降は中)。
    #expect(trimmed.intensity(at: 1) == .calm)
    #expect(trimmed.intensity(at: 3) == .intense)
    #expect(trimmed.intensity(at: 23) == .medium)
    #expect(trimmed.energy.count == 24)
  }

  @Test
  func clampedRangesStayInsideTheSongAndKeepAMinimumLength() {
    // 全体と同じなら範囲なし。
    #expect(MusicRange.clamped(start: 0, end: 60, songDuration: 60) == nil)
    #expect(MusicRange.clamped(start: -5, end: 80, songDuration: 60) == nil)

    let inside = MusicRange.clamped(start: 10, end: 30, songDuration: 60)
    #expect(inside == MusicRange(start: 10, end: 30))

    // 短すぎるときは、最短の長さまで広げる。
    let tiny = MusicRange.clamped(start: 10, end: 11, songDuration: 60)
    #expect(tiny == MusicRange(start: 10, end: 15))

    // 曲の終わりを越える開始は、最短の長さが残る位置まで戻す。
    let late = MusicRange.clamped(start: 59, end: 60, songDuration: 60)
    #expect(late == MusicRange(start: 55, end: 60))
  }

  @Test
  func nearestBeatSnapsAStartTimeToTheBeatGrid() {
    let analysis = makeAnalysis(duration: 30)
    #expect(analysis.nearestBeat(to: 10.2) == 10.0)
    #expect(analysis.nearestBeat(to: 10.3) == 10.5)
  }
}

// MARK: - 結果の数値

struct MusicVideoPlanStatsTests {
  @Test
  func statsDescribeTheCutsAndTheVideosUsed() {
    let first = UUID(), second = UUID(), unused = UUID()
    let plan = CutPlan(
      cuts: [
        plannedCut(first, from: 0, at: 0, length: 1),
        plannedCut(second, from: 0, at: 1, length: 2),
        plannedCut(first, from: 5, at: 3, length: 3)
      ],
      duration: 6
    )
    let pool = [
      motionProfile(first, motion: 0.5),
      motionProfile(second, motion: 0.5),
      motionProfile(unused, motion: 0.5)
    ]
    let stats = MusicVideoPlanStats(plan: plan, pool: pool, analysis: nil)

    #expect(stats.cutCount == 3)
    #expect(abs(stats.averageCutDuration - 2.0) < 1e-9)
    #expect(stats.shortestCutDuration == 1)
    #expect(stats.longestCutDuration == 3)
    #expect(stats.usedVideoCount == 2)
    #expect(stats.poolVideoCount == 3)
    #expect(stats.motionMatch == nil)  // 曲の解析が無ければ調べられない
  }

  @Test
  func changeSummaryNamesOnlyWhatChanged() {
    func stats(cuts: Int, average: Double, used: Int, match: Double?) -> MusicVideoPlanStats {
      let id = UUID()
      var result = MusicVideoPlanStats(
        plan: CutPlan(cuts: [plannedCut(id, from: 0, at: 0, length: 1)], duration: 1),
        pool: [],
        analysis: nil
      )
      result.cutCount = cuts
      result.averageCutDuration = average
      result.usedVideoCount = used
      result.motionMatch = match
      return result
    }

    let summary = MusicVideoChangeSummary(
      title: "最長のカット",
      before: stats(cuts: 64, average: 1.4, used: 9, match: 0.80),
      after: stats(cuts: 48, average: 1.9, used: 9, match: 0.78)
    )
    #expect(summary.text == "「最長のカット」を変えました：カット 64 → 48・平均 1.4秒 → 1.9秒・動きの一致 80％ → 78％")

    let same = MusicVideoChangeSummary(
      title: "画面の合わせ方",
      before: stats(cuts: 10, average: 2, used: 5, match: 0.5),
      after: stats(cuts: 10, average: 2, used: 5, match: 0.5)
    )
    #expect(same.text.contains("大きな違いはありません"))
  }

  @Test
  func changeSummaryReportsTheBeatAlignment() {
    func stats(hit: Double?) -> MusicVideoPlanStats {
      var result = MusicVideoPlanStats(
        plan: CutPlan(cuts: [plannedCut(UUID(), from: 0, at: 0, length: 1)], duration: 1),
        pool: [],
        analysis: nil
      )
      result.hitAlignment = hit
      return result
    }

    let improved = MusicVideoChangeSummary(title: "拍への合わせ込み", before: stats(hit: 0.44), after: stats(hit: 1.0))
    #expect(improved.text == "「拍への合わせ込み」を変えました：拍の一致 44％ → 100％")

    // 片方でも調べられなければ、比べない。小さな差も出さない。
    let unknown = MusicVideoChangeSummary(title: "拍への合わせ込み", before: stats(hit: nil), after: stats(hit: 1.0))
    #expect(unknown.text.contains("大きな違いはありません"))
    let tiny = MusicVideoChangeSummary(title: "拍への合わせ込み", before: stats(hit: 0.800), after: stats(hit: 0.805))
    #expect(tiny.text.contains("大きな違いはありません"))
  }
}

// MARK: - 保存

struct MusicVideoTuningPreferencesTests {
  @Test
  func oldSavedPreferencesStillLoadWithDefaultTuning() throws {
    let legacy = #"{"cutStyle":"energetic","renderPreset":"landscapeHD","exportQuality":"standard"}"#
    let decoded = try JSONDecoder().decode(MusicVideoPreferences.self, from: Data(legacy.utf8))
    #expect(decoded.cutStyle == .energetic)
    #expect(decoded.cutTuning == MusicVideoCutTuning())
    #expect(decoded.lookTuning == MusicVideoLookTuning())
  }

  @Test
  func lookTuningSavedBeforeSourceAudioStillLoadsWithItOff() throws {
    let legacy = #"{"cutStyle":"standard","lookTuning":{"fitMode":"fit","transition":"crossfade","fadeSeconds":1}}"#
    let decoded = try JSONDecoder().decode(MusicVideoPreferences.self, from: Data(legacy.utf8))
    #expect(decoded.lookTuning.fitMode == .fit)
    #expect(decoded.lookTuning.transition == .crossfade)
    #expect(decoded.lookTuning.fadeSeconds == 1)
    #expect(decoded.lookTuning.sourceAudio == .off)
    #expect(decoded.lookTuning.sourceParts == .all)
  }

  @Test
  func theEarlierVoiceSettingIsReadAsTheMatchingParts() throws {
    let removed = #"{"lookTuning":{"sourceAudio":"medium","sourceVoice":"remove"}}"#
    let decoded = try JSONDecoder().decode(MusicVideoPreferences.self, from: Data(removed.utf8))
    #expect(decoded.lookTuning.sourceParts == [.music, .effects])
    let kept = #"{"lookTuning":{"sourceAudio":"medium","sourceVoice":"keep"}}"#
    #expect(try JSONDecoder().decode(MusicVideoPreferences.self, from: Data(kept.utf8)).lookTuning.sourceParts == .all)
  }

  @Test
  func partsAreSavedAsNamesAndEmptyMeansNothing() throws {
    var look = MusicVideoLookTuning()
    look.sourceParts = [.voice, .effects]
    let data = try JSONEncoder().encode(look)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains(#""sourceParts":["voice","effects"]"#), "名前の並びで保存する（\(text)）")
    #expect(try JSONDecoder().decode(MusicVideoLookTuning.self, from: data).sourceParts == [.voice, .effects])

    look.sourceParts = []
    #expect(try JSONDecoder().decode(MusicVideoLookTuning.self, from: JSONEncoder().encode(look)).sourceParts.isEmpty)
    #expect(SourceAudioParts.all.needsSeparation == false, "全部残すなら、分けない")
    #expect(SourceAudioParts([]).needsSeparation == false, "何も残さないなら、分ける必要もない")
    #expect(SourceAudioParts([.voice]).needsSeparation)
  }

  @Test
  func tuningSurvivesASaveAndLoad() throws {
    var preferences = MusicVideoPreferences()
    preferences.cutTuning.setMaximum(3.0)
    preferences.cutTuning.motionMatching = .strong
    preferences.cutTuning.variety = .wide
    preferences.cutTuning.alignment = .free
    preferences.lookTuning.fitMode = .fit
    preferences.lookTuning.transition = .crossfade
    preferences.lookTuning.fadeSeconds = 1
    preferences.lookTuning.sourceAudio = .medium
    preferences.lookTuning.sourceParts = [.voice, .effects]

    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(MusicVideoPreferences.self, from: data)
    #expect(decoded == preferences)
  }
}

// MARK: - 合成: 画面の合わせ方・切り替え効果・フェード・曲の範囲

/// 合成した映像の、`seconds` 秒の位置のフレームの明るさ(4x4の区画ごと)。
private func lumaCells(of composed: MusicVideoComposition, at seconds: Double) async throws -> [Double] {
  let generator = AVAssetImageGenerator(asset: composed.composition)
  generator.videoComposition = composed.videoComposition
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
  return lumaGrid(image)
}

private func average(_ values: [Double]) -> Double {
  values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

/// 合成した音の、`start` 秒から `length` 秒の大きさ(RMS)。フェードの指定(audioMix)も反映する。
private func audioRMS(of composed: MusicVideoComposition, from start: Double, length: Double) throws -> Double {
  let reader = try AVAssetReader(asset: composed.composition)
  let tracks = composed.composition.tracks(withMediaType: .audio)
  let output = AVAssetReaderAudioMixOutput(
    audioTracks: tracks,
    audioSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 1
    ]
  )
  output.audioMix = composed.audioMix
  reader.add(output)
  reader.timeRange = CMTimeRange(
    start: CMTime(seconds: start, preferredTimescale: 600),
    duration: CMTime(seconds: length, preferredTimescale: 600)
  )
  guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

  var sum = 0.0
  var count = 0
  while let buffer = output.copyNextSampleBuffer() {
    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
    let total = CMBlockBufferGetDataLength(block)
    var data = [UInt8](repeating: 0, count: total)
    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &data)
    data.withUnsafeBytes { raw in
      for value in raw.bindMemory(to: Float.self) {
        sum += Double(value * value)
        count += 1
      }
    }
  }
  return count == 0 ? 0 : (sum / Double(count)).squareRoot()
}

/// 合成した音の、`start` 秒から `length` 秒を `block` 秒ごとに区切ったピーク(絶対値の最大)。時刻は区切りの先頭。
private func audioPeaks(
  of composed: MusicVideoComposition,
  from start: Double,
  length: Double,
  block: Double
) throws -> [(time: Double, peak: Float)] {
  let sampleRate = 44_100.0
  let reader = try AVAssetReader(asset: composed.composition)
  let output = AVAssetReaderAudioMixOutput(
    audioTracks: composed.composition.tracks(withMediaType: .audio),
    audioSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1
    ]
  )
  output.audioMix = composed.audioMix
  reader.add(output)
  reader.timeRange = CMTimeRange(
    start: CMTime(seconds: start, preferredTimescale: 600),
    duration: CMTime(seconds: length, preferredTimescale: 600)
  )
  guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

  var samples: [Float] = []
  var firstTime: Double?
  while let buffer = output.copyNextSampleBuffer() {
    if firstTime == nil { firstTime = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
    guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
    let total = CMBlockBufferGetDataLength(data)
    var bytes = [UInt8](repeating: 0, count: total)
    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: total, destination: &bytes)
    bytes.withUnsafeBytes { samples.append(contentsOf: $0.bindMemory(to: Float.self)) }
  }

  let step = max(1, Int(block * sampleRate))
  let origin = firstTime ?? start
  return stride(from: 0, to: samples.count - step, by: step).map { index in
    (origin + Double(index) / sampleRate, samples[index..<index + step].map { abs($0) }.max() ?? 0)
  }
}

@Suite(.serialized)
struct MusicVideoLookCompositionTests {
  private let render = MusicVideoRenderSettings(width: 320, height: 180, framesPerSecond: 30)

  private struct Fixture {
    let directory: URL
    let dark: UUID, bright: UUID, portrait: UUID
    let urls: [UUID: URL]
    let music: URL
  }

  /// 暗い(30)・明るい(230)・縦長(中間の200)の素材と、6秒の音楽。
  private func makeFixture() async throws -> Fixture {
    let directory = try temporaryDirectory("look")
    let darkURL = directory.appendingPathComponent("dark.mp4")
    let brightURL = directory.appendingPathComponent("bright.mp4")
    let portraitURL = directory.appendingPathComponent("portrait.mp4")
    let musicURL = directory.appendingPathComponent("music.wav")
    try await step("dark video") { try await makeTestVideo(at: darkURL, duration: 8) { _ in 30 } }
    try await step("bright video") { try await makeTestVideo(at: brightURL, duration: 8) { _ in 230 } }
    try await step("portrait video") { try await makeTestVideo(at: portraitURL, duration: 8, size: (90, 160)) { _ in 200 } }
    try await step("music") { try writeSineWAV(to: musicURL, duration: 8) }
    let dark = UUID(), bright = UUID(), portrait = UUID()
    return Fixture(
      directory: directory,
      dark: dark, bright: bright, portrait: portrait,
      urls: [dark: darkURL, bright: brightURL, portrait: portraitURL],
      music: musicURL
    )
  }

  private func compose(
    _ plan: CutPlan,
    fixture: Fixture,
    look: MusicVideoLookTuning,
    audioStart: Double = 0,
    audioSeparator: SourceAudioSeparator? = nil
  ) async throws -> MusicVideoComposition {
    try await step("compose") {
      let separator = audioSeparator ?? SourceAudioSeparator(cacheDirectory: fixture.directory.appendingPathComponent("voice-cache"))
      return try await MusicVideoComposer().makeComposition(
        plan: plan, sourceURLs: fixture.urls, audioURL: fixture.music, render: render, look: look,
        audioStart: audioStart, audioSeparator: separator
      )
    }
  }

  /// 暗い → 明るい → 暗い、各1.5秒。
  private func darkBrightDarkPlan(_ fixture: Fixture) -> CutPlan {
    CutPlan(
      cuts: [
        plannedCut(fixture.dark, from: 0, at: 0, length: 1.5),
        plannedCut(fixture.bright, from: 1, at: 1.5, length: 1.5),
        plannedCut(fixture.dark, from: 3, at: 3, length: 1.5)
      ],
      duration: 4.5
    )
  }

  /// 指示の時間が、0 秒から合成の終わりまで、隙間も重なりもなく続いている。
  private func expectContiguousInstructions(_ composed: MusicVideoComposition) {
    let instructions = composed.videoComposition.instructions
    #expect(!instructions.isEmpty)
    #expect(instructions.first?.timeRange.start == .zero)
    for (current, next) in zip(instructions, instructions.dropFirst()) {
      #expect(current.timeRange.end == next.timeRange.start)
    }
    #expect(instructions.last?.timeRange.end == composed.composition.duration)
  }

  @Test
  func defaultLookKeepsOneTrackAndOneInstruction() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let composed = try await compose(darkBrightDarkPlan(fixture), fixture: fixture, look: MusicVideoLookTuning())
    #expect(composed.composition.tracks(withMediaType: .video).count == 1)
    #expect(composed.videoComposition.instructions.count == 1)
    #expect(composed.audioMix == nil)
    expectContiguousInstructions(composed)
  }

  @Test
  func fitModeShowsTheWholeSourceWithBlackBars() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let plan = CutPlan(cuts: [plannedCut(fixture.portrait, from: 1, at: 0, length: 2)], duration: 2)

    var look = MusicVideoLookTuning()
    look.fitMode = .fill
    let fill = try await lumaCells(of: compose(plan, fixture: fixture, look: look), at: 1)
    // 画面いっぱい: 四隅まで素材で埋まる(縦長の素材を拡大するので、黒帯は出ない)。
    #expect(fill.allSatisfy { $0 > 150 })

    look.fitMode = .fit
    let fit = try await lumaCells(of: compose(plan, fixture: fixture, look: look), at: 1)
    // 全体を見せる: 縦長の素材は左右に黒帯が出て、中央だけが明るい。
    for row in 0..<4 {
      #expect(fit[row * 4 + 0] < 40, "左端は黒帯")
      #expect(fit[row * 4 + 3] < 40, "右端は黒帯")
      #expect(fit[row * 4 + 1] > 90 && fit[row * 4 + 2] > 90, "中央は素材")
    }
  }

  @Test
  func crossfadeBlendsAcrossTheBeatUsingTwoTracks() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    var look = MusicVideoLookTuning()
    look.transition = .crossfade
    let composed = try await compose(darkBrightDarkPlan(fixture), fixture: fixture, look: look)

    #expect(composed.composition.tracks(withMediaType: .video).count == 2)
    expectContiguousInstructions(composed)
    #expect(abs(composed.duration - 4.5) < 0.02)

    // 拍(1.5秒)の前は暗く、後は明るい。拍の位置は、2つの映像がほぼ半分ずつ混ざる(暗30と明230の中間)。
    let before = average(try await lumaCells(of: composed, at: 1.0))
    let atBeat = average(try await lumaCells(of: composed, at: 1.5))
    let after = average(try await lumaCells(of: composed, at: 2.0))
    #expect(before < 60)
    #expect(after > 190)
    #expect(atBeat > 100 && atBeat < 160)
    // 切り替えの途中は、明るさがなめらかに変わる(切り替えの頭より後ろのほうが明るい)。
    let early = average(try await lumaCells(of: composed, at: 1.4))
    let late = average(try await lumaCells(of: composed, at: 1.6))
    #expect(early < atBeat && atBeat < late)
  }

  @Test
  func flashLightsTheStartOfEachCutThenSettles() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    // 暗い素材だけ。普通の切り替えなら、どこも暗いまま。
    let plan = CutPlan(
      cuts: [
        plannedCut(fixture.dark, from: 0, at: 0, length: 1.5),
        plannedCut(fixture.dark, from: 3, at: 1.5, length: 1.5)
      ],
      duration: 3
    )
    var look = MusicVideoLookTuning()
    look.transition = .flash
    let composed = try await compose(plan, fixture: fixture, look: look)

    #expect(composed.composition.tracks(withMediaType: .video).count == 1)
    expectContiguousInstructions(composed)

    let beforeBeat = average(try await lumaCells(of: composed, at: 1.0))
    let justAfterBeat = average(try await lumaCells(of: composed, at: 1.52))
    let settled = average(try await lumaCells(of: composed, at: 1.8))
    #expect(beforeBeat < 60)
    #expect(justAfterBeat > 170, "拍の直後は、白く光っている")
    #expect(settled < 60, "光ったあとは、素材の明るさに戻る")

    // 最初のカットの頭は光らない(曲の始まりで光らせない)。
    let start = average(try await lumaCells(of: composed, at: 0.02))
    #expect(start < 60)
  }

  @Test
  func fadeDarkensTheEdgesOfTheVideoAndTheMusic() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let plan = CutPlan(cuts: [plannedCut(fixture.bright, from: 0, at: 0, length: 5)], duration: 5)

    var look = MusicVideoLookTuning()
    look.fadeSeconds = 1
    let composed = try await compose(plan, fixture: fixture, look: look)
    expectContiguousInstructions(composed)

    // 映像: 最初と最後は暗く、真ん中は素材の明るさ。
    let first = average(try await lumaCells(of: composed, at: 0.05))
    let middle = average(try await lumaCells(of: composed, at: 2.5))
    let last = average(try await lumaCells(of: composed, at: 4.95))
    #expect(first < 40)
    #expect(middle > 190)
    #expect(last < 40)

    // 音: 最初と最後の 0.1 秒は、真ん中よりずっと小さい。
    #expect(composed.audioMix != nil)
    let audioFirst = try audioRMS(of: composed, from: 0, length: 0.1)
    let audioMiddle = try audioRMS(of: composed, from: 2, length: 0.5)
    let audioLast = try audioRMS(of: composed, from: 4.9, length: 0.1)
    #expect(audioMiddle > 0.1)
    #expect(audioFirst < audioMiddle * 0.25)
    #expect(audioLast < audioMiddle * 0.25)
  }

  @Test
  func fadeAndTransitionsDoNotConflictOnShortCuts() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    // 0.5秒ごとに替わるカットで、フェード(2秒)と切り替え効果が重なる。
    let cuts = (0..<8).map { index in
      plannedCut(index % 2 == 0 ? fixture.dark : fixture.bright, from: Double(index) * 0.2, at: Double(index) * 0.5, length: 0.5)
    }
    let plan = CutPlan(cuts: cuts, duration: 4)

    for transition in MusicVideoTransition.allCases {
      var look = MusicVideoLookTuning()
      look.transition = transition
      look.fadeSeconds = 2
      let composed = try await compose(plan, fixture: fixture, look: look)
      expectContiguousInstructions(composed)
      #expect(abs(composed.duration - 4) < 0.02)
      // フェードの頂点(2秒)では、素材の明るさがそのまま出る(暗か明のどちらか)。
      let top = average(try await lumaCells(of: composed, at: 2.1))
      #expect(top < 60 || top > 170)
      // 最初のフレームは、どの切り替え効果でも暗い。
      let start = average(try await lumaCells(of: composed, at: 0.03))
      #expect(start < 40)
    }
  }

  /// 画素は横長のまま、90度の回転情報だけを持つ素材(スマートフォンで縦に撮った動画と同じ作り)。
  /// 表示すると縦長(90x160)になる。
  private func makeRotatedPortraitVideo(at url: URL, brightness: UInt8) async throws {
    // 画素 160x90 を、時計回りに90度回して表示する(回転後は 90x160 の縦長)。
    let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0)
    try await makeTestVideo(at: url, duration: 8, size: (160, 90), transform: rotate) { _ in brightness }
  }

  @Test
  func firstSourceOrientationDoesNotDecideTheFrameOfLaterCuts() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let rotatedURL = fixture.directory.appendingPathComponent("rotated.mp4")
    try await step("rotated video") { try await makeRotatedPortraitVideo(at: rotatedURL, brightness: 200) }
    let rotated = UUID()
    let urls = fixture.urls.merging([rotated: rotatedURL]) { current, _ in current }
    let fixtureWithRotated = Fixture(
      directory: fixture.directory, dark: fixture.dark, bright: fixture.bright, portrait: fixture.portrait,
      urls: urls, music: fixture.music
    )

    // 最初が縦向きの素材で、そのあとに横向きの素材が続く。画面は横長(320x180)。
    let plan = CutPlan(
      cuts: [
        plannedCut(rotated, from: 1, at: 0, length: 1.5),
        plannedCut(fixture.dark, from: 0, at: 1.5, length: 1.5),
        plannedCut(rotated, from: 3, at: 3, length: 1.5),
        plannedCut(fixture.bright, from: 0, at: 4.5, length: 1.5)
      ],
      duration: 6
    )

    for transition in [MusicVideoTransition.cut, .crossfade, .flash] {
      var look = MusicVideoLookTuning()
      look.transition = transition
      look.fitMode = .fill
      let composed = try await compose(plan, fixture: fixtureWithRotated, look: look)
      #expect(composed.videoComposition.renderSize == render.size, "\(transition)")

      // 画面いっぱいの設定なら、どのカットも四隅まで素材で埋まる(最初の素材の向きに引きずられない)。
      let first = try await lumaCells(of: composed, at: 0.75)
      let second = try await lumaCells(of: composed, at: 2.25)
      let third = try await lumaCells(of: composed, at: 3.75)
      let fourth = try await lumaCells(of: composed, at: 5.25)
      #expect(first.allSatisfy { $0 > 150 && $0 < 240 }, "\(transition) 縦向き(1つ目)")
      #expect(second.allSatisfy { $0 < 80 }, "\(transition) 横向き(2つ目)")
      #expect(third.allSatisfy { $0 > 150 && $0 < 240 }, "\(transition) 縦向き(3つ目)")
      #expect(fourth.allSatisfy { $0 > 190 }, "\(transition) 横向き(4つ目)")
    }

    // 全体を見せる設定なら、縦向きの素材だけ左右に黒帯が出て、横向きの素材は帯なし。
    var fit = MusicVideoLookTuning()
    fit.fitMode = .fit
    let composed = try await compose(plan, fixture: fixtureWithRotated, look: fit)
    let portraitCells = try await lumaCells(of: composed, at: 0.75)
    let landscapeCells = try await lumaCells(of: composed, at: 2.25)
    for row in 0..<4 {
      #expect(portraitCells[row * 4] < 40 && portraitCells[row * 4 + 3] < 40, "縦向きは左右が黒帯")
    }
    #expect(landscapeCells.allSatisfy { $0 > 10 && $0 < 80 }, "横向きは帯なし(暗い素材そのまま)")
  }

  @Test
  func musicStartOffsetPlaysTheChosenPartOfTheSong() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    // 前半の 3 秒は無音、その後はずっと音がある曲。
    let sampleRate = 44_100.0
    let samples: [Float] = (0..<Int(8 * sampleRate)).map { index in
      let time = Double(index) / sampleRate
      return time < 3 ? 0 : 0.3 * Float(sin(2 * Double.pi * 440 * time))
    }
    try writeMonoWAV(samples: samples, sampleRate: sampleRate, to: fixture.music)
    let plan = CutPlan(cuts: [plannedCut(fixture.dark, from: 0, at: 0, length: 4)], duration: 4)

    let fromStart = try await compose(plan, fixture: fixture, look: MusicVideoLookTuning(), audioStart: 0)
    let fromThree = try await compose(plan, fixture: fixture, look: MusicVideoLookTuning(), audioStart: 3)

    // 先頭から使うと、映像の最初の 1 秒は無音。3 秒目から使うと、最初から音がある。
    #expect(try audioRMS(of: fromStart, from: 0.2, length: 0.5) < 0.01)
    #expect(try audioRMS(of: fromThree, from: 0.2, length: 0.5) > 0.1)
    #expect(abs(fromThree.duration - 4) < 0.05)
  }

  // MARK: 素材の元の音

  /// 映像に、`samples`（モノラル 44.1kHz）の音を付けた動画を作る。素材の音が入ったかを調べるための素材。
  private func makeTestVideoWithAudio(at url: URL, duration: Double, samples: [Float]) async throws {
    let directory = url.deletingLastPathComponent()
    let videoURL = directory.appendingPathComponent("silent-\(UUID().uuidString).mp4")
    let audioURL = directory.appendingPathComponent("tone-\(UUID().uuidString).wav")
    defer {
      try? FileManager.default.removeItem(at: videoURL)
      try? FileManager.default.removeItem(at: audioURL)
    }
    try await makeTestVideo(at: videoURL, duration: duration) { _ in 120 }
    try writeMonoWAV(samples: samples, sampleRate: 44_100, to: audioURL)

    let composition = AVMutableComposition()
    for (sourceURL, mediaType) in [(videoURL, AVMediaType.video), (audioURL, .audio)] {
      let asset = AVURLAsset(url: sourceURL)
      let sourceTrack = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
      let track = try #require(composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid))
      try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: sourceTrack, at: .zero)
    }
    let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    try await session.export(to: url, as: .mov)
  }

  private func tone(duration: Double, from toneStart: Double = 0, amplitude: Float = 0.4) -> [Float] {
    let sampleRate = 44_100.0
    return (0..<Int(duration * sampleRate)).map { index in
      let time = Double(index) / sampleRate
      return time < toneStart ? 0 : amplitude * Float(sin(2 * Double.pi * 880 * time))
    }
  }

  /// 音楽は無音にして、素材の音だけを測れるようにした素材一式。
  /// `late` は 3 秒まで無音で、そのあと音がある。`toned` は最初から最後まで音がある。`silent` は音声トラックを持たない。
  private struct SourceAudioFixture {
    let fixture: Fixture
    let late: UUID, toned: UUID, silent: UUID
  }

  private func makeSourceAudioFixture() async throws -> SourceAudioFixture {
    let base = try await makeFixture()
    try writeMonoWAV(samples: [Float](repeating: 0, count: 8 * 44_100), sampleRate: 44_100, to: base.music)
    let lateURL = base.directory.appendingPathComponent("late.mov")
    let tonedURL = base.directory.appendingPathComponent("toned.mov")
    try await step("late video") { try await makeTestVideoWithAudio(at: lateURL, duration: 8, samples: tone(duration: 8, from: 3)) }
    try await step("toned video") { try await makeTestVideoWithAudio(at: tonedURL, duration: 8, samples: tone(duration: 8)) }
    let late = UUID(), toned = UUID()
    let urls = base.urls.merging([late: lateURL, toned: tonedURL]) { current, _ in current }
    return SourceAudioFixture(
      fixture: Fixture(directory: base.directory, dark: base.dark, bright: base.bright, portrait: base.portrait, urls: urls, music: base.music),
      late: late, toned: toned, silent: base.dark
    )
  }

  @Test
  func sourceAudioIsLeftOutByDefault() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    let plan = CutPlan(cuts: [plannedCut(sources.toned, from: 1, at: 0, length: 3)], duration: 3)

    let composed = try await compose(plan, fixture: sources.fixture, look: MusicVideoLookTuning())
    #expect(composed.audioMix == nil)
    #expect(composed.composition.tracks(withMediaType: .audio).count == 1, "音楽の1本だけ")
    #expect(try audioRMS(of: composed, from: 0.5, length: 1.5) < 0.01)
  }

  @Test
  func sourceAudioLevelsScaleTheOriginalSound() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    let plan = CutPlan(cuts: [plannedCut(sources.toned, from: 1, at: 0, length: 3)], duration: 3)

    var levels: [SourceAudioLevel: Double] = [:]
    for level in SourceAudioLevel.allCases {
      var look = MusicVideoLookTuning()
      look.sourceAudio = level
      let composed = try await compose(plan, fixture: sources.fixture, look: look)
      levels[level] = try audioRMS(of: composed, from: 0.5, length: 1.5)
    }
    // 振幅 0.4 の正弦波の RMS は約 0.28。「音楽と同じ」はその大きさがそのまま出る。
    let full = try #require(levels[.full])
    #expect(full > 0.24 && full < 0.32)
    #expect(try #require(levels[.off]) < 0.01)
    #expect(try #require(levels[.low]) > 0.06 && levels[.low]! < 0.11)
    #expect(try #require(levels[.medium]) > 0.14 && levels[.medium]! < 0.2)
  }

  @Test
  func sourceAudioFollowsEachCutAndStaysInSyncWithTheVideo() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    // 前半は素材の 0 秒から(無音の部分)、後半は 3.5 秒から(音のある部分)。
    let plan = CutPlan(
      cuts: [
        plannedCut(sources.late, from: 0, at: 0, length: 1.5),
        plannedCut(sources.late, from: 3.5, at: 1.5, length: 1.5)
      ],
      duration: 3
    )

    for transition in MusicVideoTransition.allCases {
      var look = MusicVideoLookTuning()
      look.sourceAudio = .full
      look.transition = transition
      let composed = try await compose(plan, fixture: sources.fixture, look: look)
      #expect(try audioRMS(of: composed, from: 0.2, length: 1.0) < 0.01, "\(transition) 前半は無音")
      #expect(try audioRMS(of: composed, from: 1.8, length: 1.0) > 0.24, "\(transition) 後半は素材の音")
    }
  }

  @Test
  func sourceAudioKeepsMusicAndSilentSourcesWorking() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    // 音声トラックのない素材のカットは、素材の音がなく、音楽だけになる。
    let plan = CutPlan(
      cuts: [
        plannedCut(sources.silent, from: 0, at: 0, length: 1.5),
        plannedCut(sources.toned, from: 1, at: 1.5, length: 1.5)
      ],
      duration: 3
    )
    var look = MusicVideoLookTuning()
    look.sourceAudio = .full
    try writeSineWAV(to: sources.fixture.music, duration: 8)
    let composed = try await compose(plan, fixture: sources.fixture, look: look)

    #expect(composed.composition.tracks(withMediaType: .audio).count == 2, "音楽と素材の音")
    let silentPart = try audioRMS(of: composed, from: 0.2, length: 1.0)
    let tonedPart = try audioRMS(of: composed, from: 1.8, length: 1.0)
    // 音楽（0.3 の正弦波）だけの所は約 0.21。そこに素材の音（約 0.28）が重なると大きくなる。
    #expect(silentPart > 0.15 && silentPart < 0.27)
    #expect(tonedPart > silentPart * 1.3)
  }

  @Test
  func sourceAudioFadesWithTheRestOfTheVideo() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    let plan = CutPlan(
      cuts: [
        plannedCut(sources.toned, from: 0, at: 0, length: 2.5),
        plannedCut(sources.toned, from: 3, at: 2.5, length: 2.5)
      ],
      duration: 5
    )
    var look = MusicVideoLookTuning()
    look.sourceAudio = .full
    look.fadeSeconds = 1
    let composed = try await compose(plan, fixture: sources.fixture, look: look)

    let first = try audioRMS(of: composed, from: 0, length: 0.1)
    let middle = try audioRMS(of: composed, from: 1.5, length: 0.5)
    let last = try audioRMS(of: composed, from: 4.9, length: 0.1)
    #expect(middle > 0.24)
    #expect(first < middle * 0.25)
    #expect(last < middle * 0.25)
  }

  @Test
  func sourceAudioDipsBrieflyAtCutSeamsToAvoidClicks() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    let plan = CutPlan(
      cuts: [
        plannedCut(sources.toned, from: 0, at: 0, length: 1.5),
        plannedCut(sources.toned, from: 4, at: 1.5, length: 1.5)
      ],
      duration: 3
    )
    var look = MusicVideoLookTuning()
    look.sourceAudio = .full
    let composed = try await compose(plan, fixture: sources.fixture, look: look)

    // つなぎ目（1.5 秒）の前後 0.03 秒だけが絞られ、その外側は素材の音のまま。
    // 短い範囲ごとに読み直すと音声処理の単位に引きずられるので、一本の読み出しで波形を並べて調べる。
    let peaks = try audioPeaks(of: composed, from: 1.3, length: 0.4, block: 0.002)
    func peak(in range: ClosedRange<Double>) -> Float {
      peaks.filter { range.contains($0.time) }.map(\.peak).min() ?? .infinity
    }
    #expect(peak(in: 1.30...1.465) > 0.35, "つなぎ目の手前は素材の音のまま")
    #expect(peak(in: 1.535...1.70) > 0.35, "つなぎ目の先も素材の音のまま")
    #expect(peak(in: 1.49...1.51) < 0.1, "つなぎ目の真ん中は絞られる")
  }

  /// macOS 標準の `say` で話し声を作り、44.1kHz モノラルのサンプルにして返す。作れない環境では nil。
  private func spokenSamples(_ text: String, in directory: URL) throws -> [Float]? {
    let say = URL(fileURLWithPath: "/usr/bin/say")
    guard FileManager.default.isExecutableFile(atPath: say.path) else { return nil }
    let url = directory.appendingPathComponent("speech-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let process = Process()
    process.executableURL = say
    process.arguments = ["-o", url.path, "--data-format=LEI16@44100", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let file = try AVAudioFile(forReading: url)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
  }

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say"), "音声合成（say）が使える環境だけ"))
  func choosingPartsKeepsOnlyTheSelectedSounds() async throws {
    let base = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: base.directory) }
    try writeMonoWAV(samples: [Float](repeating: 0, count: 8 * 44_100), sampleRate: 44_100, to: base.music)

    let speech = try #require(try spokenSamples(
      "Hello everyone, welcome back to the channel. Today we are going to build something really cool together.",
      in: base.directory
    ))
    // 素材の音: 0.4 秒から効果音（雑音の衝撃）、3 秒から話し声。
    var audio = [Float](repeating: 0, count: 14 * 44_100)
    var seed: UInt64 = 99
    for offset in 0..<Int(0.8 * 44_100) {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      let noise = Float(seed >> 40) / Float(1 << 23) - 1
      audio[Int(0.4 * 44_100) + offset] = 0.5 * noise * Float(exp(-Double(offset) / 44_100 / 0.2))
    }
    for (offset, sample) in speech.enumerated() where 3 * 44_100 + offset < audio.count { audio[3 * 44_100 + offset] += sample }
    let sourceURL = base.directory.appendingPathComponent("talking.mov")
    try await step("talking video") { try await makeTestVideoWithAudio(at: sourceURL, duration: 14, samples: audio) }
    let talking = UUID()
    let fixture = Fixture(
      directory: base.directory, dark: base.dark, bright: base.bright, portrait: base.portrait,
      urls: base.urls.merging([talking: sourceURL]) { current, _ in current }, music: base.music
    )
    // 前半は効果音だけの所、後半は話し声だけの所。
    let plan = CutPlan(
      cuts: [
        plannedCut(talking, from: 0, at: 0, length: 2),
        plannedCut(talking, from: 4, at: 2, length: 3)
      ],
      duration: 5
    )

    var keep = MusicVideoLookTuning()
    keep.sourceAudio = .full
    var remove = keep
    remove.sourceParts = [.music, .effects]   // 声以外を残す
    let kept = try await compose(plan, fixture: fixture, look: keep)
    let removed = try await compose(plan, fixture: fixture, look: remove)

    let keptEffect = try audioRMS(of: kept, from: 0.45, length: 0.6)
    let removedEffect = try audioRMS(of: removed, from: 0.45, length: 0.6)
    let keptSpeech = try audioRMS(of: kept, from: 2.3, length: 2.4)
    let removedSpeech = try audioRMS(of: removed, from: 2.3, length: 2.4)
    #expect(keptEffect > 0.05)
    #expect(keptSpeech > 0.02)
    // 声を除く処理はモノラルの素材をステレオで読み出すので、音量の絶対値は測り方で変わる（テストの測り方では約 +3dB）。
    // そこで、声と効果音の比が、どれだけ変わったかで確かめる。
    #expect(removedEffect > keptEffect * 0.7, "効果音だけの所は、削られない（\(keptEffect) → \(removedEffect)）")
    let keptRatio = keptSpeech / keptEffect
    let removedRatio = removedSpeech / removedEffect
    #expect(removedRatio < keptRatio * 0.4, "効果音に対する話し声の大きさが 8dB 以上減る（\(keptRatio) → \(removedRatio)）")
    #expect(abs(removed.duration - 5) < 0.05)

    // 声だけ残す: 話し声の所は残り、効果音だけの所は、ほとんど消える。
    var voiceOnly = keep
    voiceOnly.sourceParts = [.voice]
    let voiced = try await compose(plan, fixture: fixture, look: voiceOnly)
    let voicedEffect = try audioRMS(of: voiced, from: 0.45, length: 0.6)
    let voicedSpeech = try audioRMS(of: voiced, from: 2.3, length: 2.4)
    // 測り方でモノラルの素材が約 +3dB に出るので、比べるのは、声を残した音どうし・声以外を残した音どうし。
    #expect(voicedEffect < keptEffect * 0.2, "効果音だけの所は、ほとんど消える（\(keptEffect) → \(voicedEffect)）")
    #expect(voicedSpeech > keptSpeech * 0.6, "話し声の所は残る（\(keptSpeech) → \(voicedSpeech)）")

    // 同じ範囲をもう一度作るときは、保存した音を使い回す（保存ファイルが増えない）。
    let cache = fixture.directory.appendingPathComponent("voice-cache")
    let filesBefore = try FileManager.default.contentsOfDirectory(atPath: cache.path).count
    _ = try await compose(plan, fixture: fixture, look: remove)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == filesBefore)
    #expect(filesBefore == 4, "カットの数 × 残す成分の組み合わせ（2通り）だけ保存される")
  }

  @Test
  func partsSelectionDoesNothingWhileSourceAudioIsOff() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    let plan = CutPlan(cuts: [plannedCut(sources.toned, from: 1, at: 0, length: 3)], duration: 3)

    var look = MusicVideoLookTuning()
    look.sourceAudio = .off
    look.sourceParts = [.effects]
    let composed = try await compose(plan, fixture: sources.fixture, look: look)
    #expect(composed.audioMix == nil)
    #expect(composed.composition.tracks(withMediaType: .audio).count == 1, "音楽の1本だけ")
    #expect(!FileManager.default.fileExists(atPath: sources.fixture.directory.appendingPathComponent("voice-cache").path))
  }

  @Test
  func sourceAudioExportsIntoTheMP4() async throws {
    let sources = try await makeSourceAudioFixture()
    defer { try? FileManager.default.removeItem(at: sources.fixture.directory) }
    let plan = CutPlan(
      cuts: [
        plannedCut(sources.toned, from: 0, at: 0, length: 1.5),
        plannedCut(sources.late, from: 3.5, at: 1.5, length: 1.5)
      ],
      duration: 3
    )
    var look = MusicVideoLookTuning()
    look.sourceAudio = .medium
    look.transition = .crossfade
    look.fadeSeconds = 0.5
    let composed = try await compose(plan, fixture: sources.fixture, look: look)

    let output = sources.fixture.directory.appendingPathComponent("out/with-source-audio.mp4")
    try await step("export") { try await MusicVideoComposer().export(composed, to: output) }

    let asset = AVURLAsset(url: output)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1, "音楽と素材の音は1本に混ざる")
    #expect(abs(try await asset.load(.duration).seconds - 3) < 0.2)
  }

  @Test
  func crossfadeWithFadeExportsAPlayableMP4() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    var look = MusicVideoLookTuning()
    look.transition = .crossfade
    look.fitMode = .fit
    look.fadeSeconds = 0.5
    let composed = try await compose(darkBrightDarkPlan(fixture), fixture: fixture, look: look)

    let output = fixture.directory.appendingPathComponent("out/result.mp4")
    try await step("export") { try await MusicVideoComposer().export(composed, to: output) }

    let asset = AVURLAsset(url: output)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(abs(try await asset.load(.duration).seconds - 4.5) < 0.2)
  }
}

// MARK: - ビューモデル: 項目を変えたときの反映

private struct WaitTimeout: Error, CustomStringConvertible {
  let label: String
  var description: String { "待っていた状態にならないまま時間切れ: \(label)" }
}

@Suite(.serialized)
@MainActor
struct MusicVideoTuningViewModelTests {
  private struct Harness {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let library: LibraryViewModel
    let viewModel: MusicVideoViewModel

    func cleanUp() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// 曲(120BPM・16秒)を解析し終えた状態の画面と、`videoCount` 本の素材動画を持つライブラリを作る。
  /// 設定の保存先も、ライブラリの置き場も、テスト専用の場所にする(実際のものには触らない)。
  private func makeHarness(videoCount: Int) async throws -> Harness {
    let directory = try temporaryDirectory("tuning-vm")
    let suite = "musicvideo-vm-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))

    let musicURL = directory.appendingPathComponent("music.wav")
    let clicks = evenClicks(from: 0.25, interval: 0.5, until: 16)
    try writeMonoWAV(
      samples: clickTrack(duration: 16, clicks: clicks.map { ($0, 0.8) }),
      sampleRate: testSampleRate,
      to: musicURL
    )

    var items: [VideoItem] = []
    for index in 0..<videoCount {
      let url = directory.appendingPathComponent("source\(index).mp4")
      // 動画ごとに、明るさと動きの大きさを変える。
      try await makeTestVideo(at: url, duration: 6) { frame in
        UInt8(40 + (index % 5) * 30 + (frame / 2) % (index % 3 + 1) * 10)
      }
      items.append(VideoItem(
        id: UUID(), originalFilename: "source\(index).mp4", internalFilename: "", duration: 6,
        importDate: Date(), creationDate: nil, fileHash: "", mediaType: .video,
        externalFilePath: url.path
      ))
    }

    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { directory },
      downloadsDirectory: { nil },
      createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
    ))
    library.videos = items

    let viewModel = MusicVideoViewModel(preferencesStore: MusicVideoPreferencesStore(defaults: defaults))
    viewModel.attach(dataManager: library)
    viewModel.selectedVideoIDs = Set(items.map(\.id))
    viewModel.chooseMusic(musicURL)
    let harness = Harness(directory: directory, suite: suite, defaults: defaults, library: library, viewModel: viewModel)
    try await waitUntil("曲の解析") { viewModel.fullAnalysis != nil && !viewModel.isWorking }
    return harness
  }

  private func waitUntil(
    _ label: String,
    timeout: Double = 90,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { throw WaitTimeout(label: label) }
      try await Task.sleep(for: .milliseconds(40))
    }
  }

  /// 映像を作り終えるまで待つ。
  private func generate(_ harness: Harness) async throws {
    harness.viewModel.generate(dataManager: harness.library)
    try await waitUntil("映像の作成") { harness.viewModel.phase == .ready && harness.viewModel.plan != nil }
  }

  @Test
  func tuningRebuildsTheCutsWithTheSameSeedAndCanBeUndone() async throws {
    let harness = try await makeHarness(videoCount: 4)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let original = try #require(viewModel.plan)
    #expect(viewModel.undoDepth == 0)
    #expect(viewModel.planStats?.cutCount == original.cuts.count)

    // 最長を1.0秒にすると、すぐにカット割りが作り直される。
    viewModel.cutTuning.setMaximum(1.0)
    try await waitUntil("最長1.0秒の反映") { viewModel.plan != original && !viewModel.isApplyingEdit }
    let limited = try #require(viewModel.plan)
    #expect(limited.cuts.allSatisfy { $0.duration <= 1.0 + 1e-9 })
    #expect(limited.cuts.count > original.cuts.count)
    #expect(viewModel.lastChangeNote?.contains("最長のカット長") == true)
    #expect(viewModel.lastChangeNote?.contains("カット \(original.cuts.count) → \(limited.cuts.count)") == true)
    #expect(viewModel.planStats?.cutCount == limited.cuts.count)
    #expect(viewModel.undoDepth == 1)

    // 乱数の種は変えないので、制限を外せば、まったく同じカット割りに戻る(項目の効果だけが出ている)。
    viewModel.cutTuning.setMaximum(nil)
    try await waitUntil("制限を外した反映") { viewModel.plan == original && !viewModel.isApplyingEdit }
    #expect(viewModel.undoDepth == 2)

    // 取り消すと、カット割りと一緒に、項目も元に戻る。
    viewModel.undo()
    try await waitUntil("取り消し1回目") { viewModel.plan == limited && !viewModel.isApplyingEdit }
    #expect(viewModel.cutTuning.maximumCutDuration == 1.0)
    viewModel.undo()
    try await waitUntil("取り消し2回目") { viewModel.plan == original && !viewModel.isApplyingEdit }
    #expect(viewModel.cutTuning.maximumCutDuration == nil)
    #expect(viewModel.undoDepth == 0)
    #expect(viewModel.redoDepth == 2)

    // 取り消しで項目を戻したことは、新しい変更として反映し直されない。
    try await Task.sleep(for: .milliseconds(600))
    #expect(viewModel.plan == original)
    #expect(viewModel.undoDepth == 0)
  }

  @Test
  func rapidChangesAreAppliedOnceAndUndoneTogether() async throws {
    let harness = try await makeHarness(videoCount: 4)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let original = try #require(viewModel.plan)

    // つまみを動かすような連続した変更は、まとめて1回だけ反映する。
    viewModel.cutTuning.setMaximum(6.0)
    viewModel.cutTuning.setMaximum(3.0)
    viewModel.cutTuning.setMaximum(1.5)
    try await waitUntil("連続した変更の反映") { viewModel.plan != original && !viewModel.isApplyingEdit }
    try await Task.sleep(for: .milliseconds(500))
    #expect(viewModel.undoDepth == 1)
    #expect(viewModel.plan?.cuts.allSatisfy { $0.duration <= 1.5 + 1e-9 } == true)

    viewModel.undo()
    try await waitUntil("まとめて取り消し") { viewModel.plan == original && !viewModel.isApplyingEdit }
    #expect(viewModel.cutTuning.maximumCutDuration == nil)
  }

  @Test
  func changingTheScreenSizeRecomposesTheExistingVideo() async throws {
    let harness = try await makeHarness(videoCount: 3)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let original = try #require(viewModel.plan)
    #expect(viewModel.player.currentItem?.videoComposition?.renderSize == CGSize(width: 1920, height: 1080))

    // 画面サイズを変えると、作り直さなくても、映像そのものの大きさが変わる。カット割りはそのまま。
    viewModel.renderPreset = .portraitHD
    try await waitUntil("画面サイズの反映") {
      viewModel.player.currentItem?.videoComposition?.renderSize == CGSize(width: 720, height: 1280)
        && !viewModel.isApplyingEdit
    }
    #expect(viewModel.plan == original)
    #expect(viewModel.undoDepth == 0)
    #expect(viewModel.lastChangeNote?.contains("画面サイズ") == true)

    // 切り替え効果を変えると、合成だけがやり直される(クロスフェードは映像トラックを2本使う)。
    viewModel.lookTuning.transition = .crossfade
    try await waitUntil("切り替え効果の反映") {
      (viewModel.player.currentItem?.asset as? AVComposition)?.tracks(withMediaType: .video).count == 2
        && !viewModel.isApplyingEdit
    }
    #expect(viewModel.plan == original)
  }

  @Test
  func musicRangeTrimsThePlanAndIsUndoable() async throws {
    let harness = try await makeHarness(videoCount: 4)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let original = try #require(viewModel.plan)
    let fullDuration = try #require(viewModel.fullAnalysis?.duration)
    #expect(viewModel.targetDuration == fullDuration)

    viewModel.setMusicRange(start: 4, end: 12)
    try await waitUntil("曲の範囲の反映") { viewModel.plan != original && !viewModel.isApplyingEdit }
    let range = try #require(viewModel.musicRange)
    let trimmed = try #require(viewModel.plan)
    // 開始は拍にそろう(拍は0.25秒+0.5秒ごと)。映像の長さは、範囲の長さと一致する。
    #expect(abs(range.start - 4) <= 0.26)
    #expect(abs(range.length - 8) <= 0.5)
    #expect(abs(trimmed.duration - range.length) < 1e-9)
    #expect(abs((viewModel.analysis?.duration ?? 0) - range.length) < 1e-9)
    #expect(viewModel.targetDuration == range.length)
    #expect(abs((viewModel.player.currentItem?.asset.duration.seconds ?? 0) - range.length) < 0.1)

    viewModel.undo()
    try await waitUntil("範囲の取り消し") { viewModel.plan == original && !viewModel.isApplyingEdit }
    #expect(viewModel.musicRange == nil)
    #expect(viewModel.analysis?.duration == fullDuration)
    #expect(viewModel.targetDuration == fullDuration)
  }

  @Test
  func sourceLimitDecidesHowManyVideosAreAnalysed() async throws {
    let harness = try await makeHarness(videoCount: 12)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel

    viewModel.sourceLimit = 10
    try await generate(harness)
    #expect(viewModel.poolVideos.count == 10)
    #expect(!viewModel.sourceLimitNeedsRebuild)

    // 本数を増やしても、「作り直す」まではいまの映像のまま。反映が必要なことは分かる。
    let before = viewModel.plan
    viewModel.sourceLimit = 20
    #expect(viewModel.sourceLimitNeedsRebuild)
    try await Task.sleep(for: .milliseconds(500))
    #expect(viewModel.plan == before)
    #expect(viewModel.poolVideos.count == 10)

    try await generate(harness)
    #expect(viewModel.poolVideos.count == 12)
    #expect(!viewModel.sourceLimitNeedsRebuild)
  }

  @Test
  func skipMovesThePlaybackPositionAndStaysInsideTheVideo() async throws {
    let harness = try await makeHarness(videoCount: 4)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let plan = try #require(viewModel.plan)
    #expect(viewModel.playbackDuration == plan.duration)
    #expect(!viewModel.isPlaying)

    viewModel.skip(by: 10)
    try await waitUntil("10秒進む") { abs(viewModel.playbackTime - 10) < 0.2 }
    viewModel.skip(by: -4)
    try await waitUntil("4秒戻る") { abs(viewModel.playbackTime - 6) < 0.2 }

    // 映像の範囲の外へは出ない。
    viewModel.skip(by: -100)
    try await waitUntil("先頭で止まる") { viewModel.playbackTime < 0.1 }
    viewModel.skip(by: 1000)
    try await waitUntil("終わりで止まる") { viewModel.playbackTime > plan.duration - 0.3 }
    #expect(viewModel.playbackTime <= plan.duration)
  }

  @Test
  func skipToCutJumpsBetweenCutStarts() async throws {
    let harness = try await makeHarness(videoCount: 4)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let plan = try #require(viewModel.plan)
    #expect(plan.cuts.count >= 5)
    func expectTime(_ expected: Double, _ label: String) async throws {
      try await waitUntil(label) { abs(viewModel.playbackTime - expected) < 0.06 }
    }

    // 次のカットの頭へ、順に進む。
    viewModel.skipToCut(1)
    try await expectTime(plan.cuts[1].timelineStart, "1つ目の次のカット")
    viewModel.skipToCut(1)
    try await expectTime(plan.cuts[2].timelineStart, "2つ目の次のカット")

    // カットの途中で戻ると、まずそのカットの頭へ。頭にいるときに戻ると、前のカットの頭へ。
    let long = try #require(plan.cuts.indices.dropFirst(2).first { plan.cuts[$0].duration >= 1.6 && $0 >= 3 })
    viewModel.seek(to: plan.cuts[long].timelineStart + 1.3)
    try await expectTime(plan.cuts[long].timelineStart + 1.3, "長いカットの途中")
    viewModel.skipToCut(-1)
    try await expectTime(plan.cuts[long].timelineStart, "そのカットの頭")
    viewModel.skipToCut(-1)
    try await expectTime(plan.cuts[long - 1].timelineStart, "前のカットの頭")

    // 最後のカットでは、それより先へは進まない。
    let last = plan.cuts.count - 1
    viewModel.seek(to: plan.cuts[last].timelineStart)
    try await expectTime(plan.cuts[last].timelineStart, "最後のカット")
    viewModel.skipToCut(1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(abs(viewModel.playbackTime - plan.cuts[last].timelineStart) < 0.06)
    // 先頭のカットでは、それより前へは戻らない。
    viewModel.seek(to: 0)
    try await expectTime(0, "先頭")
    viewModel.skipToCut(-1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(viewModel.playbackTime < 0.06)
  }

  @Test
  func playPauseAndMuteWork_andReplayFromTheStartAfterTheEnd() async throws {
    let harness = try await makeHarness(videoCount: 3)
    defer { harness.cleanUp() }
    let viewModel = harness.viewModel
    try await generate(harness)
    let plan = try #require(viewModel.plan)

    viewModel.togglePlayback()
    try await waitUntil("再生開始") { viewModel.isPlaying }
    viewModel.togglePlayback()
    try await waitUntil("一時停止") { !viewModel.isPlaying }

    // 終わりまで進めてから再生すると、先頭から再生し直す。
    viewModel.seek(to: plan.duration - 0.02)
    try await waitUntil("終わりへ移動") { viewModel.playbackTime > plan.duration - 0.2 }
    viewModel.togglePlayback()
    try await waitUntil("先頭から再生") { viewModel.isPlaying && viewModel.playbackTime < 2 }
    viewModel.togglePlayback()
    try await waitUntil("再び一時停止") { !viewModel.isPlaying }

    viewModel.isMuted = true
    #expect(viewModel.player.isMuted)
    viewModel.isMuted = false
    #expect(!viewModel.player.isMuted)
  }

  @Test
  func fullScreenDoesNotOpenWithoutAVideo() {
    let viewModel = MusicVideoViewModel(preferencesStore: MusicVideoPreferencesStore(defaults: UserDefaults(suiteName: "musicvideo-fs-\(UUID().uuidString)")!))
    let presenter = MusicVideoFullScreenPresenter()
    presenter.present(viewModel: viewModel)
    #expect(!presenter.isPresented)
  }

  @Test
  func portraitIsOnlyForTheCurrentSessionAndTheNextLaunchStartsLandscape() async throws {
    let harness = try await makeHarness(videoCount: 1)
    defer { harness.cleanUp() }
    let store = MusicVideoPreferencesStore(defaults: harness.defaults)

    // 縦を選んでいる間は縦のまま使えるが、保存されるのは同じ画質の横。
    harness.viewModel.renderPreset = .portraitFullHD
    #expect(harness.viewModel.renderPreset == .portraitFullHD)
    #expect(store.load().renderPreset == .landscapeFullHD)

    // 開き直す(新しい画面を作る)と、横から始まる。
    let next = MusicVideoViewModel(preferencesStore: store)
    next.attach(dataManager: harness.library)
    #expect(next.renderPreset == .landscapeFullHD)

    harness.viewModel.renderPreset = .portraitHD
    #expect(store.load().renderPreset == .landscapeHD)
  }

  @Test
  func aPortraitSizeSavedByAnEarlierVersionIsReadAsLandscape() async throws {
    let harness = try await makeHarness(videoCount: 1)
    defer { harness.cleanUp() }
    let store = MusicVideoPreferencesStore(defaults: harness.defaults)

    // 以前の版が保存した、縦の設定。
    var stored = MusicVideoPreferences()
    stored.renderPreset = .portraitHD
    stored.cutStyle = .energetic
    store.save(stored)

    let viewModel = MusicVideoViewModel(preferencesStore: store)
    viewModel.attach(dataManager: harness.library)
    #expect(viewModel.renderPreset == .landscapeHD)   // 画質(720p)は保ち、向きだけ横へ
    #expect(viewModel.cutStyle == .energetic)          // ほかの設定は、そのまま引き継ぐ
  }

  @Test
  func renderPresetKnowsItsOrientation() {
    #expect(MusicVideoRenderPreset.allCases.filter(\.isPortrait) == [.portraitFullHD, .portraitHD])
    #expect(MusicVideoRenderPreset.portraitFullHD.landscapeEquivalent == .landscapeFullHD)
    #expect(MusicVideoRenderPreset.portraitHD.landscapeEquivalent == .landscapeHD)
    #expect(MusicVideoRenderPreset.landscapeFullHD.landscapeEquivalent == .landscapeFullHD)
    #expect(MusicVideoRenderPreset.landscapeHD.landscapeEquivalent == .landscapeHD)
    // 何も保存していないときの既定も横。
    #expect(MusicVideoPreferences().renderPreset == .landscapeFullHD)
  }

  @Test
  func tuningIsSavedAndRestoredInTheNextSession() async throws {
    let harness = try await makeHarness(videoCount: 2)
    defer { harness.cleanUp() }

    harness.viewModel.cutTuning.motionMatching = .strong
    harness.viewModel.cutTuning.variety = .wide
    harness.viewModel.lookTuning.fitMode = .fit
    harness.viewModel.lookTuning.fadeSeconds = 1
    harness.viewModel.sourceLimit = 80

    let next = MusicVideoViewModel(preferencesStore: MusicVideoPreferencesStore(defaults: harness.defaults))
    next.attach(dataManager: harness.library)
    #expect(next.cutTuning.motionMatching == .strong)
    #expect(next.cutTuning.variety == .wide)
    #expect(next.lookTuning.fitMode == .fit)
    #expect(next.lookTuning.fadeSeconds == 1)
    #expect(next.sourceLimit == 80)
    // 復元しただけでは、何も反映待ちにならない(映像がまだ無いので、何も作り直されない)。
    #expect(next.plan == nil)
  }
}
