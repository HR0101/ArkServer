import Foundation

/// 音を「声・音楽・効果音」の3つに分けた結果。`voice + music + effects` は入力にほぼ一致する。
public struct SoundComponents: Sendable {
  public var voice: AudioSignal
  public var music: AudioSignal
  public var effects: AudioSignal
  public var pitch: PitchContour

  /// 選んだ成分だけを足した音。何も選ばなければ、無音。
  public func mixed(voice includesVoice: Bool, music includesMusic: Bool, effects includesEffects: Bool) -> AudioSignal {
    var selected: [AudioSignal] = []
    if includesVoice { selected.append(voice) }
    if includesMusic { selected.append(music) }
    if includesEffects { selected.append(effects) }
    let frameCount = voice.frameCount
    var channels = voice.channels.map { _ in [Float](repeating: 0, count: frameCount) }
    for signal in selected {
      for (index, samples) in signal.channels.enumerated() where index < channels.count {
        for position in 0..<min(frameCount, samples.count) { channels[index][position] += samples[position] }
      }
    }
    return AudioSignal(sampleRate: voice.sampleRate, channels: channels)
  }
}

extension VoiceSeparator {
  /// 声・音楽・効果音の3つに分ける。
  ///
  /// 声は倍音を見つけて取り除く（`separate`）。残りは、鳴り続けている成分を音楽、突発的な成分を効果音とする。
  /// 音楽と効果音の区別は、声の分離よりずっとおおまか。くわしくは `MusicEffectsSplitter` を参照。
  /// - Parameters:
  ///   - voiceActivity: 時間ごとの声の度合い。
  ///   - musicActivity: 時間ごとの音楽の度合い。nil か空なら、音楽は無いとして、声以外をすべて効果音にする。
  ///   - effectsActivity: 時間ごとの効果音の度合い。あれば、効果音が起きている区間の突発的な成分だけを効果音にする。
  public func separateComponents(
    _ signal: AudioSignal,
    voiceActivity: VoiceActivity? = nil,
    musicActivity: VoiceActivity? = nil,
    effectsActivity: VoiceActivity? = nil
  ) -> SoundComponents {
    let result = separate(signal, voiceActivity: voiceActivity)
    guard let musicActivity else {
      let silent = AudioSignal(sampleRate: signal.sampleRate, channels: signal.channels.map { [Float](repeating: 0, count: $0.count) })
      return SoundComponents(voice: result.voice, music: silent, effects: result.background, pitch: result.pitch)
    }
    let split = MusicEffectsSplitter(configuration: configuration).split(
      result.background, musicActivity: musicActivity, effectsActivity: effectsActivity
    )
    return SoundComponents(voice: result.voice, music: split.music, effects: split.effects, pitch: result.pitch)
  }
}
