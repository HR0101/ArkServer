import AppKit
import SwiftUI

// MARK: - メインビュー
struct ContentView: View {
    @StateObject private var viewModel: AppViewModel
    @ObservedObject private var dataManager: LibraryViewModel
    @ObservedObject private var playbackCoordinator: PlaybackCoordinator
    @ObservedObject private var appSettings: AppSettings
    /// サイドバーの幅。行の幅（253）に左右の余白（10×2）とスクロールバーの分（15）を足した値で、行は固定幅で組んである。
    private let sidebarWidth: CGFloat = 288
    @State private var isSidebarVisible = true

    init() {
        let viewModel = AppViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _dataManager = ObservedObject(wrappedValue: viewModel.dataManager)
        _playbackCoordinator = ObservedObject(
            wrappedValue: viewModel.playbackCoordinator
        )
        _appSettings = ObservedObject(wrappedValue: viewModel.appSettings)
    }

    init(viewModel: AppViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _dataManager = ObservedObject(wrappedValue: viewModel.dataManager)
        _playbackCoordinator = ObservedObject(
            wrappedValue: viewModel.playbackCoordinator
        )
        _appSettings = ObservedObject(wrappedValue: viewModel.appSettings)
    }

    var body: some View {
        // 再生中はライブラリ画面（サイドバー/ツールバー含む）ごとプレイヤーに差し替え、
        // 他のUIが前面に残らない完全な全画面にする（元アプリと同じ方式）。
        // ただし通常再生をIキーでミニプレイヤー化した間はアルバム一覧を操作できるよう裏に残す。
        ZStack(alignment: .bottomTrailing) {
            // ライブラリ画面を外した瞬間に素の（＝黒い）ウィンドウ背景が覗かないよう、
            // 常駐する下地を1枚敷いておく。上端の黒帯対策の要はこの下地とウィンドウ設定であって、
            // ライブラリ画面を出しっぱなしにすることではない。
            if shouldShowLibraryView {
              // デスクトップが透けるガラス地はやめ、単色の下地にする（色の濁りと環境による見た目の差をなくす）。
              NeomorphicTheme.rail
                .id(appSettings.neomorphicDarkBase)
                .ignoresSafeArea()
            } else {
              Color.black.ignoresSafeArea()
            }

            if let error = dataManager.storageInitializationError {
                LibraryStorageInitializationErrorView(error: error)
            } else {
                // 再生中はライブラリ画面を本当に破棄する。opacity 0 で残すと、
                // ホームの1秒ごとのシステム監視・アルバム一覧のサムネイル・影付きカードが
                // 再生中もずっと描画され続け、動画がカクつく。差分探索画面はライブラリとは
                // 独立した兄弟Viewなので、こちらを外しても探索位置は保持される。
                if shouldShowLibraryView {
                    libraryView
                }

                if let albumID = playbackCoordinator.variantFinderAlbumID {
                    variantFinderOverlay(albumID: albumID)
                        .zIndex(1)
                }

                if let mode = playbackCoordinator.mode {
                    playerOverlay(for: mode)
                        .zIndex(2)
                }
            }
        }
        // ウィンドウのクロム設定はライブラリ画面の有無に関わらず効かせる必要があるため、
        // ライブラリ画面ではなくこの常駐の階層に付ける。
        .toolbar(isToolbarHidden ? .hidden : .automatic, for: .windowToolbar)
        // タイトルバーの帯は、左のレールと同じ「窓の枠」の色にして内側のパネルをくぼませて見せる。
        // 帯の色は、ツールバーの背景として描かず、窓の背景色（WindowChromeConfigurator で枠の色にしてある）に任せる。
        // ツールバーの背景を出すと、検索欄などのあるライブラリ画面で、帯がパネルの中（見出しの背後）まで広がってしまう。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(
            WindowChromeConfigurator(isToolbarHidden: isToolbarHidden)
        )
        .tint(NeomorphicTheme.accent)
        .preferredColorScheme(appSettings.neomorphicDarkBase ? .dark : .light)
        .environmentObject(playbackCoordinator)
        .environmentObject(viewModel.remotePlaybackSession)
        .environmentObject(appSettings)
        .environmentObject(viewModel.variantFinder)
        .environmentObject(viewModel.watchState)
        .focusedSceneValue(
            \.appMenuContext,
            dataManager.isStorageReady ? appMenuContext : nil
        )
        .sheet(isPresented: $viewModel.isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
        .sheet(isPresented: $viewModel.isShowingAccessLog) {
            AccessLogView(webServerManager: viewModel.webServerManager)
        }
        .alert(
            "ファイル操作の結果",
            isPresented: Binding(
                get: { dataManager.mediaDeletionNotice != nil },
                set: { if !$0 { dataManager.mediaDeletionNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                dataManager.mediaDeletionNotice = nil
            }
        } message: {
            Text(dataManager.mediaDeletionNotice ?? "")
        }
        .alert(
            "シーン抽出を開始できません",
            isPresented: Binding(
                get: { viewModel.sceneExtractionNavigationError != nil },
                set: { if !$0 { viewModel.sceneExtractionNavigationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.sceneExtractionNavigationError = nil
            }
        } message: {
            Text(viewModel.sceneExtractionNavigationError ?? "")
        }
    }

    /// 左のサイドバー。設定のページでは、アルバムの一覧の代わりに設定の項目の一覧を出す。
    @ViewBuilder
    private var sidebarColumn: some View {
        if case .settings(let pane) = viewModel.selection {
            SettingsSidebarView(
                selected: pane,
                onSelect: { viewModel.openSettings($0) },
                onBack: { viewModel.closeSettings() }
            )
        } else {
            MainSidebarView(
                dataManager: dataManager,
                webServerManager: viewModel.webServerManager,
                selection: $viewModel.selection
            )
        }
    }

    /// ミニプレイヤー表示中は通常再生の裏でライブラリも操作できるようにする。
    private var shouldShowLibraryView: Bool {
        guard let mode = playbackCoordinator.mode else { return true }
        if case .single = mode {
            return playbackCoordinator.isMiniPlayerActive
        }
        return false
    }

    private var isToolbarHidden: Bool {
        guard let mode = playbackCoordinator.mode else { return false }
        if case .single = mode, playbackCoordinator.isMiniPlayerActive { return false }
        return true
    }

    /// sheet は別ウィンドウ扱いになり、ContentView のプレイヤーをその上へ重ねられない。
    /// 同じ ZStack に探索画面を置き、再生時はこの View を残したままプレイヤーを最前面へ出す。
    private func variantFinderOverlay(albumID: UUID) -> some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            VariantVideoView(
                items: variantFinderItems,
                dataManager: dataManager,
                hostWindowSize: playbackCoordinator.variantFinderHostSize,
                initialSearchMode: playbackCoordinator.variantFinderAlignmentMode == .content
                    ? .partial
                    : .normal,
                onClose: playbackCoordinator.closeVariantFinder
            )
            .appSheet()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 0.5)
            )
            .id("\(albumID.uuidString)-\(String(describing: playbackCoordinator.variantFinderAlignmentMode))")
        }
    }

    /// 開いた時点の検索・並べ替え順を保ちつつ、削除された項目は現在のライブラリから除く。
    private var variantFinderItems: [VideoItem] {
        let itemsByID = Dictionary(
            dataManager.videos.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return playbackCoordinator.variantFinderItemIDs.compactMap { id in
            guard let item = itemsByID[id], !item.isInTrash else { return nil }
            return item
        }
    }

    /// 再生中はウィンドウ全体を占有するプレイヤー（通常再生はIキーでミニプレイヤー化できる）
    @ViewBuilder
    private func playerOverlay(for mode: PlaybackCoordinator.Mode) -> some View {
        switch mode {
        case .single(let playlist, let current):
            VideoPlayerView(
                videos: playlist,
                currentVideo: current,
                dataManager: dataManager,
                watchState: viewModel.watchState,
                settings: viewModel.playbackSettings,
                initialStartTime: playbackCoordinator.singleStartTime
            )
                .id(current.id)
        case .tour(let session):
            PlaybackTourView(session: session, dataManager: dataManager)
                .id(session.id)
        case .multi(let videos):
            MultiVideoPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .variantSwitch(let videos, let alignment):
            VariantSwitchPlayerView(
                videos: videos,
                dataManager: dataManager,
                alignmentMode: alignment
            )
                .ignoresSafeArea()
        case .slideshow(let videos):
            SlideshowPlayerView(videos: videos, dataManager: dataManager)
                .ignoresSafeArea()
        case .splitPlay(let video, let splitCount):
            SplitVideoPlayerView(
                video: video,
                splitCount: splitCount,
                dataManager: dataManager
            )
                .ignoresSafeArea()
        case .photos(let playlist, let current):
            PhotoViewerView(
                photos: playlist,
                current: current,
                dataManager: dataManager
            )
        }
    }

    private var libraryView: some View {
        ZStack {
            // ツールバーの背後まで同じ背景（窓の枠の色）を広げ，フルスクリーン時の色の段差をなくす。
            NeomorphicTheme.rail.ignoresSafeArea()

            // 標準の NavigationSplitView は macOS 26 でサイドバーが「浮いた角丸のガラス」になり、
            // 窓の端や上下に余白ができて平らにできない。そこで左カラムを自前で組み、窓の端から端まで
            // 単色で伸ばす（タイトルバーの帯もサイドバーと同じ色にして、一続きに見せる）。
            HStack(spacing: 0) {
                // 左端のアイコンのレール。サイドバーを隠しても残り、主要な行き先と設定へいつでも移れる。
                SidebarRailView(
                    dataManager: dataManager,
                    watchState: viewModel.watchState,
                    selection: $viewModel.selection,
                    allVideosAlbumID: dataManager.albums.first { $0.name == LibraryViewModel.allVideosAlbumName }?.id,
                    allPhotosAlbumID: dataManager.albums.first { $0.name == LibraryViewModel.allPhotosAlbumName }?.id,
                    onShowStorage: { viewModel.isShowingStorageManager = true },
                    onShowPreferences: { viewModel.toggleSettings() }
                )
                .background(NeomorphicTheme.rail.ignoresSafeArea())

                // サイドバーと内容は、窓の枠の内側にはめ込んだ1枚の角丸パネルにする。
                HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebarColumn
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(NeomorphicTheme.sidebar.ignoresSafeArea())
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(NeomorphicTheme.separator)
                                .frame(width: 1)
                                .ignoresSafeArea()
                        }
                        .transition(.move(edge: .leading))
                }

                NavigationStack {
                    switch viewModel.selection {
                    case .home:
                        HomeView(
                            dataManager: dataManager,
                            webServerManager: viewModel.webServerManager
                        )
                            .navigationTitle("ホーム")
                    case .favorites:
                        LibraryCategoryView(
                            kind: .favorites,
                            dataManager: dataManager,
                            onAnalyzeScenes: viewModel.openSceneExtraction
                        )
                            .navigationTitle("お気に入り")
                    case .continueWatching:
                        LibraryCategoryView(
                            kind: .continueWatching,
                            dataManager: dataManager,
                            onAnalyzeScenes: viewModel.openSceneExtraction
                        )
                            .navigationTitle("続きを見る")
                    case .history:
                        LibraryCategoryView(
                            kind: .history,
                            dataManager: dataManager,
                            onAnalyzeScenes: viewModel.openSceneExtraction
                        )
                            .navigationTitle("再生履歴")
                    case .trash:
                        LibraryCategoryView(
                            kind: .trash,
                            dataManager: dataManager,
                            onAnalyzeScenes: viewModel.openSceneExtraction
                        )
                            .navigationTitle("ゴミ箱")
                    case .sceneExtraction:
                        SceneExtractionView(
                            viewModel: viewModel.sceneExtraction,
                            onClose: viewModel.closeSceneExtraction
                        )
                    case .musicVideo:
                        MusicVideoView(
                            viewModel: viewModel.musicVideo,
                            dataManager: dataManager
                        )
                    case .albums:
                        AlbumOverviewView(
                            dataManager: dataManager,
                            selection: $viewModel.selection
                        )
                            .navigationTitle("アルバム一覧")
                    case .album(let albumID):
                        if let album = dataManager.albums.first(
                            where: { $0.id == albumID }
                        ) {
                            AlbumDetailView(
                                album: album,
                                dataManager: dataManager,
                                onAnalyzeScenes: viewModel.openSceneExtraction
                            )
                                .navigationTitle(album.displayTitle)
                        } else {
                            ContentUnavailableView("アルバムが見つかりません", systemImage: "questionmark.folder")
                        }
                    case .folder(let path, let isPhoto):
                        FolderDetailView(
                            path: path,
                            isPhoto: isPhoto,
                            dataManager: dataManager,
                            selection: $viewModel.selection,
                            onAnalyzeScenes: viewModel.openSceneExtraction
                        )
                            .navigationTitle(path.components(separatedBy: "/").last ?? path)
                    case .settings(let pane):
                        SettingsPageView(
                            pane: pane,
                            dataManager: dataManager,
                            webServerManager: viewModel.webServerManager,
                            appSettings: appSettings
                        )
                            .navigationTitle("設定")
                    case .none:
                        ContentUnavailableView("サイドバーから項目を選択してください", systemImage: "sidebar.left")
                    }
                }
                // ツールバーのメニューだけがアクセントの青になり、ボタンの中立色とちぐはぐに見えるので、
                // 内容側（ツールバー含む）の色味は文字色にそろえる。ホームは自分でアクセントを指定している。
                .tint(NeomorphicTheme.ink)
                // ページ見出しと同じ文字がタイトルバーにも出て重複するので、ツールバーのタイトルは外す
                // （ウィンドウ自体のタイトルは残るので、Mission Control などでは識別できる）。
                .toolbar(removing: .title)
                // タイトルを外すと、右寄せだった各画面のボタンが左へ詰まるので、中央に伸びる空きを置いて右側に戻す。
                .toolbar { principalSpacer }
                }
                // パネルの上端は、ツールバー（タイトルバーの帯）の下から始める。右と下には枠の色を少し残す。
                // 下地を持たない画面（ライブラリの一覧など）でも、窓の枠の色が透けないよう、内容の下地はパネルが持つ。
                .background(NeomorphicTheme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
                        .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
                )
                .padding(.top, 44)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    AppUpdateAvailabilityButton()
                }
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
                    } label: {
                        Label("サイドバー", systemImage: "sidebar.leading")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .help(isSidebarVisible ? "サイドバーを隠す（⌃⌘S）" : "サイドバーを表示（⌃⌘S）")

                }
            }
        }
        // tint / preferredColorScheme / toolbarBackground / WindowChromeConfigurator は
        // 再生中もウィンドウに効かせ続ける必要があるため body 側（常駐する階層）に付けてある。
        .ignoresSafeArea()
        // ベースカラーを切り替えたら、色を静的に参照している全ビュー（CommandDeckBackground・
        // カード・サイドバー等）を確実に描き直すため、ライブラリ画面ごと作り直す。
        // これをしないと一部だけ色が更新されず、白背景に白文字などのちぐはぐが起きる。
        .id(appSettings.neomorphicDarkBase)
    }

    /// ツールバーの中央に伸びる透明な空き。macOS 26 では部品ごとに丸い背景が付くので、その背景は消す。
    @ToolbarContentBuilder
    private var principalSpacer: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(minWidth: 40, maxWidth: .infinity, minHeight: 1)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(minWidth: 40, maxWidth: .infinity, minHeight: 1)
            }
        }
    }

    private var appMenuContext: AppMenuContext {
        AppMenuContext(
            isLibraryLoaded: dataManager.isLibraryLoaded,
            isServerRunning: viewModel.isServerRunning,
            serverURL: viewModel.currentServerURL,
            canRefreshLinkedFolders: dataManager.linkedFolderCount > 0,
            isPresentingPlayer: playbackCoordinator.isPresenting,
            canToggleMiniPlayer: isSingleVideoPlayback,
            isMiniPlayerActive: playbackCoordinator.isMiniPlayerActive,
            showPreferences: { viewModel.openSettings() },
            showStorageManager: { viewModel.isShowingStorageManager = true },
            showAccessLog: { viewModel.isShowingAccessLog = true },
            showHome: { viewModel.selection = .home },
            showAllVideos: {
                selectSystemAlbum(named: LibraryViewModel.allVideosAlbumName)
            },
            showAllPhotos: {
                selectSystemAlbum(named: LibraryViewModel.allPhotosAlbumName)
            },
            showFavorites: { viewModel.selection = .favorites },
            showTrash: { viewModel.selection = .trash },
            refreshLinkedFolders: {
                Task { await dataManager.rescanAllLinkedFolders() }
            },
            openDataFolder: dataManager.openAppRootFolderInFinder,
            startServer: viewModel.webServerManager.startServer,
            stopServer: viewModel.webServerManager.stopServer,
            openServerInBrowser: openServerInBrowser,
            copyServerURL: copyServerURL,
            closePlayer: playbackCoordinator.close,
            toggleMiniPlayer: toggleMiniPlayer
        )
    }

    private var isSingleVideoPlayback: Bool {
        guard let mode = playbackCoordinator.mode else { return false }
        if case .single = mode {
            return true
        }
        return false
    }

    private func selectSystemAlbum(named name: String) {
        guard let albumID = dataManager.albums.first(
            where: { $0.name == name }
        )?.id else {
            return
        }
        viewModel.selection = .album(albumID)
    }

    private func openServerInBrowser() {
        guard let value = viewModel.currentServerURL,
              let url = URL(string: value) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func copyServerURL() {
        guard let value = viewModel.currentServerURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func toggleMiniPlayer() {
        guard isSingleVideoPlayback else { return }
        playbackCoordinator.isMiniPlayerActive.toggle()
    }
}

private struct LibraryStorageInitializationErrorView: View {
    let error: LibraryStorageInitializationError

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.red)

            VStack(spacing: 8) {
                Text("ライブラリ保存先を準備できませんでした")
                    .font(.appTitle)
                Text("データを保護するため，ライブラリの読み込みとサーバー起動を停止しています．")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                errorRow(title: "対象", value: error.locationName)
                errorRow(title: "パス", value: error.targetPath)
                errorRow(title: "原因", value: error.reason)
                errorRow(title: "確認事項", value: error.recoverySuggestion)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .background(NeomorphicTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        error.targetPath,
                        forType: .string
                    )
                } label: {
                    Label("パスをコピー", systemImage: "doc.on.doc")
                }

                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.appCaptionStrong)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
