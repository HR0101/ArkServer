#if canImport(SoundAnalysis) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis
import VoiceSeparation

/// Apple 標準の音分類（SoundAnalysis）で、音声のどこに人の声があるかを調べる。
///
/// 約 300 種類の音を見分ける分類器のうち、人の声に当たるもの（話し声・叫び声・笑い声・歌声など）の
/// 確からしさを、時間ごとの `VoiceActivity` にして返す。`VoiceSeparator` に渡すと、
/// 声が無い区間の効果音を壊さずに済む。端末の中だけで動き、通信はしない。
public struct SpeechActivityDetector: Sendable {
  /// 人の声とみなす分類名。
  public static let defaultVoiceClasses: Set<String> = [
    "speech", "babble", "chatter", "shout", "yell", "whispering", "screaming", "children_shouting",
    "battle_cry", "laughter", "giggling", "chuckle_chortle", "snicker", "belly_laugh", "baby_laughter",
    "crying_sobbing", "baby_crying", "singing", "choir_singing", "humming", "rapping", "yodeling",
  ]

  /// 音楽とみなす分類名（楽曲そのものと、楽器・ドラム）。歌声（`singing`）は声のほうに入れる。
  public static let defaultMusicClasses: Set<String> = [
    "music", "orchestra", "accordion", "acoustic_guitar", "banjo", "bass_drum", "bass_guitar", "bassoon", "bagpipes",
    "bowed_string_instrument", "brass_instrument", "cello", "clarinet", "didgeridoo", "double_bass", "drum_kit",
    "electric_guitar", "electric_piano", "electronic_organ", "flute", "french_horn", "glockenspiel", "guitar",
    "guitar_strum", "guitar_tapping", "hammond_organ", "harmonica", "harp", "harpsichord", "hi_hat", "keyboard_musical",
    "mallet_percussion", "mandolin", "marimba_xylophone", "oboe", "organ", "percussion", "piano",
    "plucked_string_instrument", "saxophone", "sitar", "snare_drum", "steel_guitar_slide_guitar", "steelpan",
    "synthesizer", "tabla", "theremin", "timpani", "trombone", "trumpet", "ukulele", "vibraphone", "violin_fiddle",
    "wind_instrument", "zither",
  ]

  /// 効果音の度合いから外す分類名。声・音楽のほかに、音が無いこと（`silence`）や、呼吸のような声に近い音を入れる。
  public static let defaultNonEffectClasses: Set<String> = ["silence", "breathing", "sigh", "gasp", "hiccup"]

  public var voiceClasses: Set<String>
  public var musicClasses: Set<String>
  /// 分類の窓の長さ（秒）。短いほど時間の細かさが上がるが、判定は不安定になる（0.5〜15）。
  public var windowDuration: Double
  /// 隣り合う窓の重なり（0...1 未満）。
  public var overlapFactor: Double

  public init(
    voiceClasses: Set<String> = SpeechActivityDetector.defaultVoiceClasses,
    musicClasses: Set<String> = SpeechActivityDetector.defaultMusicClasses,
    windowDuration: Double = 1.0,
    overlapFactor: Double = 0.75
  ) {
    self.voiceClasses = voiceClasses
    self.musicClasses = musicClasses
    self.windowDuration = windowDuration
    self.overlapFactor = overlapFactor
  }

  /// 窓ひとつぶんの結果。
  private struct Window {
    var start: Double
    var duration: Double
    var voice: Float
    var music: Float
    /// 声・音楽以外の分類のうち、最も確からしいもの（効果音・環境音の度合い）。
    var effects: Float
  }

  /// 声の度合いと、音楽の度合い。
  public struct Activities: Sendable {
    public var voice: VoiceActivity
    public var music: VoiceActivity
    /// 声でも音楽でもない音（衝撃・動作・環境の音）の度合い。
    public var effects: VoiceActivity
  }

  private final class Collector: NSObject, SNResultsObserving {
    let voiceClasses: Set<String>
    let musicClasses: Set<String>
    let excludedFromEffects: Set<String>
    private let lock = NSLock()
    private var storedWindows: [Window] = []
    private var storedError: Error?

    init(voiceClasses: Set<String>, musicClasses: Set<String>, excludedFromEffects: Set<String>) {
      self.voiceClasses = voiceClasses
      self.musicClasses = musicClasses
      self.excludedFromEffects = excludedFromEffects
    }

    var windows: [Window] { lock.lock(); defer { lock.unlock() }; return storedWindows }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }

    func request(_ request: SNRequest, didProduce result: SNResult) {
      guard let result = result as? SNClassificationResult else { return }
      var voice: Float = 0
      var music: Float = 0
      var effects: Float = 0
      for classification in result.classifications {
        let confidence = Float(classification.confidence)
        if voiceClasses.contains(classification.identifier) {
          voice = max(voice, confidence)
        } else if musicClasses.contains(classification.identifier) {
          music = max(music, confidence)
        } else if !excludedFromEffects.contains(classification.identifier) {
          effects = max(effects, confidence)
        }
      }
      lock.lock()
      storedWindows.append(Window(
        start: result.timeRange.start.seconds, duration: result.timeRange.duration.seconds,
        voice: voice, music: music, effects: effects
      ))
      lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
      lock.lock(); storedError = error; lock.unlock()
    }

    func requestDidComplete(_ request: SNRequest) {}
  }

  /// `signal` の声の度合いを調べる。短すぎて窓が一つも作れないときは、値が空の `VoiceActivity` を返す。
  public func detect(_ signal: AudioSignal) throws -> VoiceActivity {
    try detectActivities(signal).voice
  }

  /// `signal` の声の度合いと音楽の度合いを、一度の解析で調べる。
  public func detectActivities(_ signal: AudioSignal) throws -> Activities {
    let interval = 0.05
    let none = VoiceActivity(interval: interval, values: [])
    let empty = Activities(voice: none, music: none, effects: none)
    let samples = signal.monoMix()
    guard !samples.isEmpty, signal.sampleRate > 0,
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: signal.sampleRate, channels: 1, interleaved: false)
    else {
      return empty
    }

    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
    request.windowDuration = CMTime(seconds: windowDuration, preferredTimescale: 48_000)
    request.overlapFactor = min(max(overlapFactor, 0), 0.95)

    let analyzer = SNAudioStreamAnalyzer(format: format)
    let collector = Collector(
      voiceClasses: voiceClasses, musicClasses: musicClasses, excludedFromEffects: Self.defaultNonEffectClasses
    )
    try analyzer.add(request, withObserver: collector)

    let chunk = max(Int(signal.sampleRate), 1)
    var position = 0
    while position < samples.count {
      let count = min(chunk, samples.count - position)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let destination = buffer.floatChannelData?[0] else { break }
      buffer.frameLength = AVAudioFrameCount(count)
      samples.withUnsafeBufferPointer { source in
        destination.update(from: source.baseAddress! + position, count: count)
      }
      analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
      position += count
    }
    analyzer.completeAnalysis()

    if let error = collector.error { throw error }
    let windows = collector.windows
    guard !windows.isEmpty else { return empty }
    return Activities(
      voice: Self.activity(from: windows, score: \.voice, duration: signal.duration, interval: interval),
      music: Self.activity(from: windows, score: \.music, duration: signal.duration, interval: interval),
      effects: Self.activity(from: windows, score: \.effects, duration: signal.duration, interval: interval)
    )
  }

  /// 窓ごとの得点を、一定間隔の時系列にする。各時刻は、それを覆う窓の最大値（中心から遠い窓ほど割り引く）。
  private static func activity(
    from windows: [Window], score: KeyPath<Window, Float>, duration: Double, interval: Double
  ) -> VoiceActivity {
    guard !windows.isEmpty else { return VoiceActivity(interval: interval, values: []) }
    let count = Int((duration / interval).rounded(.up)) + 1
    var values = [Float](repeating: 0, count: count)
    var covered = [Bool](repeating: false, count: count)
    for window in windows where window.duration > 0 {
      let half = window.duration / 2
      let center = window.start + half
      let first = max(0, Int(((window.start) / interval).rounded(.up)))
      let last = min(count - 1, Int(((window.start + window.duration) / interval).rounded(.down)))
      guard last >= first else { continue }
      for index in first...last {
        let distance = abs(Double(index) * interval - center) / half
        let weighted = window[keyPath: score] * Float(1 - 0.5 * min(distance, 1))
        values[index] = max(values[index], weighted)
        covered[index] = true
      }
    }
    // どの窓にも覆われない両端は、いちばん近い値で埋める。
    if let firstCovered = covered.firstIndex(of: true), let lastCovered = covered.lastIndex(of: true) {
      for index in 0..<firstCovered { values[index] = values[firstCovered] }
      if lastCovered + 1 < count { for index in (lastCovered + 1)..<count { values[index] = values[lastCovered] } }
    }
    return VoiceActivity(startTime: 0, interval: interval, values: values)
  }
}
#endif
