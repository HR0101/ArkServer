// ArkServer/Features/MusicVideo/Models/MusicPreviewPlan.swift

import Foundation

/// 曲を選ぶときの試聴で、どこを何秒聞くかを決める純粋ロジック。
nonisolated enum MusicPreviewPlan {
  /// 試聴の長さ（秒）。
  static let defaultLength = 15.0

  struct Excerpt: Equatable, Sendable {
    /// 曲の中の開始位置（秒）。
    var start: Double
    /// 聞く長さ（秒）。
    var length: Double
  }

  /// 曲をまだ解析していないとき。曲の3分の1あたりから聞く（冒頭の静かな導入部を避けるため）。
  /// 曲が短ければ頭から、曲の終わりを越えないように調整する。
  static func excerpt(forDuration duration: Double, length: Double = defaultLength) -> Excerpt {
    guard duration > 0, length > 0 else { return Excerpt(start: 0, length: 0) }
    let playable = min(length, duration)
    let start = min(duration / 3, duration - playable)
    return Excerpt(start: max(0, start), length: playable)
  }

  /// 曲を解析済みのとき。盛り上がりの平均が最も大きい区間を聞く（映像のカットが速くなる所を確かめられる）。
  /// - Parameters:
  ///   - energy: 盛り上がりの連続値。`energyHop` 秒ごと。
  static func excerpt(
    forDuration duration: Double,
    energy: [Double],
    energyHop: Double,
    length: Double = defaultLength
  ) -> Excerpt {
    let fallback = excerpt(forDuration: duration, length: length)
    guard fallback.length > 0, energyHop > 0, energy.count > 1 else { return fallback }

    let window = max(1, min(energy.count, Int((fallback.length / energyHop).rounded())))
    var prefix = [Double](repeating: 0, count: energy.count + 1)
    for (index, value) in energy.enumerated() { prefix[index + 1] = prefix[index] + value }

    var bestStart = 0
    var bestSum = -Double.infinity
    for start in 0...(energy.count - window) {
      let sum = prefix[start + window] - prefix[start]
      if sum > bestSum + 1e-9 {
        bestSum = sum
        bestStart = start
      }
    }
    let start = min(Double(bestStart) * energyHop, duration - fallback.length)
    return Excerpt(start: max(0, start), length: fallback.length)
  }
}
