// ArkServerTests/MusicVideoFullScreenPresenterTests.swift

import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import ArkServer

/// プレビューの全画面表示。アプリ本体の窓が macOS の全画面になっているときにも、画面いっぱいに出ることを確かめる。
/// (以前は macOS 標準の全画面を使っていて、本体が全画面だと、2つ目の窓は全画面に入れず、小さな窓のまま残った)
@MainActor
@Suite(.serialized, .enabled(if: NSScreen.main != nil, "画面のある環境だけ"))
struct MusicVideoFullScreenPresenterTests {
  /// 映像を作り終えた画面(曲の解析と、素材3本)。設定の保存先も置き場も、テスト専用にする。
  private func makeReadyViewModel(in directory: URL, suite: String) async throws -> (viewModel: MusicVideoViewModel, library: LibraryViewModel) {
    let defaults = try #require(UserDefaults(suiteName: suite))
    let musicURL = directory.appendingPathComponent("music.wav")
    try writeMonoWAV(
      samples: clickTrack(duration: 16, clicks: evenClicks(from: 0.25, interval: 0.5, until: 16).map { ($0, 0.8) }),
      sampleRate: testSampleRate,
      to: musicURL
    )
    var items: [VideoItem] = []
    for index in 0..<3 {
      let url = directory.appendingPathComponent("source\(index).mp4")
      try await makeTestVideo(at: url, duration: 6) { _ in UInt8(60 + index * 70) }
      items.append(VideoItem(
        id: UUID(), originalFilename: "source\(index).mp4", internalFilename: "", duration: 6,
        importDate: Date(), creationDate: nil, fileHash: "", mediaType: .video, externalFilePath: url.path
      ))
    }
    let library = LibraryViewModel(storageEnvironment: LibraryStorageEnvironment(
      moviesDirectory: { directory },
      downloadsDirectory: { nil },
      createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
    ))
    library.videos = items
    let viewModel = MusicVideoViewModel(preferencesStore: MusicVideoPreferencesStore(defaults: defaults))
    viewModel.attach(dataManager: library)
    viewModel.selectedVideoIDs = Set(items.map(\.id))
    viewModel.chooseMusic(musicURL)
    try await wait("曲の解析") { viewModel.fullAnalysis != nil && !viewModel.isWorking }
    viewModel.generate(dataManager: library)
    try await wait("映像の作成") { viewModel.phase == .ready && viewModel.plan != nil }
    viewModel.isMuted = true
    return (viewModel, library)
  }

  private func wait(_ label: String, timeout: Double = 60, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw WaitFailure(label: label) }
      try await Task.sleep(for: .milliseconds(40))
    }
  }

  private struct WaitFailure: Error, CustomStringConvertible {
    let label: String
    var description: String { "待っていた状態にならないまま時間切れ: \(label)" }
  }

  private func previewWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.title == "プレビュー" && $0.isVisible }
  }

  /// 本物のキーイベント（Esc）を、全画面の窓へ送る。
  private func pressEscape(in window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false, keyCode: 53
    ))
    NSApp.sendEvent(event)
  }

  @Test(.disabled(if: isRunningOnCIOrInVirtualMachine(), "画面のない仮想環境(CI)では、ウィンドウの操作が終わらず固まるため。手元の Mac では実行する"))
  func coversTheWholeScreenWhetherOrNotTheMainWindowIsFullScreen() async throws {
    let directory = try temporaryDirectory("fullscreen-presenter")
    let suite = "musicvideo-fullscreen-tests-\(UUID().uuidString)"
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let (viewModel, _) = try await makeReadyViewModel(in: directory, suite: suite)
    defer { viewModel.stopAllPlayback() }

    for mainIsFullScreen in [false, true] {
      let label = mainIsFullScreen ? "本体が全画面" : "本体が通常"
      let presenter = MusicVideoFullScreenPresenter()
      let main = NSWindow(
        contentRect: CGRect(x: 100, y: 100, width: 800, height: 450),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
      )
      main.isReleasedWhenClosed = false
      main.collectionBehavior = [.fullScreenPrimary]
      main.contentView = NSHostingView(rootView: MusicVideoPlayerPane(viewModel: viewModel) { presenter.present(viewModel: viewModel) })
      main.makeKeyAndOrderFront(nil)
      if mainIsFullScreen {
        main.toggleFullScreen(nil)
        try await wait("本体の全画面") { main.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .seconds(1))
      }

      viewModel.seek(to: 0)
      viewModel.togglePlayback()
      try await Task.sleep(for: .milliseconds(500))
      #expect(viewModel.isPlaying, "\(label): 再生中")

      let before = Set(previewWindows().map(\.windowNumber))
      presenter.present(viewModel: viewModel)
      try await Task.sleep(for: .seconds(1))
      let window = try #require(previewWindows().first { !before.contains($0.windowNumber) }, "\(label): 全画面の窓が出る")
      let screenFrame = try #require((window.screen ?? NSScreen.main)?.frame)
      #expect(presenter.isPresented, "\(label)")
      #expect(window.frame == screenFrame, "\(label): 画面ぴったりを覆う（\(window.frame) / \(screenFrame)）")
      #expect(window.level.rawValue > NSWindow.Level.mainMenu.rawValue, "\(label): メニューバーより上")
      // キーウィンドウ・実際に見えているか、は、アプリが前面にいて画面が点いているときだけ成り立つ（画面スリープ中などは判定できない）。
      let isForeground = NSApp.isActive && window.occlusionState.contains(.visible)
      if isForeground {
        #expect(window.isKeyWindow, "\(label): キー入力を受ける")
      }
      #expect(viewModel.isPlaying, "\(label): 全画面にしても再生が続く")

      try pressEscape(in: window)
      try await Task.sleep(for: .seconds(1))
      #expect(!presenter.isPresented, "\(label): Esc で閉じる")
      #expect(!window.isVisible, "\(label): 閉じた窓は見えない")
      if isForeground {
        #expect(main.isKeyWindow, "\(label): 元の窓へ操作が戻る")
      }
      #expect(viewModel.isPlaying, "\(label): 閉じても再生が続く")

      viewModel.pausePlayback()
      if main.styleMask.contains(.fullScreen) {
        main.toggleFullScreen(nil)
        try await wait("本体の全画面を戻す") { !main.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .seconds(1))
      }
      main.close()
    }
  }

  @Test
  func doesNothingUntilTheVideoIsReady() throws {
    // 映像ができていないときは、全画面を開かない。
    let suite = "musicvideo-fullscreen-empty-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let viewModel = MusicVideoViewModel(preferencesStore: MusicVideoPreferencesStore(defaults: defaults))
    let presenter = MusicVideoFullScreenPresenter()
    presenter.present(viewModel: viewModel)
    #expect(!presenter.isPresented)
  }
}
