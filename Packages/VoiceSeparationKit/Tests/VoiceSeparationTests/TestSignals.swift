import Foundation
@testable import VoiceSeparation

/// テスト用の決まった乱数（再現できるように、種から同じ列を出す）。
struct SeededNoise {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  /// -1...1 の一様乱数。
  mutating func next() -> Float {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Float(state >> 40) / Float(1 << 23) - 1
  }
}

enum TestSignals {
  static let sampleRate = 44_100.0

  /// 母音のような声: 基本周波数が `startPitch` から `endPitch` へ動き、ビブラートが乗り、
  /// 音節ごとに強弱がつく。倍音の強さには、二つの山（フォルマント）を付けてある。
  static func voice(
    duration: Double, startPitch: Double = 120, endPitch: Double = 180, amplitude: Float = 0.3, highestHarmonic: Double = 5_500
  ) -> [Float] {
    let count = Int(duration * sampleRate)
    var samples = [Float](repeating: 0, count: count)
    var phase = 0.0
    for index in 0..<count {
      let time = Double(index) / sampleRate
      let progress = time / duration
      let pitch = (startPitch + (endPitch - startPitch) * progress) * (1 + 0.01 * sin(2 * Double.pi * 5.5 * time))
      phase += 2 * Double.pi * pitch / sampleRate
      var value = 0.0
      var harmonic = 1
      while Double(harmonic) * pitch < highestHarmonic {
        let frequency = Double(harmonic) * pitch
        let formant = exp(-pow((frequency - 700) / 300, 2)) + 0.6 * exp(-pow((frequency - 1_800) / 500, 2)) + 0.05
        value += formant / Double(harmonic) * sin(Double(harmonic) * phase)
        harmonic += 1
      }
      // 0.45 秒鳴って 0.12 秒休む、を繰り返す（境目はなめらかに）。
      let position = time.truncatingRemainder(dividingBy: 0.57)
      let envelope = min(1, position / 0.02) * min(1, max(0, (0.45 - position) / 0.02 + 1))
      samples[index] = amplitude * Float(value * (position < 0.45 ? envelope : 0))
    }
    return samples
  }

  /// 鳴り続ける和音（音楽の伴奏のような、強さが変わらない音）。
  static func chord(duration: Double, frequencies: [Double], amplitude: Float = 0.1) -> [Float] {
    (0..<Int(duration * sampleRate)).map { index in
      let time = Double(index) / sampleRate
      return amplitude * Float(frequencies.reduce(0) { $0 + sin(2 * Double.pi * $1 * time) } / Double(frequencies.count))
    }
  }

  /// 決まった種の白色雑音。
  static func whiteNoise(duration: Double, amplitude: Float = 0.2, seed: UInt64 = 1) -> [Float] {
    var noise = SeededNoise(seed: seed)
    return (0..<Int(duration * sampleRate)).map { _ in noise.next() * amplitude }
  }

  /// `start` 秒から鳴る、急に立ち上がって減衰する雑音（爆発・衝撃のような効果音）。
  static func noiseBurst(total: Double, start: Double, length: Double, amplitude: Float = 0.3, seed: UInt64 = 7) -> [Float] {
    var noise = SeededNoise(seed: seed)
    var samples = [Float](repeating: 0, count: Int(total * sampleRate))
    let first = Int(start * sampleRate)
    for offset in 0..<Int(length * sampleRate) where first + offset < samples.count {
      let time = Double(offset) / sampleRate
      samples[first + offset] = amplitude * noise.next() * Float(exp(-time / (length / 4)))
    }
    return samples
  }

  /// 変化しない高い音（電子音）。声の倍音と重なる位置にも来ることがある。
  static func beep(total: Double, start: Double, length: Double, frequency: Double, amplitude: Float = 0.2) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(total * sampleRate))
    let first = Int(start * sampleRate)
    for offset in 0..<Int(length * sampleRate) where first + offset < samples.count {
      let time = Double(offset) / sampleRate
      let edge = Float(min(1, min(time, length - time) / 0.01))
      samples[first + offset] = amplitude * edge * Float(sin(2 * Double.pi * frequency * time))
    }
    return samples
  }

  static func add(_ signals: [Float]...) -> [Float] {
    let count = signals.map(\.count).max() ?? 0
    var result = [Float](repeating: 0, count: count)
    for signal in signals { for index in 0..<signal.count { result[index] += signal[index] } }
    return result
  }

  static func energy(_ samples: [Float], from start: Double = 0, to end: Double = .infinity, sampleRate: Double = TestSignals.sampleRate) -> Double {
    let low = max(0, Int(start * sampleRate))
    let high = min(samples.count, end.isFinite ? Int(end * sampleRate) : samples.count)
    guard high > low else { return 0 }
    var sum = 0.0
    for index in low..<high { sum += Double(samples[index]) * Double(samples[index]) }
    return sum
  }

  static func decibels(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-12)) }

  /// `signal` を `reference` に近づけたときの誤差（SDR、dB）。大きいほど `reference` に近い。
  static func sdr(_ signal: [Float], reference: [Float], from start: Double = 0, to end: Double = .infinity) -> Double {
    let difference = zip(signal, reference).map { $0 - $1 }
    return decibels(energy(reference, from: start, to: end) / energy(difference, from: start, to: end))
  }
}
