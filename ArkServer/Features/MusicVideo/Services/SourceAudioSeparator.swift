// ArkServer/Features/MusicVideo/Services/SourceAudioSeparator.swift

import AVFoundation
import CryptoKit
import Foundation
import VoiceSeparation
import VoiceSeparationSoundAnalysis

nonisolated enum SourceAudioSeparatorError: LocalizedError {
  case noAudioTrack
  case cannotRead(String)
  case cannotWrite(String)

  var errorDescription: String? {
    switch self {
    case .noAudioTrack: return "素材動画に音声トラックがありません．"
    case .cannotRead(let reason): return "素材の音を読み出せませんでした．\(reason)"
    case .cannotWrite(let reason): return "選んだ成分の音を保存できませんでした．\(reason)"
    }
  }
}

/// 素材動画の音のうち、使う範囲から、選んだ成分（音楽・声・効果音）だけを残した音声ファイルを作る。
///
/// 声・音楽・効果音に分ける処理は `VoiceSeparationKit` が行う。ここでは素材から音を読み出し、
/// 結果をファイルにして保存する。同じ素材の同じ範囲・同じ成分は、保存したファイルを使い回す
/// （色や切り替え効果を変えて作り直すたびに、音を調べ直さずに済む）。
nonisolated struct SourceAudioSeparator: Sendable {
  var cacheDirectory: URL
  /// 声の判定のために、使う範囲の前後に足して読む長さ（秒）。前後の音を聞かせると、判定が安定する。
  var context = 1.5

  /// 処理の中身を変えたときに上げる。古い保存ファイルを使わなくなる。
  private static let algorithmVersion = 2
  private static let sampleRate = 44_100.0

  static var standard: SourceAudioSeparator {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return SourceAudioSeparator(cacheDirectory: base.appendingPathComponent("ArkServer/SeparatedAudio", isDirectory: true))
  }

  // MARK: - 取り出し

  /// `source` の `start` 秒から `duration` 秒の音から、`parts` の成分だけを残したファイルを返す。ファイルの 0 秒が `start` に当たる。
  func audio(source: URL, start: Double, duration: Double, parts: SourceAudioParts) async throws -> URL {
    let output = cacheDirectory.appendingPathComponent(
      "\(cacheKey(source: source, start: start, duration: duration, parts: parts)).caf"
    )
    if FileManager.default.fileExists(atPath: output.path) {
      // 使われたことが分かるよう、更新日時を新しくする（古いファイルの整理で消されないように）。
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
      return output
    }
    try Task.checkCancellation()

    let paddedStart = max(0, start - context)
    let signal = try await readAudio(from: source, start: paddedStart, duration: (start - paddedStart) + duration + context)
    try Task.checkCancellation()

    // 声・音楽・効果音の度合いが調べられなかったときは、その情報なしで分ける（声は取り除くほうを優先し、
    // 音楽の度合いが無ければ、声以外はすべて効果音として扱う）。
    let activities = try? SpeechActivityDetector().detectActivities(signal.audio)
    let components = VoiceSeparator().separateComponents(
      signal.audio,
      voiceActivity: activities?.voice,
      musicActivity: activities?.music,
      effectsActivity: activities?.effects
    )
    let selected = components.mixed(
      voice: parts.contains(.voice), music: parts.contains(.music), effects: parts.contains(.effects)
    )
    try Task.checkCancellation()

    // 読み出した範囲のうち、実際に使う部分だけを切り出す。
    let rate = signal.audio.sampleRate
    let firstFrame = max(0, Int(((start - signal.startTime) * rate).rounded()))
    let frameCount = max(0, min(Int((duration * rate).rounded()), selected.frameCount - firstFrame))
    guard frameCount > 0 else { throw SourceAudioSeparatorError.cannotRead("使う範囲に音がありません．") }
    let channels = selected.channels.map { Array($0[firstFrame..<(firstFrame + frameCount)]) }

    try write(AudioSignal(sampleRate: rate, channels: channels), to: output)
    return output
  }

  // MARK: - 保存ファイルの整理

  /// 保存ファイルの合計が `limitBytes` を超えていたら、古いものから消す。最近使ったもの（`keepRecent` 秒以内）は、
  /// いま再生中の映像が参照していることがあるので消さない。
  func trimCache(limitBytes: Int = 1_000_000_000, keepRecent: TimeInterval = 600) {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    guard let urls = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }
    var files: [(url: URL, size: Int, date: Date)] = urls.compactMap { url in
      guard url.pathExtension == "caf", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }
    var total = files.reduce(0) { $0 + $1.size }
    guard total > limitBytes else { return }
    files.sort { $0.date < $1.date }
    let threshold = Date().addingTimeInterval(-keepRecent)
    for file in files where total > limitBytes && file.date < threshold {
      try? FileManager.default.removeItem(at: file.url)
      total -= file.size
    }
  }

  // MARK: - 部品

  private func cacheKey(source: URL, start: Double, duration: Double, parts: SourceAudioParts) -> String {
    let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let stamp = [
      source.path,
      String(values?.fileSize ?? 0),
      String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
      String(Int((start * 1000).rounded())),
      String(Int((duration * 1000).rounded())),
      String(parts.rawValue),
      String(Self.algorithmVersion),
    ].joined(separator: "|")
    return SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// 読み出した音と、その先頭が素材の何秒目に当たるか。
  private struct ReadAudio {
    var audio: AudioSignal
    var startTime: Double
  }

  /// 素材の音を、44.1kHz・ステレオ・浮動小数点で読み出す。
  private func readAudio(from url: URL, start: Double, duration: Double) async throws -> ReadAudio {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw SourceAudioSeparatorError.noAudioTrack
    }
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch { throw SourceAudioSeparatorError.cannotRead(error.localizedDescription) }
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
        AVSampleRateKey: Self.sampleRate,
        AVNumberOfChannelsKey: 2,
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw SourceAudioSeparatorError.cannotRead("読み出しを始められません．") }
    reader.add(output)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
    guard reader.startReading() else {
      throw SourceAudioSeparatorError.cannotRead(reader.error?.localizedDescription ?? "読み出しを始められません．")
    }

    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 2, interleaved: false) else {
      throw SourceAudioSeparatorError.cannotRead("音声の形式を作れません．")
    }
    var left: [Float] = []
    var right: [Float] = []
    var firstTime: Double?
    while let sampleBuffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      let frames = CMSampleBufferGetNumSamples(sampleBuffer)
      guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
      buffer.frameLength = AVAudioFrameCount(frames)
      let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
      )
      guard status == noErr, let channels = buffer.floatChannelData else { continue }
      if firstTime == nil { firstTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds }
      left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
      right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
    }
    if reader.status == .failed {
      throw SourceAudioSeparatorError.cannotRead(reader.error?.localizedDescription ?? "読み出しに失敗しました．")
    }
    guard !left.isEmpty else { throw SourceAudioSeparatorError.cannotRead("指定の範囲に音がありません．") }
    return ReadAudio(audio: AudioSignal(sampleRate: Self.sampleRate, channels: [left, right]), startTime: firstTime ?? start)
  }

  /// 16bit のステレオ PCM として保存する。書きかけのファイルが使われないよう、別名で書いてから名前を付ける。
  private func write(_ audio: AudioSignal, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
      let temporary = cacheDirectory.appendingPathComponent("tmp-\(UUID().uuidString).caf")
      defer { try? FileManager.default.removeItem(at: temporary) }
      guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 2, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frameCount)),
            let channels = buffer.floatChannelData else {
        throw SourceAudioSeparatorError.cannotWrite("音声の形式を作れません．")
      }
      buffer.frameLength = AVAudioFrameCount(audio.frameCount)
      for channel in 0..<2 {
        let samples = audio.channels[min(channel, audio.channels.count - 1)]
        samples.withUnsafeBufferPointer { channels[channel].update(from: $0.baseAddress!, count: samples.count) }
      }
      do {
        let file = try AVAudioFile(
          forWriting: temporary,
          settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
          ],
          commonFormat: .pcmFormatFloat32,
          interleaved: false
        )
        try file.write(from: buffer)
      }
      // file の解放（書き込みの完了）後に名前を付ける。同時に同じ範囲を作った場合は、先にできたものを使う。
      if FileManager.default.fileExists(atPath: url.path) { return }
      try FileManager.default.moveItem(at: temporary, to: url)
    } catch let error as SourceAudioSeparatorError {
      throw error
    } catch {
      throw SourceAudioSeparatorError.cannotWrite(error.localizedDescription)
    }
  }
}
