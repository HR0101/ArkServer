import Foundation
import SwiftUI
import AVKit
import Combine
import AppKit

// MARK: - Single playback (3-A)
// 通常再生モード: 自動チャプターサイドバー / 充実したシーク操作 / 前後の動画へ移動。
// データモデルはサーバーアプリの VideoItem + LibraryViewModel.fileURL(for:) に合わせて移植している。

/// サイドバーの各チャプター行
private struct ChapterRow: View {
    let chapter: ChapterPoint
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                (chapter.thumbnail ?? Image(systemName: "film"))
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(4)
                Text(chapter.timeString)
                    .font(.appCaption.monospacedDigit())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PlaybackVideoStrip: View {
    let videos: [VideoItem]
    let dataManager: LibraryViewModel
    let onSelect: (VideoItem) -> Void
    let onClose: () -> Void

    private let thumbnailWidth: CGFloat = 220
    private let thumbnailHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("他の動画")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PlayerChrome.icon)
                Spacer()
                PlayerRoundButton(systemImage: "xmark", help: "動画一覧を閉じる", action: onClose)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(videos) { video in
                        PlaybackVideoThumbnailButton(
                            video: video,
                            thumbnailURL: thumbnailURL(for: video),
                            width: thumbnailWidth,
                            height: thumbnailHeight
                        ) {
                            onSelect(video)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(16)
        .playerPanel()
        .padding(.horizontal, 30)
    }

    private func thumbnailURL(for video: VideoItem) -> URL {
        dataManager.thumbnailStorageURL
            .appendingPathComponent(video.id.uuidString)
            .appendingPathExtension("jpg")
    }
}

private struct PlaybackVideoThumbnailButton: View {
    let video: VideoItem
    let thumbnailURL: URL
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                thumbnailImage

                LinearGradient(
                    colors: [.clear, .black.opacity(0.68)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(displayName)
                    .font(.appCaption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .opacity(0.84)
        }
        .buttonStyle(.plain)
        .help(displayName)
        .task(id: video.id) {
            await loadThumbnail()
        }
    }

    private var thumbnailImage: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.black.opacity(0.35))
                    Image(systemName: "film")
                        .font(.appTitle)
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
        }
    }

    private var displayName: String {
        (video.originalFilename as NSString).deletingPathExtension
    }

    private func loadThumbnail() async {
        let url = thumbnailURL
        let loadedThumbnail: NSImage? = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        guard let loadedThumbnail else { return }
        thumbnail = loadedThumbnail
    }
}

/// 関連動画パネルの1行（YouTubeの「次の動画」リストと同じ、サムネイル＋タイトルの横並び）。
private struct UpNextVideoRow: View {
    let video: VideoItem
    let thumbnailURL: URL
    let action: () -> Void

    @State private var thumbnail: NSImage?

    private let thumbnailWidth: CGFloat = 158
    private let thumbnailHeight: CGFloat = 89

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    thumbnailImage
                        .frame(width: thumbnailWidth, height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text(durationString)
                        .font(.appMicro.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }

                Text(displayName)
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)

                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(displayName)
        .task(id: video.id) {
            await loadThumbnail()
        }
    }

    private var thumbnailImage: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "film")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private var displayName: String {
        (video.originalFilename as NSString).deletingPathExtension
    }

    private var durationString: String {
        let totalSeconds = Int(video.duration)
        guard totalSeconds >= 0 else { return "0:00" }
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func loadThumbnail() async {
        let url = thumbnailURL
        let loadedThumbnail: NSImage? = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        guard let loadedThumbnail else { return }
        thumbnail = loadedThumbnail
    }
}

private struct ScrollWheelDetector: NSViewRepresentable {
    let onVerticalScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelDetectorView {
        let view = ScrollWheelDetectorView()
        view.onVerticalScroll = onVerticalScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelDetectorView, context: Context) {
        nsView.onVerticalScroll = onVerticalScroll
    }
}

private final class ScrollWheelDetectorView: NSView {
    var onVerticalScroll: ((CGFloat) -> Void)?
    private var eventMonitor: Any?

    deinit {
        removeEventMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitor()
        } else {
            installEventMonitor()
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else { return event }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            self.onVerticalScroll?(event.scrollingDeltaY)
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// 数字キー(0〜9)による位置ジャンプ用の検出ビュー。
/// SwiftUIの.onKeyPressは再生ボタンなどをクリックした後にフォーカスがそちらへ移ると
/// 反応しなくなるため、ScrollWheelDetectorと同じくウィンドウレベルのイベント監視で拾う。
private struct DigitSeekDetector: NSViewRepresentable {
    let onDigit: (Int) -> Void

    func makeNSView(context: Context) -> DigitSeekDetectorView {
        let view = DigitSeekDetectorView()
        view.onDigit = onDigit
        return view
    }

    func updateNSView(_ nsView: DigitSeekDetectorView, context: Context) {
        nsView.onDigit = onDigit
    }
}

private final class DigitSeekDetectorView: NSView {
    var onDigit: ((Int) -> Void)?
    private var eventMonitor: Any?

    deinit {
        removeEventMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitor()
        } else {
            installEventMonitor()
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            guard let characters = event.charactersIgnoringModifiers,
                  characters.count == 1,
                  let digit = characters.first?.wholeNumberValue else { return event }

            self.onDigit?(digit)
            return nil
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

struct VideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel
    private let dataManager: LibraryViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var remotePlaybackSession: RemotePlaybackSession

    @FocusState private var isViewFocused: Bool
    @State private var isSidebarVisible = false
    @State private var isVideoStripVisible = false
    @State private var showShortcutHelp = false
    @State private var areCornerControlsVisible = false
    @State private var cornerControlsActivityID = UUID()
    @State private var isUpNextPanelVisible = false
    @State private var isMiniControlsVisible = false
    // マウスドラッグで範囲選択してその領域へズームする状態。
    @State private var videoZoom = MarqueeZoomState()
    @State private var videoMarqueeStart: CGPoint?
    @State private var videoMarqueeCurrent: CGPoint?
    @AppStorage(MediaShortcutSettings.versionKey) private var shortcutSettingsVersion = 0
    /// 自動再生・リピート・シャッフル・再生速度。ViewModel が持つのと同じ実体。
    @ObservedObject private var settings: PlaybackSettings
    /// 他アプリの上に浮かぶ小窓（ミニプレイヤーとは別物）。
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    /// シークバーをなぞっている位置のプレビュー。
    @StateObject private var scrubPreview = ScrubPreviewGenerator()
    /// なぞっている位置（0...1）。なぞっていなければ nil。
    @State private var scrubHoverFraction: Double?
    @State private var seekBarWidth: CGFloat = 0
    private let sidebarWidth: CGFloat = 240
    private let triggerWidth: CGFloat = 10
    private let upNextPanelWidth: CGFloat = 360
    private let miniPlayerWidth: CGFloat = 300
    private let miniPlayerHeight: CGFloat = 169
    private let cornerControlsAutoHideNanoseconds: UInt64 = 2_500_000_000
    private let playbackControlsMaxWidth: CGFloat = 780
    private let playbackControlsHorizontalPadding: CGFloat = 28
    private let playbackControlsBottomPadding: CGFloat = 24
    private let playbackControlButtonWidth: CGFloat = 26
    /// キー1打ちで動かす音量の幅。20回で無音から最大まで届く。
    private let volumeStep: Float = 0.05
    private let minimumSliderDuration: Double = 0.1
    private let videoStripScrollThreshold: CGFloat = 2
    private let secondsPerMinute = 60
    private let secondsPerHour = 3_600
    private let scrubPreviewWidth: CGFloat = 168
    private let scrubPreviewHeight: CGFloat = 95
    /// 札の総高さ（画像＋時刻＋余白）＋シークバーとの間隔。
    private let scrubPreviewTotalHeight: CGFloat = 138

    init(
        videos: [VideoItem],
        currentVideo: VideoItem,
        dataManager: LibraryViewModel,
        watchState: WatchStateStore,
        settings: PlaybackSettings,
        initialStartTime: Double? = nil
    ) {
        self.dataManager = dataManager
        _settings = ObservedObject(wrappedValue: settings)
        _viewModel = StateObject(
            wrappedValue: VideoPlayerViewModel(
                videos: videos,
                currentVideo: currentVideo,
                dataManager: dataManager,
                watchState: watchState,
                settings: settings,
                initialStartTime: initialStartTime
            )
        )
    }

    private var shortcutList: [(key: String, action: String)] {
        _ = shortcutSettingsVersion
        return MediaShortcutSettings.shortcutList(
            for: [
                .videoClose,
                .videoPlayPause,
                .videoPreviousItem,
                .videoNextItem,
                .videoSeekBack15,
                .videoSeekBack10,
                .videoSeekBack5,
                .videoSeekForward5,
                .videoSeekForward10,
                .videoSeekForward15,
                .videoRandomSeek,
                .videoToggleUpNextPanel,
                .videoToggleMiniPlayer,
                .videoToggleShuffle,
                .videoCycleRepeat,
                .videoRateDown,
                .videoRateUp,
                .videoTogglePictureInPicture,
                .videoVolumeUp,
                .videoVolumeDown,
                .videoToggleMute,
                .videoToggleFavorite,
                .videoStepBackward,
                .videoStepForward,
                .videoToggleFillScreen
            ],
            extraItems: [
                ("0〜9", "動画の 0%〜90% の位置へジャンプ"),
                ("?", "ショートカット一覧を表示"),
                ("画面左端にマウス", "10分割サムネイルを表示"),
                ("下スクロール", "他の動画を表示"),
                ("Esc", "プレイヤーを閉じる")
            ]
        )
    }

    var body: some View {
        Group {
            if coordinator.isMiniPlayerActive {
                miniPlayerView
            } else {
                fullPlayerView
            }
        }
        .onAppear {
            isViewFocused = true
            areCornerControlsVisible = false
            isVideoStripVisible = false
            isUpNextPanelVisible = false
            remotePlaybackSession.attach(viewModel)
            viewModel.setupPlayer()
        }
        // setupPlayer は次のループでプレイヤーを作るので、素材はそれを待ってから掴む。
        .onChange(of: viewModel.player == nil) { _, isMissing in
            guard !isMissing else { return }
            scrubPreview.prepare(asset: viewModel.currentAsset, videoID: viewModel.currentVideo.id)
        }
        .onChange(of: viewModel.currentVideo.id) { _, _ in
            videoZoom.reset()
            scrubHoverFraction = nil
            scrubPreview.prepare(asset: viewModel.currentAsset, videoID: viewModel.currentVideo.id)
        }
        // 一時停止したまま離席したときに画面が点きっぱなしにならないよう、
        // 実際の再生状態をコーディネーター（スリープ抑止の持ち主）へ伝える。
        .onChange(of: viewModel.isPlaybackPlaying) { _, isPlaying in
            coordinator.setPlaybackActive(isPlaying)
        }
        .onDisappear {
            remotePlaybackSession.detach(viewModel)
            // 小窓だけ残すと、止める手立てのない再生が居座る。
            pictureInPicture.detach()
            viewModel.cleanup()
        }
    }

    /// 通常のフルサイズ再生画面。
    private var fullPlayerView: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                videoPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isUpNextPanelVisible {
                    upNextPanel
                        .frame(width: upNextPanelWidth, alignment: .top)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            // 再生中の動画名。タイトルバーが出ない画面なので，ここに出さないと何を見ているか分からない。
            // 右上の操作と同じタイミングで出し入れし，右側は操作群と重ならないよう空けておく。
            Text(viewModel.currentVideo.originalFilename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PlayerChrome.icon)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .playerPanel(cornerRadius: 16)
                .padding()
                .padding(.top, PlayerCornerControls.titlebarClearance)
                .padding(.trailing, 300)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(areCornerControlsVisible || showShortcutHelp ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!(areCornerControlsVisible || showShortcutHelp))

            // シークバーと同じく，カーソル操作中だけ右上の補助操作を表示する。
            // パネルの開閉に関わらず常にウィンドウ右上端に留める。
            // 条件付きで挿入すると，隠れている間に右上の × を押しても「表示するだけ」で閉じられない。
            // 常に置いたまま透明度だけ切り替え，見えていなくても押せるようにする。
            PlayerCornerControls(
                showShortcutHelp: $showShortcutHelp,
                volume: $viewModel.volume,
                isMuted: $viewModel.isMuted
            ) {
                coordinator.close()
            }
            .opacity(areCornerControlsVisible || showShortcutHelp ? 1 : 0)

            if let notice = viewModel.resumeNotice
                ?? (viewModel.isAnalyzingLoopEdges ? viewModel.loopAnalysisNotice : nil) {
                resumeNoticeBadge(notice)
            }

            if showShortcutHelp {
                ShortcutHelpPanel(title: "通常再生のショートカット", shortcuts: shortcutList) {
                    showShortcutHelp = false
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isViewFocused)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealCornerControls()
            case .ended:
                hideCornerControls()
            }
        }
        .task(id: cornerControlsActivityID) {
            try? await Task.sleep(nanoseconds: cornerControlsAutoHideNanoseconds)
            guard !Task.isCancelled, !showShortcutHelp else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                areCornerControlsVisible = false
            }
        }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    /// Iキーで切り替える、右下に小さく表示するミニプレイヤー。
    /// アルバム一覧側を操作できるよう、キーボードフォーカスは奪わない。
    private var miniPlayerView: some View {
        ZStack(alignment: .bottom) {
            Color.black
            PlayerLayerContainerView(player: viewModel.player, videoGravity: viewModel.videoGravity)

            if isMiniControlsVisible {
                HStack(spacing: 8) {
                    Button {
                        viewModel.playPause()
                    } label: {
                        Image(systemName: viewModel.isPlaybackPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.isPlaybackPlaying ? "一時停止" : "再生")

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            coordinator.isMiniPlayerActive = false
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help("フルスクリーンに戻す")

                    Button {
                        coordinator.close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .help("閉じる")
                }
                .padding(8)
            }
        }
        .frame(width: miniPlayerWidth, height: miniPlayerHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isMiniControlsVisible = hovering }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) {
                coordinator.isMiniPlayerActive = false
            }
        }
        .padding(20)
    }

    /// 動画本体・シークバー・チャプターサイドバーをまとめた左側のペイン。
    /// 関連動画パネルが開くとこのペインだけが幅を縮めて左に寄る。
    private var videoPane: some View {
        ZStack(alignment: .leading) {
            ZStack {
                Color.black
                // AVKit標準コントロールは表示時に動画全体を暗くするため使わず、
                // 下部に独自のシークバーを重ねる。
                PlayerLayerContainerView(
                    player: viewModel.player,
                    videoGravity: viewModel.videoGravity
                ) { layer in
                    pictureInPicture.attach(playerLayer: layer)
                }
                .scaleEffect(x: videoZoom.scaleX, y: videoZoom.scaleY, anchor: .topLeading)
                .offset(videoZoom.offset)

                // マウスドラッグで範囲選択→その領域へズーム。ズーム中のクリックでフィット表示へ戻す。
                // 独自コントロール（シークバー等）はこの ZStack の外側にあるため、当たり判定は奪わない。
                GeometryReader { geo in
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                marqueeZoomGesture(start: $videoMarqueeStart, current: $videoMarqueeCurrent, containerSize: geo.size) { rect in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        videoZoom.zoom(into: rect, containerSize: geo.size)
                                    }
                                }
                            )
                            .onTapGesture {
                                if videoZoom.isZoomed {
                                    withAnimation(.easeInOut(duration: 0.2)) { videoZoom.reset() }
                                }
                            }
                        if let s = videoMarqueeStart, let c = videoMarqueeCurrent {
                            MarqueeRectangleShape(start: s, current: c)
                        }
                    }
                }
            }
            // ここでは切り抜かない。動画本体（AVPlayerView）を直に囲むクリップは
            // 再生中フレームごとのオフスクリーン描画を招きやすく、ズーム範囲の切り抜きは
            // 外側の videoPane 側の .clipped() が同じ範囲で担ってくれる。
            sidebar

            ScrollWheelDetector { deltaY in
                handlePlaybackScroll(deltaY: deltaY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // 再生・前後移動などのボタンをクリックするとSwiftUIのフォーカスがそちらへ移り、
            // .onKeyPress側の数字キー判定が届かなくなるため、ウィンドウレベルのイベント監視で拾う。
            DigitSeekDetector { digit in
                viewModel.seek(toPercentage: Double(digit) / 10.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            if areCornerControlsVisible || showShortcutHelp || isVideoStripVisible {
                VStack(spacing: 10) {
                    Spacer()
                    if isVideoStripVisible {
                        videoSelectionStrip
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if areCornerControlsVisible || showShortcutHelp {
                        playbackControls
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
    }

    /// 前回の続きから始まったことを数秒だけ知らせる札。
    /// 何も出さずに途中から再生すると、不具合と区別がつかない。
    private func resumeNoticeBadge(_ notice: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text(notice)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(PlayerChrome.icon)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .playerPanel(cornerRadius: 17)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// Tキーで開閉する、YouTubeの「次の動画」風の同じアルバムの動画一覧パネル。
    private var upNextPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("同じアルバムの動画")
                .font(.appBody.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 12)

            if viewModel.otherVideos.isEmpty {
                Spacer()
                Text("他に動画がありません")
                    .font(.appCaption)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.otherVideos) { video in
                            UpNextVideoRow(
                                video: video,
                                thumbnailURL: thumbnailURL(for: video)
                            ) {
                                viewModel.playVideo(video)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
        }
    }

    private func thumbnailURL(for video: VideoItem) -> URL {
        dataManager.thumbnailStorageURL
            .appendingPathComponent(video.id.uuidString)
            .appendingPathExtension("jpg")
    }

    /// カーソル移動が続くたびに自動非表示タイマーを更新する。
    private func revealCornerControls() {
        if !areCornerControlsVisible {
            withAnimation(.easeOut(duration: 0.16)) {
                areCornerControlsVisible = true
            }
        }
        cornerControlsActivityID = UUID()
    }

    /// マウスカーソルがウィンドウ外（別スクリーンなど）へ出たら即座にシークバーを閉じる。
    private func hideCornerControls() {
        guard areCornerControlsVisible, !showShortcutHelp else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            areCornerControlsVisible = false
        }
    }

    private func handlePlaybackScroll(deltaY: CGFloat) {
        guard abs(deltaY) >= videoStripScrollThreshold else { return }
        revealCornerControls()
        guard !viewModel.otherVideos.isEmpty else { return }
        if !isVideoStripVisible {
            withAnimation(.easeOut(duration: 0.18)) {
                isVideoStripVisible = true
            }
        }
    }

    /// AVKit標準の暗転を避けるための通常再生用コントロール。
    private var playbackControls: some View {
        HStack(spacing: 10) {
            PlayerIconButton(
                systemImage: "backward.end",
                help: "前の動画",
                accessibilityLabel: "前の動画"
            ) {
                viewModel.playPreviousVideo()
            }
            .disabled(!viewModel.canPlayPreviousVideo)

            // 主役の再生/一時停止だけを白い丸にして目立たせる。
            PlayerPlayButton(
                isPlaying: viewModel.isPlaybackPlaying,
                help: viewModel.isPlaybackPlaying ? "一時停止（Space）" : "再生（Space）"
            ) {
                viewModel.playPause()
            }

            PlayerIconButton(
                systemImage: "forward.end",
                help: "次の動画",
                accessibilityLabel: "次の動画"
            ) {
                viewModel.playNextVideo()
            }
            .disabled(!viewModel.canPlayNextVideo)

            StockMomentButton(video: viewModel.currentVideo, time: viewModel.currentTime,
              duration: viewModel.duration, dataManager: dataManager, compact: true)

            Text(formatTime(viewModel.currentTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(PlayerChrome.iconMuted)
                .frame(minWidth: 48, alignment: .trailing)

            Slider(
                value: $viewModel.currentTime,
                in: 0...max(viewModel.duration, minimumSliderDuration)
            ) { isEditing in
                viewModel.playbackSliderEditingChanged(isEditing: isEditing)
            }
            .tint(.white.opacity(0.92))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { seekBarWidth = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleSeekBarHover(phase)
            }
            .overlay(alignment: .topLeading) {
                if let fraction = scrubHoverFraction, seekBarWidth > 0 {
                    scrubPreviewCard
                        .offset(x: scrubPreviewOffsetX(for: fraction), y: -scrubPreviewTotalHeight)
                }
            }

            Text(formatTime(viewModel.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(PlayerChrome.iconMuted)
                .frame(minWidth: 48, alignment: .leading)

            Rectangle()
                .fill(PlayerChrome.panelBorder)
                .frame(width: 1, height: 16)

            PlayerIconButton(
                systemImage: "shuffle",
                isActive: settings.isShuffleEnabled,
                help: settings.isShuffleEnabled ? "シャッフル: オン" : "シャッフル: オフ",
                accessibilityLabel: "シャッフル"
            ) {
                settings.isShuffleEnabled.toggle()
            }

            PlayerIconButton(
                systemImage: settings.repeatMode.symbolName,
                isActive: settings.repeatMode != .off,
                help: viewModel.loopAnalysisNotice ?? settings.repeatMode.title,
                accessibilityLabel: settings.repeatMode.title
            ) {
                settings.repeatMode = settings.repeatMode.next
            }

            PlayerIconButton(
                systemImage: viewModel.isCurrentVideoFavorite ? "heart.fill" : "heart",
                isActive: viewModel.isCurrentVideoFavorite,
                help: viewModel.isCurrentVideoFavorite ? "お気に入りから外す" : "お気に入りに追加",
                accessibilityLabel: "お気に入り"
            ) {
                viewModel.toggleCurrentVideoFavorite()
            }

            PlayerIconButton(
                systemImage: viewModel.fillsScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                isActive: viewModel.fillsScreen,
                help: viewModel.fillsScreen ? "全体が収まる表示に戻す" : "画面いっぱいに広げる（黒帯を切り落とす）",
                accessibilityLabel: "画面いっぱい"
            ) {
                viewModel.toggleFillsScreen()
            }

            if PictureInPictureCoordinator.isSupported {
                PlayerIconButton(
                    systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                    isActive: pictureInPicture.isActive,
                    help: pictureInPicture.isActive ? "小窓をやめて戻す" : "ピクチャインピクチャ（P）",
                    accessibilityLabel: "ピクチャインピクチャ"
                ) {
                    pictureInPicture.toggle()
                }
                .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
            }

            playbackOptionsMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: playbackControlsMaxWidth)
        .playerPanel()
        // 暗い面に白で組むので、スライダーやメニューも暗い外観で描かせる。
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, playbackControlsHorizontalPadding)
        .padding(.bottom, playbackControlsBottomPadding)
    }

    /// 再生速度と自動再生。ボタンを並べるには数が多いのでメニューにまとめる。
    private var playbackOptionsMenu: some View {
        AppChoiceMenu {
            AppChoicePicker("再生速度", selection: rateBinding) {
                ForEach(PlaybackSettings.availableRates, id: \.self) { value in
                    Text(PlaybackSettings.label(forRate: value)).tag(value)
                }
            }


            // トラックが1つしかない動画にまで選択 UI を出しても選ぶものがない。
            if viewModel.audioTracks.count > 1 {
                Divider()
                AppChoicePicker("音声", selection: audioTrackBinding) {
                    ForEach(viewModel.audioTracks) { track in
                        Text(track.displayName).tag(track.index)
                    }
                }
            }

            if !viewModel.subtitleTracks.isEmpty {
                Divider()
                AppChoicePicker("字幕", selection: subtitleTrackBinding) {
                    ForEach(viewModel.subtitleTracks) { track in
                        Text(track.displayName).tag(track.index)
                    }
                }
            }

            Divider()

            Toggle("終わったら次の動画へ", isOn: $settings.autoPlayNext)
        } label: {
            HStack(spacing: 4) {
                if viewModel.selectedSubtitleIndex != VideoPlayerViewModel.MediaTrackChoice.offIndex {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 11, weight: .regular))
                }
                Text(settings.rateLabel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(PlayerChrome.icon)
            .padding(.horizontal, 6)
            .frame(height: 30)
        }

        // メニューの文字がアクセントの青になるのを避け、他のボタンと同じ白にそろえる。
        .tint(PlayerChrome.icon)
        .fixedSize()
        .help("再生速度・音声・字幕・自動再生")
        .accessibilityLabel("再生の設定")
    }

    /// なぞっている位置のプレビュー札。画像が来るまでは時刻だけ出す
    /// （出す/出さないを画像の有無で切り替えると、なぞるたびに札が点滅する）。
    private var scrubPreviewCard: some View {
        VStack(spacing: 4) {
            Group {
                if let image = scrubPreview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.black.opacity(0.55))
                }
            }
            .frame(width: scrubPreviewWidth, height: scrubPreviewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )

            Text(formatTime(hoveredSeconds ?? 0))
                .font(.appMicro.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(5)
        .playerPanel(cornerRadius: 8)
        .allowsHitTesting(false)
    }

    /// なぞっている位置の秒数（プレビュー画像の実際の位置ではなく、カーソルが指している位置）。
    private var hoveredSeconds: Double? {
        guard let fraction = scrubHoverFraction else { return nil }
        return fraction * max(viewModel.duration, 0)
    }

    /// 札の中心をカーソルに合わせつつ、シークバーの端からはみ出さないように寄せる。
    private func scrubPreviewOffsetX(for fraction: Double) -> CGFloat {
        let cardWidth = scrubPreviewWidth + 10
        let centered = seekBarWidth * fraction - cardWidth / 2
        return min(max(centered, 0), max(seekBarWidth - cardWidth, 0))
    }

    private func handleSeekBarHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            // 操作系の表示維持は外側の onContinuousHover が既に担っている。
            guard seekBarWidth > 0, viewModel.duration > minimumSliderDuration else { return }
            let fraction = min(max(location.x / seekBarWidth, 0), 1)
            scrubHoverFraction = fraction
            scrubPreview.request(seconds: fraction * viewModel.duration)
        case .ended:
            scrubHoverFraction = nil
            scrubPreview.cancel()
        }
    }

    private var audioTrackBinding: Binding<Int> {
        Binding(
            get: { viewModel.selectedAudioIndex },
            set: { viewModel.selectAudioTrack(index: $0) }
        )
    }

    private var subtitleTrackBinding: Binding<Int> {
        Binding(
            get: { viewModel.selectedSubtitleIndex },
            set: { viewModel.selectSubtitleTrack(index: $0) }
        )
    }

    /// 速度の変更は ViewModel 経由。再生中のプレイヤーへ即座に効かせる必要がある。
    private var rateBinding: Binding<Double> {
        Binding(
            get: { settings.rate },
            set: { viewModel.applyRate($0) }
        )
    }

    private var videoSelectionStrip: some View {
        PlaybackVideoStrip(
            videos: viewModel.otherVideos,
            dataManager: dataManager
        ) { video in
            viewModel.playVideo(video)
            withAnimation(.easeOut(duration: 0.16)) {
                isVideoStripVisible = false
            }
        } onClose: {
            withAnimation(.easeOut(duration: 0.16)) {
                isVideoStripVisible = false
            }
        }
        .padding(.bottom, areCornerControlsVisible || showShortcutHelp ? 0 : playbackControlsBottomPadding)
    }

    /// 10分割サムネイルを表示するサイドバー（左端ホバーで展開）
    private var sidebar: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.chapterPoints) { chapter in
                        ChapterRow(chapter: chapter) {
                            viewModel.seek(toPercentage: chapter.percentage)
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: sidebarWidth)
            .background(Color(white: 0.07))
            .offset(x: isSidebarVisible ? 0 : -sidebarWidth + triggerWidth)
        }
        .frame(width: isSidebarVisible ? sidebarWidth : triggerWidth)
        .contentShape(Rectangle())
        .onHover { hovering in
            if isSidebarVisible != hovering {
                withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible = hovering }
            }
        }
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        if MediaShortcutSettings.matches(.videoClose, press: press) {
            coordinator.close()
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
        } else if MediaShortcutSettings.matches(.videoPreviousItem, press: press) {
            viewModel.playPreviousVideo()
            return .handled
        } else if MediaShortcutSettings.matches(.videoNextItem, press: press) {
            viewModel.playNextVideo()
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
        } else if MediaShortcutSettings.matches(.videoToggleUpNextPanel, press: press) {
            withAnimation(.easeInOut(duration: 0.22)) {
                isUpNextPanelVisible.toggle()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleMiniPlayer, press: press) {
            withAnimation(.easeInOut(duration: 0.22)) {
                coordinator.isMiniPlayerActive = true
            }
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleShuffle, press: press) {
            settings.isShuffleEnabled.toggle()
            return .handled
        } else if MediaShortcutSettings.matches(.videoCycleRepeat, press: press) {
            settings.repeatMode = settings.repeatMode.next
            return .handled
        } else if MediaShortcutSettings.matches(.videoRateDown, press: press) {
            viewModel.stepRate(by: -1)
            return .handled
        } else if MediaShortcutSettings.matches(.videoRateUp, press: press) {
            viewModel.stepRate(by: 1)
            return .handled
        } else if MediaShortcutSettings.matches(.videoTogglePictureInPicture, press: press) {
            pictureInPicture.toggle()
            return .handled
        } else if MediaShortcutSettings.matches(.videoVolumeUp, press: press) {
            viewModel.adjustVolume(by: volumeStep)
            revealCornerControls()
            return .handled
        } else if MediaShortcutSettings.matches(.videoVolumeDown, press: press) {
            viewModel.adjustVolume(by: -volumeStep)
            revealCornerControls()
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleMute, press: press) {
            viewModel.toggleMute()
            revealCornerControls()
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleFavorite, press: press) {
            viewModel.toggleCurrentVideoFavorite()
            revealCornerControls()
            return .handled
        } else if MediaShortcutSettings.matches(.videoStepBackward, press: press) {
            viewModel.stepFrame(by: -1)
            return .handled
        } else if MediaShortcutSettings.matches(.videoStepForward, press: press) {
            viewModel.stepFrame(by: 1)
            return .handled
        } else if MediaShortcutSettings.matches(.videoToggleFillScreen, press: press) {
            viewModel.toggleFillsScreen()
            return .handled
        }

        return .ignored
    }

    private func formatTime(_ time: Double) -> String {
        let totalSeconds = Int(time)
        guard totalSeconds >= 0 else { return "0:00" }
        if totalSeconds >= secondsPerHour {
            return String(
                format: "%d:%02d:%02d",
                totalSeconds / secondsPerHour,
                (totalSeconds % secondsPerHour) / secondsPerMinute,
                totalSeconds % secondsPerMinute
            )
        }
        return String(format: "%d:%02d", totalSeconds / secondsPerMinute, totalSeconds % secondsPerMinute)
    }
}

// MARK: - 一覧から開始する巡回メニュー

struct LibraryTourMenu: View {
  let videos: [VideoItem]
  let dataManager: LibraryViewModel
  let beforePlay: () -> Void
  @State private var isPanelPresented = false

  var body: some View {
    Button { isPanelPresented.toggle() } label: {
      HStack(spacing: 8) {
        Label("お楽しみ再生", systemImage: "play.rectangle.on.rectangle")
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .medium))
      }
    }
    .buttonStyle(.quiet)
    .accessibilityIdentifier("library.tour.open")
    .help("チャンネル・気分ミックス・時間指定・ストック・プレビュー巡回・シーン再生")
    .disabled(videos.isEmpty)
    .popover(isPresented: $isPanelPresented, arrowEdge: .bottom) {
      LibraryTourSelectionPanel(videos: videos, dataManager: dataManager, beforePlay: beforePlay) {
        isPanelPresented = false
      }
    }
  }
}

/// パネル内の移動は表示元のツールバーから独立させ，項目を開いてもパネルを保つ。
private struct LibraryTourSelectionPanel: View {
  let videos: [VideoItem]
  let dataManager: LibraryViewModel
  let beforePlay: () -> Void
  let close: () -> Void
  @EnvironmentObject private var watchState: WatchStateStore
  @EnvironmentObject private var coordinator: PlaybackCoordinator
  @State private var errorMessage: String?
  @State private var panelPage: PanelPage = .overview
  @FocusState private var focusedOption: Int?

  private enum PanelPage {
    case overview
    case mood
    case duration
  }

  private static let durationChoices = [5, 10, 15, 30]
  private static let secondsPerMinute = 60
  private static let panelWidth: CGFloat = 360

  private var optionCount: Int {
    switch panelPage {
    case .overview: return 7
    case .mood: return PlaybackTourSession.Mood.allCases.count
    case .duration: return Self.durationChoices.count
    }
  }

  private var panelTitle: String {
    switch panelPage {
    case .overview: return "お楽しみ再生"
    case .mood: return "気分でミックス"
    case .duration: return "時間ぴったり再生"
    }
  }

  private var panelSubtitle: String {
    switch panelPage {
    case .overview: return "いつもの動画を，違う楽しみ方で"
    case .mood: return "表示中の動画から，気分に合うものを"
    case .duration: return "動画の再生時間の合計を合わせます"
    }
  }

  private var panelHeight: CGFloat {
    switch panelPage {
    case .overview: return 548
    case .mood: return 316
    case .duration: return 328
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      panelHeader
      Divider().overlay(NeomorphicTheme.separator)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch panelPage {
          case .overview: overviewOptions
          case .mood: moodOptions
          case .duration: durationOptions
          }
        }
        .padding(12)
      }
      .scrollBounceBehavior(.basedOnSize)
      Divider().overlay(NeomorphicTheme.separator)
      HStack(spacing: 4) {
        Text("↑↓ 選択")
        Text("·")
        Text("Enter 決定")
        Text("·")
        Text("Esc 閉じる")
        Spacer(minLength: 0)
      }
      .font(.appMicro)
      .foregroundStyle(NeomorphicTheme.muted)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .frame(width: Self.panelWidth, height: panelHeight)
    .background(NeomorphicTheme.canvas)
    .foregroundStyle(NeomorphicTheme.ink)
    .tint(NeomorphicTheme.accent)
    .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
    .background(LibraryTourPanelFocusBridge { focusedOption = 0 })
    .onKeyPress(.downArrow) { moveFocus(by: 1) }
    .onKeyPress(.upArrow) { moveFocus(by: -1) }
    .onKeyPress(.return) {
      guard let focusedOption else { return .ignored }
      activateOption(focusedOption)
      return .handled
    }
    .onKeyPress(.leftArrow) {
      guard panelPage != .overview else { return .ignored }
      returnToOverview()
      return .handled
    }
    .onKeyPress(.escape) {
      close()
      return .handled
    }
    .appAlert("再生を開始できません", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("閉じる", role: .cancel) { errorMessage = nil }
    } message: { Text(errorMessage ?? "") }
  }

  private var panelHeader: some View {
    HStack(spacing: 12) {
      if panelPage != .overview {
        Button(action: returnToOverview) {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("再生方法の一覧へ戻る")
        .accessibilityLabel("再生方法の一覧へ戻る")
        .accessibilityIdentifier("library.tour.back")
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(panelTitle)
          .font(.appBodyStrong)
          .accessibilityAddTraits(.isHeader)
        Text(panelSubtitle)
          .font(.appMicro)
          .foregroundStyle(NeomorphicTheme.muted)
      }
      Spacer(minLength: 0)
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .medium))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(NeomorphicTheme.muted)
      .help("閉じる")
      .accessibilityLabel("お楽しみ再生の選択を閉じる")
    }
    .padding(16)
  }

  private var overviewOptions: some View {
    Group {
      optionGroup("新しい楽しみ方") {
        optionRow(0, title: "マイチャンネル", detail: "全動画アルバムをチャンネルに", symbol: "tv")
        optionRow(1, title: "気分でミックス", detail: "短く・未視聴・お気に入りから選ぶ", symbol: "shuffle", opensPage: true)
        optionRow(2, title: "時間ぴったり再生", detail: "5・10・15・30分から選ぶ", symbol: "timer", opensPage: true)
        optionRow(3, title: "ストックした場面を再生", detail: "保存しておいた場面を見返す", symbol: "bookmark")
      }
      optionGroup("プレビュー巡回") {
        HStack(spacing: 8) {
          durationTile(4, value: "15", unit: "秒", detail: "ずつ試聴")
          durationTile(5, value: "30", unit: "秒", detail: "ずつ試聴")
        }
      }
      optionGroup("採用した区間を楽しむ") {
        optionRow(6, title: "シーンシャッフル", detail: "シーン抽出で採用した区間を再生", symbol: "film.stack")
      }
    }
  }

  private var moodOptions: some View {
    VStack(spacing: 4) {
      ForEach(Array(PlaybackTourSession.Mood.allCases.enumerated()), id: \.offset) { index, mood in
        optionRow(index, title: mood.rawValue, detail: moodDetail(mood), symbol: moodSymbol(mood))
      }
    }
  }

  private var durationOptions: some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(Array(Self.durationChoices.enumerated()), id: \.offset) { index, minutes in
          durationTile(index, value: String(minutes), unit: "分", detail: "再生する")
        }
      }
      Text("最後の区間の長さを調整して，選んだ時間に合わせます")
        .font(.appCaption)
        .foregroundStyle(NeomorphicTheme.muted)
    }
  }

  private func optionGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.appMicroStrong)
        .foregroundStyle(NeomorphicTheme.muted)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 4, content: content)
    }
  }

  private func optionRow(_ index: Int, title: String, detail: String, symbol: String, opensPage: Bool = false) -> some View {
    Button { activateOption(index) } label: {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(NeomorphicTheme.muted)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.appCaptionStrong)
            .foregroundStyle(NeomorphicTheme.ink)
          Text(detail)
            .font(.appMicro)
            .foregroundStyle(NeomorphicTheme.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: opensPage ? "chevron.right" : "play.fill")
          .font(.system(size: opensPage ? 10 : 8, weight: .medium))
          .foregroundStyle(NeomorphicTheme.muted)
          .frame(width: 12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(LibraryTourOptionStyle(isFocused: focusedOption == index))
    .focusable()
    .focused($focusedOption, equals: index)
    .onHover { inside in
      if inside { focusedOption = index }
    }
    .accessibilityLabel(title)
    .accessibilityHint(detail)
    .accessibilityIdentifier("library.tour.\(panelPage).\(index)")
  }

  private func durationTile(_ index: Int, value: String, unit: String, detail: String) -> some View {
    Button { activateOption(index) } label: {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value)
          .font(.system(size: 24, weight: .medium, design: .monospaced))
        Text(unit)
          .font(.appCaption)
        Spacer(minLength: 0)
        Text(detail)
          .font(.appMicro)
          .foregroundStyle(NeomorphicTheme.muted)
      }
      .foregroundStyle(NeomorphicTheme.ink)
      .frame(maxWidth: .infinity, minHeight: 40)
    }
    .buttonStyle(LibraryTourOptionStyle(isFocused: focusedOption == index, isTile: true))
    .focusable()
    .focused($focusedOption, equals: index)
    .onHover { inside in
      if inside { focusedOption = index }
    }
    .accessibilityLabel("\(value)\(unit)\(detail)")
    .accessibilityIdentifier("library.tour.\(panelPage).\(index)")
  }

  private func moodDetail(_ mood: PlaybackTourSession.Mood) -> String {
    switch mood {
    case .short: return "3分以内の動画を30秒ずつ"
    case .unseen: return "まだ見ていない動画を60秒ずつ"
    case .favorites: return "お気に入りの動画を60秒ずつ"
    }
  }

  private func moodSymbol(_ mood: PlaybackTourSession.Mood) -> String {
    switch mood {
    case .short: return "bolt"
    case .unseen: return "eye"
    case .favorites: return "heart"
    }
  }

  private func moveFocus(by offset: Int) -> KeyPress.Result {
    let current = focusedOption ?? (offset > 0 ? -1 : 0)
    focusedOption = (current + offset + optionCount) % optionCount
    return .handled
  }

  private func returnToOverview() {
    let previous = panelPage
    panelPage = .overview
    focusedOption = previous == .mood ? 1 : 2
  }

  /// 画面上の選択肢を，従来と同じ再生処理へ渡す。
  private func activateOption(_ index: Int) {
    switch panelPage {
    case .overview:
      switch index {
      case 0:
        start { try PlaybackTourSession.channelSession(albums: dataManager.albums, videos: dataManager.videos) }
      case 1:
        panelPage = .mood
        focusedOption = 0
      case 2:
        panelPage = .duration
        focusedOption = 0
      case 3:
        start { try PlaybackTourSession.highlights(videos: videos, urlForVideo: dataManager.fileURL) }
      case 4: startPreview(seconds: 15)
      case 5: startPreview(seconds: 30)
      case 6:
        start { try PlaybackTourSession.scenes(videos: videos, urlForVideo: dataManager.fileURL) }
      default: break
      }
    case .mood:
      let moods = PlaybackTourSession.Mood.allCases
      guard moods.indices.contains(index) else { return }
      start {
        try PlaybackTourSession.mix(videos: videos, mood: moods[index],
          seenIDs: Set(watchState.historyOrder).union(watchState.progress.keys))
      }
    case .duration:
      guard Self.durationChoices.indices.contains(index) else { return }
      let minutes = Self.durationChoices[index]
      start { try PlaybackTourSession.timed(videos: videos, seconds: Double(minutes * Self.secondsPerMinute)) }
    }
  }

  private func startPreview(seconds: Double) {
    start { try PlaybackTourSession.preview(videos: videos, seconds: seconds) }
  }

  private func start(_ makeSession: () throws -> PlaybackTourSession) {
    do {
      let session = try makeSession()
      close()
      beforePlay()
      coordinator.startTour(session)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// ツールバーのボタンではなく，表示したパネルへキー入力を渡す。
private struct LibraryTourPanelFocusBridge: NSViewRepresentable {
  let onReady: () -> Void

  func makeNSView(context: Context) -> FocusView {
    FocusView(onReady: onReady)
  }

  func updateNSView(_ view: FocusView, context: Context) {
    view.onReady = onReady
  }

  final class FocusView: NSView {
    var onReady: () -> Void

    init(onReady: @escaping () -> Void) {
      self.onReady = onReady
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      // ホストのウィンドウが用意されてから，SwiftUIのフォーカスを設定する。
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window else { return }
        window.makeKey()
        self.onReady()
      }
    }
  }
}

/// 選択行のホバーとキーボードのフォーカスを同じ面と青線で示す。
private struct LibraryTourOptionStyle: ButtonStyle {
  let isFocused: Bool
  var isTile = false
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    let isActive = isFocused || isHovering || configuration.isPressed
    return configuration.label
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(isActive ? NeomorphicTheme.controlSelected : (isTile ? NeomorphicTheme.control : .clear))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isActive || isTile ? NeomorphicTheme.cardBorder : .clear, lineWidth: 1)
      }
      .overlay(alignment: .leading) {
        if isActive {
          RoundedRectangle(cornerRadius: 1)
            .fill(NeomorphicTheme.accent)
            .frame(width: 2, height: 16)
            .padding(.leading, 2)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .onHover { isHovering = $0 }
  }
}

// MARK: - 履歴を更新せずに区間を試す専用プレイヤー

struct PlaybackTourView: View {
  @StateObject private var model: PlaybackTourViewModel
  @EnvironmentObject private var coordinator: PlaybackCoordinator
  private let session: PlaybackTourSession
  private let dataManager: LibraryViewModel

  init(session: PlaybackTourSession, dataManager: LibraryViewModel) {
    self.session = session
    self.dataManager = dataManager
    _model = StateObject(wrappedValue: PlaybackTourViewModel(session: session, dataManager: dataManager))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text(model.channelName.map { "マイチャンネル · \($0)" } ?? session.title).font(.appTitle.bold())
          Text(model.currentEntry?.video.originalFilename ?? "")
            .font(.appBody).lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        Text("\(model.index + 1) / \(session.entries.count)").monospacedDigit()
        Button("一覧に戻る", systemImage: "xmark") { coordinator.close() }
          .keyboardShortcut(.escape, modifiers: [])
      }
      .padding(20)

      ZStack {
        Color.black
        PlayerLayerContainerView(player: model.player)
        if model.isLoading {
          ProgressView("動画を読み込み中…").tint(.white)
        }
        if let error = model.errorMessage {
          VStack(spacing: 16) {
            Text("この項目を再生できません").font(.appTitle.bold())
            Text(error).multilineTextAlignment(.center)
            HStack {
              Button("再試行") { model.retry() }
              Button("次へ進む") { model.next() }
            }
          }
          .padding(24)
          .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        }
        if model.isFinished {
          VStack(spacing: 16) {
            Text("一巡しました").font(.appLargeTitle.bold())
            Text("\(session.entries.count)件の区間の巡回が終了しました．")
            HStack {
              Button("もう一度巡回") { model.restart() }
              Button("一覧に戻る") { coordinator.close() }
            }
          }
          .padding(24)
          .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      VStack(spacing: 12) {
        ProgressView(value: model.progress)
        HStack(spacing: 16) {
          Button(model.isChannelMode ? "前のCH" : "前へ", systemImage: "backward.end") { model.previous() }
            .keyboardShortcut(model.isChannelMode ? .upArrow : .leftArrow, modifiers: [])
            .disabled(!model.isChannelMode && model.index == 0)
          Button(model.isPlaying ? "一時停止" : "再生", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
            model.togglePlayback()
          }
          .keyboardShortcut(.space, modifiers: [])
          .disabled(model.isLoading || model.isFinished || model.errorMessage != nil)
          Button(model.isChannelMode ? "次のCH" : "次へ", systemImage: "forward.end") { model.next() }
            .keyboardShortcut(model.isChannelMode ? .downArrow : .rightArrow, modifiers: [])
            .disabled(model.isFinished)
          Text("残り\(Int(ceil(model.sessionRemaining)))秒").monospacedDigit()
          Spacer()
          Button(model.isMuted ? "消音を解除" : "消音", systemImage: model.isMuted ? "speaker.slash" : "speaker.wave.2") {
            model.isMuted.toggle()
          }
          .labelStyle(.iconOnly)
          .accessibilityLabel(model.isMuted ? "消音を解除" : "消音")
          Slider(value: $model.volume, in: 0...1)
            .frame(width: 90)
            .accessibilityLabel("音量")
          Button("このまま見る", systemImage: "play.rectangle") { continueWatching() }
            .buttonStyle(AppActionButtonStyle(isPrimary: true))
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.isLoading || model.errorMessage != nil || model.isFinished)
        }
        HStack {
          if let entry = model.currentEntry {
            StockMomentButton(video: entry.video, time: model.currentTime,
              duration: entry.video.duration, dataManager: dataManager)
              .disabled(model.isLoading || model.errorMessage != nil || model.isFinished)
          }
          Spacer()
          if session.kind == .timed {
            Text("予定：\(Int((session.requestedSeconds ?? 0) / 60))分 · 一時停止・読み込み・手動送りで終了時刻は変わります．")
              .font(.appCaption)
          }
        }
        Text("試聴中は視聴位置・履歴を変更しません．「このまま見る」で通常再生へ切り替わります．")
          .font(.appCaption).foregroundStyle(.white.opacity(0.75))
      }
      .padding(20)
    }
    .foregroundStyle(.white)
    .background(Color.black)
    .tint(NeomorphicTheme.accent)
    .buttonStyle(AppActionButtonStyle())
    .preferredColorScheme(.dark)
    .onAppear {
      coordinator.setPlaybackActive(false)
      model.start()
    }
    .onChange(of: model.isPlaying) { _, playing in coordinator.setPlaybackActive(playing) }
    .onChange(of: model.isFinished) { _, finished in
      if finished { coordinator.setPlaybackActive(false) }
    }
    .onDisappear { model.cleanup() }
  }

  private func continueWatching() {
    guard let entry = model.currentEntry else { return }
    let time = model.currentTime
    model.cleanup()
    var seen = Set<UUID>()
    let source = model.isChannelMode ? session.channels[model.index].videos : session.entries.map(\.video)
    let videos = source.filter { seen.insert($0.id).inserted }
    coordinator.playSingle(playlist: videos, current: entry.video, startAt: time)
  }
}

// MARK: - 再生中の前後10秒をワンアクションで保存

struct StockMomentButton: View {
  let video: VideoItem
  let time: Double
  let duration: Double
  let dataManager: LibraryViewModel
  var compact = false
  @State private var notice: String?
  @State private var errorMessage: String?

  var body: some View {
    Button {
      do {
        guard let url = dataManager.fileURL(for: video) else { throw PlaybackTourError.missingFile }
        try HighlightStore.capture(url: url, time: time, duration: duration)
        notice = "前後10秒を保存しました．一覧の「お楽しみ再生 → ストックした場面を再生」から見返せます．"
      } catch {
        errorMessage = "場面を保存できませんでした．\(error.localizedDescription)"
      }
    } label: {
      if compact { Image(systemName: "bookmark.badge.plus") }
      else { Label("場面を保存", systemImage: "bookmark.badge.plus") }
    }
    .keyboardShortcut("b", modifiers: [.command])
    .accessibilityLabel("場面を保存")
    .help("現在位置の前後10秒をストックします（⌘B）")
    .popover(isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
      Text(notice ?? "").font(.appBody).padding(16).frame(width: 300)
    }
    .appAlert("保存できません", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("閉じる", role: .cancel) { errorMessage = nil }
    } message: { Text(errorMessage ?? "") }
  }
}
