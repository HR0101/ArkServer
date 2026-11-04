// ArkServer/Features/MusicVideo/Services/CutPlanner.swift

import Accelerate
import Foundation

/// 曲の拍と盛り上がりから、カット割りと素材の区間を決める純粋ロジック。
/// 同じ入力と同じシードなら、必ず同じ結果になる。
///
/// 素材の選び方(`pickClip`)は、候補をランダムに数十回試すのではなく、すべての素材のすべての位置を採点して、いちばん良いものを選ぶ。
/// 採点は次の3つを足したもの。
///  1. 動きの強さの一致: カットの間の映像の平均の動きが、曲の盛り上がりに合っているか。
///  2. 拍と衝撃の一致: 曲の拍(音の立ち上がり)の山と、映像の「急に動いた瞬間」の山が、同じ時刻に重なるか。
///     重なりは、カットの中の時間変化の類似度(コサイン類似度)で測る。
///  3. カットの頭の一致: カットは拍の上で切り替わるので、その瞬間に映像が動き出しているか(曲の頭の強さに応じて)。
/// 全位置の採点は、Accelerate でまとめて行うので、素材が数百の窓あっても遅くならない。
nonisolated struct CutPlanner: Sendable {
  var style: MusicVideoCutStyle = .standard
  /// これより短いカットは作らない（拍が速すぎる曲では切り替えの間隔を倍にする）。
  var minimumCutDuration = 0.3
  /// これより長いカットは作らない（nil なら制限しない）。拍の数を減らして収める。
  /// 最短と同時に守れないときは、最長を優先する。
  var maximumCutDuration: Double?
  /// 盛り上がりに映像の動きを合わせる強さ。
  var motionMatching: MotionMatching = .standard
  /// 同じ動画をどれだけ避けるか。
  var variety: VideoVariety = .standard
  /// 切り替えの位置を、小節の頭にそろえるか。
  var alignment: CutAlignment = .bar
  /// 曲の拍(強い拍・小節の頭・曲の変わり目)に、映像の大きな動きを重ねる強さ。
  var hitSync: HitSync = .strong

  init() {}

  init(style: MusicVideoCutStyle, tuning: MusicVideoCutTuning) {
    self.style = style
    minimumCutDuration = tuning.minimumCutDuration
    maximumCutDuration = tuning.maximumCutDuration
    motionMatching = tuning.motionMatching
    variety = tuning.variety
    alignment = tuning.alignment
    hitSync = tuning.hitSync
  }

  func plan(
    analysis: MusicAnalysis,
    pool: [SourceMotionProfile],
    seed: UInt64
  ) throws -> CutPlan {
    guard !analysis.beats.isEmpty else { throw CutPlannerError.noBeats }
    guard !pool.isEmpty else { throw CutPlannerError.emptyPool }

    let noise = NoiseSource(seed: seed)
    let grid = makeGrid(analysis: analysis)
    // 格子の添字 i(1以上)は、拍の添字 i - 1 + beatOffset にあたる(先頭付近の短い拍は格子から除いてある)。
    let beatOffset = analysis.beats.firstIndex { $0 > 0.05 } ?? 0
    let barPhase = analysis.downbeatPhase ?? 0
    var cuts: [PlannedCut] = []
    var usage: [UUID: Int] = [:]
    var usedRanges: [UUID: [Range<Double>]] = [:]

    var index = 0
    while index < grid.count - 1 {
      let start = grid[index]
      let intensity = analysis.intensity(at: start)
      var step = nextStep(from: index, intensity: intensity, grid: grid, beatNumberOffset: beatOffset - barPhase)
      // 曲の構造が変わる所(サビ・ドロップ)に、カットの境目を合わせる。
      step = sectionAlignedStep(index: index, step: step, grid: grid, boundaries: analysis.sectionBoundaries)
      var end = grid[min(grid.count - 1, index + step)]

      // 素材が足りないときは、拍の位置を保ったままカットを短くする。
      while step > 1 && !pool.contains(where: { $0.duration >= end - start }) {
        step -= 1
        end = grid[min(grid.count - 1, index + step)]
      }

      // 曲の終わりに短い余りが出るなら、今のカットを曲の終わりまで延ばして吸収する。
      // 最長を決めているときは、最長を超えるなら吸収しない。
      let remainingAfter = analysis.duration - end
      if remainingAfter > 0, remainingAfter < minimumCutDuration,
         pool.contains(where: { $0.duration >= analysis.duration - start }),
         maximumCutDuration.map({ analysis.duration - start <= $0 + 1e-9 }) ?? true {
        end = analysis.duration
      }
      let length = end - start
      guard length > 0 else { break }

      let signal = MusicCutSignal(
        analysis: analysis,
        start: start,
        length: length,
        accentAtStart: accentAtStart(analysis: analysis, gridIndex: index, beatOffset: beatOffset, start: start)
      )
      let target = Self.targetMotion(intensity: intensity, start: start, length: length, analysis: analysis)
        + (signal.isSectionStart ? 0.1 : 0)
      guard let choice = pickClip(
        length: length,
        target: min(1, target),
        pool: pool,
        avoidVideoIDs: cuts.last.map { [$0.videoID] } ?? [],
        usage: usage,
        usedRanges: usedRanges,
        forbidden: nil,
        music: signal,
        noise: noise,
        cutKey: UInt64(cuts.count)
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

  /// 盛り上がりの段階 `intensity` で、1カットに使う拍の数。
  /// 拍が速すぎる曲では最短時間を満たすまで倍にし、最長が決まっていれば、その長さに収まるまで減らす。
  /// 画面の説明（「静かな所は約2.0秒ごと」）にも同じ計算を使う。
  func effectiveBeats(for intensity: MusicIntensity, beatInterval: Double) -> Int {
    var beats = max(1, style.beatsPerCut(for: intensity))
    while Double(beats) * beatInterval < minimumCutDuration, beats < 16 {
      beats *= 2
    }
    if let maximumCutDuration, beatInterval > 0 {
      let allowed = max(1, Int((maximumCutDuration / beatInterval + 1e-9).rounded(.down)))
      beats = min(beats, allowed)
    }
    return beats
  }

  /// 現在位置から次のカット境界までの拍数。
  /// 長いカット(2拍以上)は小節の頭に揃える(`alignment` が `.bar` のとき)。
  /// - Parameter beatNumberOffset: 格子の添字 - 1 に足すと、「小節の1拍目から数えた拍の番号」になる値。
  private func nextStep(from index: Int, intensity: MusicIntensity, grid: [Double], beatNumberOffset: Int) -> Int {
    let beatInterval = averageInterval(grid: grid, around: index)
    let beats = effectiveBeats(for: intensity, beatInterval: beatInterval)
    let remainingSteps = max(1, grid.count - 1 - index)

    var step = beats
    if index == 0 {
      // 格子の先頭(0秒)は拍ではない。最初のカットは1拍目までの導入部にするか、
      // 導入部が短すぎるなら最初の小節の終わりまで続ける。
      let introGap = grid[1] - grid[0]
      step = introGap >= minimumCutDuration ? 1 : beats + 1
    } else if beats >= 2, alignment == .bar {
      // 以降は、小節(beats 拍)の頭に境界を揃える。
      let beatNumber = index - 1 + beatNumberOffset
      let remainder = ((beatNumber % beats) + beats) % beats
      if remainder != 0 {
        let toBoundary = beats - remainder
        step = toBoundary >= max(1, beats / 2) ? toBoundary : toBoundary + beats
      }
    }
    step = min(step, remainingSteps)

    // 揃えた結果が最短に足りないときは、拍の位置を保ったまま延ばす。
    while step < remainingSteps, grid[index + step] - grid[index] < minimumCutDuration - 1e-9 {
      step += 1
    }

    // 揃えた結果が最長を超えるときは、拍の位置を保ったまま短くする（最短と両立しないときは最長を優先）。
    if let maximumCutDuration {
      while step > 1, grid[index + step] - grid[index] > maximumCutDuration + 1e-9 {
        step -= 1
      }
    }
    return step
  }

  /// カットの途中に曲の構造の境目(サビ・ドロップ)があれば、そこでカットを区切るよう拍の数を縮める。
  /// 境目が最短のカットより手前にあるときや、近い拍が無いときは、そのまま。
  private func sectionAlignedStep(index: Int, step: Int, grid: [Double], boundaries: [Double]) -> Int {
    guard !boundaries.isEmpty, step > 1 else { return step }
    let start = grid[index]
    let end = grid[min(grid.count - 1, index + step)]
    guard let boundary = boundaries.first(where: { $0 > start + minimumCutDuration && $0 < end - 0.05 }) else { return step }

    var bestStep = step
    var bestDistance = Double.infinity
    for candidate in 1..<step where index + candidate < grid.count {
      let distance = abs(grid[index + candidate] - boundary)
      if distance < bestDistance {
        bestDistance = distance
        bestStep = candidate
      }
    }
    guard bestDistance <= 0.25, grid[index + bestStep] - start >= minimumCutDuration - 1e-9 else { return step }
    return bestStep
  }

  /// カットの頭にあたる拍の強さ(0〜1)。小節の頭は強めに、曲の構造の境目は最大にする。
  private func accentAtStart(analysis: MusicAnalysis, gridIndex: Int, beatOffset: Int, start: Double) -> Double {
    if analysis.sectionBoundaries.contains(where: { abs($0 - start) < 0.03 }) { return 1 }
    guard gridIndex >= 1 else { return 0.5 }
    let beatIndex = gridIndex - 1 + beatOffset
    var accent = analysis.accent(atBeat: beatIndex)
    if analysis.isDownbeat(beatIndex: beatIndex) == true { accent = max(accent, 0.8) }
    return accent
  }

  private func averageInterval(grid: [Double], around index: Int) -> Double {
    guard grid.count > 2 else { return 0.5 }
    let upper = min(grid.count - 1, max(2, index + 4))
    let lower = max(1, upper - 4)
    guard upper > lower else { return 0.5 }
    return (grid[upper] - grid[lower]) / Double(upper - lower)
  }

  /// カットが狙う動きの大きさ(0〜1)。段階ごとの目安と、その時点の連続的な盛り上がりの平均。
  static func targetMotion(intensity: MusicIntensity, start: Double, length: Double, analysis: MusicAnalysis) -> Double {
    let midpoint: Double = start + length / 2
    let levelTarget: Double = intensity.targetMotion
    let energyTarget: Double = analysis.energy(at: midpoint)
    return (levelTarget + energyTarget) / 2
  }

  // MARK: - 素材の選択

  struct ClipChoice {
    let videoID: UUID
    let start: Double
  }

  /// 1つのカットを、素材のすべての位置の中から、いちばん点の高いものに決める。
  /// - Parameters:
  ///   - music: このカットの間の曲の拍・音の立ち上がり。nil(または情報なし)なら、動きの強さの一致だけで選ぶ。
  ///   - cutKey: カットごとに乱数の使い方を変えるための値(同じ種でも、別のカットは別の揺らぎになる)。
  private func pickClip(
    length: Double,
    target: Double,
    pool: [SourceMotionProfile],
    avoidVideoIDs: Set<UUID>,
    usage: [UUID: Int],
    usedRanges: [UUID: [Range<Double>]],
    forbidden: (videoID: UUID, range: Range<Double>)?,
    music: MusicCutSignal?,
    noise: NoiseSource,
    cutKey: UInt64
  ) -> ClipChoice? {
    let feasible = pool.filter { $0.duration >= length && $0.hop > 0 && !$0.values.isEmpty }
    guard !feasible.isEmpty else { return nil }
    // 1本の動画が複数の窓を持つので、「避ける動画以外がある」かどうかは動画IDで数える。
    let hasAlternative = feasible.contains { !avoidVideoIDs.contains($0.videoID) }

    func search(honoringForbidden: Bool) -> ClipChoice? {
      var pulseCache: [Int: [Double]] = [:]
      var best: (score: Double, videoID: UUID, start: Double)?
      for (profileIndex, profile) in feasible.enumerated() {
        let scored = bestPosition(
          in: profile,
          length: length,
          target: target,
          music: music,
          pulseCache: &pulseCache,
          penalty: Self.scalarPenalty(
            for: profile,
            hasAlternative: hasAlternative,
            avoidVideoIDs: avoidVideoIDs,
            usage: usage,
            variety: variety
          ),
          usedRanges: usedRanges[profile.videoID] ?? [],
          overlapPenalty: variety.overlapPenalty,
          forbidden: honoringForbidden && forbidden?.videoID == profile.videoID ? forbidden?.range : nil,
          noise: noise,
          noiseKey: cutKey &* 7_919 &+ UInt64(profileIndex)
        )
        guard let scored else { continue }
        if best == nil || scored.score > best!.score {
          best = (scored.score, profile.videoID, scored.start)
        }
      }
      return best.map { ClipChoice(videoID: $0.videoID, start: $0.start) }
    }

    // 禁止された区間を避けられる候補が見つからないときだけ、禁止なしでもう一度探す。
    return search(honoringForbidden: true) ?? search(honoringForbidden: false)
  }

  /// 動画の使われ方による減点(位置に依らず、その動画に一律)。
  private static func scalarPenalty(
    for profile: SourceMotionProfile,
    hasAlternative: Bool,
    avoidVideoIDs: Set<UUID>,
    usage: [UUID: Int],
    variety: VideoVariety
  ) -> Double {
    var penalty = variety.usagePenalty * Double(usage[profile.videoID] ?? 0)
    if hasAlternative, avoidVideoIDs.contains(profile.videoID) { penalty += variety.avoidLastPenalty }
    return penalty
  }

  /// 1つの窓の中で、いちばん点の高い開始位置とその点。使える位置が無ければ nil。
  private func bestPosition(
    in profile: SourceMotionProfile,
    length: Double,
    target: Double,
    music: MusicCutSignal?,
    pulseCache: inout [Int: [Double]],
    penalty: Double,
    usedRanges: [Range<Double>],
    overlapPenalty: Double,
    forbidden: Range<Double>?,
    noise: NoiseSource,
    noiseKey: UInt64
  ) -> (score: Double, start: Double)? {
    let hop = profile.hop
    let n = max(1, Int((length / hop - 1e-9).rounded(.up)))
    let lastIndexByLength = Int(((profile.duration - length) / hop + 1e-9).rounded(.down))
    let positions = min(profile.values.count - n + 1, lastIndexByLength + 1)
    guard positions >= 1, profile.prefixSums.count >= n + positions else { return nil }

    // 1. 動きの強さの一致: 平均の動きと狙いの差。
    var scores = [Double](repeating: 0, count: positions)
    if motionMatching.weight > 0 {
      let sums = vDSP.subtract(profile.prefixSums[n..<(n + positions)], profile.prefixSums[0..<positions])
      let gaps = vDSP.absolute(vDSP.add(-target * Double(n), sums))
      scores = vDSP.multiply(-motionMatching.weight / Double(n), gaps)
    }

    // 2・3. 拍と衝撃の一致、カットの頭の一致。
    if hitSync.weight > 0, let music, music.hasHitInformation, profile.impacts.count == profile.values.count {
      let key = Int((hop * 1_000_000).rounded())
      let pulses: [Double]
      if let cached = pulseCache[key] {
        pulses = cached
      } else {
        pulses = music.pulses(hop: hop, count: n)
        pulseCache[key] = pulses
      }
      let pulseNorm = vDSP.sum(vDSP.multiply(pulses, pulses)).squareRoot()
      if pulseNorm > 1e-9 {
        // 時刻をそろえた類似度: Σ 曲の山 × 映像の衝撃 / (|曲の山| × |映像の衝撃|)。
        let numerator = Self.correlate(profile.impacts, kernel: pulses, positions: positions)
        let energy = vDSP.subtract(profile.impactSquarePrefix[n..<(n + positions)], profile.impactSquarePrefix[0..<positions])
        // 衝撃が小さい(動きの少ない)窓は、見かけの類似度が高くなりすぎないよう、分母に下駄を履かせる。
        var denominator = [Double](repeating: 0, count: positions)
        vForce.sqrt(vDSP.add(0.25, energy), result: &denominator)
        let cosine = vDSP.divide(numerator, vDSP.multiply(pulseNorm, denominator))
        scores = vDSP.add(scores, vDSP.multiply(hitSync.weight * music.strength, cosine))

        // カットの頭に、映像の動き出しが来るか(頭の拍が強いほど重視)。
        let startHit: [Double]
        if n >= 2, positions + 1 <= profile.impacts.count {
          startHit = vDSP.maximum(profile.impacts[0..<positions], profile.impacts[1..<(positions + 1)])
        } else {
          startHit = Array(profile.impacts[0..<positions])
        }
        scores = vDSP.add(scores, vDSP.multiply(hitSync.weight * 0.6 * music.accentAtStart, startHit))
      }
    }

    // 4. 動画の使われ方・揺らぎ。
    scores = vDSP.add(scores, vDSP.multiply(0.05, noise.slice(count: positions, key: noiseKey)))
    if penalty != 0 { scores = vDSP.add(-penalty, scores) }

    // 同じ動画の、すでに使った区間と重なる位置は減点する。禁止された区間と重なる位置は、事実上除く。
    func overlappingIndices(_ range: Range<Double>) -> Range<Int>? {
      let first = Int(((range.lowerBound - length - profile.offset) / hop + 1e-9).rounded(.down)) + 1
      let last = Int(((range.upperBound - profile.offset) / hop - 1e-9).rounded(.up)) - 1
      let lower = max(0, first)
      let upper = min(positions - 1, last)
      return lower <= upper ? lower..<(upper + 1) : nil
    }
    for range in usedRanges {
      if let indices = overlappingIndices(range) {
        for index in indices { scores[index] -= overlapPenalty }
      }
    }
    if let forbidden, let indices = overlappingIndices(forbidden) {
      for index in indices { scores[index] = -1e9 }
    }

    var bestIndex: vDSP_Length = 0
    var bestScore = 0.0
    vDSP_maxviD(scores, 1, &bestScore, &bestIndex, vDSP_Length(positions))
    guard bestScore > -1e8 else { return nil }
    return (bestScore, profile.offset + Double(bestIndex) * hop)
  }

  /// `signal` の各位置 i から長さ `kernel.count` の窓と `kernel` の内積(相互相関)を、`positions` 個の i について求める。
  static func correlate(_ signal: [Double], kernel: [Double], positions: Int) -> [Double] {
    guard positions > 0, !kernel.isEmpty, signal.count >= positions + kernel.count - 1 else {
      return [Double](repeating: 0, count: max(0, positions))
    }
    var result = [Double](repeating: 0, count: positions)
    signal.withUnsafeBufferPointer { signalBuffer in
      kernel.withUnsafeBufferPointer { kernelBuffer in
        vDSP_convD(
          signalBuffer.baseAddress!, 1,
          kernelBuffer.baseAddress!, 1,
          &result, 1,
          vDSP_Length(positions),
          vDSP_Length(kernel.count)
        )
      }
    }
    return result
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

    let target = Self.targetMotion(
      intensity: original.intensity,
      start: original.timelineStart,
      length: original.duration,
      analysis: analysis
    )
    let signal = MusicCutSignal(
      analysis: analysis,
      start: original.timelineStart,
      length: original.duration,
      accentAtStart: accentAtCutStart(of: original, analysis: analysis)
    )

    // カットの番号ごとに乱数を変える(同じ種でも、別のカットは別の選び方になる)。
    let noise = NoiseSource(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
    guard let choice = pickClip(
      length: original.duration,
      target: target,
      pool: candidates,
      avoidVideoIDs: avoid,
      usage: usage,
      usedRanges: usedRanges,
      forbidden: (original.videoID, original.sourceStart..<(original.sourceStart + original.duration)),
      music: signal,
      noise: noise,
      cutKey: UInt64(index)
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

  /// 既にあるカットの頭にあたる拍の強さ。頭に近い拍(30ms以内)が無ければ 0.5。
  private func accentAtCutStart(of cut: PlannedCut, analysis: MusicAnalysis) -> Double {
    if analysis.sectionBoundaries.contains(where: { abs($0 - cut.timelineStart) < 0.03 }) { return 1 }
    guard let beatIndex = analysis.beats.indices.min(by: {
      abs(analysis.beats[$0] - cut.timelineStart) < abs(analysis.beats[$1] - cut.timelineStart)
    }), abs(analysis.beats[beatIndex] - cut.timelineStart) < 0.03 else { return 0.5 }
    var accent = analysis.accent(atBeat: beatIndex)
    if analysis.isDownbeat(beatIndex: beatIndex) == true { accent = max(accent, 0.8) }
    return accent
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

// MARK: - 曲のカット1つぶんの信号

/// 1つのカットの間(開始 `start` から `length` 秒)の、曲の音の立ち上がり。
nonisolated struct MusicCutSignal: Sendable {
  let analysis: MusicAnalysis
  let start: Double
  let length: Double
  /// カットの頭の拍の強さ(0〜1)。
  let accentAtStart: Double

  /// 音の立ち上がりの情報があるか。無い(簡易な解析)ときは、拍と衝撃の一致は使えない。
  var hasHitInformation: Bool { !analysis.onsetEnvelope.isEmpty && analysis.onsetHop > 0 }

  /// 曲の構造の境目(サビ・ドロップ)の頭にあたるカットか。
  var isSectionStart: Bool { analysis.sectionBoundaries.contains { abs($0 - start) < 0.03 } }

  /// カットの間の音の立ち上がりの最大(0〜1)。大きい音があるカットほど、映像の衝撃を重ねる価値が大きい。
  var strength: Double {
    guard hasHitInformation else { return 0 }
    let first = max(0, Int((start / analysis.onsetHop).rounded(.down)))
    let last = min(analysis.onsetEnvelope.count - 1, Int(((start + length) / analysis.onsetHop).rounded(.up)))
    guard first <= last else { return 0 }
    return min(1, analysis.onsetEnvelope[first...last].max() ?? 0)
  }

  /// 映像の標本間隔 `hop` 秒ごとの、音の立ち上がりの強さ(`count` 個)。前後に少しにじませる。
  func pulses(hop: Double, count: Int) -> [Double] {
    guard hasHitInformation, hop > 0, count > 0 else { return [Double](repeating: 0, count: max(0, count)) }
    var peaks = [Double](repeating: 0, count: count)
    for bucket in 0..<count {
      let from = start + Double(bucket) * hop
      let to = from + hop
      let first = max(0, Int((from / analysis.onsetHop).rounded(.down)))
      let last = min(analysis.onsetEnvelope.count - 1, Int(((to - 1e-9) / analysis.onsetHop).rounded(.down)))
      guard first <= last else { continue }
      peaks[bucket] = analysis.onsetEnvelope[first...last].max() ?? 0
    }
    return peaks.indices.map { index in
      let previous = index > 0 ? peaks[index - 1] : 0
      let next = index + 1 < peaks.count ? peaks[index + 1] : 0
      return 0.5 * peaks[index] + 0.25 * (previous + next)
    }
  }
}

// MARK: - 揺らぎ(同じ種なら同じ結果)

/// 素材選びの同点を崩すための、種から作る擬似乱数の列。
/// 候補の数だけ乱数を作ると重いので、一度だけ作った列を、カットごとに違う位置から読む。
nonisolated struct NoiseSource: Sendable {
  private let values: [Double]

  init(seed: UInt64) {
    var generator = SeededGenerator(seed: seed)
    values = (0..<8_192).map { _ in Double.random(in: 0..<1, using: &generator) }
  }

  /// `key` ごとに違う位置から読んだ、0〜1 の値 `count` 個。
  func slice(count: Int, key: UInt64) -> [Double] {
    guard count > 0 else { return [] }
    let start = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 40) % values.count
    if start + count <= values.count { return Array(values[start..<(start + count)]) }
    return (0..<count).map { values[(start + $0) % values.count] }
  }
}
