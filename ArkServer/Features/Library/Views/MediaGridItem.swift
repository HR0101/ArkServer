import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - メディアグリッドアイテム（ホバー/選択ハイライト付き）
struct MediaGridItem: View {
    let video: VideoItem
    let dataManager: LibraryViewModel
    let isSelected: Bool
    var showTitle: Bool = true
    var showImportDate: Bool = true
    let showRemoveFromAlbum: Bool
    let onSingleTap: (NSEvent.ModifierFlags) -> Void
    let onDoubleTap: () -> Void
    let onOpen: () -> Void
    let onOpenExternal: () -> Void
    let onReveal: () -> Void
    let onRemoveFromAlbum: () -> Void
    let onDelete: () -> Void
    var isTrashView: Bool = false
    var onToggleFavorite: () -> Void = {}
    var onMoveToTrash: () -> Void = {}
    var onMoveToSystemTrash: () -> Void = {}
    var onRestore: () -> Void = {}
    var currentAlbumID: UUID? = nil
    var onMoveToAlbum: (UUID) -> Void = { _ in }
    var onMoveToNewAlbum: () -> Void = {}
    var onAnalyzeScenes: (() -> Void)?
    /// このセルのメニュー操作が実際に対象とする項目（表示順）。
    /// 複数選択中に右クリックすると選択全体が対象になるため、
    /// 確認文が「このセル1件」の話に見えないよう、対象の実態をここで受け取る。
    var affectedItems: [VideoItem] = []
    /// 「再生履歴」「続きを見る」でだけ渡す、その一覧から外すための項目。
    /// nil なら右クリックメニューに出さない。
    var onRemoveFromList: (label: String, action: () -> Void)?

    @EnvironmentObject private var watchState: WatchStateStore

    /// サムネイルの角丸。フォルダ／アルバムの表紙（FolderEntryTile）と同じ値にそろえる。
    static let thumbnailRadius: CGFloat = 10

    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    /// サムネイル下端に出す視聴済みバーの割合（0...1）。まだ観ていなければ 0。
    private var watchedFraction: Double {
        guard video.mediaType == .video else { return 0 }
        return watchState.watchedFraction(for: video.id, duration: video.duration)
    }

    /// 右クリックした1件，または現在選択中の全項目を表示順で確認シートへ渡す。
    private var deletionTargets: [VideoItem] {
        affectedItems.isEmpty ? [video] : affectedItems
    }

    /// 移動先候補（システムアルバム・現在のアルバムを除き、メディアタイプが互換のもの）
    private var moveTargetAlbums: [Album] {
        dataManager.albums.filter { album in
            album.name != LibraryViewModel.allVideosAlbumName &&
            album.name != LibraryViewModel.allPhotosAlbumName &&
            album.id != currentAlbumID &&
            (album.type == .mixed
             || (video.mediaType == .video && album.type == .video)
             || (video.mediaType == .photo && album.type == .photo))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacVideoThumbnailView(videoItem: video, dataManager: dataManager, showsPlayGlyph: false)
                // YouTube と同じ、サムネイル下端の視聴済みバー。
                // サムネイル側が角丸で切り抜いているので、こちらでも同じ形で切り抜いて下端に沿わせる。
                .overlay(alignment: .bottom) {
                    if watchedFraction > 0 {
                        // 幅の計算に GeometryReader は使わない。このアプリの
                        // NavigationSplitView 配下では入れ子の GeometryReader が
                        // 描画位置を崩すことがあるため、単純な横方向の拡大で出す。
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.55))
                            Rectangle()
                                .fill(Color.accentColor)
                                .scaleEffect(x: watchedFraction, anchor: .leading)
                        }
                        .frame(height: 4)
                        .accessibilityLabel("視聴済み \(Int(watchedFraction * 100))パーセント")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous))
                // 明るい/暗い画像のどちらでも輪郭が立つよう、ごく細い縁線を引く。選択中はアクセント色の枠にする。
                .overlay(
                    RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                // 再生ボタンは常時ではなく、カーソルを乗せたときだけ出す（全サムネイルに付くと画面がうるさい）。
                .overlay {
                    if isHovering && video.mediaType == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if video.mediaType == .video, video.duration > 0 {
                        Text(formatDuration(video.duration))
                            .font(.appMicroStrong)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.62)))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 常時は状態表示のみ（お気に入り済みならハート）。ホバー中は右クリック
                    // メニューを開かなくてもワンクリックでトグルできるボタンにする。
                    if isHovering && !isTrashView {
                        Button(action: onToggleFavorite) {
                            Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                                .font(.appBody)
                                .foregroundStyle(.red)
                                .padding(7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(video.isFavorite ? "お気に入りから外す" : "お気に入りに追加")
                    } else if video.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.appBody)
                            .foregroundStyle(.red)
                            .padding(7)
                    }
                }

            if showTitle || showImportDate {
                VStack(alignment: .leading, spacing: 2) {
                    if showTitle {
                        Text(video.originalFilename)
                            .font(.appCaptionStrong)
                            .foregroundStyle(NeomorphicTheme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if showImportDate {
                        Text(MediaGridItem.itemFormatter.string(from: video.importDate))
                            .font(.appMicro)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(MediaGridLayout.itemInset)
        // 選択はサムネイルのアクセント枠で示すので、セル全体の塗りは付けない（枠と塗りの二重で重く見えるため）。
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            // アニメーション付きだとセルの出入りのたびにトランザクションが発生し、
            // 大量枚数のグリッドでスクロールがカクつく原因になるため即時反映にしている。
            isHovering = hovering
        }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) {
            onSingleTap(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .appContextMenu {
            Button("開く") { onOpen() }
            if video.mediaType == .video, !isTrashView, let onAnalyzeScenes {
                Button("シーン抽出") { onAnalyzeScenes() }
            }
            Button("外部プレイヤーで開く") { onOpenExternal() }
            Button("Finderで表示") { onReveal() }
            Button("フォルダにエクスポート…") { exportThisItem() }
            Divider()
            if isTrashView {
                Button("元に戻す") { onRestore() }
                Button("完全に削除…", role: .destructive) { showDeleteConfirmation = true }
            } else {
                Button(video.isFavorite ? "お気に入りから外す" : "お気に入りに追加") { onToggleFavorite() }
                AppChoiceMenu("アルバムに移動") {
                    ForEach(moveTargetAlbums) { album in
                        Button(album.name) { onMoveToAlbum(album.id) }
                    }
                    if !moveTargetAlbums.isEmpty { Divider() }
                    Button("新規アルバム…") { onMoveToNewAlbum() }
                }
                if showRemoveFromAlbum {
                    Button("アルバムから外す") { onRemoveFromAlbum() }
                }
                if let onRemoveFromList {
                    Button(onRemoveFromList.label) { onRemoveFromList.action() }
                }
                Divider()
                Button("削除…", role: .destructive) { showDeleteConfirmation = true }
            }
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            MediaDeletionConfirmationSheet(
                items: deletionTargets,
                dataManager: dataManager,
                onMoveToAppTrash: isTrashView ? nil : onMoveToTrash,
                onDeleteCompletely: onDelete,
                onMoveToSystemTrash: onMoveToSystemTrash
            )
        }
    }

    /// この1件を選んだフォルダへコピーとして書き出す（元ファイルを万一失っても手元にコピーが残る安全弁）。
    private func exportThisItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task { await dataManager.exportMedia(videoIDs: [video.id], to: folderURL) }
    }

    private static let itemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private func formatDuration(_ totalSeconds: TimeInterval) -> String {
        let secondsInt = Int(totalSeconds)
        return String(format: "%02d:%02d", secondsInt / 60, secondsInt % 60)
    }
}
