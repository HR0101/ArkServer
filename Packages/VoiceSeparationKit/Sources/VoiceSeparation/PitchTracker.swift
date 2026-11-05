import Foundation

/// 時間枠ごとの声の高さ。`frequencies` が 0 の枠は、声が無い（または高さが分からない）。
struct PitchTrack {
  /// 基本周波数（Hz）。声が無い枠は 0。
  var frequencies: [Float]
  /// 選んだ高さでの「倍音の山と谷の差」（対数振幅、nat）。声が無い枠は 0。
  var strengths: [Float]
}

/// 倍音が等間隔に並んでいる所を探して、声の基本周波数を追う。
///
/// 各候補の周波数 f について「f の整数倍の位置の山」と「その中間の位置の山」の差を、倍音ごとに平均する。
/// 雑音や衝撃音は山と谷の差が出ないので 0 付近になり、声のように倍音が並ぶ音だけが大きくなる。
/// そのあと時間方向に最もつながりのよい高さの流れをビタビ法で選び、声の有無も同時に決める。
struct PitchTracker {
  let configuration: VoiceSeparationConfiguration
  let sampleRate: Double
  let fftSize: Int

  /// 1 オクターブを刻む候補の数。
  private static let stepsPerOctave = 48.0
  /// 1 枠で動ける候補の幅。声の高さは 1 枠（約 20ms）で数％までしか変わらない。
  private static let maximumJump = 6
  /// 声らしさを測るのに最低限使う倍音の数（少なすぎると、雑音の偶然の並びを声と誤る）。
  private static let minimumHarmonicCount = 6

  private struct Candidate {
    var frequency: Double
    /// 倍音ごとの (山の範囲, 中間の範囲, 重み)。範囲は FFT のビン番号。
    var harmonics: [(peakLow: Int, peakHigh: Int, valleyLow: Int, valleyHigh: Int, weight: Float)]
    var totalWeight: Float
  }

  private func makeCandidates(bins: Int) -> [Candidate] {
    let binHz = sampleRate / Double(fftSize)
    let octaves = log2(configuration.maximumPitch / configuration.minimumPitch)
    let count = Int(octaves * Self.stepsPerOctave) + 1
    var candidates: [Candidate] = []
    candidates.reserveCapacity(count)
    for index in 0..<count {
      let frequency = configuration.minimumPitch * pow(2, Double(index) / Self.stepsPerOctave)
      let spacing = frequency / binHz
      var harmonics: [(Int, Int, Int, Int, Float)] = []
      var weightSum: Float = 0
      var harmonic = 1
      while true {
        let peakCenter = Double(harmonic) * spacing
        let valleyCenter = (Double(harmonic) + 0.5) * spacing
        let limit = min(configuration.pitchSearchLimit / binHz, Double(bins - 2))
        if valleyCenter > limit { break }
        let tolerance = min(max(1.0, 0.012 * peakCenter), 0.3 * spacing)
        let weight = Float(1 / Double(harmonic).squareRoot())
        harmonics.append((
          Int((peakCenter - tolerance).rounded()), Int((peakCenter + tolerance).rounded()),
          Int((valleyCenter - tolerance).rounded()), Int((valleyCenter + tolerance).rounded()),
          weight
        ))
        weightSum += weight
        harmonic += 1
      }
      candidates.append(Candidate(frequency: frequency, harmonics: harmonics, totalWeight: weightSum))
    }
    return candidates
  }

  /// - Parameters:
  ///   - logMagnitude: 時間枠×ビンの対数振幅（`frames * bins`）。
  ///   - activity: 時間枠ごとの声の度合い（0...1）。nil なら全部を 1 とみなす。
  func track(logMagnitude: [Float], frames: Int, bins: Int, activity: [Float]?) -> PitchTrack {
    guard frames > 0 else { return PitchTrack(frequencies: [], strengths: []) }
    let candidates = makeCandidates(bins: bins)
    let count = candidates.count
    guard count > 0 else {
      return PitchTrack(frequencies: [Float](repeating: 0, count: frames), strengths: [Float](repeating: 0, count: frames))
    }

    // 低い周波数を選びやすくする偏り（最も低い候補を 0 として、オクターブごとに引く）。
    let tilt = candidates.map { configuration.lowPitchBias * Float(log2($0.frequency / configuration.minimumPitch)) }

    // 1. 枠ごと・候補ごとの、倍音の山と谷の差。
    var salience = [Float](repeating: 0, count: frames * count)
    logMagnitude.withUnsafeBufferPointer { log in
      for frame in 0..<frames {
        let base = frame * bins
        for (index, candidate) in candidates.enumerated() where candidate.totalWeight > 0 {
          // 低い倍音から順に「山と谷の差」を足していき、途中までの平均のうち最大のものを採る。
          // 声によっては、高い倍音がほとんど無い（エネルギーが最初の数本に集中している）。
          // 全部の平均を取ると、そういう声は高域の「何も無い倍音」に薄められてしまい、
          // 倍音の数が少ない、本来の数倍の高さの候補に負ける。
          var cumulative: Float = 0
          var weightSum: Float = 0
          var best = -Float.infinity
          let minimumCount = min(Self.minimumHarmonicCount, candidate.harmonics.count)
          for (position, harmonic) in candidate.harmonics.enumerated() {
            var peak = -Float.infinity
            var bin = max(0, harmonic.peakLow)
            let peakEnd = min(bins - 1, harmonic.peakHigh)
            while bin <= peakEnd { peak = max(peak, log[base + bin]); bin += 1 }
            var valley = -Float.infinity
            bin = max(0, harmonic.valleyLow)
            let valleyEnd = min(bins - 1, harmonic.valleyHigh)
            while bin <= valleyEnd { valley = max(valley, log[base + bin]); bin += 1 }
            if peak.isFinite && valley.isFinite { cumulative += harmonic.weight * (peak - valley) }
            weightSum += harmonic.weight
            if position + 1 >= minimumCount { best = max(best, cumulative / weightSum) }
          }
          salience[frame * count + index] = (best.isFinite ? best : 0) - tilt[index]
        }
      }
    }

    // 2. ビタビ法。状態は「各候補の高さ」と「声なし」。
    let unvoiced = count
    let states = count + 1
    let threshold = configuration.voicingThreshold
    let switchCost = threshold * 0.5
    let stepCost = configuration.pitchChangePenalty * 0.05
    var previous = [Float](repeating: 0, count: states)
    var current = [Float](repeating: 0, count: states)
    var back = [Int16](repeating: 0, count: frames * states)
    let negativeInfinity = -Float.greatestFiniteMagnitude

    for frame in 0..<frames {
      let act = activity?[frame] ?? 1
      // 声の度合いが低い所では、声と認めるのに強い証拠を求める（声なしの得点を上げる）。
      let unvoicedScore = threshold * (1 + configuration.activityInfluence * 2 * (1 - act))

      if frame == 0 {
        for index in 0..<count { current[index] = salience[index] }
        current[unvoiced] = unvoicedScore
        for index in 0..<states { back[index] = Int16(index) }
      } else {
        var bestVoiced = negativeInfinity
        var bestVoicedIndex = 0
        for index in 0..<count where previous[index] > bestVoiced {
          bestVoiced = previous[index]
          bestVoicedIndex = index
        }
        for index in 0..<count {
          // 同じ高さの近くから来る場合。
          var best = negativeInfinity
          var from = index
          let low = max(0, index - Self.maximumJump)
          let high = min(count - 1, index + Self.maximumJump)
          for other in low...high {
            let score = previous[other] - stepCost * Float(abs(other - index))
            if score > best { best = score; from = other }
          }
          // 声なしから来る場合。
          let fromUnvoiced = previous[unvoiced] - switchCost
          if fromUnvoiced > best { best = fromUnvoiced; from = unvoiced }
          current[index] = best + salience[frame * count + index]
          back[frame * states + index] = Int16(from)
        }
        // 声なしの状態へ。
        var best = previous[unvoiced]
        var from = unvoiced
        if bestVoiced - switchCost > best { best = bestVoiced - switchCost; from = bestVoicedIndex }
        current[unvoiced] = best + unvoicedScore
        back[frame * states + unvoiced] = Int16(from)
      }
      swap(&previous, &current)
    }

    // 3. 最後から辿って、高さの流れを取り出す。
    var state = 0
    var bestScore = negativeInfinity
    for index in 0..<states where previous[index] > bestScore {
      bestScore = previous[index]
      state = index
    }
    var frequencies = [Float](repeating: 0, count: frames)
    var strengths = [Float](repeating: 0, count: frames)
    for frame in stride(from: frames - 1, through: 0, by: -1) {
      if state != unvoiced {
        frequencies[frame] = Float(candidates[state].frequency)
        strengths[frame] = salience[frame * count + state]
      }
      state = Int(back[frame * states + state])
    }
    return PitchTrack(frequencies: frequencies, strengths: strengths)
  }
}
