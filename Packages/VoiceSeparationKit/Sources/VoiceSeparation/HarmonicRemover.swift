import Foundation

/// 声の倍音の山だけを、周りの「谷」の高さまで削って、声以外の音（効果音など）を残す。
///
/// 倍音の位置を丸ごと 0 にすると、そこにあった雑音や衝撃音まで穴だらけになる。
/// そこで倍音と倍音の間（谷）の大きさから、山の位置に本来あったはずの大きさを直線でつないで見積もり、
/// 山がそれを超えている分だけを声として削る。声がなければ、谷の高さがそのまま残るので、
/// 声と同時に鳴っていた雑音や、倍音の間にある音は壊れにくい。
struct HarmonicRemover {
  let configuration: VoiceSeparationConfiguration
  let sampleRate: Double
  let fftSize: Int

  /// 声の高さの推定誤差と動きで、倍音の位置がずれる割合（周波数に対して）。山を探す範囲に使う。
  private static let relativeSmear = 0.012
  /// 周りの倍音の何倍までを、声の山として削るか。これを超える分は、別の音が重なっているとみなして残す。
  private static let outlierTolerance: Float = 2
  /// 突出の判定を始める周波数（Hz）。これより低い所には、声の第 1・第 2 フォルマントがあり、
  /// 倍音が隣の数倍も強いのがふつうなので、そのまま削る。
  private static let outlierMinimumFrequency = 1_500.0

  /// 声の強さを残す倍率を、時間枠×ビンで返す（1 = そのまま残す、0 = 全部削る）。
  /// - Parameters:
  ///   - magnitude: 解析に使う音（全チャンネルの平均）の振幅（`frames * bins`）。
  ///   - pitch: 枠ごとの声の高さと強さ。
  func gains(magnitude: [Float], frames: Int, bins: Int, pitch: PitchTrack) -> [Float] {
    var gains = [Float](repeating: 1, count: frames * bins)
    let binHz = sampleRate / Double(fftSize)
    let threshold = configuration.voicingThreshold
    magnitude.withUnsafeBufferPointer { mag in
      for frame in 0..<frames {
        let frequency = Double(pitch.frequencies[frame])
        guard frequency > 0 else { continue }
        // 山と谷が分けられるだけ、倍音の間隔が空いているときだけ処理する。
        let spacing = frequency / binHz
        guard spacing >= 4 else { continue }

        // 声らしさが弱い枠は、削る量を減らす（閾値で 0、閾値の `fullRemovalRatio` 倍で全開）。
        let ramp = max(threshold * (configuration.fullRemovalRatio - 1), 1e-6)
        let confidence = min(max((pitch.strengths[frame] - threshold) / ramp, 0), 1)
        let strength = confidence * configuration.removalStrength
        guard strength > 0 else { continue }

        removeHarmonics(
          mag: mag, base: frame * bins, bins: bins, spacing: spacing, strength: Float(strength),
          gains: &gains
        )
      }
    }
    return gains
  }

  /// 低い倍音（声の主なエネルギーがあり、山がはっきり分かれている）の実測位置から、倍音の間隔（ビン）を求め直す。
  /// 声の高さの推定は 0.7% 刻みなので、高い倍音（20 番目など）では位置が 1 ビン以上ずれる。
  /// 倍音は整数倍に並ぶので、低い倍音を使えば、高い倍音の位置もずっと正確に予測できる。
  private func refinedSpacing(mag: UnsafeBufferPointer<Float>, base: Int, bins: Int, spacing: Double) -> Double {
    var weightedPositions = 0.0
    var weights = 0.0
    var harmonic = 1
    while harmonic <= 8, Double(harmonic) * spacing < Double(bins - 3) {
      let nominal = Double(harmonic) * spacing
      let tolerance = min(max(1.5, 0.012 * nominal), 0.3 * spacing)
      let low = max(1, Int((nominal - tolerance).rounded(.up)))
      let high = min(bins - 2, Int((nominal + tolerance).rounded(.down)))
      defer { harmonic += 1 }
      guard high >= low else { continue }
      var peak = low
      for bin in low...high where mag[base + bin] > mag[base + peak] { peak = bin }
      // 範囲の端にある（その先も上がっていく）ものは、山ではないので使わない。
      guard peak > low, peak < high || mag[base + peak] >= mag[base + peak + 1] else { continue }
      let before = log(max(mag[base + peak - 1], 1e-12))
      let center = log(max(mag[base + peak], 1e-12))
      let after = log(max(mag[base + peak + 1], 1e-12))
      let curvature = before - 2 * center + after
      let offset = curvature < 0 ? Double(0.5 * (before - after) / curvature) : 0
      let position = Double(peak) + min(max(offset, -0.5), 0.5)
      let weight = Double(mag[base + peak])
      weightedPositions += weight * Double(harmonic) * position
      weights += weight * Double(harmonic) * Double(harmonic)
    }
    guard weights > 0 else { return spacing }
    let refined = weightedPositions / weights
    // 大きく外れたときは、誤った山を拾ったとみなして元の値を使う。
    return abs(refined - spacing) / spacing < 0.03 ? refined : spacing
  }

  private func removeHarmonics(
    mag: UnsafeBufferPointer<Float>,
    base: Int,
    bins: Int,
    spacing initialSpacing: Double,
    strength: Float,
    gains: inout [Float]
  ) {
    let spacing = refinedSpacing(mag: mag, base: base, bins: bins, spacing: initialSpacing)
    let binHz = sampleRate / Double(fftSize)
    let limitBin = min(configuration.maximumRemovedFrequency / binHz, Double(bins - 3))
    let count = Int(limitBin / spacing)
    guard count >= 1 else { return }

    // 3 ビンで均した振幅。谷の高さを、ビンごとのばらつきに左右されずに見るために使う。
    var smoothed = [Float](repeating: 0, count: bins)
    for bin in 1..<(bins - 1) {
      smoothed[bin] = 0.25 * mag[base + bin - 1] + 0.5 * mag[base + bin] + 0.25 * mag[base + bin + 1]
    }
    let reach = max(2, Int((0.5 * spacing).rounded(.down)))
    let bias = configuration.valleyBias

    /// 倍音ひとつぶんの、山と谷の位置。
    struct Harmonic {
      var peak: Int
      var left: Int
      var right: Int
      var leftLevel: Float
      var rightLevel: Float
      /// 山の高さのうち、谷の線を超えている分（声の強さの目安）。
      var excess: Float
      /// 削る割合（1 = 山ぜんぶ、小さいほど、周りの倍音より突出した分を残す）。
      var share: Float = 1

      func floorLevel(at bin: Int, bias: Float) -> Float {
        (leftLevel + (rightLevel - leftLevel) * Float(bin - left) / Float(right - left)) * bias
      }
    }

    var harmonics: [Harmonic] = []
    for harmonic in 1...count {
      // 山: 倍音の目安の位置の近くで、実際にいちばん大きいビン（声の高さが動くとずれるので、実測で探す）。
      let nominal = Double(harmonic) * spacing
      let tolerance = min(max(1.5, Self.relativeSmear * 0.5 * nominal), 0.3 * spacing)
      let searchLow = max(1, Int((nominal - tolerance).rounded(.up)))
      let searchHigh = min(bins - 2, Int((nominal + tolerance).rounded(.down)))
      guard searchHigh >= searchLow else { continue }
      var peak = searchLow
      for bin in searchLow...searchHigh where mag[base + bin] > mag[base + peak] { peak = bin }

      // 谷: 山の両側で、隣の倍音との中間までのうち、いちばん低い所。
      var left = peak
      var leftLevel = smoothed[peak]
      var bin = peak - 1
      while bin >= max(1, peak - reach) {
        if smoothed[bin] < leftLevel { leftLevel = smoothed[bin]; left = bin }
        bin -= 1
      }
      var right = peak
      var rightLevel = smoothed[peak]
      bin = peak + 1
      while bin <= min(bins - 2, peak + reach) {
        if smoothed[bin] < rightLevel { rightLevel = smoothed[bin]; right = bin }
        bin += 1
      }
      guard right > left else { continue }
      var entry = Harmonic(peak: peak, left: left, right: right, leftLevel: leftLevel, rightLevel: rightLevel, excess: 0)
      entry.excess = max(0, mag[base + peak] - entry.floorLevel(at: peak, bias: bias))
      harmonics.append(entry)
    }

    // 声の倍音の強さは、隣どうしでなめらかに変わる。周りの倍音より飛び抜けて強い山は、
    // 同じ位置で鳴っている別の音（電子音など）が足されているとみなし、声の分（周りの 2 倍まで）だけを削る。
    let firstOutlierBin = Self.outlierMinimumFrequency / binHz
    for index in harmonics.indices where harmonics[index].excess > 0 && Double(harmonics[index].peak) >= firstOutlierBin {
      let low = max(0, index - 2)
      let high = min(harmonics.count - 1, index + 2)
      guard high - low >= 3 else { continue }
      let neighbors = (low...high).filter { $0 != index }.map { harmonics[$0].excess }.sorted()
      let typical = neighbors[neighbors.count / 2]
      let allowed = Self.outlierTolerance * typical
      if harmonics[index].excess > allowed {
        harmonics[index].share = max(0, allowed / harmonics[index].excess)
      }
    }

    for entry in harmonics {
      // 谷から谷までを直線でつないだ高さを「声が無かったときの高さ」とみなし、山のまわりでそれを超える分だけを削る。
      // 山から外へ向かって、その高さを超えている間だけを削るので、倍音と倍音の間に独立してある音は残る。
      func attenuate(_ bin: Int) {
        let original = mag[base + bin]
        let level = entry.floorLevel(at: bin, bias: bias)
        guard original > level, original > 0 else { return }
        let kept = 1 - strength * entry.share * (1 - level / original)
        if kept < gains[base + bin] { gains[base + bin] = kept }
      }
      attenuate(entry.peak)
      var outward = entry.peak - 1
      while outward >= entry.left, smoothed[outward] > entry.floorLevel(at: outward, bias: bias) {
        attenuate(outward)
        outward -= 1
      }
      outward = entry.peak + 1
      while outward <= entry.right, smoothed[outward] > entry.floorLevel(at: outward, bias: bias) {
        attenuate(outward)
        outward += 1
      }
    }
  }
}
