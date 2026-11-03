// ArkServer/Features/MusicVideo/Services/CutPlanner.swift

import Foundation

/// 曲の拍と盛り上がりから、カット割りと素材の区間を決める純粋ロジック。
/// 同じ入力と同じシードなら、必ず同じ結果になる。
nonisolated struct CutPlanner: Sendable {
  var style: MusicVideoCutStyle = .standard
  /// これより短いカットは作らない（拍が速すぎる曲では切り替えの間隔を倍にする）。
  var minimumCutDuration = 0.3
  /// 1カットごとに試す素材候補の数。多いほど動きの一致度が上がる。
  var candidateAttemptsPerCut = 40

  func plan(
    analysis: MusicAnalysis,
    pool: [SourceMotionProfile],
    seed: UInt64
  ) throws -> CutPlan {
    guard !analysis.beats.isEmpty else { throw CutPlannerError.noBeats }
    guard !pool.isEmpty else { throw CutPlannerError.emptyPool }

    var generator = SeededGenerator(seed: seed)
    let grid = makeGrid(analysis: analysis)
    var cuts: [PlannedCut] = []
    var usage: [UUID: Int] = [:]
    var usedRanges: [UUID: [Range<Double>]] = [:]

    var index = 0
    while index < grid.count - 1 {
      let start = grid[index]
      let intensity = analysis.intensity(at: start)
      var step = nextStep(from: index, intensity: intensity, grid: grid)
      var end = grid[min(grid.count - 1, index + step)]

      // 素材が足りないときは、拍の位置を保ったままカットを短くする。
      while step > 1 && !pool.contains(where: { $0.duration >= end - start }) {
        step -= 1
        end = grid[min(grid.count - 1, index + step)]
      }

      // 曲の終わりに短い余りが出るなら、今のカットを曲の終わりまで延ばして吸収する。
      let remainingAfter = analysis.duration - end
      if remainingAfter > 0, remainingAfter < minimumCutDuration,
         pool.contains(where: { $0.duration >= analysis.duration - start }) {
        end = analysis.duration
      }
      let length = end - start
      guard length > 0 else { break }

      // 狙う動きの大きさ: 段階ごとの目安と、その時点の連続的な盛り上がりの平均。
      let midpoint: Double = start + length / 2
      let levelTarget: Double = intensity.targetMotion
      let energyTarget: Double = analysis.energy(at: midpoint)
      let target: Double = (levelTarget + energyTarget) / 2
      guard let choice = pickClip(
        length: length,
        target: target,
        pool: pool,
        avoidVideoIDs: cuts.last.map { [$0.videoID] } ?? [],
        usage: usage,
        usedRanges: usedRanges,
        forbidden: nil,
        generator: &generator
      ) else {
        throw CutPlannerError.noClipLongEnough
      }

      cuts.append(PlannedCut(
        videoID: choice.videoID,
        sourceStart: choice.start,
        duration: length,
        timelineStart: start,
        intensity: intensity
      ))
      usage[choice.videoID, default: 0] += 1
      usedRanges[choice.videoID, default: []].append(choice.start..<(choice.start + length))

      if end >= analysis.duration { break }
      index += step
    }

    return CutPlan(cuts: cuts, duration: analysis.duration)
  }

  // MARK: - 格子（カットの境界になりうる時刻）

  /// 先頭に 0 秒、末尾に曲の終わりを加えた拍の一覧。
  private func makeGrid(analysis: MusicAnalysis) -> [Double] {
    var grid = analysis.beats.filter { $0 > 0.05 && $0 < analysis.duration - 0.05 }
    grid.insert(0, at: 0)
    grid.append(analysis.duration)
    return grid
  }

  /// 現在位置から次のカット境界までの拍数。
  /// 長いカット(2拍以上)は小節の頭に揃え、拍が速すぎる曲では最短時間を満たすまで倍にする。
  private func nextStep(from index: Int, intensity: MusicIntensity, grid: [Double]) -> Int {
    var beats = max(1, style.beatsPerCut(for: intensity))
    let beatInterval = averageInterval(grid: grid, around: index)
    while Double(beats) * beatInterval < minimumCutDuration, beats < 16 {
      beats *= 2
    }
    let remainingSteps = max(1, grid.count - 1 - index)

    // 格子の先頭(0秒)は拍ではない。最初のカットは1拍目までの導入部にするか、
    // 導入部が短すぎるなら最初の小節の終わりまで続ける。
    if index == 0 {
      let introGap = grid[1] - grid[0]
      return min(introGap >= minimumCutDuration ? 1 : beats + 1, remainingSteps)
    }

    // 以降は、小節(beats 拍)の頭に境界を揃える。拍の番号は格子の番号 - 1。
    var step = beats
    if beats >= 2 {
      let remainder = (index - 1) % beats
      if remainder != 0 {
        let toBoundary = beats - remainder
        step = toBoundary >= max(1, beats / 2) ? toBoundary : toBoundary + beats
      }
    }
    return min(step, remainingSteps)
  }

  private func averageInterval(grid: [Double], around index: Int) -> Double {
    guard grid.count > 2 else { return 0.5 }
    let upper = min(grid.count - 1, max(2, index + 4))
    let lower = max(1, upper - 4)
    guard upper > lower else { return 0.5 }
    return (grid[upper] - grid[lower]) / Double(upper - lower)
  }

  // MARK: - 素材の選択

  private struct ClipChoice {
    let videoID: UUID
    let start: Double
  }

  private func pickClip(
    length: Double,
    target: Double,
    pool: [SourceMotionProfile],
    avoidVideoIDs: Set<UUID>,
    usage: [UUID: Int],
    usedRanges: [UUID: [Range<Double>]],
    forbidden: (videoID: UUID, range: Range<Double>)?,
    generator: inout SeededGenerator
  ) -> ClipChoice? {
    let feasible = pool.filter { $0.duration >= length }
    guard !feasible.isEmpty else { return nil }
    // 1本の動画が複数の窓を持つので、「避ける動画以外がある」かどうかは動画IDで数える。
    let hasAlternative = feasible.contains { !avoidVideoIDs.contains($0.videoID) }

    func search(honoringForbidden: Bool, generator: inout SeededGenerator) -> ClipChoice? {
      var best: (choice: ClipChoice, score: Double)?
      for _ in 0..<max(1, candidateAttemptsPerCut) {
        let profile = feasible[Int.random(in: 0..<feasible.count, using: &generator)]
        let latestStart = profile.duration - length
        var start = latestStart > 0 ? Double.random(in: 0...latestStart, using: &generator) : 0
        // 標本の間隔に揃えて、同じ位置が重なりやすくなるのを抑えつつ計算を安定させる。
        if profile.hop > 0 { start = (start / profile.hop).rounded(.down) * profile.hop }
        start = min(start, max(0, latestStart))

        let motion = profile.meanMotion(start: start, length: length)
        // 以降の比較・記録は、動画全体の中での位置（窓の先頭からの位置 + 窓の開始位置）で行う。
        start += profile.offset
        let range = start..<(start + length)
        if honoringForbidden, let forbidden,
           forbidden.videoID == profile.videoID, forbidden.range.overlaps(range) {
          continue
        }

        var score = -2 * abs(motion - target)
        if hasAlternative, avoidVideoIDs.contains(profile.videoID) { score -= 1.0 }
        score -= 0.05 * Double(usage[profile.videoID] ?? 0)
        if (usedRanges[profile.videoID] ?? []).contains(where: { $0.overlaps(range) }) { score -= 0.8 }
        score += 0.05 * Double.random(in: 0...1, using: &generator)

        if best == nil || score > best!.score {
          best = (ClipChoice(videoID: profile.videoID, start: start), score)
        }
      }
      return best?.choice
    }

    // 禁止された区間を避けられる候補が見つからないときだけ、禁止なしでもう一度探す。
    return search(honoringForbidden: true, generator: &generator)
      ?? search(honoringForbidden: false, generator: &generator)
  }

  // MARK: - カット単位の差し替え

  /// `index` 番目のカットだけを、別の素材区間に選び直す。
  /// カットの枠(開始・長さ・盛り上がりの段階)は変えない。前後のカットと同じ動画は、他に選べる動画があるかぎり避け、
  /// 元の区間とは重ならない位置を選ぶ。
  /// - Parameters:
  ///   - excludedVideoIDs: 候補から外す動画。
  ///   - forcedVideoID: 指定すると、その動画の区間だけから選ぶ。
  func replaceCut(
    at index: Int,
    in plan: CutPlan,
    analysis: MusicAnalysis,
    pool: [SourceMotionProfile],
    seed: UInt64,
    excluding excludedVideoIDs: Set<UUID> = [],
    forcing forcedVideoID: UUID? = nil
  ) throws -> CutPlan {
    guard plan.cuts.indices.contains(index) else { return plan }
    let candidates = pool.filter { profile in
      !excludedVideoIDs.contains(profile.videoID) && (forcedVideoID == nil || profile.videoID == forcedVideoID)
    }
    guard !candidates.isEmpty else { throw CutPlannerError.emptyPool }

    let original = plan.cuts[index]
    var usage: [UUID: Int] = [:]
    var usedRanges: [UUID: [Range<Double>]] = [:]
    for (otherIndex, other) in plan.cuts.enumerated() where otherIndex != index {
      usage[other.videoID, default: 0] += 1
      usedRanges[other.videoID, default: []].append(other.sourceStart..<(other.sourceStart + other.duration))
    }
    var avoid = Set<UUID>()
    if forcedVideoID == nil {
      if index > 0 { avoid.insert(plan.cuts[index - 1].videoID) }
      if index + 1 < plan.cuts.count { avoid.insert(plan.cuts[index + 1].videoID) }
    }

    let midpoint: Double = original.timelineStart + original.duration / 2
    let levelTarget: Double = original.intensity.targetMotion
    let energyTarget: Double = analysis.energy(at: midpoint)
    let target: Double = (levelTarget + energyTarget) / 2

    // カットの番号ごとに乱数を変える(同じ種でも、別のカットは別の選び方になる)。
    var generator = SeededGenerator(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
    guard let choice = pickClip(
      length: original.duration,
      target: target,
      pool: candidates,
      avoidVideoIDs: avoid,
      usage: usage,
      usedRanges: usedRanges,
      forbidden: (original.videoID, original.sourceStart..<(original.sourceStart + original.duration)),
      generator: &generator
    ) else {
      throw CutPlannerError.noClipLongEnough
    }

    var cuts = plan.cuts
    cuts[index] = PlannedCut(
      videoID: choice.videoID,
      sourceStart: choice.start,
      duration: original.duration,
      timelineStart: original.timelineStart,
      intensity: original.intensity
    )
    return CutPlan(cuts: cuts, duration: plan.duration)
  }

  /// `videoID` の動画を使っているカットを、すべて別の動画に選び直す。
  func replaceAllCuts(
    usingVideo videoID: UUID,
    in plan: CutPlan,
    analysis: MusicAnalysis,
    pool: [SourceMotionProfile],
    seed: UInt64,
    excluding excludedVideoIDs: Set<UUID> = []
  ) throws -> CutPlan {
    var result = plan
    for index in plan.cuts.indices where plan.cuts[index].videoID == videoID {
      result = try replaceCut(
        at: index,
        in: result,
        analysis: analysis,
        pool: pool,
        seed: seed,
        excluding: excludedVideoIDs.union([videoID])
      )
    }
    return result
  }
}
