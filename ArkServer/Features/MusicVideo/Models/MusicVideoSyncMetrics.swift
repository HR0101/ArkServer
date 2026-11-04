// ArkServer/Features/MusicVideo/Models/MusicVideoSyncMetrics.swift

import Foundation

/// 曲と映像の動きが、どれだけ合っているかを表す数値。
///
/// カット割り(`CutPlan`)の各カットを素材の時刻にたどり、「そのとき映像で何が起きているか」を曲の時刻に並べ直して測る。
/// 調整項目の効果を、体感ではなく数値で見られるようにするためと、合わせ込みの改良を測るために使う。
nonisolated struct MusicVideoSyncMetrics: Equatable, Sendable {
  /// 強い拍(拍の強さ 0.6 以上)の前後 0.09 秒に、映像の「急に動いた瞬間」がある度合い(0〜1の平均)。
  /// 1 に近いほど、曲の強い音と映像の大きな動きが同じ瞬間に起きている。調べられないときは nil。
  var hitAlignment: Double?
  /// 曲の盛り上がりと、映像の動きの強さの相関(-1〜1)。1 に近いほど、盛り上がる所で映像も激しく動く。調べられないときは nil。
  var energyCorrelation: Double?
  /// `hitAlignment` に使った強い拍の数。
  var strongBeatCount: Int

  /// 強い拍とみなす拍の強さ。
  static let strongAccent = 0.6
  /// 拍と衝撃が「同じ瞬間」とみなす時間のずれ(秒)。映像の標本間隔(約0.083秒)に合わせた値。
  static let hitTolerance = 0.09

  init(plan: CutPlan, analysis: MusicAnalysis, pool: [SourceMotionProfile]) {
    var windows: [UUID: [SourceMotionProfile]] = [:]
    for profile in pool { windows[profile.videoID, default: []].append(profile) }

    /// 時刻 `time`(曲の時刻=映像の時刻)に映されている素材の、(窓, 窓の中の位置の秒数)。
    func footage(at time: Double) -> (profile: SourceMotionProfile, seconds: Double)? {
      guard let cutIndex = plan.cutIndex(at: time) else { return nil }
      let cut = plan.cuts[cutIndex]
      let sourceTime = cut.sourceStart + (time - cut.timelineStart)
      guard let profile = windows[cut.videoID]?.first(where: {
        sourceTime >= $0.offset - 1e-6 && sourceTime <= $0.offset + $0.duration + 1e-6
      }) else { return nil }
      return (profile, sourceTime - profile.offset)
    }

    // 拍と衝撃の一致。
    var strongBeats = analysis.beats.indices.filter { analysis.accent(atBeat: $0) >= Self.strongAccent }
    if analysis.beatAccents.isEmpty { strongBeats = Array(analysis.beats.indices) }
    var alignments: [Double] = []
    for index in strongBeats {
      guard let (profile, seconds) = footage(at: analysis.beats[index]), !profile.impacts.isEmpty, profile.hop > 0 else { continue }
      let first = max(0, Int(((seconds - Self.hitTolerance) / profile.hop).rounded(.down)))
      let last = min(profile.impacts.count - 1, Int(((seconds + Self.hitTolerance) / profile.hop).rounded(.up)))
      guard first <= last else { continue }
      alignments.append(profile.impacts[first...last].max() ?? 0)
    }
    strongBeatCount = alignments.count
    hitAlignment = alignments.isEmpty ? nil : alignments.reduce(0, +) / Double(alignments.count)

    // 盛り上がりと動きの強さの相関(0.25 秒ごとに標本を取る)。
    var music: [Double] = []
    var video: [Double] = []
    var time = 0.0
    while time < plan.duration {
      if let (profile, seconds) = footage(at: time), profile.hop > 0, !profile.values.isEmpty {
        let index = min(profile.values.count - 1, max(0, Int(seconds / profile.hop)))
        music.append(analysis.energy(at: time))
        video.append(profile.values[index])
      }
      time += 0.25
    }
    energyCorrelation = Self.pearson(music, video)
  }

  /// ピアソンの相関係数。標本が少ない・どちらかが一定のときは nil。
  static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, x.count >= 8 else { return nil }
    let n = Double(x.count)
    let meanX = x.reduce(0, +) / n
    let meanY = y.reduce(0, +) / n
    var covariance = 0.0
    var varianceX = 0.0
    var varianceY = 0.0
    for (a, b) in zip(x, y) {
      covariance += (a - meanX) * (b - meanY)
      varianceX += (a - meanX) * (a - meanX)
      varianceY += (b - meanY) * (b - meanY)
    }
    guard varianceX > 1e-12, varianceY > 1e-12 else { return nil }
    return covariance / (varianceX * varianceY).squareRoot()
  }
}
