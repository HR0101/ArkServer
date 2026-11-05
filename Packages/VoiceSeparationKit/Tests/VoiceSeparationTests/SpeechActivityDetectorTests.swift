#if canImport(SoundAnalysis)
import AVFoundation
import XCTest
@testable import VoiceSeparation
import VoiceSeparationSoundAnalysis

final class SpeechActivityDetectorTests: XCTestCase {
  /// macOS 標準の `say` で話し声を作る（実際の音声合成なので、分類器が「話し声」と認める）。
  private func spokenSignal(_ text: String) throws -> AudioSignal {
    let say = URL(fileURLWithPath: "/usr/bin/say")
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: say.path), "say が無い環境")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let process = Process()
    process.executableURL = say
    process.arguments = ["-o", url.path, "--data-format=LEI16@44100", text]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)

    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return AudioSignal(sampleRate: format.sampleRate, channels: [Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))])
  }

  func testFindsSpeechAndIgnoresSoundEffects() throws {
    let speech = try spokenSignal("Hello everyone. Welcome back to the channel. Today we are going to build something really cool together.")
    let rate = speech.sampleRate
    // 前の 4 秒は効果音（雑音の衝撃）だけ、そのあとが話し声、最後に再び効果音。
    let before = TestSignals.noiseBurst(total: 4, start: 0.5, length: 0.6, amplitude: 0.4, seed: 21)
    let after = TestSignals.noiseBurst(total: 4, start: 1.0, length: 0.6, amplitude: 0.4, seed: 22)
    let samples = before + speech.channels[0] + after
    let signal = AudioSignal(sampleRate: rate, channels: [samples])
    let speechStart = 4.0
    let speechEnd = 4.0 + speech.duration

    let activity = try SpeechActivityDetector().detect(signal)
    XCTAssertFalse(activity.values.isEmpty)
    // 話し声の中ほどでは高く、効果音だけの所では低い。
    let inside = stride(from: speechStart + 1, to: speechEnd - 1, by: 0.5).compactMap { activity.value(at: $0) }
    let outside = stride(from: 0.2, to: speechStart - 1, by: 0.5).compactMap { activity.value(at: $0) }
    XCTAssertGreaterThan(inside.min() ?? 0, 0.5, "話し声の中は 0.5 より高い")
    XCTAssertLessThan(outside.max() ?? 1, 0.3, "効果音だけの所は 0.3 より低い")
  }

  func testVeryShortAudioReturnsNoInformationInsteadOfFailing() throws {
    let signal = AudioSignal(sampleRate: 44_100, channels: [TestSignals.whiteNoise(duration: 0.2)])
    let activity = try SpeechActivityDetector().detect(signal)
    XCTAssertNil(activity.value(at: 0.1), "窓より短い音では、判断できないので値を返さない")
  }

  func testDetectorFeedsTheSeparatorToProtectEffectsBeforeTheVoice() throws {
    let speech = try spokenSignal("The quick brown fox jumps over the lazy dog, and then it runs away through the forest.")
    let rate = speech.sampleRate
    let lead = 3.0
    // 先頭の効果音（声の前）が、声の除去で壊れないこと。
    let effect = TestSignals.noiseBurst(total: lead, start: 0.4, length: 0.8, amplitude: 0.4, seed: 5)
    let samples = effect + speech.channels[0]
    let signal = AudioSignal(sampleRate: rate, channels: [samples])
    let activity = try SpeechActivityDetector().detect(signal)

    let withActivity = VoiceSeparator().separate(signal, voiceActivity: activity)
    let kept = TestSignals.decibels(TestSignals.energy(withActivity.background.channels[0], from: 0, to: lead) / TestSignals.energy(samples, from: 0, to: lead))
    XCTAssertGreaterThan(kept, -0.5, "声の前の効果音はそのまま残る（実測 \(kept) dB）")
    let removed = TestSignals.decibels(TestSignals.energy(withActivity.background.channels[0], from: lead + 0.5, to: lead + speech.duration - 0.5) / TestSignals.energy(samples, from: lead + 0.5, to: lead + speech.duration - 0.5))
    XCTAssertLessThan(removed, -8, "声のある所では声が減る（実測 \(removed) dB）")
  }
}
#endif
