import AppKit
import SwiftUI

// MARK: - フォルダ詳細（子フォルダ・子アルバムを表紙付きで一覧する）

/// サイドバーでフォルダをクリックしたときに右ペインへ出す画面。
/// フォルダは実体を持たず、アルバム名の "/" 区切りだけで表現されているため、
/// ここでも `dataManager.albums` から毎回ツリーを組み直して該当ノードを引く
/// （サイドバーと同じ `SidebarAlbumNode.buildTree` を使うので階層・並び順は必ず一致する）。
struct FolderDetailView: View {
    let path: String
    let isPhoto: Bool
    @ObservedObject var dataManager: LibraryViewModel
    @Binding var selection: NavigationSelection?
    let onAnalyzeScenes: (VideoItem) -> Void

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var watchState: WatchStateStore

    /// このフォルダ直下のメディアの選択。フォルダ画面はキーボード送りまでは持たず、
    /// クリック（⌘で追加）だけの軽い選択にとどめる。
    @State private var selectedMediaIDs = Set<UUID>()
    @State private var showMoveToNewAlbumAlert = false
    @State private var newAlbumNameForMove = ""
    @State private var pendingMoveVideoIDs: [UUID] = []

    private var columnCount: Int {
        MediaGridLayout.columnCount(requested: appSettings.columnCount, availableWidth: gridWidth)
    }

    /// グリッドを置く領域の幅。狭いウィンドウで列を自動的に減らすために測る。
    @State private var gridWidth: CGFloat = 0

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: MediaGridLayout.spacing), count: columnCount)
    }

    /// このフォルダに対応するノード。アルバムのリネーム（サイドバーでのドラッグ移動）で
    /// パスごと消えることがあるため Optional で扱う。
    private var node: SidebarAlbumNode? {
        let albums = SidebarViewModel.treeAlbums(from: dataManager.albums, isPhoto: isPhoto)
        return SidebarAlbumNode.node(atPath: path, in: SidebarAlbumNode.buildTree(from: albums))
    }

    /// このフォルダ自身がアルバムを持つ場合（"旅行" という名前のアルバムが実在する場合）の中身。
    private var ownAlbum: Album? {
        node?.album
    }

    var body: some View {
        let context = FolderContent(
            node: node,
            videos: dataManager.videos,
            sortOrder: appSettings.sortOrder,
            sortReversed: appSettings.sortReversed,
            lastPlayed: watchState.lastPlayed,
            metadata: { dataManager.fileMetadata(for: $0) }
        )

        return VStack(spacing: 0) {
            LibraryPageHeader(
              title: path.components(separatedBy: "/").last ?? path,
              // 件数は、子フォルダ・子アルバムのカードと、このフォルダ直下のメディアの合計にする
              // （カードだけを数えると、メディアだけのフォルダが「0件」に見える）。
              subtitle: "フォルダ · \(path)", count: context.entries.count + context.directMedia.count
            )
            if node == nil {
                ContentUnavailableView(
                    "フォルダが見つかりません",
                    systemImage: "questionmark.folder",
                    description: Text("「\(path)」は移動または名前変更された可能性があります．")
                )
            } else if context.entries.isEmpty && context.directMedia.isEmpty {
                ContentUnavailableView(
                    "このフォルダは空です",
                    systemImage: "folder",
                    description: Text("アルバムをこのフォルダへドラッグすると，ここに表紙が並びます．")
                )
            } else {
                content(context)
            }

            Divider()
            MediaGridControlBar(dataManager: dataManager)
        }
        .background(CommandDeckBackground())
        .safeAreaInset(edge: .top, spacing: 0) {
            breadcrumb
        }
        .toolbar {
            if selectedMediaIDs.count == 1,
               let video = context.directMedia.first(where: { selectedMediaIDs.contains($0.id) }),
               video.mediaType == .video {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onAnalyzeScenes(video)
                    } label: {
                        Label("シーン抽出", systemImage: "waveform.path.ecg")
                    }
                    .help("選択した動画から候補シーンを抽出します")
                }
            }
        }
        .appAlert("新規アルバムに移動", isPresented: $showMoveToNewAlbumAlert) {
            TextField("アルバム名", text: $newAlbumNameForMove)
            Button("移動", action: moveToNewAlbum)
            Button("キャンセル", role: .cancel) {
                pendingMoveVideoIDs = []
                newAlbumNameForMove = ""
            }
        } message: {
            Text("\(pendingMoveVideoIDs.count)件を新しく作るアルバムへ移動します．")
        }
        .onDisappear {
            // 表紙のためにデコードした画像を持ち越さない（ディスクキャッシュは残るので戻れば即表示される）。
            MacVideoThumbnailView.evictFromMemoryCache(
                videoIDs: context.entries.flatMap { $0.coverItems.map(\.id) } + context.directMedia.map(\.id)
            )
        }
    }

    // MARK: - 本体

    private func content(_ context: FolderContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !context.entries.isEmpty {
                    sectionTitle("フォルダ・アルバム", count: context.entries.count)
                    LazyVGrid(columns: gridColumns, spacing: MediaGridLayout.spacing) {
                        ForEach(context.entries) { entry in
                            FolderEntryTile(
                                entry: entry,
                                dataManager: dataManager,
                                showTitle: appSettings.showTitles,
                                onOpen: { open(entry) }
                            )
                        }
                    }
                }

                if !context.directMedia.isEmpty {
                    sectionTitle("このフォルダのメディア", count: context.directMedia.count)
                    LazyVGrid(columns: gridColumns, spacing: MediaGridLayout.spacing) {
                        ForEach(context.directMedia) { video in
                            mediaCell(video, in: context.directMedia)
                        }
                    }
                }
            }
            .padding(MediaGridLayout.contentInset)
            .padding(.bottom, 12)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .background(
            // 背景クリックで選択解除
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selectedMediaIDs.removeAll() }
        )
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.appBody.weight(.medium))
                .foregroundStyle(NeomorphicTheme.muted)
            Text("\(count)")
                .font(.appMonoMicro.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
        .padding(.top, 4)
    }

    /// 「旅行 › 2024 › 沖縄」。フォルダを掘ったあとに1つ上へ戻れるようにする。
    private var breadcrumb: some View {
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        return HStack(spacing: 4) {
            // 一番左は「アルバム一覧」へ戻る入口。フォルダを掘ったあとに最上位へ一気に戻れる。
            Button {
                selection = .albums
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isPhoto ? "photo.stack" : "film.stack")
                        .font(.system(size: 11, weight: .semibold))
                    Text("アルバム")
                        .font(.appCaptionStrong)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("アルバム一覧へ戻る")
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)

            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }

                let isLast = index == parts.count - 1
                Button {
                    selection = .folder(
                        path: parts.prefix(index + 1).joined(separator: "/"),
                        isPhoto: isPhoto
                    )
                } label: {
                    Text(part)
                        .font(isLast ? Font.appCaptionStrong : Font.appCaption)
                        .foregroundStyle(isLast ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLast)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(NeomorphicTheme.canvas)
    }

    private func mediaCell(_ video: VideoItem, in items: [VideoItem]) -> some View {
        MediaGridItem(
            video: video,
            dataManager: dataManager,
            isSelected: selectedMediaIDs.contains(video.id),
            showTitle: appSettings.showTitles,
            showImportDate: appSettings.showImportDates,
            showRemoveFromAlbum: ownAlbum != nil,
            onSingleTap: { flags in
                if flags.contains(.command) {
                    if selectedMediaIDs.contains(video.id) {
                        selectedMediaIDs.remove(video.id)
                    } else {
                        selectedMediaIDs.insert(video.id)
                    }
                } else {
                    selectedMediaIDs = [video.id]
                }
            },
            onDoubleTap: { openFile(video, in: items) },
            onOpen: { openFile(video, in: items) },
            onOpenExternal: { openFileExternal(video) },
            onReveal: { revealInFinder(video) },
            onRemoveFromAlbum: {
                guard let albumID = ownAlbum?.id else { return }
                dataManager.removeVideosFromAlbum(videoIDs: targetIDs(for: video), albumID: albumID)
                selectedMediaIDs.removeAll()
            },
            onDelete: {
                dataManager.deleteVideos(videoIDs: targetIDs(for: video))
                selectedMediaIDs.removeAll()
            },
            onToggleFavorite: {
                dataManager.toggleFavorite(videoIDs: targetIDs(for: video))
            },
            onMoveToTrash: {
                dataManager.moveToTrash(videoIDs: targetIDs(for: video))
                selectedMediaIDs.removeAll()
            },
            onMoveToSystemTrash: {
                dataManager.moveMediaFilesToSystemTrash(
                    videoIDs: targetIDs(for: video)
                )
                selectedMediaIDs.removeAll()
            },
            currentAlbumID: ownAlbum?.id,
            onMoveToAlbum: { targetID in
                guard let albumID = ownAlbum?.id else { return }
                dataManager.moveVideos(videoIDs: targetIDs(for: video), from: albumID, to: targetID)
                selectedMediaIDs.removeAll()
            },
            onMoveToNewAlbum: {
                pendingMoveVideoIDs = targetIDs(for: video)
                newAlbumNameForMove = ""
                showMoveToNewAlbumAlert = true
            },
            onAnalyzeScenes: video.mediaType == .video ? {
                onAnalyzeScenes(video)
            } : nil,
            affectedItems: items.filter { targetIDs(for: video).contains($0.id) }
        )
        .id(video.id)
    }

    // MARK: - 操作

    /// 右クリックしたセルが選択に含まれていれば選択全体、含まれていなければそのセルだけを対象にする
    /// （アルバム詳細と同じ考え方。取り違えて選択全体を消してしまうのを防ぐ）。
    private func targetIDs(for video: VideoItem) -> [UUID] {
        selectedMediaIDs.contains(video.id) ? Array(selectedMediaIDs) : [video.id]
    }

    private func open(_ entry: FolderEntry) {
        switch entry.kind {
        case .folder(let childPath):
            selection = .folder(path: childPath, isPhoto: isPhoto)
        case .album(let albumID):
            selection = .album(albumID)
        }
    }

    private func openFile(_ video: VideoItem, in items: [VideoItem]) {
        if video.mediaType == .video {
            coordinator.playSingle(playlist: items.filter { $0.mediaType == .video }, current: video)
        } else {
            coordinator.viewPhotos(playlist: items.filter { $0.mediaType == .photo }, current: video)
        }
    }

    private func openFileExternal(_ video: VideoItem) {
        guard let url = dataManager.fileURL(for: video) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ video: VideoItem) {
        guard let url = dataManager.revealURL(for: video) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func moveToNewAlbum() {
        let name = newAlbumNameForMove.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoIDs = pendingMoveVideoIDs
        pendingMoveVideoIDs = []
        newAlbumNameForMove = ""
        guard !name.isEmpty, !videoIDs.isEmpty,
              let sourceAlbumID = ownAlbum?.id,
              let newAlbumID = dataManager.createAlbum(name: name, type: isPhoto ? .photo : .video) else { return }
        dataManager.moveVideos(videoIDs: videoIDs, from: sourceAlbumID, to: newAlbumID)
        selectedMediaIDs.removeAll()
    }
}

// MARK: - 表示内容の組み立て

/// フォルダ画面に並べる1タイル分。子フォルダと子アルバムを同じ見た目で扱う。
struct FolderEntry: Identifiable {
    enum Kind {
        case folder(path: String)
        case album(UUID)
    }

    let id: String
    let title: String
    let isFolder: Bool
    let kind: Kind
    /// 本数・合計時間・表紙など。サイドバーやアルバム一覧ページと同じ集計を使う。
    let summary: AlbumSummary

    var count: Int { summary.mediaCount }
    /// 表紙モザイクに使う代表メディア（最大4件）。
    var coverItems: [VideoItem] { summary.coverItems }
}

/// 1回の描画で必要なものをまとめて1度だけ計算する（body の中で何度も再計算しないため）。
struct FolderContent {
    let entries: [FolderEntry]
    let directMedia: [VideoItem]

    static let coverLimit = AlbumSummary.coverLimit

    init(
        node: SidebarAlbumNode?,
        videos: [VideoItem],
        sortOrder: SortOrder,
        sortReversed: Bool,
        lastPlayed: [UUID: Date],
        metadata: (VideoItem) -> VideoFileMetadata
    ) {
        guard let node else {
            entries = []
            directMedia = []
            return
        }

        let itemByID = AlbumSummary.itemIndex(videos)
        entries = Self.entries(for: node.children, itemByID: itemByID, includeEmpty: false)

        directMedia = (node.album?.videoIDs ?? [])
            .compactMap { itemByID[$0] }
            .sorted(by: sortOrder, reversed: sortReversed, lastPlayed: lastPlayed, metadata: metadata)
    }

    /// 子ノードをタイル1件ずつにする。アルバム一覧ページ（最上位）とフォルダ画面で同じ組み立てを使う。
    /// includeEmpty が false だと、中身のないアルバム／フォルダは出さない。
    static func entries(
        for nodes: [SidebarAlbumNode],
        itemByID: [UUID: VideoItem],
        includeEmpty: Bool
    ) -> [FolderEntry] {
        nodes.compactMap { child in
            let summary = AlbumSummary.of(node: child, itemByID: itemByID)
            guard includeEmpty || summary.mediaCount > 0 else { return nil }

            if child.children.isEmpty, let album = child.album {
                return FolderEntry(
                    id: child.id,
                    title: child.name,
                    isFolder: false,
                    kind: .album(album.id),
                    summary: summary
                )
            }
            return FolderEntry(
                id: child.id,
                title: child.name,
                isFolder: true,
                kind: .folder(path: child.id),
                summary: summary
            )
        }
    }
}

// MARK: - タイル

/// 子フォルダ／子アルバム1件分のタイル（2×2モザイクの表紙＋件数＋名前）。
struct FolderEntryTile: View {
    let entry: FolderEntry
    let dataManager: LibraryViewModel
    var showTitle: Bool = true
    /// 名前の下に「動画 12本 · 38分」のような要約を出すか。
    var showDetail: Bool = true
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumCoverMosaicView(items: entry.coverItems, dataManager: dataManager, isFolder: entry.isFolder)
                // 縁線は常時ごく細く、カーソルを乗せると少し濃く太くして「押せる」ことを示す（塗りではなく線で示す）。
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.30 : 0.10), lineWidth: isHovering ? 1.5 : 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if entry.isFolder {
                        badge(systemImage: "folder.fill")
                            .padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Text("\(entry.count)")
                        .font(.appMicroStrong)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .padding(7)
                }

            if showTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.appCaptionStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showDetail {
                        Text(entry.summary.detailText(isFolder: entry.isFolder))
                            .font(.appMicro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(MediaGridLayout.itemInset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen() }
        .help(
            (entry.isFolder ? "フォルダ「\(entry.title)」を開く" : "アルバム「\(entry.title)」を開く")
                + "\n" + entry.summary.detailText(isFolder: entry.isFolder)
        )
    }

    private func badge(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(.black.opacity(0.55)))
    }
}

/// 表紙。中身が4件以上なら2×2、少なければ枚数に応じて分割を変える。
struct AlbumCoverMosaicView: View {
    let items: [VideoItem]
    let dataManager: LibraryViewModel
    let isFolder: Bool

    private let tileGap: CGFloat = 1.5

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { mosaic }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var mosaic: some View {
        switch items.count {
        case 0:
            placeholder
        case 1:
            tile(items[0])
        case 2:
            HStack(spacing: tileGap) {
                tile(items[0])
                tile(items[1])
            }
        case 3:
            HStack(spacing: tileGap) {
                tile(items[0])
                VStack(spacing: tileGap) {
                    tile(items[1])
                    tile(items[2])
                }
            }
        default:
            VStack(spacing: tileGap) {
                HStack(spacing: tileGap) {
                    tile(items[0])
                    tile(items[1])
                }
                HStack(spacing: tileGap) {
                    tile(items[2])
                    tile(items[3])
                }
            }
        }
    }

    private func tile(_ item: VideoItem) -> some View {
        CoverThumbnail(item: item, dataManager: dataManager)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: isFolder ? "folder.fill" : "rectangle.stack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// モザイクの1マス。グリッドのセルと同じキャッシュから画像を取るので、
/// 一度表示したメディアの表紙は生成し直しにならない。
struct CoverThumbnail: View {
    let item: VideoItem
    let dataManager: LibraryViewModel

    @EnvironmentObject private var appSettings: AppSettings
    @State private var image: NSImage?

    var body: some View {
        Color.primary.opacity(0.08)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: item.id) {
                image = await MacVideoThumbnailView.loadThumbnail(
                    for: item,
                    dataManager: dataManager,
                    thumbnailOption: appSettings.thumbnailOption,
                    customThumbnailTime: appSettings.customThumbnailTime
                )
            }
    }
}
