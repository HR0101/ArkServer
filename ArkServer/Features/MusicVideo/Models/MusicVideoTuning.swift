// ArkServer/Features/MusicVideo/Models/MusicVideoTuning.swift

import Foundation

// ミュージックビデオの調整項目。
// 「カット割り」に効くもの(MusicVideoCutTuning)と、「見た目と音」に効くもの(MusicVideoLookTuning)に分ける。
// どの項目も既定値は、この項目を足す前の動作と同じにしてある。

/// 曲の盛り上がりに、映像の動きの大きさをどのくらい合わせるか。
nonisolated enum MotionMatching: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case weak
  case standard
  case strong

  var displayName: String {
    switch self {
    case .off: return "合わせない"
    case .weak: return "弱い"
    case .standard: return "標準"
    case .strong: return "強い"
    }
  }

  /// 動きの差(0〜1)に掛ける重み。大きいほど、狙った動きに近い素材を選ぶ。
  var weight: Double {
    switch self {
    case .off: return 0
    case .weak: return 1
    case .standard: return 2
    case .strong: return 4
    }
  }

  var summary: String {
    switch self {
    case .off: return "動きの大きさは見ず、素材をばらけさせて選びます．"
    case .weak: return "動きの大きさを少しだけ考えて選びます．"
    case .standard: return "盛り上がる所では動きの大きい映像、静かな所では動きの少ない映像を選びます．"
    case .strong: return "動きの大きさを最優先で合わせます．素材が偏ることがあります．"
    }
  }
}

/// 曲の拍(強い拍・小節の頭・曲の変わり目)に、映像の大きな動き(動作の始まり・衝撃)を重ねる強さ。
nonisolated enum HitSync: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case standard
  case strong

  var displayName: String {
    switch self {
    case .off: return "合わせない"
    case .standard: return "標準"
    case .strong: return "強い"
    }
  }

  /// 拍と衝撃の一致を、採点でどれだけ重くみるか。
  var weight: Double {
    switch self {
    case .off: return 0
    case .standard: return 1.5
    case .strong: return 3
    }
  }

  var summary: String {
    switch self {
    case .off: return "拍の位置は気にせず、動きの強さだけで素材を選びます．"
    case .standard: return "曲の強い拍に、映像の大きな動き（動き出し・衝撃）が重なる素材を、優先して選びます．"
    case .strong: return "曲の強い拍・小節の頭・曲の変わり目に、映像の大きな動きを重ねることを最優先にします．素材が偏ることがあります．"
    }
  }
}

/// 同じ動画を、どれだけ避けるか(どれだけいろいろな動画を使うか)。
nonisolated enum VideoVariety: String, Codable, CaseIterable, Hashable, Sendable {
  case wide
  case standard
  case repeating

  var displayName: String {
    switch self {
    case .wide: return "いろいろ"
    case .standard: return "標準"
    case .repeating: return "多めに使い回す"
    }
  }

  /// 直前のカットと同じ動画を選んだときの減点。
  var avoidLastPenalty: Double {
    switch self {
    case .wide: return 2.0
    case .standard: return 1.0
    case .repeating: return 0.2
    }
  }

  /// すでに使った回数 1 回ごとの減点。大きいほど、まだ使っていない動画を選ぶ。
  var usagePenalty: Double {
    switch self {
    case .wide: return 0.3
    case .standard: return 0.05
    case .repeating: return 0
    }
  }

  /// すでに使った区間と重なる位置を選んだときの減点。
  var overlapPenalty: Double {
    switch self {
    case .wide: return 1.5
    case .standard: return 0.8
    case .repeating: return 0.4
    }
  }

  var summary: String {
    switch self {
    case .wide: return "できるだけ違う動画を使います．使う動画の本数が増えます．"
    case .standard: return "同じ動画が続かない程度に、自然にばらけさせます．"
    case .repeating: return "動きが合う動画を、何度でも使います．使う動画の本数が減ります．"
    }
  }
}

/// 切り替えの位置を、どう決めるか。
nonisolated enum CutAlignment: String, Codable, CaseIterable, Hashable, Sendable {
  /// 2拍以上のカットは、区切りのよい拍(小節の頭)に境界をそろえる。
  case bar
  /// 設定した拍数ぴったりで切る。
  case free

  var displayName: String {
    switch self {
    case .bar: return "区切りにそろえる"
    case .free: return "拍の数どおり"
    }
  }

  var summary: String {
    switch self {
    case .bar: return "盛り上がりが変わる所で、切り替えを区切りのよい拍に寄せます．リズムが整います．"
    case .free: return "決めた拍の数ぴったりで切ります．変わり目で、区切りとずれることがあります．"
    }
  }
}

/// カット割りに効く調整項目。変えると、素材の解析はそのままで、カット割りだけを作り直せる。
nonisolated struct MusicVideoCutTuning: Codable, Equatable, Sendable {
  /// これより短いカットは作らない(秒)。
  var minimumCutDuration: Double = 0.3
  /// これより長いカットは作らない(秒)。nil なら制限しない。
  var maximumCutDuration: Double?
  var motionMatching: MotionMatching = .standard
  /// 曲の拍に、映像の大きな動きを重ねる強さ。
  var hitSync: HitSync = .strong
  var variety: VideoVariety = .standard
  var alignment: CutAlignment = .bar

  static let minimumChoices: [Double] = [0.3, 0.5, 0.8, 1.0, 1.5, 2.0]
  static let maximumChoices: [Double] = [1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0]

  /// 最短を変える。最長より長くなるときは、最長も合わせて延ばす。
  mutating func setMinimum(_ value: Double) {
    minimumCutDuration = value
    if let maximum = maximumCutDuration, maximum < value { maximumCutDuration = value }
  }

  /// 最長を変える。最短より短くなるときは、最短も合わせて縮める。
  mutating func setMaximum(_ value: Double?) {
    maximumCutDuration = value
    if let value, value < minimumCutDuration { minimumCutDuration = value }
  }
}

extension MusicVideoCutTuning {
  private enum CodingKeys: String, CodingKey {
    case minimumCutDuration, maximumCutDuration, motionMatching, hitSync, variety, alignment
  }

  /// 項目が足りない古い保存データでも、読めた分は使い、残りは既定値にする。
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = MusicVideoCutTuning()
    minimumCutDuration = try container.decodeIfPresent(Double.self, forKey: .minimumCutDuration) ?? defaults.minimumCutDuration
    maximumCutDuration = try container.decodeIfPresent(Double.self, forKey: .maximumCutDuration)
    motionMatching = try container.decodeIfPresent(MotionMatching.self, forKey: .motionMatching) ?? defaults.motionMatching
    hitSync = try container.decodeIfPresent(HitSync.self, forKey: .hitSync) ?? defaults.hitSync
    variety = try container.decodeIfPresent(VideoVariety.self, forKey: .variety) ?? defaults.variety
    alignment = try container.decodeIfPresent(CutAlignment.self, forKey: .alignment) ?? defaults.alignment
  }
}

/// 画面に素材をどう収めるか。
nonisolated enum MusicVideoFitMode: String, Codable, CaseIterable, Hashable, Sendable {
  /// 画面いっぱいに敷き詰める(はみ出す部分は切り落とす)。
  case fill
  /// 素材の全体を見せる(余った所は黒帯)。
  case fit

  var displayName: String {
    switch self {
    case .fill: return "画面いっぱい"
    case .fit: return "全体を見せる"
    }
  }

  var summary: String {
    switch self {
    case .fill: return "素材を拡大して画面を埋めます．はみ出す部分は切り取られます．"
    case .fit: return "素材の全体を見せます．縦横比が違う素材には黒い帯が出ます．"
    }
  }
}

/// カットの切り替え方。
nonisolated enum MusicVideoTransition: String, Codable, CaseIterable, Hashable, Sendable {
  case cut
  case crossfade
  case flash

  var displayName: String {
    switch self {
    case .cut: return "そのまま"
    case .crossfade: return "クロスフェード"
    case .flash: return "フラッシュ"
    }
  }

  /// 切り替えにかける時間(秒)。そのままは 0。
  var duration: Double {
    switch self {
    case .cut: return 0
    case .crossfade: return 0.3
    case .flash: return 0.12
    }
  }

  var summary: String {
    switch self {
    case .cut: return "拍の位置で、ぱっと切り替えます．"
    case .crossfade: return "拍の位置を中心に、前後の映像を\(Self.secondsText(0.3))秒かけて重ねます．"
    case .flash: return "拍の位置で、画面を白く光らせてから切り替えます．"
    }
  }

  private static func secondsText(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}

/// 見た目と音に効く調整項目。カット割りは変わらず、合成だけをやり直す。
nonisolated struct MusicVideoLookTuning: Codable, Equatable, Sendable {
  var fitMode: MusicVideoFitMode = .fill
  var transition: MusicVideoTransition = .cut
  /// 映像と音の、最初と最後のフェード(秒)。0 ならフェードしない。
  var fadeSeconds: Double = 0

  static let fadeChoices: [Double] = [0, 0.5, 1, 2]
}

/// 曲のうち、映像にする範囲(秒)。
nonisolated struct MusicRange: Equatable, Sendable {
  var start: Double
  var end: Double

  var length: Double { end - start }

  /// これより短い範囲は選べない。
  static let minimumLength = 5.0

  /// 曲の長さに収めた範囲。短すぎるときは、最短の長さまで広げる。全体と同じなら nil。
  static func clamped(start: Double, end: Double, songDuration: Double) -> MusicRange? {
    guard songDuration > minimumLength else { return nil }
    var lower = min(max(0, start), songDuration - minimumLength)
    var upper = min(max(end, lower + minimumLength), songDuration)
    lower = min(lower, upper - minimumLength)
    upper = max(upper, lower + minimumLength)
    if lower <= 0.001, upper >= songDuration - 0.001 { return nil }
    return MusicRange(start: lower, end: upper)
  }
}

/// 解析に使う素材動画の本数の選択肢。選んだ動画がこれより多いときは、無作為にこの本数へ絞る。
/// 多いほど変化に富むが、初回の解析に時間がかかる(解析した結果は保存され、次回から速い)。
nonisolated enum MusicVideoSourceLimit {
  static let choices = [10, 20, 40, 80, 120, 200]
  static let standard = 40

  /// 選択肢にない値(古い保存データなど)は、最も近い選択肢に直す。
  static func normalized(_ value: Int) -> Int {
    choices.min { abs($0 - value) < abs($1 - value) } ?? standard
  }
}

/// カット割りを作ったときの設定。取り消し・やり直しで、カット割りと一緒に元へ戻す。
nonisolated struct MusicVideoPlanSettings: Equatable, Sendable {
  var cutStyle: MusicVideoCutStyle
  var cutTuning: MusicVideoCutTuning
  var musicRange: MusicRange?
}

extension MusicAnalysis {
  /// 曲の `range` の部分だけを取り出した解析結果。時刻は範囲の先頭が 0 秒になるようにずらす。
  func trimmed(to range: MusicRange) -> MusicAnalysis {
    let start = min(max(0, range.start), duration)
    let end = min(max(start, range.end), duration)
    let length = end - start
    guard length > 0 else { return self }

    // 拍: 範囲に入るものだけを、0 秒を先頭にずらして残す。強さ・小節の頭も、残した拍に合わせる。
    let keptIndices = beats.indices.filter { beats[$0] >= start && beats[$0] < end }
    let newBeats = keptIndices.map { beats[$0] - start }
    let firstKept = keptIndices.first ?? 0
    var result = MusicAnalysis(duration: length, tempo: tempo, beats: newBeats, energy: energy, intensity: intensity, energyHop: energyHop)
    result.beatsPerBar = beatsPerBar
    if beatAccents.count == beats.count {
      result.beatAccents = keptIndices.map { beatAccents[$0] }
    }
    if let downbeatPhase, beatsPerBar > 0 {
      result.downbeatPhase = ((downbeatPhase - firstKept) % beatsPerBar + beatsPerBar) % beatsPerBar
    }
    result.sectionBoundaries = sectionBoundaries.filter { $0 > start && $0 < end }.map { $0 - start }

    // onset の細かい強さ: 範囲の先頭の位置から切り出す。
    if !onsetEnvelope.isEmpty, onsetHop > 0 {
      let first = Int((start / onsetHop).rounded(.down))
      let count = Int((length / onsetHop).rounded(.up))
      result.onsetHop = onsetHop
      result.onsetEnvelope = (0..<count).map { offset in
        onsetEnvelope.indices.contains(first + offset) ? onsetEnvelope[first + offset] : 0
      }
    }

    // 盛り上がり: 範囲に合わせて切り出す。
    guard energyHop > 0, !energy.isEmpty else { return result }
    let count = max(1, Int((length / energyHop).rounded(.up)))
    var newEnergy: [Double] = []
    var newIntensity: [MusicIntensity] = []
    newEnergy.reserveCapacity(count)
    newIntensity.reserveCapacity(count)
    for index in 0..<count {
      let sourceTime = start + Double(index) * energyHop
      newEnergy.append(energy(at: sourceTime))
      newIntensity.append(intensity(at: sourceTime))
    }
    result.energy = newEnergy
    result.intensity = newIntensity
    return result
  }

  /// `time` に最も近い拍の時刻。拍が無ければ `time` のまま。範囲の開始を拍に合わせるときに使う。
  func nearestBeat(to time: Double) -> Double {
    beats.min { abs($0 - time) < abs($1 - time) } ?? time
  }
}
