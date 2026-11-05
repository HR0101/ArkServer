import XCTest
@testable import VoiceSeparation

final class SoundComponentsTests: XCTestCase {
  private let rate = TestSignals.sampleRate
  private func mono(_ samples: [Float]) -> AudioSignal { AudioSignal(sampleRate: rate, channels: [samples]) }
  private func constant(_ value: Float, seconds: Double = 10) -> VoiceActivity {
    VoiceActivity(interval: 0.1, values: [Float](repeating: value, count: Int(seconds / 0.1) + 1))
  }

  /// 伴奏の和音 + 効果音（雑音の衝撃 2 回）。
  private func musicAndEffects(duration: Double) -> (music: [Float], effects: [Float]) {
    let music = TestSignals.chord(duration: duration, frequencies: [262, 330, 392, 523], amplitude: 0.15)
    let effects = TestSignals.add(
      TestSignals.noiseBurst(total: duration, start: 1.0, length: 0.4, amplitude: 0.5, seed: 31),
      TestSignals.noiseBurst(total: duration, start: 2.5, length: 0.3, amplitude: 0.5, seed: 32)
    )
    return (music, effects)
  }

  func testThreeComponentsAddUpToTheInput() {
    let (music, effects) = musicAndEffects(duration: 4)
    let input = TestSignals.add(TestSignals.voice(duration: 4), music, effects)
    let result = VoiceSeparator().separateComponents(mono(input), voiceActivity: constant(0.9, seconds: 4), musicActivity: constant(0.9, seconds: 4))
    for index in stride(from: 0, to: input.count, by: 7) {
      let total = result.voice.channels[0][index] + result.music.channels[0][index] + result.effects.channels[0][index]
      XCTAssertEqual(total, input[index], accuracy: 1e-4)
    }
  }

  func testWithoutMusicActivityEverythingExceptTheVoiceIsEffects() {
    let (music, effects) = musicAndEffects(duration: 3)
    let input = TestSignals.add(music, effects)
    // 和音は倍音が整数倍に並ぶので、声の度合いを与えないと声と誤られる。ここでは「声は無い」と教える。
    let result = VoiceSeparator().separateComponents(mono(input), voiceActivity: constant(0, seconds: 3))
    XCTAssertEqual(TestSignals.energy(result.music.channels[0]), 0, accuracy: 1e-9, "音楽の度合いが無ければ、音楽は無い")
    XCTAssertEqual(result.music.channels.count, 1)
    // 声が無い入力なので、効果音（声以外）は入力そのもの。
    XCTAssertGreaterThan(TestSignals.decibels(TestSignals.energy(result.effects.channels[0]) / TestSignals.energy(input)), -0.5)
  }

  func testSteadyAccompanimentGoesToMusicAndSuddenSoundsToEffects() {
    let duration = 4.0
    let (music, effects) = musicAndEffects(duration: duration)
    let input = TestSignals.add(music, effects)
    let result = VoiceSeparator().separateComponents(
      mono(input), voiceActivity: constant(0, seconds: duration), musicActivity: constant(1, seconds: duration)
    )

    // 鳴り続ける和音のエネルギーの大半は音楽へ、衝撃の区間のエネルギーの大半は効果音へ入る。
    let steady = TestSignals.energy(music, from: 3.2, to: 3.9)
    let steadyInMusic = TestSignals.energy(result.music.channels[0], from: 3.2, to: 3.9)
    XCTAssertGreaterThan(steadyInMusic / steady, 0.7, "和音は音楽に残る（\(steadyInMusic / steady)）")
    let burst = TestSignals.energy(effects, from: 1.0, to: 1.4)
    let burstInEffects = TestSignals.energy(result.effects.channels[0], from: 1.0, to: 1.4)
    XCTAssertGreaterThan(burstInEffects / burst, 0.5, "衝撃は効果音に入る（\(burstInEffects / burst)）")
    XCTAssertLessThan(TestSignals.energy(result.effects.channels[0], from: 3.2, to: 3.9) / steady, 0.3, "和音は効果音にほとんど入らない")
  }

  func testNoEffectEventMeansEverythingElseStaysInMusic() {
    // 効果音が起きていないと分かっている（効果音の度合いが 0）なら、声以外はすべて音楽に残す。
    let duration = 3.0
    let (music, effects) = musicAndEffects(duration: duration)
    let input = TestSignals.add(music, effects)
    let result = VoiceSeparator().separateComponents(
      mono(input), voiceActivity: constant(0, seconds: duration),
      musicActivity: constant(1, seconds: duration), effectsActivity: constant(0, seconds: duration)
    )
    XCTAssertLessThan(TestSignals.decibels(TestSignals.energy(result.effects.channels[0]) / TestSignals.energy(input)), -30)
  }

  func testMixedKeepsOnlyTheChosenComponents() {
    let (music, effects) = musicAndEffects(duration: 3)
    let input = TestSignals.add(TestSignals.voice(duration: 3), music, effects)
    let result = VoiceSeparator().separateComponents(mono(input), voiceActivity: constant(0.9, seconds: 3), musicActivity: constant(0.9, seconds: 3))

    let none = result.mixed(voice: false, music: false, effects: false)
    XCTAssertEqual(none.frameCount, input.count)
    XCTAssertEqual(TestSignals.energy(none.channels[0]), 0, accuracy: 1e-12)

    let voiceOnly = result.mixed(voice: true, music: false, effects: false)
    XCTAssertEqual(voiceOnly.channels[0], result.voice.channels[0])

    let all = result.mixed(voice: true, music: true, effects: true)
    for index in stride(from: 0, to: input.count, by: 11) { XCTAssertEqual(all.channels[0][index], input[index], accuracy: 1e-4) }

    // 声を除いた音 = 音楽 + 効果音。
    let withoutVoice = result.mixed(voice: false, music: true, effects: true)
    for index in stride(from: 0, to: input.count, by: 11) {
      XCTAssertEqual(withoutVoice.channels[0][index], result.music.channels[0][index] + result.effects.channels[0][index], accuracy: 1e-6)
    }
  }
}
