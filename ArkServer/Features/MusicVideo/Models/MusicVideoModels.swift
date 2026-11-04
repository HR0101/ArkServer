// ArkServer/Features/MusicVideo/Models/MusicVideoModels.swift

import Foundation

/// 曲の盛り上がりの段階。カットの長さと、選ぶ素材の動きの大きさを決める。
nonisolated enum MusicIntensity: Int, Codable, Comparable, CaseIterable, Sendable {
  case calm = 0
  case medium
  case intense

  static func < (lhs: MusicIntensity, rhs: MusicIntensity) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var displayName: String {
    switch self {
    case .calm: return "静か"
    case .medium: return "中"
    case .intense: return "盛り上がり"
    }
  }

  /// この段階で選びたい素材の動きの大きさ（0〜1）。
  var targetMotion: Double {
    switch self {
    case .calm: return 0.15
    case .medium: return 0.5
    case .intense: return 0.85
    }
  }
}

/// カット割りの細かさ。盛り上がりの段階ごとに「何拍で切り替えるか」を決める。
nonisolated enum MusicVideoCutStyle: String, Codable, CaseIterable, Sendable {
  case relaxed
  case standard
  case energetic

  var displayName: String {
    switch self {
    case .relaxed: return "控えめ"
    case .standard: return "標準"
    case .energetic: return "激しい"
    }
  }

  func beatsPerCut(for intensity: MusicIntensity) -> Int {
    switch (self, intensity) {
    case (.relaxed, .calm): return 8
    case (.relaxed, .medium): return 4
    case (.relaxed, .intense): return 2
    case (.standard, .calm): return 4
    case (.standard, .medium): return 2
    case (.standard, .intense): return 1
    case (.energetic, .calm): return 2
    case (.energetic, .medium): return 1
    case (.energetic, .intense): return 1
    }
  }
}

/// 完成映像の画面サイズの選択肢。
nonisolated enum MusicVideoRenderPreset: String, Codable, CaseIterable, Hashable, Sendable {
  case landscapeFullHD
  case landscapeHD
  case portraitFullHD
  case portraitHD

  var displayName: String {
    switch self {
    case .landscapeFullHD: return "横 1080p"
    case .landscapeHD: return "横 720p"
    case .portraitFullHD: return "縦 1080p"
    case .portraitHD: return "縦 720p"
    }
  }

  var settings: MusicVideoRenderSettings {
    switch self {
    case .landscapeFullHD: return .landscapeFullHD
    case .landscapeHD: return .landscapeHD
    case .portraitFullHD: return .portraitFullHD
    case .portraitHD: return .portraitHD
    }
  }

  var isPortrait: Bool {
    self == .portraitFullHD || self == .portraitHD
  }

  /// 同じ画質の横向き。基本は横にするので、縦の設定は保存せず、開き直したときにこれへ戻す。
  var landscapeEquivalent: MusicVideoRenderPreset {
    switch self {
    case .portraitFullHD: return .landscapeFullHD
    case .portraitHD: return .landscapeHD
    case .landscapeFullHD, .landscapeHD: return self
    }
  }
}

/// 書き出しの画質。画面サイズは変えず、映像のビットレート(1秒あたりのデータ量)で決める。
nonisolated enum MusicVideoExportQuality: String, Codable, CaseIterable, Hashable, Sendable {
  case high
  case standard
  case compact

  static let audioBitRate = 192_000
  static let audioSampleRate = 44_100.0

  var displayName: String {
    switch self {
    case .high: return "高画質"
    case .standard: return "標準"
    case .compact: return "小さめ"
    }
  }

  /// 1画素・1フレームあたりのビット数。H.264 で、カットが細かく動きの多い映像でも崩れにくい目安。
  private var bitsPerPixel: Double {
    switch self {
    case .high: return 0.16
    case .standard: return 0.08
    case .compact: return 0.04
    }
  }

  /// 画面サイズ・フレームレートに応じた映像のビットレート(bps)。
  func videoBitRate(for render: MusicVideoRenderSettings) -> Int {
    let raw = Double(render.width * render.height * render.framesPerSecond) * bitsPerPixel
    return max(300_000, Int(raw))
  }

  /// 1分あたりのファイルサイズの目安(MB)。音声を含む。
  func estimatedMegabytesPerMinute(for render: MusicVideoRenderSettings) -> Double {
    Double(videoBitRate(for: render) + Self.audioBitRate) * 60 / 8 / 1_000_000
  }
}

/// 曲の解析結果。拍の位置と、時間ごとの盛り上がりを持つ。
nonisolated struct MusicAnalysis: Codable, Equatable, Sendable {
  /// 曲全体の長さ（秒）。
  var duration: Double
  /// 推定したテンポ（BPM）。
  var tempo: Double
  /// 拍の時刻（秒、昇順）。
  var beats: [Double]
  /// 盛り上がりの連続値（0〜1）。`energyHop` 秒ごと。
  var energy: [Double]
  /// 盛り上がりの段階。`energy` と同じ間隔。
  var intensity: [MusicIntensity]
  /// `energy` / `intensity` の標本間隔（秒）。
  var energyHop: Double

  // 以下は、動きを曲に細かく合わせるための解析結果。解析していない(古いデータ・テスト用の簡易な解析)ときは、
  // 空か nil のままにして、使う側は「情報なし」として扱う。

  /// 拍ごとの強さ(0〜1)。`beats` と同じ並び。
  var beatAccents: [Double] = []
  /// 1小節の拍の数(3 か 4)。
  var beatsPerBar: Int = 4
  /// 小節の1拍目にあたる拍の、`beats` の添字を `beatsPerBar` で割った余り。分からなければ nil。
  var downbeatPhase: Int?
  /// 音の立ち上がり(onset)の細かい強さ(0〜1)。`onsetHop` 秒ごと。拍より細かい位置の合わせ込みに使う。
  var onsetEnvelope: [Double] = []
  /// `onsetEnvelope` の標本間隔（秒）。
  var onsetHop: Double = 0.05
  /// 曲の構造が変わる時刻(秒、昇順)。サビやドロップの頭。
  var sectionBoundaries: [Double] = []

  /// `index` 番目の拍の強さ。情報が無ければ中間の 0.5。
  func accent(atBeat index: Int) -> Double {
    beatAccents.indices.contains(index) ? beatAccents[index] : 0.5
  }

  /// `index` 番目の拍が、小節の1拍目か。小節の頭が分からないときは nil。
  func isDownbeat(beatIndex index: Int) -> Bool? {
    guard let downbeatPhase, beatsPerBar > 0 else { return nil }
    return ((index - downbeatPhase) % beatsPerBar + beatsPerBar) % beatsPerBar == 0
  }

  /// `time` 秒を含む区間の onset の強さ。情報が無ければ 0。
  func onset(at time: Double) -> Double {
    guard !onsetEnvelope.isEmpty, onsetHop > 0 else { return 0 }
    let index = Int((time / onsetHop).rounded(.down))
    return onsetEnvelope.indices.contains(index) ? onsetEnvelope[index] : 0
  }

  func energy(at time: Double) -> Double {
    guard !energy.isEmpty, energyHop > 0 else { return 0.5 }
    let index = min(max(0, Int(time / energyHop)), energy.count - 1)
    return energy[index]
  }

  func intensity(at time: Double) -> MusicIntensity {
    guard !intensity.isEmpty, energyHop > 0 else { return .medium }
    let index = min(max(0, Int(time / energyHop)), intensity.count - 1)
    return intensity[index]
  }
}

/// 素材動画の「ある区間」について、時間ごとの映像の動きの大きさ（0〜1）。
/// 長い動画は全体を調べず、離れた複数の区間（窓）だけを調べるので、1本の動画が複数の窓になりうる。
nonisolated struct SourceMotionProfile: Codable, Equatable, Sendable {
  let videoID: UUID
  /// この区間の動画内での開始位置（秒）。`values` の先頭がこの位置に当たる。
  let offset: Double
  /// この区間の長さ（秒）。カットはこの範囲の中から選ぶ。
  let duration: Double
  /// `values` の標本間隔（秒）。
  let hop: Double
  /// 動きの大きさ（0〜1）。
  let values: [Double]
  /// 「急に動いた瞬間」の強さ（0〜1）。`values` と同じ間隔。動きが急に増えた所(動作の始まり・衝撃・画面の切り替わり)が高い。
  /// 曲の大きな音(拍・アクセント)に、映像の大きな動きを重ねるために使う。調べていないときは空。
  let impacts: [Double]
  /// 区間の平均を O(1) で求めるための累積和。保存はせず、読み込み時に作り直す。
  let prefixSums: [Double]
  /// `impacts` の2乗の累積和。位置ごとの類似度の分母を O(1) で求めるために使う。保存はしない。
  let impactSquarePrefix: [Double]

  init(videoID: UUID, offset: Double = 0, duration: Double, hop: Double, values: [Double], impacts: [Double] = []) {
    self.videoID = videoID
    self.offset = offset
    self.duration = duration
    self.hop = hop
    self.values = values
    // 長さが合わない衝撃の列は、使わない(位置がずれるより、情報なしにする)。
    let aligned = impacts.count == values.count ? impacts : []
    self.impacts = aligned
    self.prefixSums = Self.makePrefixSums(values)
    self.impactSquarePrefix = Self.makePrefixSums(aligned.map { $0 * $0 })
  }

  private enum CodingKeys: String, CodingKey {
    case videoID, offset, duration, hop, values, impacts
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let videoID = try container.decode(UUID.self, forKey: .videoID)
    let offset = try container.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    let duration = try container.decode(Double.self, forKey: .duration)
    let hop = try container.decode(Double.self, forKey: .hop)
    let values = try container.decode([Double].self, forKey: .values)
    let impacts = try container.decodeIfPresent([Double].self, forKey: .impacts) ?? []
    self.init(videoID: videoID, offset: offset, duration: duration, hop: hop, values: values, impacts: impacts)
  }

  private static func makePrefixSums(_ values: [Double]) -> [Double] {
    var sums = [Double](repeating: 0, count: values.count + 1)
    for (index, value) in values.enumerated() {
      sums[index + 1] = sums[index] + value
    }
    return sums
  }

  /// この区間の中の `start`（区間の先頭からの秒数）から `length` 秒の、動きの平均。標本が無いときは中間値を返す。
  func meanMotion(start: Double, length: Double) -> Double {
    guard !values.isEmpty, hop > 0 else { return 0.5 }
    let first = min(max(0, Int(start / hop)), values.count - 1)
    let end = min(values.count, max(first + 1, Int(((start + length) / hop).rounded(.up))))
    return (prefixSums[end] - prefixSums[first]) / Double(end - first)
  }
}

/// 1カット分の計画。素材のどこを、タイムラインのどこに置くか。
nonisolated struct PlannedCut: Identifiable, Equatable, Sendable {
  let id = UUID()
  let videoID: UUID
  /// 素材動画の中の開始位置（秒）。
  let sourceStart: Double
  let duration: Double
  /// 完成映像の中での開始位置（秒）。
  let timelineStart: Double
  let intensity: MusicIntensity

  var timelineEnd: Double { timelineStart + duration }

  static func == (lhs: PlannedCut, rhs: PlannedCut) -> Bool {
    lhs.videoID == rhs.videoID
      && lhs.sourceStart == rhs.sourceStart
      && lhs.duration == rhs.duration
      && lhs.timelineStart == rhs.timelineStart
      && lhs.intensity == rhs.intensity
  }
}

/// 映像全体のカット割り。曲の長さに一致する。
nonisolated struct CutPlan: Equatable, Sendable {
  var cuts: [PlannedCut]
  var duration: Double

  /// `time` 秒の位置にあるカットの番号。範囲外なら最初/最後のカットに寄せる。カットが無ければ nil。
  func cutIndex(at time: Double) -> Int? {
    guard !cuts.isEmpty else { return nil }
    var low = 0
    var high = cuts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if cuts[middle].timelineStart <= time { low = middle } else { high = middle - 1 }
    }
    return low
  }
}

nonisolated enum CutPlannerError: LocalizedError, Equatable {
  case noBeats
  case emptyPool
  case noClipLongEnough

  var errorDescription: String? {
    switch self {
    case .noBeats:
      return "曲から拍を検出できませんでした．"
    case .emptyPool:
      return "使える素材動画がありません．"
    case .noClipLongEnough:
      return "素材動画が短すぎて，曲のカット長を満たせません．長めの動画を選んでください．"
    }
  }
}

/// 同じ種から同じ乱数列を作る擬似乱数（SplitMix64）。カット割りを再現可能にするために使う。
nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

extension MusicAnalysis {
  private enum CodingKeys: String, CodingKey {
    case duration, tempo, beats, energy, intensity, energyHop
    case beatAccents, beatsPerBar, downbeatPhase, onsetEnvelope, onsetHop, sectionBoundaries
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    duration = try container.decode(Double.self, forKey: .duration)
    tempo = try container.decode(Double.self, forKey: .tempo)
    beats = try container.decode([Double].self, forKey: .beats)
    energy = try container.decode([Double].self, forKey: .energy)
    intensity = try container.decode([MusicIntensity].self, forKey: .intensity)
    energyHop = try container.decode(Double.self, forKey: .energyHop)
    beatAccents = try container.decodeIfPresent([Double].self, forKey: .beatAccents) ?? []
    beatsPerBar = try container.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
    downbeatPhase = try container.decodeIfPresent(Int.self, forKey: .downbeatPhase)
    onsetEnvelope = try container.decodeIfPresent([Double].self, forKey: .onsetEnvelope) ?? []
    onsetHop = try container.decodeIfPresent(Double.self, forKey: .onsetHop) ?? 0.05
    sectionBoundaries = try container.decodeIfPresent([Double].self, forKey: .sectionBoundaries) ?? []
  }
}
