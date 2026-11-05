import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AlbumDetailView
struct AlbumDetailView: View {
    let album: Album
    @ObservedObject var dataManager: LibraryViewModel
    let onAnalyzeScenes: (VideoItem) -> Void

    @State private var isTargeted = false
    @State private var selectedVideoIDs = Set<UUID>()
    @State private var showMixedContentAlert = false
    @State private var pendingFolderURL: URL?
    @State private var mixedContentInfo = ""
    @State private var lastSelectedVideoID: UUID?
    @State private var searchText = ""
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

    // ラフ画・線画の抽出
    @State private var showSketchCleanup = false
    // 似ているメディアの整理
    @State private var showSimilarMedia = false


    // 分割再生用
    @State private var showSplitSheet = false
    @State private var splitCount: Int = 4
    @State private var splitTargetVideo: VideoItem?

    @State private var isCheckingDuplicates = false
    @State private var duplicateCheckProgress: Double = 0
    @State private var duplicateCheckCurrent = 0
    @State private var duplicateCheckTotal = 0
    @State private var duplicateCheckResultMessage = ""
    @State private var showDuplicateCheckResultAlert = false

    @State private var isImporting = false
    @State private var importedCount = 0

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportCurrent = 0
    @State private var exportTotal = 0
    @State private var exportResultMessage = ""
    @State private var showExportResultAlert = false

    @State private var showBulkDeleteConfirmation = false

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var watchState: WatchStateStore

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

    /// ツールバーの「整理」メニューに出せる項目が1つでもあるか。
    private var hasOrganizeTools: Bool {
        canRemoveItemsFromCurrentAlbum || displayedItems.count >= 2
            || displayedItems.contains(where: { $0.mediaType == .photo })
    }

    private var currentAlbum: Album {
        dataManager.albums.first(where: { $0.id == album.id }) ?? album
    }

    private var isLinkedToFolder: Bool {
        currentAlbum.linkedFolderPath != nil || currentAlbum.linkedFolderBookmarkData != nil
    }

    /// 検索・並べ替えを適用した表示アイテム（動画＋画像、ゴミ箱を除く）
    private var displayedItems: [VideoItem] {
        let memberIDs = Set(album.videoIDs)
        return dataManager.videos
            .filter { memberIDs.contains($0.id) && !$0.isInTrash }
            .filtered(bySearch: searchText)
            .sorted(by: appSettings.sortOrder, reversed: appSettings.sortReversed, lastPlayed: watchState.lastPlayed) { dataManager.fileMetadata(for: $0) }
    }

    /// このアルバムの動画のみ（表示順）
    private var albumVideoItems: [VideoItem] {
        displayedItems.filter { $0.mediaType == .video }
    }

    /// 現在の選択のうち動画のみ（表示順）
    private var selectedVideoItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }
    }

    /// 現在の選択すべて（表示順、画像も含む）。削除の確認で何を消すのか見せるために使う。
    private var selectedItems: [VideoItem] {
        displayedItems.filter { selectedVideoIDs.contains($0.id) }
    }

    private func headerSubtitle(for items: [VideoItem]) -> String {
        var parts: [String] = []
        let folders = album.name.components(separatedBy: "/").dropLast()
        if canRemoveItemsFromCurrentAlbum, !folders.isEmpty {
            parts.append(folders.joined(separator: " › "))
        }
        parts.append(AlbumSummary.of(items: items).detailText(isFolder: false))
        return parts.joined(separator: " · ")
    }

    private var canRemoveItemsFromCurrentAlbum: Bool {
        album.name != LibraryViewModel.allVideosAlbumName && album.name != LibraryViewModel.allPhotosAlbumName
    }

    var body: some View {
        // displayedItems（フィルタ＋ソート）は件数が多いと軽くないため、1回の描画につき1回だけ計算し、
        // toolbar/sheet も含めて使い回す（以前は同じ描画の中で何度も呼ばれ、そのたびに再計算されていた）。
        let items = displayedItems
        let videoItems = items.filter { $0.mediaType == .video }
        let selectedItems = items.filter { selectedVideoIDs.contains($0.id) && $0.mediaType == .video }

        return VStack(spacing: 0) {
            LibraryPageHeader(
              title: album.displayTitle,
              // 2行目は「動画 12本 · 38分」のような中身の要約にする（以前は見出しと同じ名前の繰り返しだった）。
              // 階層のあるアルバムは、場所が分かるよう親フォルダのパスを頭に付ける。
              subtitle: headerSubtitle(for: items)
            )
            ZStack {
                // 背景タップで選択解除（カードタップ時は内側のジェスチャーが優先される）
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedVideoIDs.removeAll()
                        lastSelectedVideoID = nil
                    }

                if items.isEmpty {
                    if searchText.isEmpty { emptyState } else { noResultsState }
                } else {
                    grid(items)
                }

                if isTargeted {
                    dropOverlay
                }

                if isCheckingDuplicates {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView("重複チェック中...", value: duplicateCheckProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                            .tint(.accentColor)
                            .foregroundColor(.white)
                        Text("\(duplicateCheckCurrent) / \(duplicateCheckTotal) (\(Int(duplicateCheckProgress * 100))%)")
                            .foregroundColor(.white)
                            .font(.appBody)
                    }
                    .padding(20)
                    .background(NeomorphicTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 0.5))
                    .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
                }

                // フォルダの中身が多いと動画の尺・撮影日時の読み込みに時間がかかるため、
                // 「固まっているように見える」ことがないよう進捗（処理件数）を表示する。
                if isImporting {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.accentColor)
                        Text("インポート中...（\(importedCount)件処理済み）")
                            .foregroundColor(.white)
                            .font(.appBody)
                    }
                    .padding(20)
                    .background(NeomorphicTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 0.5))
                    .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
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
            MediaGridControlBar(dataManager: dataManager)
        }
        .background(CommandDeckBackground())
        .searchable(text: $searchText, placement: .toolbar, prompt: "タイトルを検索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
              LibraryTourMenu(videos: videoItems, dataManager: dataManager, beforePlay: { rememberGridState() })
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: importFilesViaDialog) {
                    Label("インポート", systemImage: "plus.circle")
                }
                .help("ファイルまたはフォルダをインポート")
            }

            if canRemoveItemsFromCurrentAlbum {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: isLinkedToFolder ? rescanLinkedFolder : linkFolderViaDialog) {
                        Label(isLinkedToFolder ? "フォルダ更新" : "フォルダ紐づけ", systemImage: isLinkedToFolder ? "arrow.triangle.2.circlepath" : "folder.badge.plus")
                    }
                    .help(isLinkedToFolder ? "紐づけフォルダを再スキャンして新規メディアを取り込みます" : "このアルバムにFinder上のフォルダを紐づけます")
                    .disabled(isImporting)
                }
            }

            // 重複チェック・似ているもの・差分動画などの整理系ツールは，アイコンだけを5つ並べると
            // 見分けがつかないため，名前付きの1つのメニューにまとめる。
            ToolbarItem(placement: .primaryAction) {
                if hasOrganizeTools {
                    AppChoiceMenu {
                        // 重複チェックはアルバム単位でのみ意味を持つ（すべての動画/画像には全アルバムのメディアが
                        // 集まっているため、ここで実行すると別アルバム同士のメディアまで重複扱いになってしまう）。
                        if canRemoveItemsFromCurrentAlbum {
                            Button(action: runDuplicateCheck) {
                                Label("重複チェック", systemImage: "checkmark.seal")
                            }
                            .help("このアルバム内の重複メディアを検出してゴミ箱へ移動")
                            .disabled(isCheckingDuplicates || dataManager.isDuplicateCheckRunning || items.isEmpty)
                        }

                        // 似ているメディアの整理（重複チェックと違い、完全一致でなくても拾う）
                        if items.count >= 2 {
                            Button {
                                showSimilarMedia = true
                            } label: {
                                Label("似ているものを探す", systemImage: "square.on.square.dashed")
                            }
                            .help("見た目が似ているメディアをまとめて表示し，残す1件を選んで残りを削除します")
                        }

                        // ラフ画・線画の抽出（画像がある場合のみ）
                        if items.contains(where: { $0.mediaType == .photo }) {
                            Button {
                                showSketchCleanup = true
                            } label: {
                                Label("ラフ画・線画を探す", systemImage: "scribble.variable")
                            }
                            .help("このアルバムの画像からラフ画・線画を自動で拾い出して，確認してから削除します")
                        }

                        if videoItems.count >= 2 {
                            Divider()
                            // 差分動画（同じ尺・同じ動きで絵だけ違う書き出し）を探して切り替え再生へ渡す
                            Button {
                                openVariantFinder(alignmentMode: .sameTime)
                            } label: {
                                Label("差分動画を探す", systemImage: "rectangle.on.rectangle.angled")
                            }
                            .help("尺が揃っていて絵だけが違う動画を束にして，選んだぶんを切り替えながら再生します")

                            // 尺が違っても，動画内の一部に同じ場面が続く強制差分候補を探す
                            Button {
                                openVariantFinder(alignmentMode: .content)
                            } label: {
                                Label("強制差分候補を探す", systemImage: "link.badge.plus")
                            }
                            .help("尺が大きく違っても，一部に同じ場面が続く動画を探します")
                        }
                    } label: {
                        Label("整理", systemImage: "wand.and.stars")
                    }
                    .help("重複チェック・似ているもの・差分動画など，アルバムを整理する機能")
                }
            }

            // ランダム同時再生（本数を選ぶと、このアルバムからその数だけ無作為に選んで並べる）
            ToolbarItem(placement: .primaryAction) {
                if videoItems.count >= 2 {
                    AppChoiceMenu {
                        ForEach(2...min(9, videoItems.count), id: \.self) { count in
                            Button("\(count)本") {
                                startMultiPlayback(Array(videoItems.shuffled().prefix(count)))
                            }
                        }
                    } label: {
                        Label("ランダム同時再生", systemImage: "square.grid.2x2")
                    }
                    .help("このアルバムの動画から，選んだ本数だけ無作為に選んで同時再生します")
                }
            }

            // ランダム再生（選択不要・このアルバムの動画をシャッフルして連続再生）
            ToolbarItem(placement: .primaryAction) {
                if !videoItems.isEmpty {
                    Button {
                        startRandomPlayback(from: videoItems)
                    } label: {
                        Label("ランダム再生", systemImage: "shuffle")
                    }
                    .help("このアルバムの動画をシャッフルして再生")
                }
            }

            if !selectedVideoIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Text("\(selectedVideoIDs.count)項目を選択中")
                        .font(.appMicro)
                        .foregroundStyle(.secondary)
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
                ToolbarItem(placement: .primaryAction) {
                    if selectedItems.count == 1, let video = selectedItems.first {
                        Button {
                            splitTargetVideo = video
                            showSplitSheet = true
                        } label: {
                            Label("分割再生", systemImage: "rectangle.split.2x2")
                        }
                        .help("選択した動画を指定数で分割して同時再生")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: exportSelectedItems) {
                        Label("エクスポート", systemImage: "square.and.arrow.up")
                    }
                    .help("選択した項目のコピーを指定フォルダへ書き出す（元ファイルが失われた場合の安全弁）")
                }
                if canRemoveItemsFromCurrentAlbum {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: removeSelectedFromAlbum) {
                            Label("アルバムから外す", systemImage: "minus.circle")
                        }
                        .help("選択した項目をこのアルバムから外す（メディア自体は削除されません）")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { showBulkDeleteConfirmation = true } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .help("選択した項目をゴミ箱に入れるか完全に削除します")
                }
            }
        }
        .sheet(isPresented: $showBulkDeleteConfirmation) {
            MediaDeletionConfirmationSheet(
                items: self.selectedItems,
                dataManager: dataManager,
                onMoveToAppTrash: moveSelectedToTrash,
                onDeleteCompletely: deleteSelectedVideos,
                onMoveToSystemTrash: moveSelectedToSystemTrash
            )
        }
        .sheet(isPresented: $showSketchCleanup) {
            SketchCleanupView(items: displayedItems, dataManager: dataManager) {
                selectedVideoIDs.removeAll()
                lastSelectedVideoID = nil
            }
        }
        .sheet(isPresented: $showSimilarMedia) {
            SimilarMediaView(items: displayedItems, dataManager: dataManager) {
                selectedVideoIDs.removeAll()
                lastSelectedVideoID = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            return handleDrop(providers: providers)
        }
        .appAlert("異なるメディアタイプの混在", isPresented: $showMixedContentAlert) {
            Button("現在のアルバムのタイプ (\(album.type.displayName)) としてインポート") {
                if let url = pendingFolderURL {
                    Task {
                        isImporting = true
                        importedCount = 0
                        let progress = ImportProgressThrottle { importedCount = $0 }
                        await dataManager.importAndLinkFolder(folderURL: url, as: album.type) { progress.tick() }
                        progress.finish()
                        isImporting = false
                        pendingFolderURL = nil
                    }
                }
            }
            Button("キャンセル", role: .cancel) { pendingFolderURL = nil }
        } message: {
            Text("\(mixedContentInfo)\n指定したタイプ (\(album.type.displayName)) 以外のファイルは無視されます．")
        }
        .appAlert("重複チェック完了", isPresented: $showDuplicateCheckResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(duplicateCheckResultMessage)
        }
        .appAlert("エクスポート完了", isPresented: $showExportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportResultMessage)
        }
        .appAlert("新規アルバムに移動", isPresented: $showMoveToNewAlbumAlert) {
            TextField("アルバム名", text: $newAlbumNameForMove)
            Button("作成して移動") {
                let name = newAlbumNameForMove.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !pendingMoveVideoIDs.isEmpty,
                      let newID = dataManager.createAlbum(name: name, type: album.type) else { return }
                dataManager.moveVideos(videoIDs: pendingMoveVideoIDs, from: album.id, to: newID)
                pendingMoveVideoIDs = []
                selectedVideoIDs.removeAll()
                lastSelectedVideoID = nil
            }
            Button("キャンセル", role: .cancel) { pendingMoveVideoIDs = [] }
        } message: {
            Text("移動先の新しいアルバム名を入力してください．")
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
        // 他のアルバムに移動したら、このアルバムのデコード済みサムネイルはメモリから解放する。
        // ディスクキャッシュは消さないので、戻ってきたときの再表示は速いまま。
        .onDisappear {
            MacVideoThumbnailView.evictFromMemoryCache(videoIDs: items.map { $0.id })
        }
    }

    // MARK: - Grid + keyboard navigation

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
                            showRemoveFromAlbum: album.name != LibraryViewModel.allVideosAlbumName && album.name != LibraryViewModel.allPhotosAlbumName,
                            onSingleTap: { flags in
                                handleGridSelection(for: video, in: items, flags: flags)
                                focusedVideoID = video.id
                                // クリック後もそのまま矢印キーで送れるようにフォーカスを戻す。
                                isGridFocused = true
                            },
                            onDoubleTap: { openFile(video) },
                            onOpen: { openFile(video) },
                            onOpenExternal: { openFileExternal(video) },
                            onReveal: { revealInFinder(video) },
                            onRemoveFromAlbum: {
                                dataManager.removeVideosFromAlbum(videoIDs: [video.id], albumID: album.id)
                            },
                            onDelete: {
                                // 「ゴミ箱に入れる」と対象範囲を揃える。複数選択中に右クリックしたとき、
                                // ゴミ箱行きは選択全体なのに完全削除だけ1件、では取り違えのもとになる。
                                dataManager.deleteVideos(videoIDs: effectiveTargetIDs(for: video))
                            },
                            onToggleFavorite: {
                                dataManager.toggleFavorite(videoIDs: effectiveTargetIDs(for: video))
                            },
                            onMoveToTrash: {
                                dataManager.moveToTrash(videoIDs: effectiveTargetIDs(for: video))
                                selectedVideoIDs.removeAll()
                                lastSelectedVideoID = nil
                            },
                            onMoveToSystemTrash: {
                                dataManager.moveMediaFilesToSystemTrash(
                                    videoIDs: effectiveTargetIDs(for: video)
                                )
                                selectedVideoIDs.removeAll()
                                lastSelectedVideoID = nil
                            },
                            currentAlbumID: album.id,
                            onMoveToAlbum: { targetID in
                                dataManager.moveVideos(videoIDs: effectiveTargetIDs(for: video), from: album.id, to: targetID)
                                selectedVideoIDs.removeAll()
                                lastSelectedVideoID = nil
                            },
                            onMoveToNewAlbum: {
                                pendingMoveVideoIDs = effectiveTargetIDs(for: video)
                                newAlbumNameForMove = ""
                                showMoveToNewAlbumAlert = true
                            },
                            onAnalyzeScenes: video.mediaType == .video ? {
                                onAnalyzeScenes(video)
                            } : nil,
                            affectedItems: menuTargets(for: video, in: items)
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
            .onKeyPress(phases: .down) { press in
                handleGridKey(press, items: items, proxy: proxy)
            }
            .onAppear {
                // グリッドにフォーカスを持たせて onKeyPress を有効化する
                isGridFocused = true
                if focusedVideoID == nil, let first = items.first { focusedVideoID = first.id }
            }
        }
    }

    /// 矢印キーでフォーカス移動、Enter/Option+Spaceで再生
    private func handleGridKey(_ press: KeyPress, items: [VideoItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        if handleLibraryShortcut(press, items: items, proxy: proxy) == .handled {
            return .handled
        }

        // Option+Space は既存互換の固定ショートカットとして残す。
        if press.key == .space, press.modifiers.contains(.option) {
            playFromGrid(items: items); return .handled
        }

        guard let focused = focusedVideoID, items.contains(where: { $0.id == focused }) else {
            let first = items[0].id
            focusedVideoID = first
            selectedVideoIDs = [first]
            lastSelectedVideoID = first
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
            playFromGrid(items: items)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryQuickLook, press: press) {
            quickLookFocusedVideo(in: items, proxy: proxy)
            return .handled
        } else if MediaShortcutSettings.matches(.libraryOpenExternal, press: press) {
            if let item = primaryTarget(in: items) { openFileExternal(item) }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRevealInFinder, press: press) {
            if let item = primaryTarget(in: items) { revealInFinder(item) }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryToggleFavorite, press: press) {
            if let item = primaryTarget(in: items) {
                dataManager.toggleFavorite(videoIDs: effectiveTargetIDs(for: item))
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryDelete, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { showBulkDeleteConfirmation = true }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMoveToTrash, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { moveSelectedToTrash() }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryExport, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if !selectedVideoIDs.isEmpty { exportSelectedItems() }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryImport, press: press) {
            importFilesViaDialog()
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRandomPlay, press: press) {
            startRandomPlayback(from: items.filter { $0.mediaType == .video })
            return .handled
        } else if MediaShortcutSettings.matches(.libraryMultiPlay, press: press) {
            let selected = selectedVideoItems
            if selected.count >= 2 { startMultiPlayback(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryVariantPlay, press: press) {
            let selected = selectedVideoItems
            if selected.count >= 2 { startVariantSwitchPlayback(selected) } else { openVariantFinder() }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySlideshow, press: press) {
            let selected = selectedVideoItems
            if selected.count >= 2 { startSlideshowPlayback(selected) }
            return .handled
        } else if MediaShortcutSettings.matches(.librarySplitPlay, press: press) {
            let selected = selectedVideoItems
            if selected.count == 1, let video = selected.first {
                splitTargetVideo = video
                showSplitSheet = true
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryDuplicateCheck, press: press) {
            if canRemoveItemsFromCurrentAlbum, !items.isEmpty {
                runDuplicateCheck()
            }
            return .handled
        } else if MediaShortcutSettings.matches(.libraryRemoveFromAlbum, press: press) {
            ensureSelectionForFocusedItem(in: items)
            if canRemoveItemsFromCurrentAlbum, !selectedVideoIDs.isEmpty {
                removeSelectedFromAlbum()
            }
            return .handled
        }

        return .ignored
    }

    /// 選択が複数なら同時再生、単一/フォーカス対象を通常再生
    private func playFromGrid(items: [VideoItem]) {
        let selectedVideos = selectedVideoItems
        if selectedVideos.count > 1 {
            startMultiPlayback(selectedVideos)
        } else if let focused = focusedVideoID, let item = items.first(where: { $0.id == focused }) {
            openFile(item)
        } else if let first = items.first {
            openFile(first)
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

    private var noResultsState: some View {
      ContentUnavailableView {
        Label("該当する項目がありません", systemImage: "magnifyingglass")
      } description: {
        Text("「\(searchText)」に一致するタイトルは見つかりませんでした．")
      } actions: {
        Button("検索を解除") { searchText = "" }
          .buttonStyle(AppActionButtonStyle(isPrimary: true))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("メディアがありません")
                .font(.appTitle)
            Text("ファイルやフォルダをここにドロップして追加")
                .font(.appBody)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                .foregroundStyle(.quaternary)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        ZStack {
            Rectangle()
                .fill(NeomorphicTheme.canvas.opacity(0.88))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("ドロップして追加")
                    .font(.appTitle)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8]))
                .padding(10)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    // アプリ内プレイヤーで開く（動画は全画面プレイヤー、画像はプレビュー）
    private func openFile(_ video: VideoItem) {
        rememberGridState(opening: video.id)
        if video.mediaType == .video {
            coordinator.playSingle(playlist: albumVideoItems, current: video)
        } else {
            coordinator.viewPhotos(playlist: displayedItems.filter { $0.mediaType == .photo }, current: video)
        }
    }

    // QuickTime Player など外部のデフォルトアプリで開く
    private func openFileExternal(_ video: VideoItem) {
        guard let url = dataManager.fileURL(for: video) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ video: VideoItem) {
        guard let url = dataManager.revealURL(for: video) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("📥 [DROP] アルバムへのドロップを受け取りました: providers=\(providers.count)")
        loadDroppedFileURLs(from: providers) { urls in
            var folderURLs: [URL] = []
            var fileURLs: [URL] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    folderURLs.append(url)
                } else {
                    fileURLs.append(url)
                }
            }

            if folderURLs.count == 1, fileURLs.isEmpty, let folderURL = folderURLs.first {
                let counts = dataManager.scanFolder(folderURL: folderURL)

                if (album.type == .video && counts.photoCount > 0) || (album.type == .photo && counts.videoCount > 0) {
                    self.mixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                    self.pendingFolderURL = folderURL
                    self.showMixedContentAlert = true
                    return
                }
            }

            Task {
                isImporting = true
                importedCount = 0
                let progress = ImportProgressThrottle { importedCount = $0 }
                for folderURL in folderURLs {
                    await dataManager.importAndLinkFolder(folderURL: folderURL, as: album.type) { progress.tick() }
                }
                await dataManager.importMediaFiles(from: fileURLs, to: album.id) { progress.tick() }
                progress.finish()
                isImporting = false
            }
        }
        return true
    }

    private func loadDroppedFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var loadedURLs: [URL] = []

        func loadNextProvider(at index: Int) {
            guard index < providers.count else {
                if loadedURLs.count != providers.count {
                    print("⚠️ [DROP] \(providers.count)件中\(loadedURLs.count)件のURLを取得しました．")
                }
                completion(loadedURLs)
                return
            }

            let provider = providers[index]
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = droppedFileURL(from: item)
                DispatchQueue.main.async {
                    if let url {
                        loadedURLs.append(url)
                    }
                    loadNextProvider(at: index + 1)
                }
            }
        }

        loadNextProvider(at: 0)
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        } else if let itemURL = item as? URL {
            return itemURL
        } else if let itemURL = item as? NSURL {
            return itemURL as URL
        }
        return nil
    }

    private func deleteSelectedVideos() {
        dataManager.deleteVideos(videoIDs: Array(selectedVideoIDs))
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    private func removeSelectedFromAlbum() {
        guard canRemoveItemsFromCurrentAlbum else { return }
        dataManager.removeVideosFromAlbum(videoIDs: Array(selectedVideoIDs), albumID: album.id)
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    private func moveSelectedToTrash() {
        dataManager.moveToTrash(videoIDs: Array(selectedVideoIDs))
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    private func moveSelectedToSystemTrash() {
        dataManager.moveMediaFilesToSystemTrash(
            videoIDs: Array(selectedVideoIDs)
        )
        selectedVideoIDs.removeAll()
        lastSelectedVideoID = nil
    }

    /// 選択した項目のコピーを指定フォルダへ書き出す。フォルダインポートは元ファイルを参照するだけで
    /// アプリはコピーを持たないため、誤って元ファイルを失っても手元に控えを残せる安全弁として使う。
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

    private func runDuplicateCheck() {
        guard !isCheckingDuplicates, !dataManager.isDuplicateCheckRunning else { return }

        isCheckingDuplicates = true
        duplicateCheckProgress = 0
        duplicateCheckCurrent = 0
        duplicateCheckTotal = displayedItems.count

        Task {
            let result = await dataManager.removeDuplicateMedia(in: album.id) { current, total in
                duplicateCheckCurrent = current
                duplicateCheckTotal = total
                duplicateCheckProgress = total == 0 ? 0 : Double(current) / Double(total)
            }

            duplicateCheckResultMessage = duplicateCheckMessage(for: result)
            isCheckingDuplicates = false
            selectedVideoIDs.removeAll()
            lastSelectedVideoID = nil
            showDuplicateCheckResultAlert = true
        }
    }

    private func duplicateCheckMessage(for result: DuplicateCheckResult) -> String {
        var lines: [String]
        if result.duplicateCount > 0 {
            lines = ["\(result.duplicateCount)件の重複メディアをゴミ箱へ移動しました．"]
        } else {
            lines = ["重複メディアは見つかりませんでした．"]
        }

        lines.append("確認した項目: \(result.checkedCount)件")
        if result.missingFileCount > 0 {
            lines.append("ファイルが見つからない項目: \(result.missingFileCount)件")
        }
        if result.failedHashCount > 0 {
            lines.append("ハッシュ計算に失敗した項目: \(result.failedHashCount)件")
        }
        return lines.joined(separator: "\n")
    }

    /// コンテキストメニュー操作の対象（右クリック対象が複数選択に含まれていれば選択全体）
    private func effectiveTargetIDs(for video: VideoItem) -> [UUID] {
        if selectedVideoIDs.contains(video.id) && selectedVideoIDs.count > 1 {
            return Array(selectedVideoIDs)
        }
        return [video.id]
    }

    /// `effectiveTargetIDs` と同じ対象を、確認文へ出すために表示順の項目として返す。
    private func menuTargets(for video: VideoItem, in items: [VideoItem]) -> [VideoItem] {
        guard selectedVideoIDs.contains(video.id), selectedVideoIDs.count > 1 else { return [video] }
        return items.filter { selectedVideoIDs.contains($0.id) }
    }

    private func handleGridSelection(for video: VideoItem, in videos: [VideoItem], flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), let lastID = lastSelectedVideoID {
            guard let lastIndex = videos.firstIndex(where: { $0.id == lastID }), let currentIndex = videos.firstIndex(where: { $0.id == video.id }) else { return }
            let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
            let idsToSelect = videos[range].map { $0.id }
            for id in idsToSelect { selectedVideoIDs.insert(id) }
        } else if flags.contains(.command) {
            if selectedVideoIDs.contains(video.id) { selectedVideoIDs.remove(video.id) } else { selectedVideoIDs.insert(video.id); lastSelectedVideoID = video.id }
        } else {
            selectedVideoIDs.removeAll(); selectedVideoIDs.insert(video.id); lastSelectedVideoID = video.id
        }
    }

    private func importFilesViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "インポートするファイルまたはフォルダを選択してください"

        switch album.type {
        case .video:
            panel.allowedContentTypes = [.movie, .video, .folder]
        case .photo:
            panel.allowedContentTypes = [.image, .folder]
        case .mixed:
            panel.allowedContentTypes = [.movie, .video, .image, .folder]
        }

        if panel.runModal() == .OK {
            let urls = panel.urls
            var folderURLs: [URL] = []
            var fileURLs: [URL] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    folderURLs.append(url)
                } else {
                    fileURLs.append(url)
                }
            }

            if folderURLs.count == 1, fileURLs.isEmpty, let folderURL = folderURLs.first {
                let counts = dataManager.scanFolder(folderURL: folderURL)

                if (album.type == .video && counts.photoCount > 0) || (album.type == .photo && counts.videoCount > 0) {
                    self.mixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                    self.pendingFolderURL = folderURL
                    self.showMixedContentAlert = true
                    return
                }
            }

            Task {
                isImporting = true
                importedCount = 0
                let progress = ImportProgressThrottle { importedCount = $0 }
                for folderURL in folderURLs {
                    await dataManager.importAndLinkFolder(folderURL: folderURL, as: album.type) { progress.tick() }
                }
                await dataManager.importMediaFiles(from: fileURLs, to: album.id) { progress.tick() }
                progress.finish()
                isImporting = false
            }
        }
    }

    private func linkFolderViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "このアルバムに紐づけるフォルダを選択してください"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        Task {
            isImporting = true
            importedCount = 0
            let progress = ImportProgressThrottle { importedCount = $0 }
            await dataManager.linkFolder(folderURL: folderURL, to: album.id) { progress.tick() }
            progress.finish()
            isImporting = false
        }
    }

    private func rescanLinkedFolder() {
        Task {
            isImporting = true
            importedCount = 0
            let progress = ImportProgressThrottle { importedCount = $0 }
            await dataManager.rescanLinkedFolder(albumID: album.id) { progress.tick() }
            progress.finish()
            isImporting = false
        }
    }

    @MainActor
    private func restoreReturnState(proxy: ScrollViewProxy) async {
        guard let state = coordinator.libraryReturnState else { return }
        guard state.scope == .album(album.id) else {
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

        coordinator.rememberLibraryState(
            PlaybackCoordinator.LibraryReturnState(
                scope: .album(album.id),
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

    /// 差分の一覧を ContentView の最上位へ開く。
    /// 表示中の検索・並べ替え順も渡し、その順番のまま探索できるようにする。
    private func openVariantFinder(
        alignmentMode: VariantPlaybackAlignmentMode = .sameTime
    ) {
        coordinator.openVariantFinder(
            albumID: album.id,
            itemIDs: displayedItems.map(\.id),
            hostSize: NSApp.keyWindow?.frame.size,
            alignmentMode: alignmentMode
        )
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
}

extension Album {
    /// 画面に出すアルバム名。システムアルバムの内部名（ALL VIDEOS など）は日本語にし，
    /// 階層付きの名前は末尾だけにする。ページ見出しとウィンドウタイトルで同じ表記を使う。
    @MainActor var displayTitle: String {
        switch name {
        case LibraryViewModel.allVideosAlbumName: return "すべての動画"
        case LibraryViewModel.allPhotosAlbumName: return "すべての画像"
        default: return name.components(separatedBy: "/").last ?? name
        }
    }
}
