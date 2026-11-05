import Foundation

/// 声の高さの流れ（診断や表示に使う）。
public struct PitchContour: Equatable, Sendable {
  /// 各時間枠の中心の時刻（秒）。
  public var times: [Double]
  /// 基本周波数（Hz）。声が無い枠は 0。
  public var frequencies: [Float]
  /// 声らしさ（倍音の山と谷の差、対数振幅 nat）。声が無い枠は 0。
  public var strengths: [Float]

  /// 声がある枠の割合（0...1）。
  public var voicedRatio: Double {
    guard !frequencies.isEmpty else { return 0 }
    return Double(frequencies.filter { $0 > 0 }.count) / Double(frequencies.count)
  }
}

/// 声の分離結果。`voice + background` は入力にほぼ一致する。
public struct SeparationResult: Sendable {
  /// 取り除いた声。
  public var voice: AudioSignal
  /// 声を取り除いた残り（効果音・環境音・音楽など）。
  public var background: AudioSignal
  public var pitch: PitchContour
}

/// 人の声と、それ以外の音を分ける。
///
/// 学習済みのモデルは使わず、声の倍音（基本周波数の整数倍に並ぶ山）を信号処理で見つけて削る。
/// 話し声のうち、声帯が震える母音や有声子音はよく分かれるが、息の音や「s」「f」のような無声子音は残りやすい。
/// 声と同じ周波数で鳴る楽器や警告音は、声と見分けられず一緒に削れることがある。
public struct VoiceSeparator: Sendable {
  public var configuration: VoiceSeparationConfiguration

  /// 息の音を弱める周波数の下限（Hz）。これより下には声の本体があり、倍音として別に扱う。
  private static let breathLowestFrequency = 1_500.0

  public init(configuration: VoiceSeparationConfiguration = VoiceSeparationConfiguration()) {
    self.configuration = configuration
  }

  /// - Parameters:
  ///   - signal: 分けたい音。ステレオなら、声の判断は左右の平均で行い、同じ削り方を左右に当てる。
  ///   - voiceActivity: 時間ごとの声の度合い（`VoiceActivity`）。与えると、声が無いと分かっている区間を壊さない。
  public func separate(_ signal: AudioSignal, voiceActivity: VoiceActivity? = nil) -> SeparationResult {
    let frameCount = signal.frameCount
    guard frameCount > 0, signal.sampleRate > 0 else {
      return SeparationResult(
        voice: AudioSignal(sampleRate: signal.sampleRate, channels: signal.channels.map { _ in [] }),
        background: signal,
        pitch: PitchContour(times: [], frequencies: [], strengths: [])
      )
    }

    let stft = STFT(fftSize: configuration.fftSize, hop: configuration.hopSize)
    let frames = stft.frameCount(forLength: frameCount)
    let bins = stft.bins

    // 声の判断は、全チャンネルの平均で行う（モノラルなら、その音そのもの）。
    let decisionSpectrogram = stft.analyze(signal.monoMix())
    let magnitude = decisionSpectrogram.magnitudes()

    let peak = magnitude.max() ?? 0
    let floorLevel = max(peak * 1e-4, 1e-9)
    let logMagnitude = magnitude.map { log($0 + floorLevel) }

    let times = (0..<frames).map { stft.centerTime(ofFrame: $0, sampleRate: signal.sampleRate) }
    let activity: [Float]? = voiceActivity.map { activity in
      times.map { min(max(activity.value(at: $0) ?? 1, 0), 1) }
    }

    let tracker = PitchTracker(configuration: configuration, sampleRate: signal.sampleRate, fftSize: configuration.fftSize)
    let pitch = tracker.track(logMagnitude: logMagnitude, frames: frames, bins: bins, activity: activity)
    var gains = HarmonicRemover(configuration: configuration, sampleRate: signal.sampleRate, fftSize: configuration.fftSize)
      .gains(magnitude: magnitude, frames: frames, bins: bins, pitch: pitch)

    // 声の度合いがほぼ 0 の枠は削らない（ピッチ追跡が誤って声と判断していても守る）。0.25 以上では何もしない。
    if let activity, configuration.activityInfluence > 0 {
      for frame in 0..<frames {
        let protection = configuration.activityInfluence * (1 - min(max(activity[frame] * 4, 0), 1))
        guard protection > 0 else { continue }
        for bin in 0..<bins {
          let index = frame * bins + bin
          gains[index] += (1 - gains[index]) * protection
        }
      }
    }

    // 声の高さが見つからない枠（息の音・子音）は、声の区間にあるときだけ、高い周波数を弱める。
    if let activity, configuration.breathReduction > 0 {
      let binHz = signal.sampleRate / Double(configuration.fftSize)
      let firstBin = min(bins - 1, Int(Self.breathLowestFrequency / binHz))
      for frame in 0..<frames where pitch.frequencies[frame] == 0 && activity[frame] >= 0.5 {
        let gain = 1 - configuration.breathReduction * activity[frame]
        for bin in firstBin..<bins { gains[frame * bins + bin] = min(gains[frame * bins + bin], gain) }
      }
    }

    var backgroundChannels: [[Float]] = []
    var voiceChannels: [[Float]] = []
    for samples in signal.channels {
      var spectrogram = signal.channels.count == 1 ? decisionSpectrogram : stft.analyze(samples)
      for position in 0..<spectrogram.real.count {
        spectrogram.real[position] *= gains[position]
        spectrogram.imag[position] *= gains[position]
      }
      let background = stft.synthesize(spectrogram, length: frameCount)
      backgroundChannels.append(background)
      var voice = [Float](repeating: 0, count: frameCount)
      for position in 0..<frameCount { voice[position] = samples[position] - background[position] }
      voiceChannels.append(voice)
    }

    return SeparationResult(
      voice: AudioSignal(sampleRate: signal.sampleRate, channels: voiceChannels),
      background: AudioSignal(sampleRate: signal.sampleRate, channels: backgroundChannels),
      pitch: PitchContour(times: times, frequencies: pitch.frequencies, strengths: pitch.strengths)
    )
  }
}
