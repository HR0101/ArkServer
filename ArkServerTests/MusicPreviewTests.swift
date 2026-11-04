// ArkServerTests/MusicPreviewTests.swift

import Foundation
import Testing
@testable import ArkServer

// MARK: - 聞く区間の決め方

@Suite(.serialized)
struct MusicPreviewPlanTests {
  @Test
  func startsAboutAThirdIntoTheSongAndKeepsToTheLength() {
    let excerpt = MusicPreviewPlan.excerpt(forDuration: 200)

    #expect(abs(excerpt.start - 200.0 / 3) < 1e-9)
    #expect(excerpt.length == MusicPreviewPlan.defaultLength)
  }

  @Test
  func neverRunsPastTheEndOfAShortSong() {
    // 15秒より短い曲は、頭から最後まで。
    #expect(MusicPreviewPlan.excerpt(forDuration: 10) == .init(start: 0, length: 10))
    // 少し長いだけの曲は、終わりを越えないよう開始を前へ寄せる。
    #expect(MusicPreviewPlan.excerpt(forDuration: 20) == .init(start: 5, length: 15))
    for duration in stride(from: 1.0, through: 600.0, by: 7.3) {
      let excerpt = MusicPreviewPlan.excerpt(forDuration: duration)
      #expect(excerpt.start >= 0)
      #expect(excerpt.start + excerpt.length <= duration + 1e-9)
    }
  }

  @Test
  func degenerateInputsGiveAnEmptyExcerpt() {
    #expect(MusicPreviewPlan.excerpt(forDuration: 0).length == 0)
    #expect(MusicPreviewPlan.excerpt(forDuration: -5).length == 0)
    #expect(MusicPreviewPlan.excerpt(forDuration: 100, length: 0).length == 0)
  }

  @Test
  func picksTheLoudestStretchWhenTheSongHasBeenAnalysed() {
    // 1秒ごとの盛り上がり。100〜130秒だけ大きい。
    var energy = [Double](repeating: 0.1, count: 240)
    for second in 100..<130 { energy[second] = 0.9 }

    let excerpt = MusicPreviewPlan.excerpt(forDuration: 240, energy: energy, energyHop: 1)

    #expect(excerpt.length == MusicPreviewPlan.defaultLength)
    #expect(excerpt.start >= 100 && excerpt.start + excerpt.length <= 130 + 1e-9)
  }

  @Test
  func theLoudestStretchNearTheEndStillStaysInsideTheSong() {
    var energy = [Double](repeating: 0.1, count: 100)
    for second in 95..<100 { energy[second] = 1.0 }

    let excerpt = MusicPreviewPlan.excerpt(forDuration: 100, energy: energy, energyHop: 1)

    #expect(excerpt.start + excerpt.length <= 100 + 1e-9)
    #expect(excerpt.start >= 85 - 1e-9)
  }

  @Test
  func fallsBackToTheSimpleRuleWithoutUsableEnergy() {
    let simple = MusicPreviewPlan.excerpt(forDuration: 180)

    #expect(MusicPreviewPlan.excerpt(forDuration: 180, energy: [], energyHop: 0.1) == simple)
    #expect(MusicPreviewPlan.excerpt(forDuration: 180, energy: [0.5], energyHop: 0.1) == simple)
    #expect(MusicPreviewPlan.excerpt(forDuration: 180, energy: [0.2, 0.9, 0.4], energyHop: 0) == simple)
  }
}

// MARK: - 試聴の再生状態

@MainActor
private final class FakePreviewAudio: PreviewAudio {
  var duration: TimeInterval
  var currentTime: TimeInterval = 0
  var isPlaying = false
  var canPlay = true
  var fadeOutDuration: TimeInterval?
  var fadeOutCount = 0
  var stopCount = 0

  init(duration: TimeInterval) { self.duration = duration }

  func play() -> Bool {
    guard canPlay else { return false }
    isPlaying = true
    return true
  }
  func stop() { isPlaying = false; stopCount += 1 }
  func fadeOut(over seconds: TimeInterval) { fadeOutDuration = seconds; fadeOutCount += 1 }
}

private enum FakeAudioError: Error { case unreadable }

@Suite(.serialized)
struct MusicPreviewPlayerTests {
  private let songA = URL(fileURLWithPath: "/music/a.mp3")
  private let songB = URL(fileURLWithPath: "/music/b.mp3")

  @MainActor
  private func makePlayer(_ audios: [URL: FakePreviewAudio]) -> MusicPreviewPlayer {
    MusicPreviewPlayer { url in
      guard let audio = audios[url] else { throw FakeAudioError.unreadable }
      return audio
    }
  }

  @Test @MainActor
  func startsAtTheExcerptAndShowsProgressUntilItStopsByItself() {
    let audio = FakePreviewAudio(duration: 180)
    let player = makePlayer([songA: audio])

    player.play(songA)

    #expect(player.playingURL == songA)
    #expect(abs(audio.currentTime - 60) < 1e-9)   // 180秒の曲の3分の1 = 60秒から
    #expect(audio.isPlaying)

    audio.currentTime = 60 + 7.5
    player.tick()
    #expect(abs(player.progress - 0.5) < 1e-9)
    #expect(player.playingURL == songA)

    audio.currentTime = 60 + 15
    player.tick()
    #expect(player.playingURL == nil)
    #expect(player.progress == 0)
    #expect(!audio.isPlaying)
  }

  @Test @MainActor
  func fadesOutOnceInTheLastSecond() {
    let audio = FakePreviewAudio(duration: 180)
    let player = makePlayer([songA: audio])
    player.play(songA)

    audio.currentTime = 60 + 10
    player.tick()
    #expect(audio.fadeOutCount == 0)

    audio.currentTime = 60 + 14.2
    player.tick()
    player.tick()
    #expect(audio.fadeOutCount == 1)
    #expect(abs((audio.fadeOutDuration ?? 0) - 0.8) < 1e-6)
  }

  @Test @MainActor
  func togglingTheSameSongStopsItAndAnotherSongSwitchesOver() {
    let audioA = FakePreviewAudio(duration: 120)
    let audioB = FakePreviewAudio(duration: 120)
    let player = makePlayer([songA: audioA, songB: audioB])

    player.toggle(songA)
    #expect(player.isPlaying(songA))

    player.toggle(songB)
    #expect(player.isPlaying(songB))
    #expect(!player.isPlaying(songA))
    #expect(audioA.stopCount >= 1 && !audioA.isPlaying)
    #expect(audioB.isPlaying)

    player.toggle(songB)
    #expect(player.playingURL == nil)
    #expect(!audioB.isPlaying)
  }

  @Test @MainActor
  func usesTheAnalysedLoudestStretchWhenGiven() {
    let audio = FakePreviewAudio(duration: 240)
    let player = makePlayer([songA: audio])
    var energy = [Double](repeating: 0.1, count: 240)
    for second in 150..<180 { energy[second] = 0.9 }
    let analysis = MusicAnalysis(
      duration: 240, tempo: 120, beats: [], energy: energy,
      intensity: [MusicIntensity](repeating: .medium, count: 240), energyHop: 1
    )

    player.play(songA, analysis: analysis)

    #expect(audio.currentTime >= 150 && audio.currentTime + 15 <= 180 + 1e-9)
  }

  @Test @MainActor
  func stopsWhenTheAudioEndsOnItsOwn() {
    let audio = FakePreviewAudio(duration: 8)
    let player = makePlayer([songA: audio])
    player.play(songA)

    audio.isPlaying = false   // 曲の終わりで再生が終わった
    player.tick()

    #expect(player.playingURL == nil)
  }

  @Test @MainActor
  func reportsAFailureOnTheSongThatCouldNotBePlayedAndRecoversNextTime() {
    let silent = FakePreviewAudio(duration: 0)
    let blocked = FakePreviewAudio(duration: 60)
    blocked.canPlay = false
    let good = FakePreviewAudio(duration: 60)
    let player = makePlayer([songA: silent, songB: blocked, URL(fileURLWithPath: "/music/c.mp3"): good])

    player.play(songA)
    #expect(player.playingURL == nil && player.failedURL == songA && player.failureMessage != nil)

    player.play(songB)
    #expect(player.playingURL == nil && player.failedURL == songB)

    // 読めない曲(未登録)
    player.play(URL(fileURLWithPath: "/music/missing.mp3"))
    #expect(player.failedURL?.lastPathComponent == "missing.mp3")

    // 次に成功したら、失敗の表示は消える。
    player.play(URL(fileURLWithPath: "/music/c.mp3"))
    #expect(player.playingURL?.lastPathComponent == "c.mp3")
    #expect(player.failedURL == nil && player.failureMessage == nil)
  }

  @Test @MainActor
  func stopIsSafeWhenNothingIsPlaying() {
    let player = makePlayer([:])
    player.stop()
    player.tick()
    #expect(player.playingURL == nil && player.progress == 0)
  }
}
