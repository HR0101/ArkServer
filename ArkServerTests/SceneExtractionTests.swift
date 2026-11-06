// ArkServerTests/SceneExtractionTests.swift

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import ArkServer

@Suite(.serialized)
struct SceneExtractionTests {
  @Test @MainActor
  func discoveryMixUsesMoodAndSeenFilters() throws {
    let short = tourVideo(duration: 90)
    let long = tourVideo(duration: 600)
    var favorite = tourVideo(duration: 200)
    favorite.isFavorite = true
    let all = [short, long, favorite]
    let shortMix = try PlaybackTourSession.mix(videos: all, mood: .short, seenIDs: [])
    #expect(shortMix.entries.map(\.video.id) == [short.id])
    let unseen = try PlaybackTourSession.mix(videos: all, mood: .unseen, seenIDs: [short.id, favorite.id])
    #expect(unseen.entries.map(\.video.id) == [long.id])
    let favorites = try PlaybackTourSession.mix(videos: all, mood: .favorites, seenIDs: [])
    #expect(favorites.entries.map(\.video.id) == [favorite.id])
    #expect(throws: PlaybackTourError.self) {
      try PlaybackTourSession.mix(videos: all, mood: .unseen, seenIDs: Set(all.map(\.id)))
    }
  }

  @Test @MainActor
  func timedPlaybackFillsBudgetAndTrimsLastEntry() throws {
    let video = tourVideo(duration: 7)
    let session = try PlaybackTourSession.timed(videos: [video], seconds: 20)
    #expect(session.entries.map { $0.end - $0.start } == [7, 7, 6])
    #expect(session.entries.reduce(0) { $0 + $1.end - $1.start } == 20)
    #expect(session.requestedSeconds == 20)
    #expect(throws: PlaybackTourError.self) { try PlaybackTourSession.timed(videos: [video], seconds: .nan) }
  }

  @Test @MainActor
  func highlightsPersistIndependentlyAndClampAtFileEdges() throws {
    let suite = "Highlights-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = URL(fileURLWithPath: "/tmp/highlight.mp4")
    try HighlightStore.capture(url: url, time: 2, duration: 100, defaults: defaults)
    try HighlightStore.capture(url: url, time: 2, duration: 100, defaults: defaults)
    try HighlightStore.capture(url: url, time: 98, duration: 100, defaults: defaults)
    let stored = try AcceptedSceneStore.load(defaults: defaults, key: HighlightStore.defaultsKey)
    let scenes = try #require(stored[AcceptedSceneStore.sourceKey(url)])
    #expect(scenes.count == 2)
    #expect(scenes[0].startTime == 0 && scenes[0].endTime == 12)
    #expect(scenes[1].startTime == 88 && scenes[1].endTime == 100)
    #expect(try AcceptedSceneStore.load(defaults: defaults).isEmpty)
    let session = try PlaybackTourSession.highlights(videos: [tourVideo(duration: 100, url: url)],
      urlForVideo: { _ in url }, defaults: defaults)
    #expect(session.entries.count == 2)
  }

  @Test @MainActor
  func channelsContinueWithinAlbumAndWrapOnNavigation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Channels-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clip.mp4")
    try await makeSyntheticVideo(at: url)
    let first = tourVideo(duration: 2, url: url)
    let second = tourVideo(duration: 2, url: url)
    let albums = [Album(id: UUID(), name: "A", videoIDs: [first.id, second.id], type: .video),
      Album(id: UUID(), name: "B", videoIDs: [second.id], type: .video),
      Album(id: UUID(), name: LibraryViewModel.allVideosAlbumName, videoIDs: [first.id], type: .video)]
    let built = try PlaybackTourSession.channelSession(albums: albums, videos: [first, second])
    #expect(built.channels.count == 2)
    let session = PlaybackTourSession(kind: .channels, entries: [
      PlaybackTourEntry(id: UUID(), video: first, start: 1.8, end: 2),
      PlaybackTourEntry(id: UUID(), video: second, start: 0, end: 2)
    ], channels: built.channels)
    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { nil }, downloadsDirectory: { nil }, createDirectory: { _ in }
    ))
    let model = PlaybackTourViewModel(session: session, dataManager: library)
    defer { model.cleanup() }
    model.start()
    try await waitForLoopPlayback { model.channelEntry != nil && !model.isLoading }
    #expect(model.index == 0 && !model.isFinished)
    #expect(model.currentEntry?.video.id == second.id)
    model.previous()
    #expect(model.index == 1)
    model.next()
    #expect(model.index == 0)
  }

  @Test @MainActor
  func previewTourClampsShortVideosAndDeduplicates() throws {
    let video = tourVideo(duration: 3)
    let session = try PlaybackTourSession.preview(videos: [video, video], seconds: 15)
    #expect(session.entries.count == 1)
    #expect(session.entries[0].start == 0)
    #expect(session.entries[0].end == 3)
    let long = tourVideo(duration: 120)
    let tour = try PlaybackTourSession.preview(videos: [long], seconds: 30)
    #expect(tour.entries[0].start >= 0)
    #expect(tour.entries[0].end <= 120)
    #expect(abs(tour.entries[0].end - tour.entries[0].start - 30) < 0.001)
    #expect(throws: PlaybackTourError.self) {
      try PlaybackTourSession.preview(videos: [], seconds: 15)
    }
  }

  @Test @MainActor
  func acceptedScenesPersistClampAndProtectCorruptData() throws {
    let suite = "SceneTourTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = URL(fileURLWithPath: "/tmp/scene-tour-test.mp4")
    let video = tourVideo(duration: 10, url: url)
    let accepted = CandidateSegment(startTime: 2, endTime: 20, peakTime: 3,
      score: 1, audioScore: 0, visualScore: 0, transitionScore: 0,
      reason: [], userLabel: .accepted)
    var rejected = accepted
    rejected.userLabel = .rejected
    try AcceptedSceneStore.save(url: url, candidates: [accepted, rejected], defaults: defaults)
    #expect(try AcceptedSceneStore.load(defaults: defaults)[AcceptedSceneStore.sourceKey(url)]?.count == 1)
    let session = try PlaybackTourSession.scenes(videos: [video], urlForVideo: { _ in url }, defaults: defaults)
    #expect(session.entries.count == 1)
    #expect(session.entries[0].start == 2)
    #expect(session.entries[0].end == 10)
    try AcceptedSceneStore.save(url: url, candidates: [], defaults: defaults)
    #expect(throws: PlaybackTourError.self) {
      try PlaybackTourSession.scenes(videos: [video], urlForVideo: { _ in url }, defaults: defaults)
    }
    let corrupted = Data("invalid-json".utf8)
    defaults.set(corrupted, forKey: AcceptedSceneStore.defaultsKey)
    #expect(throws: (any Error).self) {
      try AcceptedSceneStore.save(url: url, candidates: [accepted], defaults: defaults)
    }
    #expect(defaults.data(forKey: AcceptedSceneStore.defaultsKey) == corrupted)
  }

  @Test @MainActor
  func tourAdvancesAtRangeEndAndStopsAfterOnePass() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TourPlayback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clip.mp4")
    try await makeSyntheticVideo(at: url)
    let video = tourVideo(duration: 2, url: url)
    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { nil }, downloadsDirectory: { nil }, createDirectory: { _ in }
    ))
    library.videos = [video]
    let session = PlaybackTourSession(kind: .scenes, entries: [
      PlaybackTourEntry(id: UUID(), video: video, start: 0.2, end: 0.5),
      PlaybackTourEntry(id: UUID(), video: video, start: 0.7, end: 1.0)
    ])
    let model = PlaybackTourViewModel(session: session, dataManager: library)
    defer { model.cleanup() }
    model.start()
    try await waitForLoopPlayback { model.index == 1 && !model.isLoading }
    #expect(model.currentTime >= 0.7)
    try await waitForLoopPlayback { model.isFinished }
    #expect(model.player.rate == 0)
    #expect(model.errorMessage == nil)
    #expect(model.index == 1)
  }

  @Test @MainActor
  func tourPauseAndMissingFileRemainControllable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TourPause-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clip.mp4")
    try await makeSyntheticVideo(at: url)
    let video = tourVideo(duration: 2, url: url)
    let missing = tourVideo(duration: 2, url: directory.appendingPathComponent("missing.mp4"))
    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { nil }, downloadsDirectory: { nil }, createDirectory: { _ in }
    ))
    let session = PlaybackTourSession(kind: .preview, entries: [
      PlaybackTourEntry(id: UUID(), video: missing, start: 0, end: 1),
      PlaybackTourEntry(id: UUID(), video: video, start: 0.2, end: 1.5)
    ])
    let model = PlaybackTourViewModel(session: session, dataManager: library)
    defer { model.cleanup() }
    model.start()
    try await waitForLoopPlayback { model.errorMessage != nil }
    model.next()
    try await waitForLoopPlayback { model.isPlaying && !model.isLoading }
    model.togglePlayback()
    try await waitForLoopPlayback { !model.isPlaying }
    let time = model.player.currentTime().seconds
    try await Task.sleep(for: .milliseconds(400))
    #expect(abs(model.player.currentTime().seconds - time) < 0.05)
    #expect(!model.isFinished)
    model.togglePlayback()
    try await waitForLoopPlayback { model.isFinished }
  }

  @Test @MainActor
  func tourHandoffStartsAtPreviewPositionInsteadOfSavedResume() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TourHandoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clip.mp4")
    try await makeSyntheticVideo(at: url)
    let video = tourVideo(duration: 60, url: url)
    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { nil }, downloadsDirectory: { nil }, createDirectory: { _ in }
    ))
    library.videos = [video]
    let watchState = WatchStateStore(store: WebSyncStore(rootURL: directory, persistenceEnabled: false))
    watchState.recordProgress(videoID: video.id, seconds: 20, duration: 60, force: true)
    let keys = ["playback.repeatMode", "playback.autoPlayNext"]
    let original = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, original) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
      }
    }
    let settings = PlaybackSettings()
    settings.repeatMode = .off
    settings.autoPlayNext = false
    let model = VideoPlayerViewModel(videos: [video], currentVideo: video, dataManager: library,
      watchState: watchState, settings: settings, initialStartTime: 0.4)
    defer { model.cleanup() }
    model.setupPlayer()
    try await waitForLoopPlayback { model.player?.rate ?? 0 > 0 }
    let time = try #require(model.player?.currentTime().seconds)
    #expect(time >= 0.39 && time < 1.5)
  }

  @MainActor
  private func tourVideo(duration: Double, url: URL = URL(fileURLWithPath: "/tmp/tour.mp4")) -> VideoItem {
    VideoItem(id: UUID(), originalFilename: url.lastPathComponent, internalFilename: "",
      duration: duration, importDate: Date(), creationDate: nil, fileHash: "",
      externalFilePath: url.path)
  }

  @Test
  func loopBlackFrameAnalysisKeepsInternalBlackFrames() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LoopBlackFrameTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("black-edges.mp4")
    let brightness: [UInt8] = Array(repeating: 0, count: 6)
      + Array(repeating: 80, count: 12)
      + Array(repeating: 0, count: 6)
      + Array(repeating: 80, count: 12)
      + Array(repeating: 0, count: 6)
    try await makeSyntheticVideo(at: sourceURL, frameBrightness: brightness)

    let range = try #require(try await LoopBlackFrameAnalyzer().analyze(
      asset: AVURLAsset(url: sourceURL)
    ))
    let framePrecision = 0.001
    #expect(abs(range.start.seconds - 0.2) < framePrecision)
    #expect(abs(range.end.seconds - 1.2) < framePrecision)
    #expect(CMTimeRangeContainsTime(range, time: CMTime(seconds: 0.7, preferredTimescale: 600)))
  }

  @Test
  func loopBlackFrameAnalysisScansLongTrailingBlackAndKeepsDarkContent() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LoopLongBlackFrameTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("long-black-tail.mp4")
    let brightness: [UInt8] = Array(repeating: 0, count: 6)
      + Array(repeating: 16, count: 12)
      + Array(repeating: 0, count: 90)
    try await makeSyntheticVideo(at: sourceURL, frameBrightness: brightness)

    let range = try #require(try await LoopBlackFrameAnalyzer().analyze(
      asset: AVURLAsset(url: sourceURL)
    ))
    let framePrecision = 0.001
    #expect(abs(range.start.seconds - 0.2) < framePrecision)
    #expect(abs(range.end.seconds - 0.6) < framePrecision)
  }

  @Test
  func loopBlackFrameAnalysisDoesNotTrimEntirelyBlackVideo() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LoopEntirelyBlackTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("black.mp4")
    try await makeSyntheticVideo(at: sourceURL, frameBrightness: Array(repeating: 0, count: 12))

    let range = try await LoopBlackFrameAnalyzer().analyze(asset: AVURLAsset(url: sourceURL))
    #expect(range == nil)
  }

  @Test
  func loopBlackFrameAnalysisKeepsVideoWithBlackBars() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LoopBlackBarTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("letterboxed.mp4")
    try await makeSyntheticVideo(
      at: sourceURL, frameBrightness: Array(repeating: 64, count: 12), hasBlackBars: true
    )

    let range = try #require(try await LoopBlackFrameAnalyzer().analyze(
      asset: AVURLAsset(url: sourceURL)
    ))
    #expect(range.start == .zero)
    #expect(abs(range.end.seconds - 0.4) < 0.001)
  }

  @Test(arguments: [PlaybackRepeatMode.one, .all]) @MainActor
  func localLoopSkipsBlackEdgesAndRestoresFullRangeWhenDisabled(mode: PlaybackRepeatMode) async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalBlackEdgePlaybackTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("black-edges.mp4")
    let brightness: [UInt8] = Array(repeating: 0, count: 6)
      + Array(repeating: 80, count: 30)
      + Array(repeating: 0, count: 6)
    try await makeSyntheticVideo(at: sourceURL, frameBrightness: brightness)

    let defaults = UserDefaults.standard
    let keys = ["playback.repeatMode", "playback.autoPlayNext", "playback.rate"]
    let savedValues = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, savedValues) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    let settings = PlaybackSettings()
    settings.repeatMode = .off
    settings.autoPlayNext = false
    settings.rate = 1
    let video = VideoItem(
      id: UUID(), originalFilename: sourceURL.lastPathComponent, internalFilename: "",
      duration: 1.4, importDate: Date(), creationDate: nil, fileHash: "",
      externalFilePath: sourceURL.path
    )
    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { nil }, downloadsDirectory: { nil }, createDirectory: { _ in }
    ))
    library.videos = [video]
    let model = VideoPlayerViewModel(
      videos: [video], currentVideo: video, dataManager: library,
      watchState: WatchStateStore(store: WebSyncStore(
        rootURL: temporaryDirectory, persistenceEnabled: false
      )), settings: settings
    )
    defer { model.cleanup() }
    model.setupPlayer()
    try await waitForLoopPlayback { model.player?.rate ?? 0 > 0 }
    let queue = try #require(model.player as? AVQueuePlayer)
    model.pause()
    #expect(!model.isAnalyzingLoopEdges)
    #expect(model.loopAnalysisNotice == nil)
    #expect(queue.items().count == 1)
    #expect(queue.currentItem?.forwardPlaybackEndTime.isValid == false)

    settings.autoPlayNext = mode == .all
    settings.repeatMode = mode
    try await waitForLoopPlayback {
      model.loopAnalysisNotice?.contains("スキップ") == true && !model.isAnalyzingLoopEdges
    }
    try await waitForLoopPlayback {
      queue.items().count == 3 && queue.items().allSatisfy { $0.currentTime().seconds >= 0.199 }
    }
    #expect(queue.rate == 0)
    for item in queue.items() {
      #expect(abs(item.forwardPlaybackEndTime.seconds - 1.2) < 0.001)
    }

    model.play()
    for _ in 0..<3 {
      let previousItem = try #require(queue.currentItem)
      try await waitForLoopPlayback { queue.currentItem != nil && queue.currentItem !== previousItem }
      let seconds = try #require(queue.currentItem?.currentTime().seconds)
      #expect(seconds >= 0.199 && seconds < 1.2)
      #expect(queue.rate == 1)
    }
    model.pause()
    settings.repeatMode = .off
    try await waitForLoopPlayback {
      queue.items().count == 1 && queue.currentItem?.forwardPlaybackEndTime.isValid == false
    }
    model.seek(toSeconds: 0)
    try await waitForLoopPlayback { queue.currentTime().seconds < 0.001 }
    #expect(model.loopAnalysisNotice == nil)

    // 再度有効にしたときも，保存済みの解析結果で冒頭を飛ばします．
    settings.repeatMode = mode
    try await waitForLoopPlayback { queue.currentTime().seconds >= 0.199 }
    #expect(!model.isAnalyzingLoopEdges)
    #expect(queue.rate == 0)
  }

  @MainActor
  private func waitForLoopPlayback(_ condition: () -> Bool) async throws {
    let timeoutSeconds: TimeInterval = 5
    let pollNanoseconds: UInt64 = 10_000_000
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition(), Date() < deadline {
      try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    try #require(condition(), "ループの黒画面スキップが制限時間内に準備できませんでした")
  }

  @Test
  func tutorialCoversCompleteWorkflow() {
    let steps = SceneExtractionTutorialContent.steps

    #expect(steps.count == 6)
    #expect(steps.map(\.id) == Array(1...6))
    #expect(steps.allSatisfy { !$0.title.isEmpty })
    #expect(steps.allSatisfy { $0.details.count >= 4 })
    #expect(SceneExtractionTutorialContent.currentVersion > 0)
    #expect(steps[1].title.contains("ライブラリ"))
    #expect(steps[1].summary.contains("シーン抽出"))
    #expect(!steps[1].summary.contains("動画を開く"))
    #expect(steps[4].details.contains { $0.contains("1・2・3キー") })
  }

  @Test
  @MainActor
  func reviewingCandidateAdvancesToNextUnlabeledCandidate() {
    let first = CandidateSegment(
      startTime: 0,
      endTime: 10,
      peakTime: 4,
      score: 0.9,
      audioScore: 0.9,
      visualScore: 0.8,
      transitionScore: 0.7,
      reason: ["テスト"]
    )
    let second = CandidateSegment(
      startTime: 10,
      endTime: 20,
      peakTime: 14,
      score: 0.8,
      audioScore: 0.8,
      visualScore: 0.7,
      transitionScore: 0.6,
      reason: ["テスト"]
    )
    let viewModel = SceneExtractionViewModel()
    viewModel.candidates = [first, second]
    viewModel.selectedCandidateID = first.id

    viewModel.reviewCandidate(.accepted, candidateID: first.id)

    #expect(viewModel.candidates.first { $0.id == first.id }?.userLabel == .accepted)
    #expect(viewModel.selectedCandidateID == second.id)
  }

  @Test
  func glossaryExplainsImportantVisibleTerms() {
    let requiredTerms: Set<String> = [
      "候補区間",
      "ピーク時刻",
      "合成スコア",
      "候補しきい値",
      "A・音声スコア",
      "B・映像スコア",
      "C・遷移スコア",
      "FFT",
      "RMS",
      "freeze",
      "dissolve",
      "fade",
      "GT",
      "fps",
      "出力フレーム数",
      "H.264",
      "HEVC",
      "sidecar JSON",
      "CSV"
    ]
    let terms = SceneExtractionTutorialContent.glossaryTerms
    let availableTerms = Set(terms.map(\.term))
    let explainedCategories = Set(terms.map(\.category))
    let requiredCategories = Set(
      SceneExtractionGlossaryCategory.allCases.filter { $0 != .all }
    )

    #expect(requiredTerms.isSubset(of: availableTerms))
    #expect(requiredCategories.isSubset(of: explainedCategories))
    #expect(terms.allSatisfy { !$0.shortDefinition.isEmpty && !$0.detail.isEmpty })
  }

  @Test
  func mergerFillsMissingAudioFeaturesWithZero() throws {
    let visualPoints = (0..<3).map { index in
      makeVisualPoint(time: Double(index), frameDiff: Double(index) * 0.1)
    }
    let transitionPoints = (0..<3).map { index in
      TransitionFeaturePoint(
        time: Double(index),
        freezeScore: Double(index) * 0.2,
        dissolveScore: 0,
        fadeScore: 0,
        editScore: 0
      )
    }

    let merged = try FeatureMerger().merge(
      audioPoints: [],
      visualPoints: visualPoints,
      transitionPoints: transitionPoints
    )

    #expect(merged.count == visualPoints.count)
    #expect(merged.allSatisfy { $0.audioBandEnergy == 0 })
    #expect(merged.allSatisfy { $0.audioRise == 0 })
    #expect(merged.allSatisfy { $0.audioDecay == 0 })
  }

  @Test
  func transitionAnalyzerRaisesFreezeScoreForConsecutiveStillFrames() throws {
    let visualPoints = (0..<5).map { index in
      makeVisualPoint(time: Double(index) / 8, frameDiff: 0.001)
    }

    let transitions = try TransitionAnalyzer().analyze(
      visualPoints: visualPoints,
      settings: AnalysisSettings()
    )

    #expect(transitions.first?.freezeScore == 0.25)
    #expect(transitions.last?.freezeScore == 1)
  }

  @Test
  func detectorKeepsSeparatedPeaksAndClampsClipToVideoBounds() throws {
    var settings = AnalysisSettings()
    settings.candidateThreshold = 0.6
    settings.minimumCandidateDistance = 8
    var features = (0..<16).map { index in
      makeFeature(time: Double(index), score: 0.1)
    }
    features[2].combinedScore = 0.8
    features[12].combinedScore = 0.9

    let candidates = try CandidateDetector().detect(
      features: features,
      duration: 16,
      settings: settings
    )

    #expect(candidates.count == 2)
    #expect(candidates[0].peakTime == 12)
    #expect(candidates[0].startTime == 6)
    #expect(candidates[0].endTime == 16)
    #expect(candidates[1].peakTime == 2)
    #expect(candidates[1].startTime == 0)
    #expect(candidates[1].endTime == 10)
  }

  @Test
  func exportSettingsRejectZeroFramesPerSecond() {
    var settings = AnalysisSettings()
    settings.targetFramesPerSecond = 0

    #expect(throws: AnalysisSettingsError.self) {
      try settings.validateForExport()
    }
  }

  @Test
  func clipExporterProducesExactFrameCount() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SceneExtractionExporterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appendingPathComponent("source.mp4")
    try await makeSyntheticVideo(at: sourceURL)

    let document = VideoDocument(
      url: sourceURL,
      duration: 2,
      nominalFrameRate: 30,
      resolutionWidth: 160,
      resolutionHeight: 90,
      hasAudioTrack: false,
      hasVideoTrack: true,
      audioSampleRate: nil,
      timeScale: 600
    )
    let candidate = CandidateSegment(
      startTime: 0,
      endTime: 2,
      peakTime: 1,
      score: 0.9,
      audioScore: 0,
      visualScore: 0.9,
      transitionScore: 0,
      reason: ["テスト"]
    )
    var settings = AnalysisSettings()
    settings.clipDuration = 2
    settings.peakLeadTime = 1
    settings.targetFramesPerSecond = 24
    settings.targetFrameCount = 49
    settings.includesAudio = false

    let result = try await ClipExporter().export(
      document: document,
      candidate: candidate,
      settings: settings,
      outputDirectory: temporaryDirectory
    )

    let exportedFrameCount = try await countVideoFrames(at: result.videoURL)
    #expect(exportedFrameCount == 49, "実フレーム数は\(exportedFrameCount)でした．")
    #expect(result.metadata.frameCount == 49)
    #expect(result.metadataURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
  }

  @Test
  func clipExporterCompletesWithAudioAndVideo() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SceneExtractionAudioExporterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let videoOnlyURL = temporaryDirectory.appendingPathComponent("video-only.mp4")
    let audioURL = temporaryDirectory.appendingPathComponent("audio.caf")
    let sourceURL = temporaryDirectory.appendingPathComponent("source-with-audio.mp4")
    try await makeSyntheticVideo(at: videoOnlyURL)
    try makeSilentAudio(at: audioURL, duration: 2)
    try await muxVideoAndAudio(
      videoURL: videoOnlyURL,
      audioURL: audioURL,
      outputURL: sourceURL,
      duration: 2
    )

    let document = VideoDocument(
      url: sourceURL,
      duration: 2,
      nominalFrameRate: 30,
      resolutionWidth: 160,
      resolutionHeight: 90,
      hasAudioTrack: true,
      hasVideoTrack: true,
      audioSampleRate: 48_000,
      timeScale: 600
    )
    let candidate = CandidateSegment(
      startTime: 0,
      endTime: 2,
      peakTime: 1,
      score: 0.9,
      audioScore: 0.9,
      visualScore: 0.9,
      transitionScore: 0,
      reason: ["音声付きテスト"]
    )
    var settings = AnalysisSettings()
    settings.clipDuration = 2
    settings.peakLeadTime = 1
    settings.targetFramesPerSecond = 24
    settings.targetFrameCount = 49
    settings.includesAudio = true

    let result = try await ClipExporter().export(
      document: document,
      candidate: candidate,
      settings: settings,
      outputDirectory: temporaryDirectory
    )
    let exportedAsset = AVURLAsset(url: result.videoURL)
    let videoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
    let audioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
    let fileSize = try #require(
      FileManager.default.attributesOfItem(atPath: result.videoURL.path)[.size] as? NSNumber
    )
    let partialFiles = try FileManager.default.contentsOfDirectory(
      at: temporaryDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".partial.mp4") }

    #expect(!videoTracks.isEmpty)
    #expect(!audioTracks.isEmpty)
    #expect(fileSize.int64Value > 0)
    #expect(partialFiles.isEmpty)
  }

  private func makeVisualPoint(time: Double, frameDiff: Double) -> VisualFeaturePoint {
    VisualFeaturePoint(
      time: time,
      frameDiff: frameDiff,
      meanLuminance: 0.5,
      luminanceDiff: frameDiff,
      edgeDiff: 0,
      motionSpike: 0,
      motionDrop: 0,
      zScore: 0
    )
  }

  private func makeFeature(time: Double, score: Double) -> FeatureVector {
    FeatureVector(
      time: time,
      audioBandEnergy: 0.8,
      audioRise: 0.7,
      audioDecay: 0.7,
      visualMotion: 0.8,
      visualSpike: 0.7,
      visualDrop: 0.7,
      freezeScore: 0.2,
      dissolveScore: 0,
      fadeScore: 0,
      editScore: 0,
      combinedScore: score
    )
  }

  private func makeSyntheticVideo(
    at url: URL, frameBrightness: [UInt8]? = nil, hasBlackBars: Bool = false
  ) async throws {
    let width = 160
    let height = 90
    let framesPerSecond: Int32 = 30
    let frameCount = frameBrightness?.count ?? 60
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
      ]
    )
    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<frameCount {
      // 書き込みが失敗したとき、または進まないまま長く待ったときは、理由をつけて失敗させる(待ち続けない)。
      let deadline = Date().addingTimeInterval(60)
      while !input.isReadyForMoreMediaData {
        try Task.checkCancellation()
        if writer.status == .failed || writer.status == .cancelled {
          throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        if Date() > deadline {
          writer.cancelWriting()
          throw TestVideoWriteStalled(frame: frameIndex, status: writer.status.rawValue)
        }
        try await Task.sleep(for: .milliseconds(2))
      }
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
      )
      guard status == kCVReturnSuccess, let pixelBuffer else {
        throw CocoaError(.fileWriteUnknown)
      }
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(
          baseAddress,
          Int32(frameBrightness?[frameIndex] ?? UInt8(frameIndex % 255)),
          CVPixelBufferGetDataSize(pixelBuffer)
        )
        if hasBlackBars {
          let barHeight = height / 3
          let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
          memset(baseAddress, 0, barHeight * rowBytes)
          memset(baseAddress.advanced(by: (height - barHeight) * rowBytes), 0, barHeight * rowBytes)
        }
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)
      // 追加できなかったとき(エンコーダーの失敗など)は、続けても受け付け可能にならないので、そこで失敗させる。
      guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
    }

    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }

  private func makeSilentAudio(at url: URL, duration: Double) throws {
    let sampleRate = 48_000.0
    let channelCount: AVAudioChannelCount = 2
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let format = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channelCount
      )
    )
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )
    )
    buffer.frameLength = frameCount
    if let channelData = buffer.floatChannelData {
      for channel in 0..<Int(channelCount) {
        channelData[channel].initialize(
          repeating: 0,
          count: Int(frameCount)
        )
      }
    }

    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: format.settings
    )
    try audioFile.write(from: buffer)
  }

  private func muxVideoAndAudio(
    videoURL: URL,
    audioURL: URL,
    outputURL: URL,
    duration: Double
  ) async throws {
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    let sourceVideoTrack = try #require(
      try await videoAsset.loadTracks(withMediaType: .video).first
    )
    let sourceAudioTrack = try #require(
      try await audioAsset.loadTracks(withMediaType: .audio).first
    )
    let composition = AVMutableComposition()
    let videoTrack = try #require(
      composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    )
    let audioTrack = try #require(
      composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    )
    let timeRange = CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
    try videoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
    try audioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
    let exportSession = try #require(
      AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetHighestQuality
      )
    )
    try await exportSession.export(to: outputURL, as: .mp4)
  }

  private func countVideoFrames(at url: URL) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    #expect(reader.canAdd(output))
    reader.add(output)
    #expect(reader.startReading())
    var frameCount = 0
    while let sampleBuffer = output.copyNextSampleBuffer() {
      frameCount += CMSampleBufferGetNumSamples(sampleBuffer)
    }
    return frameCount
  }
}
