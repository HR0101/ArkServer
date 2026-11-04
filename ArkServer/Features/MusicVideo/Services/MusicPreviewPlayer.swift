// ArkServer/Features/MusicVideo/Services/MusicPreviewPlayer.swift

import AVFoundation
import Combine
import Foundation

/// 試聴に使う音声。本物は AVAudioPlayer で、テストでは差し替える。
@MainActor
protocol PreviewAudio: AnyObject {
  var duration: TimeInterval { get }
  var currentTime: TimeInterval { get set }
  var isPlaying: Bool { get }
  func play() -> Bool
  func stop()
  func fadeOut(over seconds: TimeInterval)
}

@MainActor
final class SystemPreviewAudio: PreviewAudio {
  private let player: AVAudioPlayer

  init(url: URL) throws {
    player = try AVAudioPlayer(contentsOf: url)
    player.prepareToPlay()
  }

  var duration: TimeInterval { player.duration }
  var currentTime: TimeInterval {
    get { player.currentTime }
    set { player.currentTime = newValue }
  }
  var isPlaying: Bool { player.isPlaying }
  func play() -> Bool { player.play() }
  func stop() { player.stop() }
  func fadeOut(over seconds: TimeInterval) { player.setVolume(0, fadeDuration: seconds) }
}

/// 曲を選ぶときの試聴。1度に1曲だけ、短い区間を流して自動で止まる。
@MainActor
final class MusicPreviewPlayer: ObservableObject {
  /// いま試聴している曲。
  @Published private(set) var playingURL: URL?
  /// 試聴区間の中での進み具合（0〜1）。
  @Published private(set) var progress: Double = 0
  /// 再生できなかった曲（その曲のボタンに注意を出す）。
  @Published private(set) var failedURL: URL?
  @Published private(set) var failureMessage: String?

  private let makeAudio: (URL) throws -> PreviewAudio
  private var audio: PreviewAudio?
  private var timer: Timer?
  private var excerpt = MusicPreviewPlan.Excerpt(start: 0, length: 0)
  private var isFadingOut = false

  /// 終わりぎわに音量を下げる時間（秒）。
  static let fadeSeconds = 1.0

  /// - Parameter makeAudio: 音声の作り方。省略すると AVAudioPlayer を使う（テストでは差し替える）。
  init(makeAudio: ((URL) throws -> PreviewAudio)? = nil) {
    self.makeAudio = makeAudio ?? { try SystemPreviewAudio(url: $0) }
  }

  deinit {
    timer?.invalidate()
  }

  func isPlaying(_ url: URL) -> Bool { playingURL == url }

  /// 同じ曲なら止め、別の曲なら切り替えて流す。
  /// - Parameter analysis: 解析済みならその盛り上がりから、聞く区間を決める。
  func toggle(_ url: URL, analysis: MusicAnalysis? = nil) {
    if playingURL == url {
      stop()
    } else {
      play(url, analysis: analysis)
    }
  }

  func play(_ url: URL, analysis: MusicAnalysis? = nil) {
    stop()
    failedURL = nil
    failureMessage = nil
    do {
      let audio = try makeAudio(url)
      guard audio.duration > 0 else { throw PreviewError.empty }

      let excerpt: MusicPreviewPlan.Excerpt
      if let analysis, !analysis.energy.isEmpty {
        excerpt = MusicPreviewPlan.excerpt(forDuration: audio.duration, energy: analysis.energy, energyHop: analysis.energyHop)
      } else {
        excerpt = MusicPreviewPlan.excerpt(forDuration: audio.duration)
      }
      audio.currentTime = excerpt.start
      guard audio.play() else { throw PreviewError.cannotStart }

      self.audio = audio
      self.excerpt = excerpt
      playingURL = url
      progress = 0
      isFadingOut = false
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
    } catch {
      failedURL = url
      failureMessage = "試聴できませんでした．ファイルを読み込めない可能性があります．"
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    audio?.stop()
    audio = nil
    playingURL = nil
    progress = 0
    isFadingOut = false
  }

  /// 0.1秒ごとの更新。進み具合を出し、区間の終わりで止める。テストからも呼べる。
  func tick() {
    guard let audio, playingURL != nil else { return }
    let elapsed = audio.currentTime - excerpt.start
    progress = min(1, max(0, elapsed / max(excerpt.length, 0.001)))
    if !audio.isPlaying || elapsed >= excerpt.length {
      stop()
      return
    }
    let remaining = excerpt.length - elapsed
    if !isFadingOut, remaining <= Self.fadeSeconds {
      isFadingOut = true
      audio.fadeOut(over: max(0.1, remaining))
    }
  }

  private enum PreviewError: Error {
    case empty
    case cannotStart
  }
}
