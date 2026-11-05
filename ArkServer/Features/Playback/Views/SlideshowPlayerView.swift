import Foundation
import SwiftUI
import AVKit
import AVFoundation

// MARK: - Slideshow playback (3-C)
// 選択した複数の動画を指定秒数ずつ切り出して1本のスライドショーとして連続再生する。
// クリップ単位のチャプターをサイドバーに表示し、クリックで該当クリップへジャンプできる。

/// 生成状態を管理し、準備ができたらプレイヤーを表示するラッパーView
struct SlideshowPlayerView: View {
    let videos: [VideoItem]
    let dataManager: LibraryViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    private enum Phase {
        case setup
        case loading
        case playing(SlideshowGenerationResult)
        case error(String)
    }

    @State private var phase: Phase = .setup
    @State private var clipDuration: Double = 15

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .setup:
                setupForm
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("スライドショーを生成中...").foregroundStyle(.white)
                }
            case .playing(let result):
                SlideshowContentView(
                    playerItem: result.playerItem,
                    videos: videos,
                    clipDurations: result.clipDurations,
                    dataManager: dataManager
                )
            case .error(let message):
                VStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").font(.appLargeTitle).foregroundStyle(.red)
                    Text(message).foregroundStyle(.white).padding()
                    Button("閉じる") { coordinator.close() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setupForm: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                Text("スライドショー")
                    .font(.appTitle.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(videos.count)本の動画から各クリップを切り出して連続再生します")
                    .font(.appBody)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(spacing: 8) {
                HStack {
                    Text("1クリップの長さ")
                    Spacer()
                    Text("\(Int(clipDuration))秒").monospacedDigit()
                }
                .foregroundStyle(.white)
                Slider(value: $clipDuration, in: 1...60, step: 1)
            }
            .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button("キャンセル") { coordinator.close() }
                    .keyboardShortcut(.cancelAction)
                Button("開始") { startGeneration() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AppActionButtonStyle(isPrimary: true))
            }
        }
        .padding(40)
    }

    private func startGeneration() {
        phase = .loading
        let seconds = clipDuration
        Task {
            do {
                let result = try await SlideshowGenerator.generate(from: videos, clipDuration: seconds, dataManager: dataManager)
                phase = .playing(result)
            } catch {
                phase = .error("スライドショーの生成に失敗しました: \(error.localizedDescription)")
            }
        }
    }
}

/// チャプターリストの各行（サムネイル付き）
private struct SlideshowChapterRow: View {
    let chapter: SlideshowChapter
    @State private var thumbnail: Image?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.2))
                if let thumbnail = thumbnail { thumbnail.resizable() }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .cornerRadius(4)
            .clipped()

            Text(chapter.title).font(.appCaption).lineLimit(2)
        }
        .padding(.vertical, 4)
        .task(id: chapter.id) { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        guard thumbnail == nil, let url = chapter.sourceURL else { return }
        let asset = AVURLAsset(url: url)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        if let cgImage = await PlayerThumbnailGenerator.generateLiveThumbnail(for: asset, at: time) {
            thumbnail = Image(cgImage, scale: 1.0, label: Text("Chapter Thumbnail"))
        }
    }
}

/// 実際のプレイヤーと操作ロジックを持つView
private struct SlideshowContentView: View {
    @StateObject private var viewModel: SlideshowPlayerViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @FocusState private var isFocused: Bool

    @State private var selectedChapterID: UUID?
    @State private var isSidebarVisible = false
    @State private var showShortcutHelp = false
    /// 隅のボタンの出し入れ（他のプレイヤーと共通）。
    /// シークバーは AVKit 標準のものがそれ自体で隠れるので、ここでは触らない。
    @StateObject private var chrome = PlayerChromeController()
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    private let sidebarWidth: CGFloat = 250
    private let triggerWidth: CGFloat = 20

    init(playerItem: AVPlayerItem, videos: [VideoItem], clipDurations: [TimeInterval], dataManager: LibraryViewModel) {
        _viewModel = StateObject(wrappedValue: SlideshowPlayerViewModel(
            playerItem: playerItem, videos: videos, clipDurations: clipDurations, dataManager: dataManager
        ))
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoClose,
                .videoPlayPause,
                .videoSeekBack15,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoSeekForward15,
                .videoRandomSeek
            ],
            extraItems: [
                ("0〜9", "全体の 0%〜90% の位置へジャンプ"),
                ("?", "ショートカット一覧を表示"),
                ("画面左端にマウス", "チャプター一覧を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            PlayerContainerView(player: viewModel.player)
                .ignoresSafeArea()

            List(viewModel.chapters, selection: $selectedChapterID) { chapter in
                SlideshowChapterRow(chapter: chapter).tag(chapter.id)
            }
            .frame(width: sidebarWidth)
            .background(Color(white: 0.07))
            .offset(x: isSidebarVisible ? 0 : -sidebarWidth + triggerWidth)
            .onHover { hovering in isSidebarVisible = hovering }

            if chrome.isShown {
                VStack {
                    HStack {
                        Spacer()
                        PlayerCornerControls(showShortcutHelp: $showShortcutHelp) {
                            coordinator.close()
                        }
                        .playerChromeHoverGuard(chrome)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }

            if showShortcutHelp {
                ShortcutHelpPanel(title: "スライドショーのショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
        .playerChromeActivity(chrome)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            chrome.reveal()
        }
        .onChange(of: showShortcutHelp) { _, shown in
            chrome.setHold(.overlayVisible, shown)
        }
        // チャプター一覧を出している間は、隅のボタンも一緒に残しておく。
        .onChange(of: isSidebarVisible) { _, shown in
            chrome.setHold(.pointerOverControls, shown)
        }
        .onDisappear {
            chrome.cancel()
            viewModel.cleanup()
        }
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onChange(of: selectedChapterID) { _, newID in
            guard let newID = newID, let chapter = viewModel.chapters.first(where: { $0.id == newID }) else { return }
            if abs(viewModel.player.currentTime().seconds - chapter.startTime) > 1 {
                viewModel.seek(to: chapter)
            }
        }
        .onChange(of: viewModel.currentChapterID) { _, newID in
            withAnimation { selectedChapterID = newID }
        }
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if MediaShortcutSettings.matches(.videoClose, press: press) {
            coordinator.close()
            return .handled
        }

        if let digit = press.key.character.wholeNumberValue {
            viewModel.seek(toPercentage: Double(digit) / 10.0)
            return .handled
        }
        switch press.key {
        case .escape:
            if showShortcutHelp { showShortcutHelp = false } else { coordinator.close() }
            return .handled
        case "?":
            showShortcutHelp.toggle()
            return .handled
        case .space:
            if press.modifiers.contains(.option) {
                coordinator.close()
                return .handled
            }
            break
        default:
            break
        }

        if MediaShortcutSettings.matches(.videoPlayPause, press: press) {
            viewModel.playPause()
            return .handled
        } else if MediaShortcutSettings.matches(.videoRandomSeek, press: press) {
            viewModel.seekToRandomTime()
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack15, press: press) {
            viewModel.seek(by: -15)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack10, press: press) {
            viewModel.seek(by: -10)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekBack5, press: press) {
            viewModel.seek(by: -5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward5, press: press) {
            viewModel.seek(by: 5)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward10, press: press) {
            viewModel.seek(by: 10)
            return .handled
        } else if MediaShortcutSettings.matches(.videoSeekForward15, press: press) {
            viewModel.seek(by: 15)
            return .handled
        }

        return .ignored
    }
}
