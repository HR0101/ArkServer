import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - お気に入り / 再生履歴 / ゴミ箱 カテゴリビュー
struct LibraryCategoryView: View {
    enum Kind: Hashable {
        case favorites
        /// 途中でやめた動画だけを並べる。中身は視聴位置の保管庫なので、
        /// ブラウザ・iPhone で途中まで観たものもここに出る。
        case continueWatching
        case history
        case trash
    }
    let kind: Kind
    @ObservedObject var dataManager: LibraryViewModel
    let onAnalyzeScenes: (VideoItem) -> Void

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var watchState: WatchStateStore

    @State private var selectedVideoIDs = Set<UUID>()
    @State private var lastSelectedVideoID: UUID?
    @State private var searchText = ""
    @State private var showEmptyTrashAlert = false
    @State private var showMoveToNewAlbumAlert = false
    @State private var newAlbumNameForMove = ""
    @State private var pendingMoveVideoIDs: [UUID] = []
    /// キーボードで今どのセルを指しているか。セル側の @FocusState ではなくただの状態として持つ
    /// （SwiftUI 標準のフォーカス送りと矢印キーを取り合わないようにするため）。
    @State private var focusedVideoID: UUID?
    /// 一覧を再生成したときに元の表示位置へ戻すため，上端付近の項目を記録する。
    @State private var scrollTargetMediaID: UUID?
    /// グリッドがキー入力を受け取れる状態か。フォーカスはグリッド全体で1つ。
    @FocusState private var isGridFocused: Bool

    // 分割再生用
    @State private var showSplitSheet = false
    @State private var splitCount: Int = 4
    @State private var splitTargetVideo: VideoItem?

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportCurrent = 0
    @State private var exportTotal = 0
    @State private var exportResultMessage = ""
    @State private var showExportResultAlert = false

    @State private var showBulkDeleteConfirmation = false

    private var isTrash: Bool { kind == .trash }
    private var isHistory: Bool { kind == .history }
    private var isContinueWatching: Bool { kind == .continueWatching }

    @State private var showClearHistoryAlert = false

    private var sourceItems: [VideoItem] {
        switch kind {
        case .favorites:
            return dataManager.favoriteVideos
        case .continueWatching:
            return continueWatchingItems
        case .history:
            return historyItems
        case .trash:
            return dataManager.trashedVideos
        }
    }

    /// 再生履歴に載っている順（新しい順）に並べた、いまもライブラリにある項目。
    /// 履歴には削除済み・ゴミ箱行きの ID も残るので、ここで引き当てられたものだけを出す。
    private var historyItems: [VideoItem] {
        let itemByID = Dictionary(
            dataManager.videos.lazy.filter { !$0.isInTrash }.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return watchState.historyOrder.compactMap { itemByID[$0] }
    }

    /// 途中でやめた動画を、最後に再生した順（新しい順）に並べたもの。
    /// 並びに `historyOrder` を使うのは、視聴位置そのものには前後関係が無いため。
    /// 履歴から外した動画は並びから消えるので、視聴位置だけが残っているものを末尾に足す。
    private var continueWatchingItems: [VideoItem] {
        let itemByID = Dictionary(
            dataManager.videos.lazy.filter { !$0.isInTrash && $0.mediaType == .video }.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var seen = Set<UUID>()
        var result: [VideoItem] = []
        for id in watchState.historyOrder {
            guard let item = itemByID[id],
                  watchState.resumableSeconds(for: id, duration: item.duration) != nil else { continue }
            seen.insert(id)
            result.append(item)
        }
        // 履歴を消しても視聴位置は残る（仕様）。その分は順序を決めようがないので後ろへ回す。
        let orphans = itemByID.values
            .filter { !seen.contains($0.id) && watchState.resumableSeconds(for: $0.id, duration: $0.duration) != nil }
            .sorted { $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending }
        return result + orphans
    }

    private var displayedItems: [VideoItem] {
        let filtered = sourceItems.filtered(bySearch: searchText)
        // 履歴と「続きを見る」は、並び（最後に再生した順）そのものが中身なので並べ替えない。
        guard !isHistory, !isContinueWatching else { return filtered }
        return filtered.sorted(by: appSettings.sortOrder, reversed: appSettings.sortReversed, lastPlayed: watchState.lastPlayed) { dataManager.fileMetadata(for: $0) }
    }
    private var selectedVideoItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }
    }

    /// 現在の選択すべて（表示順、画像も含む）。削除の確認で何を消すのか見せるために使う。
    private var selectedItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) }
    }

    /// 実際に並べる列数。グリッドの組み立てと矢印キーの上下移動が必ず同じ値を見るように、
    /// ここだけで決める（ズレると下キーが斜めに飛ぶ）。
    private var columnCount: Int {
        MediaGridLayout.columnCount(requested: appSettings.columnCount, availableWidth: gridWidth)
    }

    /// グリッドを置く領域の幅。狭いウィンドウで列を自動的に減らすために測る。
    @State private var gridWidth: CGFloat = 0

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: MediaGridLayout.spacing), count: columnCount)
    }

    private var pageTitle: String {
      switch kind {
      case .favorites: return "お気に入り"
      case .continueWatching: return "続きを見る"
      case .history: return "再生履歴"
      case .trash: return "ゴミ箱"
      }
    }

    private var pageSubtitle: String {
      switch kind {
      case .favorites: return "もう一度楽しみたいメディアを，ひとつの場所に．"
      case .continueWatching: return "前回の続きから，再生できます．"
      case .history: return "最近再生した順に並んでいます．"
      case .trash: return "削除したメディアを確認・復元できます．"
      }
    }

    var body: some View {
        // displayedItems（フィルタ＋ソート）は1回の描画につき1回だけ計算し、toolbar/sheetも含めて使い回す。
        let items = displayedItems
        let videoItems = items.filter { $0.mediaType == .video }
        let selectedItems = items.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }

        return VStack(spacing: 0) {
            LibraryPageHeader(title: pageTitle, subtitle: pageSubtitle, count: items.count)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedVideoIDs.removeAll(); lastSelectedVideoID = nil }

                if items.isEmpty {
                    emptyState
                } else {
                    grid(items)
                }

                if isExporting {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView("エクスポート中...", value: exportProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                            .tint(.accentColor)
                            .foregroundColor(.white)
                        Text("\(exportCurrent) / \(exportTotal)")
                            .foregroundColor(.white)
                            .font(.appBody)
                    }
                    .padding(20)
                    .background(NeomorphicTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 0.5))
                    .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
                }
            }
            Divider()
            MediaGridControlBar(dataManager: dataManager, showsSortControls: !isHistory && !isContinueWatching)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "タイトルを検索")
        .toolbar {
            if !isTrash {
              ToolbarItem(placement: .primaryAction) {
                LibraryTourMenu(videos: videoItems, dataManager: dataManager, beforePlay: { rememberGridState() })
              }
            }
            if isTrash {
                ToolbarItem(placement: .primaryAction) {
                    if !dataManager.trashedVideos.isEmpty {
                        Button(role: .destructive) { showEmptyTrashAlert = true } label: {
                            Label("ゴミ箱を空にする", systemImage: "trash.slash")
                        }
                    }
                }
                if !selectedVideoIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { dataManager.restoreFromTrash(videoIDs: Array(selectedVideoIDs)); selectedVideoIDs.removeAll() } label: {
                            Label("元に戻す", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            } else {
                if isHistory, !items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { showClearHistoryAlert = true } label: {
                            Label("履歴を消去", systemImage: "clock.badge.xmark")
                        }
                        .help("再生履歴を空にします（視聴位置や動画そのものは消えません）")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !videoItems.isEmpty {
                        Button { startRandomPlayback(from: videoItems) } label: {
                            Label("ランダム再生", systemImage: "shuffle")
                        }
                    }
                }
                if !selectedVideoIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(selectedVideoIDs.count)項目を選択中")
                            .font(.appMicro)
                            .foregroundStyle(.secondary)
                    }
                }
                if selectedItems.count == 1, let video = selectedItems.first {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onAnalyzeScenes(video)
                        } label: {
                            Label("シーン抽出", systemImage: "waveform.path.ecg")
                        }
                        .help("選択した動画から候補シーンを抽出します")
                    }
                }
                // 複数選択時の再生方法は4種類あり，アイコンだけを並べると見分けにくいので1つのメニューにまとめる。
                ToolbarItem(placement: .primaryAction) {
                    if selectedItems.count >= 2 {
                        AppChoiceMenu {
                            Button {
                                startMultiPlayback(selectedItems)
                            } label: {
                                Label("同時再生", systemImage: "square.grid.2x2.fill")
                            }
                            .help("選択した動画を同期再生（最大9本）")
                            Button {
                                startVariantSwitchPlayback(selectedItems)
                            } label: {
                                Label("差分切り替え再生", systemImage: "rectangle.on.rectangle.angled")
                            }
                            .help("選択した動画を同期再生し，一定間隔／キー操作で見せる1本を切り替える（最大9本）")
                            Button {
                                startContentAlignedVariantPlayback(selectedItems)
                            } label: {
                                Label("類似点で合わせる", systemImage: "link")
                            }
                            .help("動画内の類似場面を探し，最初に共通位置へ一度だけ合わせて再生する（最大9本）")
                            Button {
                                startSlideshowPlayback(selectedItems)
                            } label: {
                                Label("スライドショー", systemImage: "play.square.stack")
                            }
                            .help("選択した動画をスライドショー再生")
                        } label: {
                            Label("選択を再生", systemImage: "play.rectangle.on.rectangle")
                        }
                        .help("選択した動画を同時再生・差分切り替え・スライドショーなどで再生")
                    }
                }
                if selectedItems.count == 1, let video = selectedItems.first {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            splitTargetVideo = video
                            showSplitSheet = true
                        } label: {
                            Label("分割再生", systemImage: "rectangle.split.2x2")
                        }
                        .help("選択した動画を指定数で分割して同時再生")
                    }
                }
                if !selectedVideoIDs.isEmpty {
                    // 以前は右クリックメニューでしか一括削除できず、多数選択後の
                    // 操作先が分かりにくかったため、他画面と同じ削除ボタンをツールバーにも出す。
                    // 削除は必ず「ゴミ箱に入れる」か「完全に削除」かを確認してから実行する。
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { showBulkDeleteConfirmation = true } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .help("選択した項目をゴミ箱に入れるか完全に削除します")
                    }
                }
            }
            if !selectedVideoIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: exportSelectedItems) {
                        Label("エクスポート", systemImage: "square.and.arrow.up")
                    }
                    .help("選択した項目のコピーを指定フォルダへ書き出す（元ファイルが失われた場合の安全弁）")
                }
            }
        }
        .appConfirmationPanel("ゴミ箱を空にする方法を選んでください", isPresented: $showEmptyTrashAlert, titleVisibility: .visible) {
            Button("完全に削除", role: .destructive) { dataManager.emptyTrash() }
            Button("実ファイルをMacのゴミ箱へ移動", role: .destructive) {
                dataManager.moveMediaFilesToSystemTrash(
                    videoIDs: dataManager.trashedVideos.map(\.id)
                )
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("完全に削除するとアプリ管理内のファイルは復元できません．Macのゴミ箱へ移動するとFinderから復元できます．")
        }
        .appConfirmationPanel("再生履歴を消去しますか？", isPresented: $showClearHistoryAlert, titleVisibility: .visible) {
            Button("消去", role: .destructive) {
                watchState.clearHistory()
                selectedVideoIDs.removeAll()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("動画そのものと「続きから」の視聴位置は消えません．ブラウザや iPhone の履歴からも消えます．")
        }
        .appAlert("エクスポート完了", isPresented: $showExportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportResultMessage)
        }
        .sheet(isPresented: $showBulkDeleteConfirmation) {
            MediaDeletionConfirmationSheet(
                items: self.selectedItems,
                dataManager: dataManager,
                onMoveToAppTrash: isTrash ? nil : {
                    dataManager.moveToTrash(videoIDs: Array(selectedVideoIDs))
                    selectedVideoIDs.removeAll()
                },
                onDeleteCompletely: {
                    dataManager.deleteVideos(videoIDs: Array(selectedVideoIDs))
                    selectedVideoIDs.removeAll()
                },
                onMoveToSystemTrash: {
                    dataManager.moveMediaFilesToSystemTrash(
                        videoIDs: Array(selectedVideoIDs)
                    )
                    selectedVideoIDs.removeAll()
                }
            )
        }
        .appAlert("新規アルバムに移動", isPresented: $showMoveToNewAlbumAlert) {
            TextField("アルバム名", text: $newAlbumNameForMove)
            Button("作成して追加") {
                let name = newAlbumNameForMove.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !pendingMoveVideoIDs.isEmpty,
                      let newID = dataManager.createAlbum(name: name, type: .mixed) else { return }
                dataManager.addVideosToAlbum(videoIDs: pendingMoveVideoIDs, albumID: newID)
                pendingMoveVideoIDs = []
                selectedVideoIDs.removeAll()
            }
            Button("キャンセル", role: .cancel) { pendingMoveVideoIDs = [] }
        } message: {
            Text("作成する新しいアルバム名を入力してください．")
        }
        .sheet(isPresented: $showSplitSheet) {
            VStack(spacing: 20) {
                Text("分割再生")
                    .font(.appTitle)
                if let video = splitTargetVideo {
                    Text(video.originalFilename)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                AppNumberStepper("分割数: \(splitCount)", value: $splitCount, in: 2...9)
                    .frame(width: 200)
                Text("動画を\(splitCount)等分して\(splitCount)画面で同時再生します")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("キャンセル") { showSplitSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("再生") {
                        showSplitSheet = false
                        if let video = splitTargetVideo {
                            startSplitPlayback(video: video, splitCount: splitCount)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AppActionButtonStyle(isPrimary: true))
                }
            }
            .padding(30)
            .frame(minWidth: 320)
            .appSheet()
        }
        // 他の画面に移動したら、ここで表示していたサムネイルはメモリから解放する。
        .onDisappear {
            MacVideoThumbnailView.evictFromMemoryCache(videoIDs: items.map { $0.id })
        }
    }

    private func grid(_ items: [VideoItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: MediaGridLayout.spacing) {
                    ForEach(items) { video in
                        MediaGridItem(
                            video: video,
                            dataManager: dataManager,
                            isSelected: selectedVideoIDs.contains(video.id),
                            showTitle: appSettings.showTitles,
                            showImportDate: appSettings.showImportDates,
                            showRemoveFromAlbum: false,
                            onSingleTap: { flags in
                                handleSelection(for: video, in: items, flags: flags)
                                focusedVideoID = video.id
                                // クリック後もそのまま矢印キーで送れるようにフォーカスを戻す。
                                isGridFocused = true
                            },
                            onDoubleTap: { open(video) },
                            onOpen: { open(video) },
                            onOpenExternal: { if let url = dataManager.fileURL(for: video) { NSWorkspace.shared.open(url) } },
                            onReveal: { if let url = dataManager.revealURL(for: video) { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
                            onRemoveFromAlbum: {},
                            onDelete: { dataManager.deleteVideos(videoIDs: targetIDs(for: video)) },
                            isTrashView: isTrash,
                            onToggleFavorite: { dataManager.toggleFavorite(videoIDs: targetIDs(for: video)) },
                            onMoveToTrash: { dataManager.moveToTrash(videoIDs: targetIDs(for: video)); selectedVideoIDs.removeAll() },
                            onMoveToSystemTrash: {
                                dataManager.moveMediaFilesToSystemTrash(
                                    videoIDs: targetIDs(for: video)
                                )
                                selectedVideoIDs.removeAll()
                            },
                            onRestore: { dataManager.restoreFromTrash(videoIDs: targetIDs(for: video)); selectedVideoIDs.removeAll() },
                            currentAlbumID: nil,
                            onMoveToAlbum: { targetID in
                                dataManager.addVideosToAlbum(videoIDs: targetIDs(for: video), albumID: targetID)
                                selectedVideoIDs.removeAll()
                            },
                            onMoveToNewAlbum: {
                                pendingMoveVideoIDs = targetIDs(for: video)
                                newAlbumNameForMove = ""
                                showMoveToNewAlbumAlert = true
                            },
                            onAnalyzeScenes: !isTrash && video.mediaType == .video ? {
                                onAnalyzeScenes(video)
                            } : nil,
                            affectedItems: menuTargets(for: video, in: items),
                            onRemoveFromList: listRemoval(for: video)
                        )
                        .id(video.id)
                    }
                }
                .scrollTargetLayout()
                .padding(MediaGridLayout.contentInset)
            }
            .scrollPosition(id: $scrollTargetMediaID, anchor: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            // フォーカスはグリッド全体で1つだけ持つ。セルごとに .focusable() を付けると、
            // SwiftUI 標準の矢印キーによるフォーカス送りが自前の「index ± 列数」移動と同時に走り、
            // 1回の入力で二重に動いたり斜めに飛んだりする（列数によって挙動が変わって見える原因）。
            // どのセルを指しているかは focusedVideoID（ただの @State）で持つ。
            .focusable()
            .focusEffectDisabled()
            .focused($isGridFocused)
            .task {
                await restoreReturnState(proxy: proxy)
            }
            .onKeyPress(phases: .down) { press in handleKey(press, items: items, proxy: proxy) }
            .onAppear {
                isGridFocused = true
                if focusedVideoID == nil, let first = items.first { focusedVideoID = first.id }
            }
        }
    }

    private func open(_ video: VideoItem) {
        rememberGridState(opening: video.id)
        if video.mediaType == .video {
            coordinator.playSingle(playlist: displayedItems.filter { $0.mediaType == .video }, current: video)
        } else {
            // 画像は最初から「全画面表示（PhotoViewerView）」で開く
            coordinator.viewPhotos(playlist: displayedItems.filter { $0.mediaType == .photo }, current: video)
        }
    }

    private func targetIDs(for video: VideoItem) -> [UUID] {
        if selectedVideoIDs.contains(video.id) && selectedVideoIDs.count > 1 { return Array(selectedVideoIDs) }
        return [video.id]
    }

    /// `targetIDs` と同じ対象を、確認文へ出すために表示順の項目として返す。
    private func menuTargets(for video: VideoItem, in items: [VideoItem]) -> [VideoItem] {
        guard selectedVideoIDs.contains(video.id), selectedVideoIDs.count > 1 else { return [video] }
        return items.filter { selectedVideoIDs.contains($0.id) }
    }

    private func handleSelection(for video: VideoItem, in videos: [VideoItem], flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), let lastID = lastSelectedVideoID,
           let lastIndex = videos.firstIndex(where: { $0.id == lastID }),
           let currentIndex = videos.firstIndex(where: { $0.id == video.id }) {
            let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
            for id in videos[range].map({ $0.id }) { selectedVideoIDs.insert(id) }
        } else if flags.contains(.command) {
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id); lastSelectedVideoID = video.id }
        } else {
            selectedVideoIDs = [video.id]; lastSelectedVideoID = video.id
        }
    }

    private func handleKey(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        if handleLibraryShortcut(press, items: items, proxy: proxy) == .handled {
            return .handled
        }

        // Option+Space は既存互換の固定ショートカットとして残す。
        if press.key == .space, press.modifiers.contains(.option) {
            playFocused(items: items); return .handled
        }

        guard let focused = focusedVideoID, items.contains(where: { $0.id == focused }) else {
            let first = items[0].id
            focusedVideoID = first; selectedVideoIDs = [first]; lastSelectedVideoID = first
            return .handled
        }

        guard let direction = MediaGridNavigation.direction(for: press) else { return .ignored }
        return moveFocus(direction, items: items, proxy: proxy) != nil ? .handled : .ignored
    }

    /// フォーカスと選択を矢印1回ぶん動かし、移動後の項目を返す。端で動けなければ nil。
    /// キー処理とクイックルック中の送りが同じ動きになるよう、移動はここだけで行う。
    @discardableResult
    private func moveFocus(
        _ direction: QuickLookPreviewController.NavigationDirection,
        items: [VideoItem],
        proxy: ScrollViewProxy
    ) -> VideoItem? {
        guard let focused = focusedVideoID,
              let index = items.firstIndex(where: { $0.id == focused }),
              let next = MediaGridNavigation.nextIndex(
                  from: index, direction: direction, columnCount: columnCount, itemCount: items.count
              ) else { return nil }

        let item = items[next]
        focusedVideoID = item.id
        selectedVideoIDs = [item.id]
        lastSelectedVideoID = item.id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item.id, anchor: .center) }
        return item
    }

    private func handleLibraryShortcut(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        if MediaShortcutSettings.matches(.libraryOpenFocused, press: press) {
            playFocused(items: items)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryQuickLook, press: press) {
            quickLookFocusedVideo(in: items, proxy: proxy)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryOpenExternal, press: press) {
            if let item = primaryTarget(in: items), let url = dataManager.fileURL(for: item) {
                NSWorkspace.shared.open(url)
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRevealInFinder, press: press) {
            if let item = primaryTarget(in: items), let url = dataManager.revealURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryToggleFavorite, press: press) {
            if !isTrash, let item = primaryTarget(in: items) {
                dataManager.toggleFavorite(videoIDs: targetIDs(for: item))
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryDelete, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { showBulkDeleteConfirmation = true }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMoveToTrash, press: press) {
            guard !isTrash else { return .handled }
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty {
                dataManager.moveToTrash(videoIDs: Array(selectedVideoIDs))
                selectedVideoIDs.removeAll()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRestoreFromTrash, press: press) {
            guard isTrash else { return .handled }
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty {
                dataManager.restoreFromTrash(videoIDs: Array(selectedVideoIDs))
                selectedVideoIDs.removeAll()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryExport, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { exportSelectedItems() }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRandomPlay, press: press) {
            guard !isTrash else { return .handled }
            startRandomPlayback(from: items.filter { $0.mediaType == .video })
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMultiPlay, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count >= 2 { startMultiPlayback(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryVariantPlay, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count >= 2 { startVariantSwitchPlayback(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySlideshow, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count >= 2 { startSlideshowPlayback(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySplitPlay, press: press) {
            guard !isTrash else { return .handled }
            let selected = selectedVideoItems
            if selected.count == 1, let video = selected.first {
                splitTargetVideo = video
                showSplitSheet = true
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryEmptyTrash, press: press) {
            if isTrash, !dataManager.trashedVideos.isEmpty {
                showEmptyTrashAlert = true
            }
            return .handled
        }

        return .ignored
    }

    private func playFocused(items: [VideoItem]) {
        let selected = selectedVideoItems
        if selected.count > 1 {
            startMultiPlayback(selected)
        } else if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            open(item)
        } else if let first = items.first {
            open(first)
        }
    }

    private func primaryTarget(in items: [VideoItem]) -> VideoItem? {
        if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            return item
        }
        if let selectedID = selectedVideoIDs.first, let item = items.first(where: { $0.id == selectedID }) {
            return item
        }
        return items.first
    }

    /// 選択中の動画を Finder と同じクイックルックパネルで開く（動画専用。画像は対象外）。
    /// Finder と同じく、複数選択しているときはその選択ぶんをパネル内で送れるようにする。
    /// 一覧全件を渡さないのは、URL の解決が1件ずつファイル探索になるため
    /// 大きなアルバムで Space を押すたびに数千回のファイルIOが走ってしまうから。
    private func quickLookFocusedVideo(in items: [VideoItem], proxy: ScrollViewProxy) {
        guard let target = primaryTarget(in: items), target.mediaType == .video else { return }
        var candidates = selectedVideoIDs.count > 1 ? items.filter { selectedVideoIDs.contains($0.id) } : []
        if !candidates.contains(where: { $0.id == target.id }) { candidates = [target] }

        let targets = QuickLookPreviewController.previewTargets(in: candidates, focusedOn: target) {
            dataManager.fileURL(for: $0)
        }
        guard let startIndex = targets.startIndex else { return }

        // プレビュー中の矢印キーで一覧の選択を動かし、その項目をそのまま表示させる。
        // グリッドと同じ moveFocus を通すので、列数ぶんの上下移動もスクロール追従も一致する。
        QuickLookPreviewController.shared.onNavigate = { direction in
            guard let moved = moveFocus(direction, items: items, proxy: proxy) else { return nil }
            return dataManager.fileURL(for: moved)
        }
        QuickLookPreviewController.shared.present(urls: targets.urls, startingAt: startIndex)
    }

    private func ensureSelectionForFocusedItem(in items: [VideoItem]) {
        guard selectedVideoIDs.isEmpty, let item = primaryTarget(in: items) else { return }
        selectedVideoIDs = [item.id]
        lastSelectedVideoID = item.id
        focusedVideoID = item.id
    }

    @MainActor
    private func restoreReturnState(proxy: ScrollViewProxy) async {
        guard let state = coordinator.libraryReturnState else { return }
        let scope: PlaybackCoordinator.LibraryScope = categoryScope
        guard state.scope == scope else {
            coordinator.clearLibraryReturnState()
            return
        }

        searchText = state.searchText
        await Task.yield()

        let availableIDs = Set(displayedItems.map(\.id))
        selectedVideoIDs = state.selectedMediaIDs.intersection(availableIDs)
        focusedVideoID = state.focusedMediaID.flatMap {
            availableIDs.contains($0) ? $0 : nil
        }
        lastSelectedVideoID = state.selectionAnchorMediaID.flatMap {
            availableIDs.contains($0) ? $0 : nil
        }
        isGridFocused = true

        let targetID = state.scrollTargetMediaID.flatMap {
            availableIDs.contains($0) ? $0 : nil
        } ?? focusedVideoID

        if let targetID {
            for _ in 0..<3 {
                await Task.yield()
                proxy.scrollTo(targetID, anchor: .top)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            scrollTargetMediaID = targetID
        }
        coordinator.clearLibraryReturnState()
    }

    private func rememberGridState(opening mediaID: UUID? = nil) {
        let restoredSelection: Set<UUID>
        if let mediaID, !selectedVideoIDs.contains(mediaID) {
            restoredSelection = [mediaID]
        } else {
            restoredSelection = selectedVideoIDs
        }

        let scope: PlaybackCoordinator.LibraryScope = categoryScope
        coordinator.rememberLibraryState(
            PlaybackCoordinator.LibraryReturnState(
                scope: scope,
                selectedMediaIDs: restoredSelection,
                focusedMediaID: mediaID ?? focusedVideoID,
                selectionAnchorMediaID: mediaID ?? lastSelectedVideoID,
                scrollTargetMediaID: scrollTargetMediaID ?? mediaID ?? focusedVideoID,
                searchText: searchText
            )
        )
    }

    private func startRandomPlayback(from videos: [VideoItem]) {
        guard !videos.isEmpty else { return }
        rememberGridState()
        coordinator.playRandom(from: videos)
    }

    private func startMultiPlayback(_ videos: [VideoItem]) {
        guard videos.count >= 2 else { return }
        rememberGridState()
        coordinator.playMulti(videos)
    }

    private func startVariantSwitchPlayback(_ videos: [VideoItem]) {
        guard videos.count >= 2 else { return }
        rememberGridState()
        coordinator.playVariantSwitch(videos)
    }

    private func startContentAlignedVariantPlayback(_ videos: [VideoItem]) {
        guard videos.count >= 2 else { return }
        rememberGridState()
        coordinator.playContentAlignedVariantSwitch(videos)
    }

    private func startSlideshowPlayback(_ videos: [VideoItem]) {
        guard videos.count >= 2 else { return }
        rememberGridState()
        coordinator.startSlideshow(videos)
    }

    private func startSplitPlayback(video: VideoItem, splitCount: Int) {
        rememberGridState(opening: video.id)
        coordinator.playSplit(video: video, splitCount: splitCount)
    }

    /// 選択した項目のコピーを指定フォルダへ書き出す（元ファイルが失われた場合の安全弁）。
    private func exportSelectedItems() {
        // runModal はネストしたイベントループを回すため、パネル表示中もタイマーやHTTP起因の
        // 状態変更で selectedVideoIDs が変わりうる。対象はパネルを開く「前」に確定させる。
        let ids = Array(selectedVideoIDs)
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task {
            isExporting = true
            exportProgress = 0
            exportCurrent = 0
            exportTotal = ids.count
            let result = await dataManager.exportMedia(videoIDs: ids, to: folderURL) { current, total in
                exportCurrent = current
                exportTotal = total
                exportProgress = total == 0 ? 0 : Double(current) / Double(total)
            }
            isExporting = false
            exportResultMessage = result.failedCount > 0
                ? "\(result.successCount)件を書き出しました．\(result.failedCount)件は失敗しました．"
                : "\(result.successCount)件を書き出しました．"
            showExportResultAlert = true
        }
    }

    /// 「再生履歴」「続きを見る」から外す右クリック項目。どちらでもない画面では出さない。
    private func listRemoval(for video: VideoItem) -> (label: String, action: () -> Void)? {
        if isHistory {
            return ("履歴から削除", {
                watchState.removeHistory(videoIDs: targetIDs(for: video))
                selectedVideoIDs.removeAll()
            })
        }
        if isContinueWatching {
            // 捨てるのは視聴位置だけ。履歴にも動画そのものにも触らない
            // （「もう続きは要らない」と「観た記録を消したい」は別の意思表示）。
            return ("続きを見るから外す", {
                for id in targetIDs(for: video) { watchState.markFinished(videoID: id) }
                watchState.publishPendingChanges()
                selectedVideoIDs.removeAll()
            })
        }
        return nil
    }

    private var categoryScope: PlaybackCoordinator.LibraryScope {
        switch kind {
        case .favorites: return .favorites
        case .continueWatching: return .continueWatching
        case .history: return .history
        case .trash: return .trash
        }
    }

    @ViewBuilder
    private var emptyState: some View {
      if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ContentUnavailableView {
          Label("該当する項目がありません", systemImage: "magnifyingglass")
        } description: {
          Text("「\(searchText)」に一致するタイトルは見つかりませんでした．")
        } actions: {
          Button("検索を解除") { searchText = "" }
            .buttonStyle(AppActionButtonStyle(isPrimary: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          emptyStateTitle,
          systemImage: emptyStateSymbol,
          description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }

    private var emptyStateTitle: String {
        switch kind {
        case .favorites: return "お気に入りはありません"
        case .continueWatching: return "途中の動画はありません"
        case .history: return "再生履歴はありません"
        case .trash: return "ゴミ箱は空です"
        }
    }

    private var emptyStateSymbol: String {
        switch kind {
        case .favorites: return "heart"
        case .continueWatching: return "play.circle"
        case .history: return "clock.arrow.circlepath"
        case .trash: return "trash"
        }
    }

    private var emptyStateDescription: String {
        switch kind {
        case .favorites: return "グリッドの右クリックメニューからお気に入りに追加できます"
        case .continueWatching: return "最後まで観ずにやめた動画がここに並びます（ブラウザや iPhone で観た分も含みます）"
        case .history: return "再生した動画がここに新しい順で並びます（ブラウザや iPhone での再生も含みます）"
        case .trash: return "削除した項目はここに移動します"
        }
    }
}
