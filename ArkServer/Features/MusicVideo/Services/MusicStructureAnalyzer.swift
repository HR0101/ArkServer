// ArkServer/Features/MusicVideo/Services/MusicStructureAnalyzer.swift

import Foundation

/// 曲の拍の「強さ」「小節の頭」「構造の境目」と、細かい音の立ち上がりを求める。
///
/// 拍の位置(`BeatAnalyzer` が求める)だけでは、「どの拍で映像を大きく動かすか」が決められない。
/// 小節の1拍目やサビの頭、拍ごとの強さが分かれば、映像の大きな動きを、曲の大きな音に当てられる。
/// 配列だけを入出力にした純粋な計算なので、音声ファイルなしでテストできる。
nonisolated enum MusicStructureAnalyzer {
  struct Result: Sendable, Equatable {
    var beatAccents: [Double]
    var onsetEnvelope: [Double]
    var onsetHop: Double
    var beatsPerBar: Int
    var downbeatPhase: Int?
    var sectionBoundaries: [Double]
  }

  /// 細かい onset の標本間隔(秒)。
  static let fineHop = 0.05

  /// - Parameters:
  ///   - onset: フレームごとの onset の強さ(0 以上)。
  ///   - framesPerSecond: `onset` の1秒あたりのフレーム数。
  ///   - onsetOffset: フレーム番号 / framesPerSecond に足すと、実際の音の時刻になる秒数。
  ///   - beats: 拍の時刻(秒、昇順)。
  ///   - structureFeature: 曲の構造を見るための、盛り上がりの連続値(0〜1)。`featureHop` 秒ごと。短めの平滑化まで。
  static func analyze(
    onset: [Double],
    framesPerSecond: Double,
    onsetOffset: Double,
    beats: [Double],
    structureFeature: [Double],
    featureHop: Double,
    duration: Double
  ) -> Result {
    let rawAccents = rawBeatAccents(onset: onset, framesPerSecond: framesPerSecond, onsetOffset: onsetOffset, beats: beats)
    let (beatsPerBar, phase) = estimateMeter(rawAccents: rawAccents)
    let sections = sectionBoundaries(
      feature: structureFeature,
      hop: featureHop,
      beats: beats,
      downbeats: phase.map { downbeatTimes(beats: beats, phase: $0, beatsPerBar: beatsPerBar) },
      duration: duration
    )
    return Result(
      beatAccents: normalizedAccents(rawAccents),
      onsetEnvelope: fineOnsetEnvelope(
        onset: onset, framesPerSecond: framesPerSecond, onsetOffset: onsetOffset, hop: fineHop, duration: duration
      ),
      onsetHop: fineHop,
      beatsPerBar: beatsPerBar,
      downbeatPhase: phase,
      sectionBoundaries: sections
    )
  }

  // MARK: - 細かい onset

  /// `hop` 秒ごとの、onset の強さ(その区間の最大値)。上位2%を 1 として規格化する。
  static func fineOnsetEnvelope(
    onset: [Double],
    framesPerSecond: Double,
    onsetOffset: Double,
    hop: Double,
    duration: Double
  ) -> [Double] {
    guard !onset.isEmpty, hop > 0, duration > 0 else { return [] }
    let blockCount = max(1, Int((duration / hop).rounded(.up)))
    var values = [Double](repeating: 0, count: blockCount)
    for block in 0..<blockCount {
      let first = Int(((Double(block) * hop - onsetOffset) * framesPerSecond).rounded(.down))
      let last = Int(((Double(block + 1) * hop - onsetOffset) * framesPerSecond).rounded(.up))
      let lower = max(0, first)
      let upper = min(onset.count - 1, max(lower, last - 1))
      guard lower <= upper else { continue }
      var peak = 0.0
      for frame in lower...upper where onset[frame] > peak { peak = onset[frame] }
      values[block] = peak
    }
    let sorted = values.sorted()
    let high = sorted[Int(Double(sorted.count - 1) * 0.98)]
    guard high > 1e-9 else { return values.map { _ in 0 } }
    return values.map { min(1, $0 / high) }
  }

  // MARK: - 拍の強さ

  /// 拍ごとの、前後 40ms の onset の最大値(規格化していない)。
  static func rawBeatAccents(onset: [Double], framesPerSecond: Double, onsetOffset: Double, beats: [Double]) -> [Double] {
    guard !onset.isEmpty else { return beats.map { _ in 0 } }
    let radius = max(1, Int((0.04 * framesPerSecond).rounded()))
    return beats.map { time in
      let center = Int(((time - onsetOffset) * framesPerSecond).rounded())
      let lower = max(0, center - radius)
      let upper = min(onset.count - 1, center + radius)
      guard lower <= upper else { return 0 }
      var peak = 0.0
      for frame in lower...upper where onset[frame] > peak { peak = onset[frame] }
      return peak
    }
  }

  /// 下位10%を0、上位10%を1として規格化する。拍が少なすぎる・強さに差が無いときは、すべて 0.5。
  static func normalizedAccents(_ raw: [Double]) -> [Double] {
    guard raw.count >= 4 else { return raw.map { _ in 0.5 } }
    let sorted = raw.sorted()
    let low = sorted[Int(Double(sorted.count - 1) * 0.1)]
    let high = sorted[Int(Double(sorted.count - 1) * 0.9)]
    guard high - low > 1e-9 else { return raw.map { _ in 0.5 } }
    return raw.map { min(1, max(0, ($0 - low) / (high - low))) }
  }

  // MARK: - 小節の頭

  /// 拍の強さの周期から、拍子(3 か 4)と、小節の1拍目の位置(拍の添字を拍子で割った余り)を推定する。
  /// 周期の山がはっきりしないときは、拍子は 4、位置は nil。
  static func estimateMeter(rawAccents: [Double]) -> (beatsPerBar: Int, phase: Int?) {
    guard rawAccents.count >= 12 else { return (4, nil) }
    let four = periodicContrast(rawAccents, meter: 4)
    let three = periodicContrast(rawAccents, meter: 3)
    // 4拍子を基本にして、3拍子は、はっきり良いときだけ採る(3は4の約数でなく、取り違えると全体がずれるため)。
    let useThree = three.contrast > four.contrast * 1.5 && three.contrast >= 0.25
    let chosen = useThree ? three : four
    let meter = useThree ? 3 : 4
    return (meter, chosen.contrast >= 0.1 ? chosen.phase : nil)
  }

  /// 拍の強さを `meter` ごとに分けたとき、いちばん強い位置の、ほかの位置に対する際立ち。
  private static func periodicContrast(_ accents: [Double], meter: Int) -> (phase: Int, contrast: Double) {
    var sums = [Double](repeating: 0, count: meter)
    var counts = [Int](repeating: 0, count: meter)
    for (index, value) in accents.enumerated() {
      sums[index % meter] += value
      counts[index % meter] += 1
    }
    let means = (0..<meter).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    guard let best = means.indices.max(by: { means[$0] < means[$1] }) else { return (0, 0) }
    let others = means.indices.filter { $0 != best }.map { means[$0] }
    let otherMean = others.reduce(0, +) / Double(max(1, others.count))
    let overall = means.reduce(0, +) / Double(meter)
    return (best, (means[best] - otherMean) / (overall + 0.05))
  }

  static func downbeatTimes(beats: [Double], phase: Int, beatsPerBar: Int) -> [Double] {
    beats.enumerated().compactMap { index, time in
      ((index - phase) % beatsPerBar + beatsPerBar) % beatsPerBar == 0 ? time : nil
    }
  }

  // MARK: - 曲の構造の境目

  /// 盛り上がりが大きく変わる時刻(サビ・ドロップ・静かな部分への切り替わり)。
  /// 前後 4 秒ずつの平均の差(novelty)が大きい所を、6 秒以上離して選び、近くの小節の頭(無ければ拍)に寄せる。
  static func sectionBoundaries(
    feature: [Double],
    hop: Double,
    beats: [Double],
    downbeats: [Double]?,
    duration: Double
  ) -> [Double] {
    let window = Int((4.0 / hop).rounded())
    guard hop > 0, window >= 2, feature.count > window * 2 else { return [] }

    var prefix = [Double](repeating: 0, count: feature.count + 1)
    for (index, value) in feature.enumerated() { prefix[index + 1] = prefix[index] + value }
    func mean(_ lower: Int, _ upper: Int) -> Double { (prefix[upper] - prefix[lower]) / Double(upper - lower) }

    var novelty = [Double](repeating: 0, count: feature.count)
    for index in window..<(feature.count - window) {
      novelty[index] = abs(mean(index, index + window) - mean(index - window, index))
    }

    let nonZero = novelty.filter { $0 > 0 }.sorted()
    let median = nonZero.isEmpty ? 0 : nonZero[nonZero.count / 2]
    let threshold = max(0.2, median * 2)

    // 大きい順に採り、近すぎるものは捨てる。
    let minimumGap = Int((6.0 / hop).rounded())
    var chosen: [Int] = []
    for index in novelty.indices.sorted(by: { novelty[$0] > novelty[$1] }) {
      guard novelty[index] >= threshold else { break }
      guard chosen.allSatisfy({ abs($0 - index) >= minimumGap }) else { continue }
      chosen.append(index)
    }

    let snapTargets = (downbeats?.isEmpty == false) ? downbeats! : beats
    return chosen
      .map { Double($0) * hop }
      .filter { $0 > 4 && $0 < duration - 4 }
      .map { time in
        guard let nearest = snapTargets.min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) <= 2.5 else { return time }
        return nearest
      }
      .sorted()
  }
}
