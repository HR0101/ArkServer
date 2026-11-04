// ArkServer/Features/MusicVideo/Models/MusicVideoPlanStats.swift

import Foundation

/// いまのカット割りの結果を表す数値。調整項目の横に出して、「変えるとどうなるか」を目で確かめられるようにする。
nonisolated struct MusicVideoPlanStats: Equatable, Sendable {
  var cutCount: Int
  var averageCutDuration: Double
  var shortestCutDuration: Double
  var longestCutDuration: Double
  /// 実際に使った動画の本数。
  var usedVideoCount: Int
  /// 素材として使える動画の本数。
  var poolVideoCount: Int
  /// 映像の動きが、曲の盛り上がりにどれだけ合っているか(0〜1)。調べられないときは nil。
  var motionMatch: Double?

  init(plan: CutPlan, pool: [SourceMotionProfile], analysis: MusicAnalysis?) {
    let durations = plan.cuts.map(\.duration)
    cutCount = durations.count
    averageCutDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
    shortestCutDuration = durations.min() ?? 0
    longestCutDuration = durations.max() ?? 0
    usedVideoCount = Set(plan.cuts.map(\.videoID)).count
    poolVideoCount = Set(pool.map(\.videoID)).count
    motionMatch = analysis.flatMap { Self.motionMatch(plan: plan, pool: pool, analysis: $0) }
  }

  /// 各カットの素材の動きと、狙った動きとの差の平均を、1 から引いた値。
  /// 素材の動きを調べた区間(窓)に収まっていないカットは数えない。
  static func motionMatch(plan: CutPlan, pool: [SourceMotionProfile], analysis: MusicAnalysis) -> Double? {
    var windowsByVideo: [UUID: [SourceMotionProfile]] = [:]
    for profile in pool { windowsByVideo[profile.videoID, default: []].append(profile) }

    var totalGap = 0.0
    var counted = 0
    for cut in plan.cuts {
      let end = cut.sourceStart + cut.duration
      guard let window = windowsByVideo[cut.videoID]?.first(where: {
        $0.offset <= cut.sourceStart + 1e-6 && end <= $0.offset + $0.duration + 1e-6
      }) else { continue }
      let motion = window.meanMotion(start: cut.sourceStart - window.offset, length: cut.duration)
      let target = CutPlanner.targetMotion(
        intensity: cut.intensity,
        start: cut.timelineStart,
        length: cut.duration,
        analysis: analysis
      )
      totalGap += abs(motion - target)
      counted += 1
    }
    guard counted > 0 else { return nil }
    return min(1, max(0, 1 - totalGap / Double(counted)))
  }
}

/// 調整項目を変えたときの、変更前と変更後の違い。「どう変わったか」を一行で見せる。
nonisolated struct MusicVideoChangeSummary: Equatable, Sendable {
  /// 変えた項目の名前（「動画のばらけ具合」など）。
  var title: String
  var before: MusicVideoPlanStats
  var after: MusicVideoPlanStats

  /// 例: 「カット 64 → 48・平均 1.4秒 → 1.9秒・使った動画 9 → 14本」。変わらなかった数値は出さない。
  var text: String {
    var parts: [String] = []
    if before.cutCount != after.cutCount {
      parts.append("カット \(before.cutCount) → \(after.cutCount)")
    }
    if abs(before.averageCutDuration - after.averageCutDuration) >= 0.05 {
      parts.append("平均 \(Self.seconds(before.averageCutDuration)) → \(Self.seconds(after.averageCutDuration))")
    }
    if before.usedVideoCount != after.usedVideoCount {
      parts.append("使った動画 \(before.usedVideoCount) → \(after.usedVideoCount)本")
    }
    if let oldMatch = before.motionMatch, let newMatch = after.motionMatch,
       abs(oldMatch - newMatch) >= 0.01 {
      parts.append("動きの一致 \(Self.percent(oldMatch)) → \(Self.percent(newMatch))")
    }
    if parts.isEmpty { return "「\(title)」を変えました．数値の上では大きな違いはありません．" }
    return "「\(title)」を変えました：" + parts.joined(separator: "・")
  }

  static func seconds(_ value: Double) -> String {
    String(format: "%.1f秒", value)
  }

  static func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))％"
  }
}
