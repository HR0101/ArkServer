import XCTest
@testable import VoiceSeparation

final class FFTTests: XCTestCase {
  func testSinusoidAppearsInTheExpectedBin() {
    let size = 1024
    let plan = FFTPlan(size: size)
    var real = (0..<size).map { Float(cos(2 * Double.pi * 100 * Double($0) / Double(size))) }
    var imag = [Float](repeating: 0, count: size)
    plan.transform(real: &real, imag: &imag, inverse: false)
    let magnitudes = (0..<size / 2).map { (real[$0] * real[$0] + imag[$0] * imag[$0]).squareRoot() }
    XCTAssertEqual(magnitudes.firstIndex(of: magnitudes.max()!), 100)
    XCTAssertEqual(magnitudes[100], Float(size) / 2, accuracy: 0.01)
  }

  func testForwardThenInverseRestoresTheInput() {
    let size = 2048
    let plan = FFTPlan(size: size)
    let original = TestSignals.whiteNoise(duration: Double(size) / TestSignals.sampleRate, seed: 3)
    var real = original
    var imag = [Float](repeating: 0, count: size)
    plan.transform(real: &real, imag: &imag, inverse: false)
    plan.transform(real: &real, imag: &imag, inverse: true)
    for index in 0..<size { XCTAssertEqual(real[index], original[index], accuracy: 1e-5) }
  }
}

final class STFTTests: XCTestCase {
  func testAnalysisThenSynthesisRestoresTheSignalIncludingTheEdges() {
    // 長さが hop の倍数でなくても、先頭・末尾まで元に戻る。
    let stft = STFT(fftSize: 2048, hop: 512)
    let original = TestSignals.voice(duration: 0.97)
    let restored = stft.synthesize(stft.analyze(original), length: original.count)
    XCTAssertEqual(restored.count, original.count)
    var worst: Float = 0
    for index in 0..<original.count { worst = max(worst, abs(restored[index] - original[index])) }
    XCTAssertLessThan(worst, 1e-4)
  }
}

final class VoiceActivityTests: XCTestCase {
  func testValuesAreInterpolatedAndClampedAtTheEnds() {
    let activity = VoiceActivity(startTime: 1, interval: 0.5, values: [0, 1, 0.5])
    XCTAssertEqual(activity.value(at: 0), 0)       // 範囲の前は、最初の値
    XCTAssertEqual(activity.value(at: 1.25)!, 0.5, accuracy: 1e-6)
    XCTAssertEqual(activity.value(at: 1.5)!, 1, accuracy: 1e-6)
    XCTAssertEqual(activity.value(at: 9), 0.5)     // 範囲の後は、最後の値
    XCTAssertNil(VoiceActivity(interval: 0.1, values: []).value(at: 0))
  }
}

final class VoiceSeparatorTests: XCTestCase {
  private let rate = TestSignals.sampleRate

  private func mono(_ samples: [Float]) -> AudioSignal { AudioSignal(sampleRate: rate, channels: [samples]) }

  func testTracksTheMovingPitchOfASyntheticVoice() {
    let voice = TestSignals.voice(duration: 3, startPitch: 120, endPitch: 180)
    let result = VoiceSeparator().separate(mono(voice))
    // 声のある枠だけで、真の高さ（ビブラート込み）との差を見る。
    var errors: [Double] = []
    for (index, time) in result.pitch.times.enumerated() where result.pitch.frequencies[index] > 0 && time > 0.2 && time < 2.8 {
      let base = 120 + 60 * (time / 3)
      errors.append(abs(Double(result.pitch.frequencies[index]) - base) / base)
    }
    XCTAssertGreaterThan(errors.count, 40, "声のある枠が十分に見つかる")
    errors.sort()
    XCTAssertLessThan(errors[errors.count / 2], 0.03, "高さの中央値のずれは 3% 以内")
  }

  func testTracksAVoiceWhoseEnergyIsOnlyInTheFirstFewHarmonics() {
    // 高い倍音がほとんど無い声（低い男声など）。全部の倍音の平均で声らしさを測ると、薄まって、
    // 本来の 4 倍の高さ（倍音の数が少ない候補）に取り違える。
    let voice = TestSignals.voice(duration: 3, startPitch: 105, endPitch: 112, highestHarmonic: 650)
    let result = VoiceSeparator().separate(mono(voice))
    var wrong = 0
    var voiced = 0
    for (index, time) in result.pitch.times.enumerated() where time > 0.2 && time < 2.8 && result.pitch.frequencies[index] > 0 {
      voiced += 1
      if abs(Double(result.pitch.frequencies[index]) - 108) / 108 > 0.1 { wrong += 1 }
    }
    XCTAssertGreaterThan(voiced, 40)
    XCTAssertLessThan(Double(wrong) / Double(max(voiced, 1)), 0.05, "高さの取り違えは 5% 未満（\(wrong)/\(voiced)）")
    let remaining = TestSignals.decibels(TestSignals.energy(result.background.channels[0], from: 0.3, to: 2.7) / TestSignals.energy(voice, from: 0.3, to: 2.7))
    XCTAssertLessThan(remaining, -12, "声が 12dB 以上減る（実測 \(remaining) dB）")
  }

  func testRemovesASyntheticVoice() {
    let voice = TestSignals.voice(duration: 3)
    let result = VoiceSeparator().separate(mono(voice))
    let remaining = TestSignals.decibels(TestSignals.energy(result.background.channels[0], from: 0.3, to: 2.7) / TestSignals.energy(voice, from: 0.3, to: 2.7))
    XCTAssertLessThan(remaining, -15, "声のエネルギーが 15dB 以上減る（実測 \(remaining) dB）")
  }

  func testVoiceAndBackgroundAddUpToTheInput() {
    let input = TestSignals.add(TestSignals.voice(duration: 2), TestSignals.noiseBurst(total: 2, start: 0.8, length: 0.4))
    let result = VoiceSeparator().separate(mono(input))
    for index in 0..<input.count {
      XCTAssertEqual(result.voice.channels[0][index] + result.background.channels[0][index], input[index], accuracy: 1e-5)
    }
  }

  func testNoiseWithoutAnyVoiceIsNotTreatedAsVoice() {
    let noise = TestSignals.whiteNoise(duration: 2)
    let result = VoiceSeparator().separate(mono(noise))
    XCTAssertLessThan(result.pitch.voicedRatio, 0.05)
    let kept = TestSignals.decibels(TestSignals.energy(result.background.channels[0]) / TestSignals.energy(noise))
    XCTAssertGreaterThan(kept, -0.5, "雑音はほとんど削れない（実測 \(kept) dB）")
  }

  func testZeroActivityLeavesTheInputUntouched() {
    // 声と同じ音でも、「声は無い」と教えれば削らない。
    let voice = TestSignals.voice(duration: 2)
    let silence = VoiceActivity(interval: 0.1, values: [Float](repeating: 0, count: 25))
    let result = VoiceSeparator().separate(mono(voice), voiceActivity: silence)
    for index in 0..<voice.count { XCTAssertEqual(result.background.channels[0][index], voice[index], accuracy: 1e-4) }
  }

  func testKeepsEffectsThatSoundAtTheSameTimeAsTheVoice() {
    let duration = 4.0
    let voice = TestSignals.voice(duration: duration)
    let effects = TestSignals.add(
      TestSignals.noiseBurst(total: duration, start: 1.0, length: 0.5, amplitude: 0.5, seed: 11),
      TestSignals.noiseBurst(total: duration, start: 2.6, length: 0.4, amplitude: 0.5, seed: 13)
    )
    let mix = TestSignals.add(voice, effects)
    let result = VoiceSeparator().separate(mono(mix))

    let before = TestSignals.sdr(mix, reference: effects, from: 0.3, to: 3.6)
    let after = TestSignals.sdr(result.background.channels[0], reference: effects, from: 0.3, to: 3.6)
    XCTAssertGreaterThan(after - before, 8, "効果音への声の混じりが 8dB 以上減る（\(before) → \(after) dB）")
  }

  func testKeepsATonalEffectThatLiesBetweenTheVoiceHarmonics() {
    // 声の倍音の間で鳴る電子音は、声の一部ではないので残す（声の高さが動くので、倍音の位置は時々重なる）。
    let duration = 4.0
    let beep = TestSignals.beep(total: duration, start: 1.2, length: 1.0, frequency: 3_150, amplitude: 0.2)
    let mix = TestSignals.add(TestSignals.voice(duration: duration), beep)
    let result = VoiceSeparator().separate(mono(mix))

    let before = TestSignals.sdr(mix, reference: beep, from: 1.2, to: 2.2)
    let after = TestSignals.sdr(result.background.channels[0], reference: beep, from: 1.2, to: 2.2)
    // 声が重なる分だけ、電子音そのものも一部は巻き込まれる。実測は +2.3dB 程度の改善（削りすぎると悪化する）。
    XCTAssertGreaterThan(after, before + 1.5, "電子音への声の混じりが減り、電子音自体は削れない（\(before) → \(after) dB）")
  }

  func testStereoKeepsAnEffectPannedToOneSide() {
    let duration = 3.0
    let voice = TestSignals.voice(duration: duration)
    let burst = TestSignals.noiseBurst(total: duration, start: 1.2, length: 0.5, amplitude: 0.5)
    // 声は中央（左右同じ）、効果音は右だけ。
    let left = voice
    let right = TestSignals.add(voice, burst)
    let result = VoiceSeparator().separate(AudioSignal(sampleRate: rate, channels: [left, right]))

    XCTAssertEqual(result.background.channels.count, 2)
    let leftKept = TestSignals.energy(result.background.channels[0], from: 1.2, to: 1.7)
    let rightKept = TestSignals.energy(result.background.channels[1], from: 1.2, to: 1.7)
    XCTAssertGreaterThan(rightKept, leftKept * 4, "効果音のある右側に、背景が残る")
    let rightBurst = TestSignals.energy(burst, from: 1.2, to: 1.7)
    XCTAssertGreaterThan(rightKept / rightBurst, 0.5, "右の効果音の半分以上は残る")
  }

  func testEmptyAndVeryShortInputsDoNotCrash() {
    XCTAssertEqual(VoiceSeparator().separate(mono([])).background.frameCount, 0)
    let short = VoiceSeparator().separate(mono([0.1, -0.1, 0.2]))
    XCTAssertEqual(short.background.frameCount, 3)
    XCTAssertEqual(short.voice.frameCount, 3)
  }
}
