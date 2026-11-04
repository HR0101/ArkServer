import SwiftUI

// MARK: - アルバム一覧ページ（動画・画像のアルバムを表紙つきで並べる）

/// サイドバーの「アルバム一覧」で右ペインに出す画面。
/// サイドバーは名前と件数しか見えず、アルバムが多いと中身の見当がつかないので、
/// 表紙・本数・合計時間を一度に見渡せるカードで並べる。フォルダは階層のまま、または全アルバムを平らに並べられる。
struct AlbumOverviewView: View {
    @ObservedObject var dataManager: LibraryViewModel
    @Binding var selection: NavigationSelection?

    @EnvironmentObject private var appSettings: AppSettings

    enum Kind: String, CaseIterable, Identifiable {
        case all = "すべて"
        case video = "動画"
        case photo = "画像"
        var id: String { rawValue }
    }

    enum Order: String, CaseIterable, Identifiable {
        case name = "名前"
        case count = "件数の多い順"
        case recent = "最近追加した順"
        case duration = "再生時間の長い順"
        var id: String { rawValue }
    }

    /// 動画ツリー／画像ツリーそれぞれのカード一式。
    private struct OverviewSection: Identifiable {
        let isPhoto: Bool
        let entries: [FolderEntry]
        var id: Bool { isPhoto }
        var title: String { isPhoto ? "画像アルバム" : "動画アルバム" }
    }

    @AppStorage("albumOverview.kind") private var kind: Kind = .all
    @AppStorage("albumOverview.order") private var order: Order = .name
    /// フォルダの中のアルバムも最上位に並べる（false なら、フォルダはフォルダとして1枚のカードにまとめる）。
    @AppStorage("albumOverview.flat") private var showsAllAlbums = false
    /// 中身のないアルバム（紐づけ元のフォルダが空になったものなど）を出さない。
    @AppStorage("albumOverview.hideEmpty") private var hidesEmpty = false

    @State private var searchText = ""
    @State private var sections: [OverviewSection] = []
    /// 絞り込み前の，実アルバムの総数（サイドバーの「アルバム一覧」の件数と同じ数え方）。
    @State private var totalAlbumCount = 0

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 検索中は、フォルダの中も含めて名前に一致するアルバムをすべて出す（サイドバーの検索と同じ考え方）。
    private var isFlat: Bool {
        showsAllAlbums || !trimmedQuery.isEmpty
    }

    private var totalCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryPageHeader(
                title: "アルバム",
                subtitle: isFlat
                    ? "フォルダの中も含めて，アルバムを1枚ずつ並べています．（全\(totalAlbumCount.formatted())アルバム）"
                    : "全\(totalAlbumCount.formatted())アルバム．フォルダのカードを開くと，中のアルバムが見られます．",
                count: totalCount
            )

            controls

            Divider()

            if totalCount == 0 {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(sections) { section in
                            if !section.entries.isEmpty {
                                sectionTitle(section.title, count: section.entries.count)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 14)],
                                    alignment: .leading,
                                    spacing: 14
                                ) {
                                    ForEach(section.entries) { entry in
                                        FolderEntryTile(
                                            entry: entry,
                                            dataManager: dataManager,
                                            onOpen: { open(entry, isPhoto: section.isPhoto) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(MediaGridLayout.contentInset)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(CommandDeckBackground())
        .searchable(text: $searchText, placement: .toolbar, prompt: "アルバム名を検索")
        .onAppear(perform: rebuild)
        .onChange(of: dataManager.albums) { rebuild() }
        .onChange(of: dataManager.videos) { rebuild() }
        .onChange(of: kind) { rebuild() }
        .onChange(of: order) { rebuild() }
        .onChange(of: showsAllAlbums) { rebuild() }
        .onChange(of: hidesEmpty) { rebuild() }
        .onChange(of: searchText) { rebuild() }
        .onDisappear {
            // 表紙のためにデコードした画像を持ち越さない（ディスクキャッシュは残るので戻れば即表示される）。
            MacVideoThumbnailView.evictFromMemoryCache(
                videoIDs: sections.flatMap { $0.entries.flatMap { $0.coverItems.map(\.id) } }
            )
        }
    }

    // MARK: - 操作バー

    /// 幅が足りないとチェックボックスの文言が折り返して崩れるので、そのときは2段に組み替える。
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                kindPicker
                flatToggle
                hideEmptyToggle
                orderMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    kindPicker
                    orderMenu
                }
                HStack(spacing: 16) {
                    flatToggle
                    hideEmptyToggle
                }
            }
        }
        .font(.appCaption)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindPicker: some View {
        FlatSegmentedControl(
            options: Kind.allCases,
            title: { $0.rawValue },
            selection: $kind,
            width: 190
        )
        .accessibilityLabel("種類")
    }

    private var flatToggle: some View {
        Toggle("フォルダの中も並べる", isOn: $showsAllAlbums)
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .fixedSize()
            .disabled(!trimmedQuery.isEmpty)
            .help(trimmedQuery.isEmpty
                ? "オンにすると，フォルダの中のアルバムも最上位に並べます．"
                : "検索中は，フォルダの中も含めて探します．")
    }

    private var hideEmptyToggle: some View {
        Toggle("空のアルバムを隠す", isOn: $hidesEmpty)
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .fixedSize()
            .help("中身が0件のアルバムを一覧から外します．オフでも，空のアルバムは各区画の末尾にまとまります．")
    }

    private var orderMenu: some View {
        Menu {
            ForEach(Order.allCases) { option in
                Toggle(option.rawValue, isOn: Binding(
                    get: { order == option },
                    set: { isOn in if isOn { order = option } }
                ))
            }
        } label: {
            Label("並び順：\(order.rawValue)", systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.appBody.weight(.medium))
                .foregroundStyle(NeomorphicTheme.muted)
            Text("\(count.formatted())")
                .font(.appMonoMicro.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView(
                "アルバムがありません",
                systemImage: "rectangle.stack",
                description: Text("サイドバーの＋でアルバムを作るか，フォルダをサイドバーへドラッグして取り込んでください．")
            )
        } else {
            ContentUnavailableView(
                "一致するアルバムはありません",
                systemImage: "magnifyingglass",
                description: Text("「\(trimmedQuery)」を名前に含むアルバムは見つかりませんでした．")
            )
        }
    }

    // MARK: - 組み立て

    /// 表示内容は videos / albums / 絞り込み条件が変わったときだけ組み立て直す
    /// （body のたびに全メディアを集計し直さないため）。
    private func rebuild() {
        let itemByID = AlbumSummary.itemIndex(dataManager.videos)
        let terms = trimmedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

        let built: [OverviewSection] = [false, true].compactMap { isPhoto in
            guard kind == .all || (kind == .photo) == isPhoto else { return nil }
            let albums = SidebarViewModel.treeAlbums(from: dataManager.albums, isPhoto: isPhoto)

            var entries: [FolderEntry]
            if isFlat {
                entries = albums
                    .filter { album in terms.allSatisfy { album.name.localizedStandardContains($0) } }
                    .map { album in
                        FolderEntry(
                            id: album.id.uuidString,
                            title: album.name,
                            isFolder: false,
                            kind: .album(album.id),
                            summary: AlbumSummary.of(album: album, itemByID: itemByID)
                        )
                    }
            } else {
                let roots = SidebarAlbumNode.buildTree(from: albums)
                // 作ったばかりの空のアルバムも出す（出ないと「作ったのに無い」ように見える）。
                entries = FolderContent.entries(for: roots, itemByID: itemByID, includeEmpty: true)
            }

            if hidesEmpty {
                entries.removeAll { $0.count == 0 }
            }
            entries.sort(by: ordering)
            return OverviewSection(isPhoto: isPhoto, entries: entries)
        }
        sections = built
        totalAlbumCount = [false, true]
            .filter { kind == .all || (kind == .photo) == $0 }
            .reduce(0) { $0 + SidebarViewModel.treeAlbums(from: dataManager.albums, isPhoto: $1).count }
    }

    private func ordering(_ lhs: FolderEntry, _ rhs: FolderEntry) -> Bool {
        // 中身のないアルバムは、どの並び順でも末尾にまとめる（先頭に並ぶと本命が見えなくなる）。
        if (lhs.count == 0) != (rhs.count == 0) { return lhs.count != 0 }
        let byName = lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        switch order {
        case .name:
            return byName
        case .count:
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return byName
        case .recent:
            switch (lhs.summary.latestImportDate, rhs.summary.latestImportDate) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return byName
            }
        case .duration:
            if lhs.summary.totalDuration != rhs.summary.totalDuration {
                return lhs.summary.totalDuration > rhs.summary.totalDuration
            }
            return byName
        }
    }

    private func open(_ entry: FolderEntry, isPhoto: Bool) {
        switch entry.kind {
        case .folder(let path):
            selection = .folder(path: path, isPhoto: isPhoto)
        case .album(let albumID):
            selection = .album(albumID)
        }
    }
}
