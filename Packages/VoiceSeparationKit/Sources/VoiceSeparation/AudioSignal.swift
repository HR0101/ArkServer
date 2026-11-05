import Foundation

/// 複数チャンネルの音声。サンプルは 32bit 浮動小数点（ふつう -1...1）で、チャンネルごとに配列を持つ。
public struct AudioSignal: Equatable, Sendable {
  public var sampleRate: Double
  public var channels: [[Float]]

  /// チャンネルの長さが違うときは、いちばん短いものに合わせて切り詰める。
  public init(sampleRate: Double, channels: [[Float]]) {
    self.sampleRate = sampleRate
    let length = channels.map(\.count).min() ?? 0
    self.channels = channels.map { $0.count == length ? $0 : Array($0.prefix(length)) }
  }

  public var frameCount: Int { channels.first?.count ?? 0 }
  public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

  /// 全チャンネルの平均。解析（ピッチ・分離の判断）はこの音で行う。
  public func monoMix() -> [Float] {
    guard let first = channels.first else { return [] }
    guard channels.count > 1 else { return first }
    var mix = [Float](repeating: 0, count: first.count)
    for channel in channels {
      for index in 0..<mix.count { mix[index] += channel[index] }
    }
    let scale = 1 / Float(channels.count)
    for index in 0..<mix.count { mix[index] *= scale }
    return mix
  }
}

/// 時間ごとの「声がありそうな度合い」（0...1）。外から与えると、声がない所を壊さずに済む。
public struct VoiceActivity: Equatable, Sendable {
  /// `values[0]` の時刻（秒）。
  public var startTime: Double
  /// 値と値の間隔（秒）。
  public var interval: Double
  public var values: [Float]

  public init(startTime: Double = 0, interval: Double, values: [Float]) {
    self.startTime = startTime
    self.interval = max(interval, .leastNonzeroMagnitude)
    self.values = values
  }

  /// `time`（秒）の値。値と値の間は直線でつなぎ、範囲の外は端の値のままにする。値が無ければ nil。
  public func value(at time: Double) -> Float? {
    guard !values.isEmpty else { return nil }
    let position = (time - startTime) / interval
    if position <= 0 { return values[0] }
    let last = values.count - 1
    if position >= Double(last) { return values[last] }
    let lower = Int(position)
    let fraction = Float(position - Double(lower))
    return values[lower] * (1 - fraction) + values[lower + 1] * fraction
  }
}
