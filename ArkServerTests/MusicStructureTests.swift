// ArkServerTests/MusicStructureTests.swift

import Foundation
import Testing
@testable import ArkServer

/// 曲の拍の強さ・小節の頭・構造の境目・細かい onset。
@Suite(.serialized)
struct MusicStructureTests {
  // MARK: 部品の単体テスト(配列だけで確かめる)

  @Test
  func meterAndDownbeatPhaseAreFoundFromTheAccentPattern() {
    // 強・弱・中・弱 の繰り返し(4拍子)。
    let pattern = [1.0, 0.3, 0.5, 0.3]
    let fourBeat = (0..<32).map { pattern[$0 % 4] }
    #expect(MusicStructureAnalyzer.estimateMeter(rawAccents: fourBeat).beatsPerBar == 4)
    #expect(MusicStructureAnalyzer.estimateMeter(rawAccents: fourBeat).phase == 0)

    // 先頭が2拍ぶんずれていれば、小節の頭は添字 2 の位置。
    let shifted = (0..<32).map { pattern[($0 + 2) % 4] }
    #expect(MusicStructureAnalyzer.estimateMeter(rawAccents: shifted).phase == 2)

    // 3拍子(強・弱・弱)。
    let waltz = (0..<30).map { $0 % 3 == 1 ? 1.0 : 0.3 }
    let meter = MusicStructureAnalyzer.estimateMeter(rawAccents: waltz)
    #expect(meter.beatsPerBar == 3)
    #expect(meter.phase == 1)

    // 強さに周期が無ければ、小節の頭は分からない(nil)。拍子は 4 のまま。
    let flat = [Double](repeating: 0.6, count: 32)
    #expect(MusicStructureAnalyzer.estimateMeter(rawAccents: flat).phase == nil)
    #expect(MusicStructureAnalyzer.estimateMeter(rawAccents: flat).beatsPerBar == 4)

    // 拍が少なすぎれば、判断しない。
    #expect(MusicStructureAnalyzer.estimateMeter(rawAccents: [1, 0.3, 0.5]).phase == nil)
  }

  @Test
  func accentsAreNormalizedAndFlatOnesStayNeutral() {
    let normalized = MusicStructureAnalyzer.normalizedAccents([0.2, 0.2, 0.2, 0.2, 1.0, 1.0, 1.0, 1.0, 0.6, 0.6])
    #expect(normalized.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(normalized[4] > normalized[0])
    #expect(MusicStructureAnalyzer.normalizedAccents([0.5, 0.5, 0.5, 0.5, 0.5]).allSatisfy { $0 == 0.5 })
    #expect(MusicStructureAnalyzer.normalizedAccents([1, 2]).allSatisfy { $0 == 0.5 })   // 少なすぎる
  }

  @Test
  func sectionBoundariesAreFoundWhereTheEnergyChanges() {
    // 0.1秒ごと。0〜12秒は静か、12〜24秒は盛り上がり、24〜40秒は静か。
    let feature: [Double] = (0..<400).map { index in
      let time = Double(index) * 0.1
      return (time >= 12 && time < 24) ? 0.9 : 0.3
    }
    let beats = stride(from: 0.5, to: 40, by: 0.5).map { $0 }
    let sections = MusicStructureAnalyzer.sectionBoundaries(
      feature: feature, hop: 0.1, beats: beats, downbeats: nil, duration: 40
    )
    #expect(sections.count == 2)
    #expect(abs(sections[0] - 12) <= 0.6)
    #expect(abs(sections[1] - 24) <= 0.6)
    // 拍に寄せている。
    #expect(sections.allSatisfy { time in beats.contains { abs($0 - time) < 1e-9 } })
  }

  @Test
  func flatMusicHasNoSectionBoundaries() {
    let feature = [Double](repeating: 0.5, count: 400)
    let sections = MusicStructureAnalyzer.sectionBoundaries(feature: feature, hop: 0.1, beats: [], downbeats: nil, duration: 40)
    #expect(sections.isEmpty)
  }

  @Test
  func sectionBoundariesSnapToDownbeatsWhenKnown() {
    let feature: [Double] = (0..<400).map { Double($0) * 0.1 >= 20 ? 0.9 : 0.3 }
    let beats = stride(from: 0.5, to: 40, by: 0.5).map { $0 }
    // 小節の頭(4拍ごと=2秒おき)は 0.5, 2.5, 4.5 …。境目はそのどれかに寄る。
    let downbeats = stride(from: 0.5, to: 40, by: 2.0).map { $0 }
    let sections = MusicStructureAnalyzer.sectionBoundaries(feature: feature, hop: 0.1, beats: beats, downbeats: downbeats, duration: 40)
    #expect(sections.count == 1)
    #expect(downbeats.contains { abs($0 - sections[0]) < 1e-9 })
  }

  // MARK: 合成した音での確認

  /// 120BPM(0.5秒ごと)のクリック。`amplitudes[i % amplitudes.count]` が i 番目の強さ。
  private func accentedClicks(
    duration: Double,
    amplitudes: [Float],
    first: Double = 0.5
  ) -> (samples: [Float], clicks: [(time: Double, amplitude: Float)]) {
    var clicks: [(Double, Float)] = []
    var index = 0
    var time = first
    while time < duration - 0.1 {
      clicks.append((time, amplitudes[index % amplitudes.count]))
      index += 1
      time += 0.5
    }
    return (clickTrack(duration: duration, clicks: clicks), clicks.map { (time: $0.0, amplitude: $0.1) })
  }

  /// 解析した拍のうち、`predicate` に合う強さのクリックの近く(±40ms)にあるものの添字。
  private func beatIndices(
    in analysis: MusicAnalysis,
    clicks: [(time: Double, amplitude: Float)],
    where predicate: (Float) -> Bool
  ) -> [Int] {
    analysis.beats.indices.filter { index in
      guard let nearest = clicks.min(by: { abs($0.time - analysis.beats[index]) < abs($1.time - analysis.beats[index]) }),
            abs(nearest.time - analysis.beats[index]) < 0.04 else { return false }
      return predicate(nearest.amplitude)
    }
  }

  @Test
  func strongBeatsGetHigherAccentsAndTheBarStartIsFound() {
    // 4拍に1回だけ強いクリック(小節の頭)。
    let (samples, clicks) = accentedClicks(duration: 40, amplitudes: [1.0, 0.35, 0.5, 0.35])
    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)

    #expect(analysis.beatAccents.count == analysis.beats.count)
    #expect(analysis.beatsPerBar == 4)

    let strong = beatIndices(in: analysis, clicks: clicks) { $0 >= 0.99 }
    let weak = beatIndices(in: analysis, clicks: clicks) { $0 <= 0.4 }
    #expect(strong.count >= 6 && weak.count >= 12)

    // 強い拍の強さは、弱い拍よりはっきり大きい。
    let strongMean = strong.map { analysis.accent(atBeat: $0) }.reduce(0, +) / Double(strong.count)
    let weakMean = weak.map { analysis.accent(atBeat: $0) }.reduce(0, +) / Double(weak.count)
    #expect(strongMean > weakMean + 0.3, "強い \(strongMean) 弱い \(weakMean)")

    // 小節の頭は、強いクリックの位置。強い拍の9割以上が「小節の頭」、弱い拍の9割以上が「頭ではない」。
    #expect(analysis.downbeatPhase != nil)
    let strongAsDownbeat = strong.filter { analysis.isDownbeat(beatIndex: $0) == true }.count
    let weakAsOffbeat = weak.filter { analysis.isDownbeat(beatIndex: $0) == false }.count
    #expect(Double(strongAsDownbeat) / Double(strong.count) >= 0.9)
    #expect(Double(weakAsOffbeat) / Double(weak.count) >= 0.9)
  }

  @Test
  func theBarStartFollowsAShiftedAccentPattern() {
    // 強いクリックが 2 拍目から始まる(最初の拍は弱い)。
    let (samples, clicks) = accentedClicks(duration: 40, amplitudes: [0.35, 1.0, 0.35, 0.5])
    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)
    let strong = beatIndices(in: analysis, clicks: clicks) { $0 >= 0.99 }
    #expect(strong.count >= 6)
    #expect(Double(strong.filter { analysis.isDownbeat(beatIndex: $0) == true }.count) / Double(strong.count) >= 0.9)
  }

  @Test
  func fineOnsetEnvelopePeaksAtTheClicks() {
    let (samples, clicks) = accentedClicks(duration: 20, amplitudes: [1.0, 0.6])
    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)
    #expect(!analysis.onsetEnvelope.isEmpty)
    #expect(analysis.onsetHop == MusicStructureAnalyzer.fineHop)
    #expect(analysis.onsetEnvelope.allSatisfy { $0 >= 0 && $0 <= 1 })

    // クリックの近く(±50ms)は高く、クリックとクリックの真ん中は低い。
    var nearValues: [Double] = []
    var midValues: [Double] = []
    for index in 2..<(clicks.count - 2) {
      let click = clicks[index].time
      nearValues.append(stride(from: click - 0.05, through: click + 0.05, by: 0.025).map { analysis.onset(at: $0) }.max() ?? 0)
      midValues.append(analysis.onset(at: click + 0.25))
    }
    let nearMean = nearValues.reduce(0, +) / Double(nearValues.count)
    let midMean = midValues.reduce(0, +) / Double(midValues.count)
    #expect(nearMean > 0.4, "クリックの近く \(nearMean)")
    #expect(midMean < 0.15, "クリックの間 \(midMean)")
  }

  @Test
  func aLoudSectionInTheMiddleIsDetectedAsTwoBoundaries() {
    // 0〜14秒は弱く、14〜28秒は強く、28〜42秒は弱い。
    var clicks: [(time: Double, amplitude: Float)] = []
    var time = 0.5
    while time < 41.9 {
      clicks.append((time, (time >= 14 && time < 28) ? 1.0 : 0.25))
      time += 0.5
    }
    let samples = clickTrack(duration: 42, clicks: clicks)
    let analysis = BeatAnalyzer().analyze(samples: samples, sampleRate: testSampleRate)

    #expect(analysis.sectionBoundaries.count >= 2, "境目 \(analysis.sectionBoundaries)")
    func nearest(_ target: Double) -> Double {
      analysis.sectionBoundaries.map { abs($0 - target) }.min() ?? .infinity
    }
    #expect(nearest(14) <= 2.0, "14秒の近く \(analysis.sectionBoundaries)")
    #expect(nearest(28) <= 2.0, "28秒の近く \(analysis.sectionBoundaries)")
  }

  // MARK: 切り出しと互換

  @Test
  func trimmingKeepsAccentsTheBarStartAndSections() {
    var analysis = MusicAnalysis(
      duration: 40, tempo: 120,
      beats: Array(stride(from: 0.5, to: 39.9, by: 0.5)),
      energy: [Double](repeating: 0.5, count: 400),
      intensity: [MusicIntensity](repeating: .medium, count: 400),
      energyHop: 0.1
    )
    analysis.beatsPerBar = 4
    analysis.downbeatPhase = 1                       // 拍の添字 1, 5, 9, … が小節の頭
    analysis.beatAccents = (0..<analysis.beats.count).map { Double($0 % 7) / 7 }
    analysis.sectionBoundaries = [12, 24]
    analysis.onsetEnvelope = (0..<800).map { Double($0 % 10) / 10 }
    analysis.onsetHop = 0.05

    // 10秒から30秒。10秒より前の拍(添字 0〜18)は落ち、先頭の拍は元の添字 19(10.0秒)。
    let trimmed = analysis.trimmed(to: MusicRange(start: 10, end: 30))
    #expect(abs(trimmed.beats.first ?? 1) < 1e-9)    // 10.0秒の拍が、0秒になる
    #expect(trimmed.beatAccents.count == trimmed.beats.count)
    #expect(trimmed.beatAccents.first == analysis.beatAccents[19])
    // 元の添字 19 が先頭(新しい添字 0)。元で小節の頭だった添字 21 は、新しい添字 2。
    #expect(trimmed.isDownbeat(beatIndex: 2) == true)
    #expect(trimmed.isDownbeat(beatIndex: 0) == false)
    #expect(trimmed.sectionBoundaries == [2, 14])    // 12→2, 24→14(30秒の外は落ちる場合もあるが、ここでは範囲内)
    #expect(trimmed.onsetEnvelope.count == 400)
    #expect(trimmed.onsetEnvelope.first == analysis.onsetEnvelope[200])
  }

  @Test
  func analysisWithoutTheNewFieldsStillDecodesAndReportsNoInformation() throws {
    let legacy = #"{"duration":10,"tempo":120,"beats":[0.5,1.0],"energy":[0.5],"intensity":[1],"energyHop":1}"#
    let decoded = try JSONDecoder().decode(MusicAnalysis.self, from: Data(legacy.utf8))
    #expect(decoded.beats == [0.5, 1.0])
    #expect(decoded.beatAccents.isEmpty)
    #expect(decoded.downbeatPhase == nil)
    #expect(decoded.sectionBoundaries.isEmpty)
    // 情報が無いときは、「中間」「頭ではない/分からない」として扱う。
    #expect(decoded.accent(atBeat: 0) == 0.5)
    #expect(decoded.isDownbeat(beatIndex: 0) == nil)
    #expect(decoded.onset(at: 0.5) == 0)
  }
}
