import Combine
import SwiftUI

// MARK: - 件数

/// レールのバッジに出す件数。ライブラリの全件を数えるので、描画のたびには数えず、
/// データが変わったあと少し待って（まとめて）数え直す。
@MainActor
final class RailCountsModel: ObservableObject {
    struct Counts: Equatable {
        var videos = 0
        var photos = 0
        var albums = 0
        var favorites = 0
        var continueWatching = 0
        var history = 0
        var trash = 0
    }

    @Published private(set) var counts = Counts()

    private let dataManager: LibraryViewModel
    private let watchState: WatchStateStore
    private var cancellable: AnyCancellable?

    init(dataManager: LibraryViewModel, watchState: WatchStateStore) {
        self.dataManager = dataManager
        self.watchState = watchState
        // 取り込みや視聴位置の更新は連続で起きるので、落ち着いてから1回だけ数える。
        cancellable = Publishers.Merge3(
            dataManager.$videos.map { _ in () },
            dataManager.$albums.map { _ in () },
            watchState.objectWillChange.map { _ in () }
        )
        .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        var trashedIDs = Set<UUID>()
        var availableIDs = Set<UUID>()
        var favorites = 0
        var continueWatching = 0
        let hasProgress = !watchState.progress.isEmpty
        let needsAvailable = !watchState.historyOrder.isEmpty

        for item in dataManager.videos {
            if item.isInTrash {
                trashedIDs.insert(item.id)
                continue
            }
            if needsAvailable { availableIDs.insert(item.id) }
            if item.isFavorite { favorites += 1 }
            if hasProgress, item.mediaType == .video,
               watchState.resumableSeconds(for: item.id, duration: item.duration) != nil {
                continueWatching += 1
            }
        }

        let history = watchState.historyOrder.reduce(0) { $0 + (availableIDs.contains($1) ? 1 : 0) }
        let albums = dataManager.albums
        func visibleCount(named name: String) -> Int {
            albums.first { $0.name == name }
                .map { album in album.videoIDs.reduce(0) { $0 + (trashedIDs.contains($1) ? 0 : 1) } } ?? 0
        }
        let albumCount = [false, true].reduce(0) {
            $0 + SidebarViewModel.treeAlbums(from: albums, isPhoto: $1).count
        }

        let next = Counts(
            videos: visibleCount(named: LibraryViewModel.allVideosAlbumName),
            photos: visibleCount(named: LibraryViewModel.allPhotosAlbumName),
            albums: albumCount,
            favorites: favorites,
            continueWatching: continueWatching,
            history: history,
            trash: trashedIDs.count
        )
        if next != counts { counts = next }
    }
}

// MARK: - アイコンのレール（サイドバーの左に並ぶ細い縦の列）

/// 主要な行き先と、ストレージ・設定のボタンを、アイコンだけでまとめた細い列。
/// 以前はサイドバーの上半分を「ライブラリ」の行が占め、アルバムの一覧が下に押されていた。
/// 行き先をここへ移すことで、サイドバーはアルバムの一覧に専念でき、サイドバーを隠してもレールは残る。
struct SidebarRailView: View {
    @StateObject private var countsModel: RailCountsModel
    @Binding var selection: NavigationSelection?
    /// 「すべての動画」「すべての画像」は、システムアルバムの ID で指す。ライブラリの読み込み前は nil。
    let allVideosAlbumID: UUID?
    let allPhotosAlbumID: UUID?
    let onShowStorage: () -> Void
    let onShowPreferences: () -> Void

    static let width: CGFloat = 56

    init(
        dataManager: LibraryViewModel,
        watchState: WatchStateStore,
        selection: Binding<NavigationSelection?>,
        allVideosAlbumID: UUID?,
        allPhotosAlbumID: UUID?,
        onShowStorage: @escaping () -> Void,
        onShowPreferences: @escaping () -> Void
    ) {
        _countsModel = StateObject(wrappedValue: RailCountsModel(dataManager: dataManager, watchState: watchState))
        _selection = selection
        self.allVideosAlbumID = allVideosAlbumID
        self.allPhotosAlbumID = allPhotosAlbumID
        self.onShowStorage = onShowStorage
        self.onShowPreferences = onShowPreferences
    }

    private struct Destination: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let target: NavigationSelection?
        var count: Int? = nil
    }

    /// 区切り線で分ける4つのまとまり：ホーム／ライブラリ全体／自分用の入口／作成ツール。
    private var groups: [[Destination]] {
        let c = countsModel.counts
        return [
            [
                Destination(id: "home", title: "ホーム", symbol: "house", target: .home),
            ],
            [
                Destination(id: "videos", title: "すべての動画", symbol: "film.stack", target: allVideosAlbumID.map { .album($0) }, count: c.videos),
                Destination(id: "photos", title: "すべての画像", symbol: "photo.stack", target: allPhotosAlbumID.map { .album($0) }, count: c.photos),
                Destination(id: "albums", title: "アルバム一覧", symbol: "square.grid.2x2", target: .albums, count: c.albums),
            ],
            [
                Destination(id: "favorites", title: "お気に入り", symbol: "heart", target: .favorites, count: c.favorites),
                Destination(id: "continue", title: "続きを見る", symbol: "play.circle", target: .continueWatching, count: c.continueWatching),
                Destination(id: "history", title: "再生履歴", symbol: "clock.arrow.circlepath", target: .history, count: c.history),
                Destination(id: "trash", title: "ゴミ箱", symbol: "trash", target: .trash, count: c.trash),
            ],
            [
                Destination(id: "musicVideo", title: "ミュージックビデオ", symbol: "music.note.tv", target: .musicVideo),
            ],
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 信号機ボタンとツールバーの帯の下から始める。
            Spacer().frame(height: 54)

            VStack(spacing: 6) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(NeomorphicTheme.separator)
                            .frame(width: 24, height: 0.5)
                            .padding(.vertical, 6)
                    }
                    ForEach(group) { item in
                        RailButton(
                            title: item.title,
                            symbol: item.symbol,
                            count: item.count,
                            isActive: item.target != nil && selection == item.target
                        ) {
                            if let target = item.target { selection = target }
                        }
                        .disabled(item.target == nil)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(spacing: 6) {
                RailButton(title: "ストレージ管理", symbol: "internaldrive", count: nil, isActive: false, action: onShowStorage)
                RailButton(title: "詳細設定", symbol: "gearshape", count: nil, isActive: SettingsRouting.isSettings(selection), action: onShowPreferences)
            }
            .padding(.bottom, 14)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }
}

/// レールの1ボタン。選んでいるものは面を一段明るくし、色は付けない（サイドバーの選択表示と同じ）。
private struct RailButton: View {
    let title: String
    let symbol: String
    /// 件数バッジ。nil か 0 のときは出さない（0 件のバッジが並ぶと、何もないのに目立つため）。
    let count: Int?
    let isActive: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isActive ? NeomorphicTheme.ink : NeomorphicTheme.muted)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? NeomorphicTheme.selection : (isHovering ? NeomorphicTheme.hover : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // 件数はアイコンの右上に小さく重ねる。幅の限られたレールに収まるよう、1,000 以上は「1.0K」の形にする。
        .overlay(alignment: .topTrailing) {
            if let count, count > 0 {
                Text(Self.compact(count))
                    .font(.appMicroStrong.monospacedDigit())
                    .foregroundStyle(isActive ? NeomorphicTheme.ink : NeomorphicTheme.muted)
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 16, minHeight: 15)
                    .background(Capsule().fill(NeomorphicTheme.rail))
                    .overlay(Capsule().strokeBorder(NeomorphicTheme.separator, lineWidth: 0.5))
                    .offset(x: 7, y: -3)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var helpText: String {
        guard let count else { return title }
        return "\(title)（\(count.formatted())）"
    }

    /// 999 まではそのまま、1,000 以上は「1.0K」「26K」の形（2文字ぶんの幅に収める）。
    private static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000: return "\(n / 1_000)K"
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}
