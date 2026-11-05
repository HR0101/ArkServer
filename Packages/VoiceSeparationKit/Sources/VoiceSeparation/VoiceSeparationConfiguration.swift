import Foundation

/// 声の分離の調整項目。既定値は、話し声（男女・子どもを含む）を想定している。
public struct VoiceSeparationConfiguration: Equatable, Sendable {
  /// FFT の長さ（2 のべき乗）。長いほど、低い声の倍音を分けて見られるが、声の高さが動く所はにじむ。
  public var fftSize = 4096
  /// 時間枠の間隔（サンプル）。`fftSize` の半分以下にする。
  public var hopSize = 1024
  /// 声の基本周波数を探す範囲（Hz）。
  public var minimumPitch = 70.0
  public var maximumPitch = 450.0
  /// 声の高さを調べるときに見る周波数の上限（Hz）。
  public var pitchSearchLimit = 3500.0
  /// 声として取り除く周波数の上限（Hz）。これより上の倍音は残す。
  public var maximumRemovedFrequency = 5000.0
  /// 声とみなす「倍音の山と谷の差」の最小値（対数振幅、nat）。小さいほど声を拾いやすいが、効果音を声と誤る。
  public var voicingThreshold: Float = 0.45
  /// 低い周波数を選びやすくする偏り（1 オクターブ上がるごとに、声らしさから引く値、nat）。
  /// 基本周波数の整数倍の櫛も、同じくらい声らしく見えてしまう（本来の 3〜4 倍の高さを選ぶ誤り）ので、同点なら低いほうを採る。
  public var lowPitchBias: Float = 0.1
  /// 声の高さが急に変わることへの罰則の強さ。大きいほど高さの流れがなめらかになる。
  public var pitchChangePenalty: Float = 0.5
  /// 外から与えた「声の度合い」（`VoiceActivity`）を、どれだけ重く見るか。0 なら無視する。
  public var activityInfluence: Float = 1.0
  /// 声らしさが `voicingThreshold` の何倍以上なら、全力で削るか。閾値から、この倍率までの間は、声らしさに応じて削る量を増やす。
  public var fullRemovalRatio: Float = 2.0
  /// 倍音の谷の高さに掛ける倍率。1 より大きいと声が少し残るが、同時に鳴っている雑音を削りすぎない。
  public var valleyBias: Float = 1.0
  /// 声の区間（`VoiceActivity` が 0.5 以上）で、声の高さが見つからない枠（「s」「f」などの息の音・子音）の
  /// 高い周波数をどれだけ弱めるか（0...1）。これらは倍音を持たないので、分けられずに残る。
  /// 弱めると息の音は減るが、同じ区間・同じ周波数の効果音も一緒に弱まる。`VoiceActivity` を与えたときだけ働く。
  public var breathReduction: Float = 0.7
  /// 音楽と効果音を分けるとき、「音楽の度合い」（`VoiceActivity`）がこの値以下なら、音楽は無いとみなす。
  public var musicGateLow: Float = 0.4
  /// 「音楽の度合い」がこの値以上なら、鳴り続けている成分を、すべて音楽とみなす。`musicGateLow` との間は、なだらかにつなぐ。
  public var musicGateHigh: Float = 0.7
  /// 「効果音の度合い」がこの値以下なら、効果音は起きていないとみなす。
  public var effectsGateLow: Float = 0.3
  /// 「効果音の度合い」がこの値以上なら、その区間の突発的な成分を、すべて効果音とみなす。
  public var effectsGateHigh: Float = 0.6
  /// 「鳴り続けている音」を見分ける時間の長さ（秒）。前後この長さのあいだ、ほぼ同じ強さで鳴っている成分を音楽とする。
  public var musicStationarySeconds = 0.8
  /// 声を取り除く強さ（0...1）。1 で、見つけた声をできるだけ取り除く。
  public var removalStrength: Float = 1.0

  public init() {}
}
