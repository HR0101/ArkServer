import Foundation

/// 声を取り除いた残りを、音楽と効果音に分ける。
///
/// 音楽は、一定の時間のあいだ同じような強さで鳴り続ける（和音・伴奏・環境の連続音）。
/// 効果音は、短く突発的に鳴る（衝撃・動作の音）。そこで、周波数の帯ごとに、前後 `musicStationarySeconds` 秒の
/// 強さの中央値を「鳴り続けている分」とみなし、全体のうちその分を音楽、はみ出した分を効果音とする。
/// ただし、音楽が鳴っているとは限らないので、外から与える「音楽の度合い」が低い区間は、すべて効果音にする。
///
/// これは、音楽と効果音を**スペクトルで見分けている**のではなく、「鳴り続けるか、突発的か」で分けているだけ。
/// 長く鳴り続ける効果音は音楽に、音楽のドラムのような短い音は効果音に入ることがある。
struct MusicEffectsSplitter {
  let configuration: VoiceSeparationConfiguration

  /// 帯に束ねるビンの数。ビンごとの細かいばらつきに、中央値が左右されないようにする。
  private static let bandWidth = 4

  func split(
    _ background: AudioSignal, musicActivity: VoiceActivity, effectsActivity: VoiceActivity? = nil
  ) -> (music: AudioSignal, effects: AudioSignal) {
    let frameCount = background.frameCount
    let empty = AudioSignal(sampleRate: background.sampleRate, channels: background.channels.map { _ in [Float](repeating: 0, count: frameCount) })
    guard frameCount > 0, background.sampleRate > 0, !musicActivity.values.isEmpty else { return (empty, background) }

    let stft = STFT(fftSize: configuration.fftSize, hop: configuration.hopSize)
    let frames = stft.frameCount(forLength: frameCount)
    let bins = stft.bins
    let decision = stft.analyze(background.monoMix())
    let magnitude = decision.magnitudes()

    // 1. 周波数の帯ごとの強さ。
    let width = Self.bandWidth
    let bands = (bins + width - 1) / width
    var level = [Float](repeating: 0, count: frames * bands)
    for frame in 0..<frames {
      for band in 0..<bands {
        let first = band * width
        let last = min(bins, first + width)
        var sum: Float = 0
        for bin in first..<last { sum += magnitude[frame * bins + bin] }
        level[frame * bands + band] = sum / Float(last - first)
      }
    }

    // 2. 帯ごとに、前後の中央値（鳴り続けている分）を求め、全体に占める割合を出す。
    let halfWindow = max(2, Int((configuration.musicStationarySeconds * background.sampleRate / Double(configuration.hopSize)).rounded()))
    var share = [Float](repeating: 0, count: frames * bands)
    var window: [Float] = []
    window.reserveCapacity(halfWindow + 1)
    for band in 0..<bands {
      for frame in 0..<frames {
        window.removeAll(keepingCapacity: true)
        var other = max(0, frame - halfWindow)
        let end = min(frames - 1, frame + halfWindow)
        while other <= end {
          window.append(level[other * bands + band])
          other += 2
        }
        window.sort()
        let stationary = window[window.count / 2]
        let current = level[frame * bands + band]
        share[frame * bands + band] = current > 1e-9 ? min(1, stationary / current) : 0
      }
    }

    // 3. 音楽の度合いで、区間ごとに音楽を認めるかを決める（低ければ、すべて効果音）。
    let low = configuration.musicGateLow
    let high = max(configuration.musicGateHigh, low + 1e-3)
    let gate: [Float] = (0..<frames).map { frame in
      let time = stft.centerTime(ofFrame: frame, sampleRate: background.sampleRate)
      let activity = musicActivity.value(at: time) ?? 0
      let x = min(max((activity - low) / (high - low), 0), 1)
      return x * x * (3 - 2 * x)
    }

    // 効果音の度合いが分かるときは、効果音が起きている区間の突発的な成分だけを効果音とし、それ以外は音楽とする
    // （効果音が起きていない所で、音楽のドラムなどを効果音と誤らない）。分からないときは、鳴り続けている成分だけを音楽とする。
    //   音楽の割合 = 音楽の区間の度合い ×（1 − 突発成分の割合 × 効果音の区間の度合い）
    var gains = [Float](repeating: 0, count: frames * bins)
    if let effectsActivity, !effectsActivity.values.isEmpty {
      let effectsLow = configuration.effectsGateLow
      let effectsHigh = max(configuration.effectsGateHigh, effectsLow + 1e-3)
      for frame in 0..<frames where gate[frame] > 0 {
        let time = stft.centerTime(ofFrame: frame, sampleRate: background.sampleRate)
        let x = min(max(((effectsActivity.value(at: time) ?? 0) - effectsLow) / (effectsHigh - effectsLow), 0), 1)
        let effectsGate = x * x * (3 - 2 * x)
        for bin in 0..<bins {
          let transient = 1 - share[frame * bands + bin / width]
          gains[frame * bins + bin] = gate[frame] * (1 - transient * effectsGate)
        }
      }
    } else {
      for frame in 0..<frames where gate[frame] > 0 {
        for bin in 0..<bins {
          gains[frame * bins + bin] = share[frame * bands + bin / width] * gate[frame]
        }
      }
    }

    // 4. 全チャンネルに同じ割合を当てる。音楽 + 効果音 = 入力。
    var musicChannels: [[Float]] = []
    var effectsChannels: [[Float]] = []
    for samples in background.channels {
      var spectrogram = background.channels.count == 1 ? decision : stft.analyze(samples)
      for position in 0..<spectrogram.real.count {
        spectrogram.real[position] *= gains[position]
        spectrogram.imag[position] *= gains[position]
      }
      let music = stft.synthesize(spectrogram, length: frameCount)
      musicChannels.append(music)
      var effects = [Float](repeating: 0, count: frameCount)
      for position in 0..<frameCount { effects[position] = samples[position] - music[position] }
      effectsChannels.append(effects)
    }
    return (
      AudioSignal(sampleRate: background.sampleRate, channels: musicChannels),
      AudioSignal(sampleRate: background.sampleRate, channels: effectsChannels)
    )
  }
}
