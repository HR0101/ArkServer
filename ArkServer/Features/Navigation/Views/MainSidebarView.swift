import SwiftUI
import UniformTypeIdentifiers

struct MainSidebarView: View {
    @StateObject private var viewModel = SidebarViewModel()
    @ObservedObject var dataManager: LibraryViewModel
    @ObservedObject var webServerManager: ServerViewModel
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject private var watchState: WatchStateStore
    @Binding var selection: NavigationSelection?

    @State private var albumSearchText = ""
    @State private var albumFilter = "すべて"
    @FocusState private var isAlbumSearchFocused: Bool

    @State private var isShowingAddAlbumSheet = false
    @State private var newAlbumName = ""
    @State private var newAlbumType: AlbumType = .video
    @State private var albumDeletionRequest: AlbumDeletionRequest?
    @State private var isAlbumSelectionMode = false
    @State private var selectedAlbumIDs = Set<UUID>()

    @State private var isSidebarTargeted = false
    @State private var showSidebarMixedContentAlert = false
    @State private var pendingSidebarFolderURL: URL?
    @State private var sidebarMixedContentInfo = ""

    @State private var isShowingCreateFolderFromSelectionAlert = false
    @State private var newFolderNameForSelection = ""
    @State private var dropTargetFolderID: String?

    // サイドバーへ個別ファイル（フォルダではない写真・動画）を直接ドロップしたときに、
    // 新規アルバム名を入力させて取り込むための状態
    @State private var isShowingSidebarFileImportAlbumNameAlert = false
    @State private var newAlbumNameForSidebarFileImport = ""
    @State private var pendingSidebarFileURLs: [URL] = []

    // サイドバーからアルバム/フォルダをまるごとエクスポートするときの進捗
    @State private var isExportingFromSidebar = false
    @State private var sidebarExportCurrent = 0
    @State private var sidebarExportTotal = 0
    @State private var sidebarExportResultMessage = ""
    @State private var showSidebarExportResultAlert = false

    // 以下はサイドバーの再描画のたびに全件スキャンし直すと重くなるためキャッシュする。
    // selection（クリックしたアルバム）が変わるだけでもサイドバー全体が再描画されるため、
    // キャッシュなしだと「アルバムをクリックするたびにライブラリ全件を再集計する」状態になっていた。
    // dataManager.videos / .albums が実際に変化したときだけ refreshSidebarCaches() で更新する。
    private let sidebarContentPadding: CGFloat = 10
    private let sidebarTopPadding: CGFloat = 12
    private let sidebarToolbarInset: CGFloat = 14
    private let sidebarRowHeight: CGFloat = 32
    /// 表紙と2行目（要約）つきの行の高さ。
    private let sidebarDetailRowHeight: CGFloat = 46
    private let sidebarCoverSize: CGFloat = 34
    private let sidebarRowCornerRadius: CGFloat = 7
    private let sidebarIconWidth: CGFloat = 16
    // 行の左余白。アイコンが左端ギリギリに見えないよう、右側の余白より少し広めにとる。
    private let sidebarRowLeadingPadding: CGFloat = 16
    private let sidebarRowTrailingPadding: CGFloat = 10

    // サイドバー行の横幅。`.frame(maxWidth: .infinity)` や HStack 内の `Spacer`、
    // `.overlay(alignment:)`、GeometryReader での実測、DisclosureGroup など、
    // 「利用可能な幅いっぱいに広げる」系のAPIを使うと、このビルド環境ではなぜか
    // 行の中身（アイコン・文字）が描画位置ごと画面外に飛んでしまう現象があった。
    // そのため、ContentView 側で決めているサイドバー列の幅（288pt）に
    // 合わせた固定値を `.frame(width:)` に渡すことで回避している。
    // 行の幅は、列の幅から左右の余白（10）とスクロールバーの分（15）を引いた値にしてある。
    private let sidebarColumnWidth: CGFloat = 288
    private let sidebarRowWidth: CGFloat = 253

    /// 展開中のフォルダ（動画/画像ツリーで独立させるため dropKey と同じキーを使う）。
    /// DisclosureGroup 標準の「＞」は当たり判定が小さいため、タイトルをクリックしても
    /// 開閉できるようにこの状態を明示的に持つ。
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
        ZStack {
            NeomorphicTheme.sidebar.ignoresSafeArea()
            VStack(spacing: 0) {
              albumSearchControls
              Divider().padding(.horizontal, sidebarContentPadding)
              sidebarList
            }
            if isSidebarTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(NeomorphicTheme.accent.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(NeomorphicTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    )
                    .padding(6)
                    .allowsHitTesting(false)
            }
            if isExportingFromSidebar {
                NeomorphicTheme.ink.opacity(0.18).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(NeomorphicTheme.accent)
                    Text("エクスポート中... \(sidebarExportCurrent) / \(sidebarExportTotal)")
                        .foregroundColor(NeomorphicTheme.ink)
                        .font(.appCaption)
                }
                .padding()
                .background(GlassCardSurface())
            }
        }
        .appAlert("エクスポート完了", isPresented: $showSidebarExportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sidebarExportResultMessage)
        }
        .onDrop(of: [.fileURL], isTargeted: $isSidebarTargeted) { providers in
            handleDropOnSidebar(providers: providers)
        }
        .appAlert("異なるメディアタイプの混在", isPresented: $showSidebarMixedContentAlert) {
            Button("動画アルバムとして作成") {
                if let url = pendingSidebarFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: .video); pendingSidebarFolderURL = nil }
                }
            }
            Button("画像アルバムとして作成") {
                if let url = pendingSidebarFolderURL {
                    Task { await dataManager.importFolder(folderURL: url, as: .photo); pendingSidebarFolderURL = nil }
                }
            }
            Button("キャンセル", role: .cancel) { pendingSidebarFolderURL = nil }
        } message: {
            Text("\(sidebarMixedContentInfo)\nどちらのタイプのアルバムとして作成しますか？指定したタイプ以外のファイルは無視されます．")
        }
    }

    private var albumSectionHeader: some View {
        // 選択モードでは「フォルダにまとめる / 削除 / 完了」の3ボタン（完了は文字）になり
        // 60pt には収まらないため、モードに応じてボタン領域の幅を変える。
        let buttonsWidth: CGFloat = isAlbumSelectionMode ? 116 : 60
        return HStack(spacing: 0) {
            Text("アルバム")
                .font(.appCaptionStrong)
                .foregroundStyle(NeomorphicTheme.muted)
                .padding(.leading, 10)
                .frame(width: sidebarRowWidth - buttonsWidth, alignment: .leading)
            albumSectionHeaderButtons
                .frame(width: buttonsWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTargetFolderID == "" ? NeomorphicTheme.accent.opacity(0.12) : Color.clear)
        )
        // フォルダの外（ルート）へドラッグして戻すためのドロップ領域
        .dropDestination(for: AlbumDragPayload.self) { payloads, _ in
            handleAlbumDrop(payloads, ontoFolderPath: "")
        } isTargeted: { targeted in
            dropTargetFolderID = targeted ? "" : (dropTargetFolderID == "" ? nil : dropTargetFolderID)
        }
        .help("ここにドラッグするとフォルダの外（最上位）に移動します")
    }

    // 複数のボタンを HStack で囲まずに並べると、親の `.frame(width:)` の中で
    // ボタン同士が重なって表示が潰れるため、必ず明示的な HStack でまとめる。
    private var albumSectionHeaderButtons: some View {
        HStack(spacing: 8) {
            if isAlbumSelectionMode {
                Button(action: { newFolderNameForSelection = ""; isShowingCreateFolderFromSelectionAlert = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .disabled(selectedAlbumIDs.isEmpty)
                .help("選択したアルバムを新しいフォルダにまとめる")

                Button(action: requestSelectedAlbumDeletion) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(selectedAlbumIDs.isEmpty)
                .help("選択したアルバムを削除")

                Button(action: exitAlbumSelectionMode) {
                    Text("完了")
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { isShowingAddAlbumSheet = true }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("新規アルバムを作成")

                Button(action: { isAlbumSelectionMode = true }) {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.plain)
                .help("複数選択")
            }
        }
    }

    /// スクロールしても検索の入口が隠れないように固定します．
    private var albumSearchControls: some View {
      VStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(NeomorphicTheme.muted)
          TextField("アルバム・フォルダを検索", text: $albumSearchText)
            .textFieldStyle(.plain)
            .focused($isAlbumSearchFocused)
            .onSubmit { openFirstAlbumSearchResult() }
            .onExitCommand {
              albumSearchText = ""
              isAlbumSearchFocused = false
            }
            .help("名前やフォルダ名で検索します．Enterで先頭の結果を開き，Escで検索を解除します．")
            .accessibilityLabel("アルバム・フォルダを検索")
          if !albumSearchText.isEmpty {
            Button {
              albumSearchText = ""
              isAlbumSearchFocused = true
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("アルバム検索を解除")
            .accessibilityLabel("アルバム検索を解除")
          }
        }
        .padding(10)
        .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        FlatSegmentedControl(
          options: ["すべて", "動画", "画像"],
          title: { $0 },
          selection: $albumFilter,
          width: sidebarRowWidth
        )
        .accessibilityLabel("アルバムの種類")
      }
      .frame(width: sidebarRowWidth)
      .padding(.horizontal, sidebarContentPadding)
      .frame(width: sidebarColumnWidth, alignment: .leading)
      // タイトルバーの下から検索欄を始めます．
      .padding(.top, sidebarToolbarInset)
      .padding(.bottom, 12)
    }

    private func openFirstAlbumSearchResult() {
      guard !isAlbumSelectionMode, !normalizedAlbumQuery.isEmpty,
            let album = matchingAlbums.first else { return }
      selection = .album(album.id)
      isAlbumSearchFocused = false
    }

    private var normalizedAlbumQuery: String {
      albumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// フルパスを検索するため，閉じたフォルダの中も検索対象になります．
    private var matchingAlbums: [Album] {
      let terms = normalizedAlbumQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      return dataManager.albums.filter { album in
        guard album.name != LibraryViewModel.allVideosAlbumName,
              album.name != LibraryViewModel.allPhotosAlbumName else { return false }
        guard albumFilter == "すべて" || (albumFilter == "画像" ? album.type == .photo : album.type != .photo) else {
          return false
        }
        return terms.allSatisfy { album.name.localizedStandardContains($0) }
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var sidebarList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                // 表紙つきの行は数百件になりうるので、画面に入った行だけ作る（表紙の読み込みも遅延される）。
                // 幅は他の行と同じ固定値にそろえる（貪欲な幅のままだと、行が左に寄って検索欄とずれる）。
                LazyVStack(alignment: .leading, spacing: 5) {
                    albumSectionHeader

                    if !normalizedAlbumQuery.isEmpty {
                      Text("\(matchingAlbums.count)件のアルバム · Enterで先頭を開く")
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                        .padding(.leading, sidebarRowLeadingPadding)
                      if matchingAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                          Text("一致するアルバムはありません")
                            .font(.appBodyStrong)
                          Text("名前やフォルダ名を変えて検索してください．")
                            .font(.appCaption)
                            .foregroundStyle(NeomorphicTheme.muted)
                          Button("検索と絞り込みを解除") {
                            albumSearchText = ""
                            albumFilter = "すべて"
                          }
                        }
                        .padding(16)
                        .frame(width: sidebarRowWidth, alignment: .leading)
                      }
                      ForEach(matchingAlbums) { album in
                        VStack(alignment: .leading, spacing: 0) {
                          sidebarAlbumRow(
                            album: album,
                            title: album.name.components(separatedBy: "/").last ?? album.name,
                            systemImage: iconForAlbum(album)
                          )
                          // 表紙つきの行は2行目に要約を出すので、フォルダの階層があるときだけ場所を補足する
                          // （最上位のアルバムでは名前の繰り返しになる）。
                          if !appSettings.sidebarShowsAlbumDetails || album.name.contains("/") {
                            Text(album.name)
                              .font(.appMicro)
                              .foregroundStyle(NeomorphicTheme.muted)
                              .lineLimit(1)
                              .truncationMode(.middle)
                              .padding(.leading, appSettings.sidebarShowsAlbumDetails
                                ? sidebarRowLeadingPadding - 4 + sidebarCoverSize + 10
                                : sidebarRowLeadingPadding + sidebarIconWidth + 8)
                              .frame(width: sidebarRowWidth, alignment: .leading)
                          }
                        }
                        .help(album.name)
                      }
                    } else {
                      if albumFilter != "画像" {
                        sidebarSectionTitle("動画アルバム")
                        ForEach(viewModel.videoAlbumNodes) { node in
                          sidebarAlbumNodeRow(node, isPhotoTree: false)
                        }
                      }
                      if albumFilter != "動画" {
                        sidebarSectionTitle("画像アルバム")
                        ForEach(viewModel.photoAlbumNodes) { node in
                          sidebarAlbumNodeRow(node, isPhotoTree: true)
                        }
                      }
                    }
                }
                .frame(width: sidebarRowWidth, alignment: .leading)
            }
            .padding(.horizontal, sidebarContentPadding)
            // スクロールバーの有無で領域の幅が変わっても、行が中央寄せではみ出さず左端にそろうようにする。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, sidebarTopPadding)
            .padding(.bottom, 14)
        }
        .background(Color.clear)
        .tint(NeomorphicTheme.accent)
        .foregroundStyle(NeomorphicTheme.ink)
        .environment(\.colorScheme, appSettings.neomorphicDarkBase ? .dark : .light)
        .onAppear {
            refreshSidebarCaches()
            revealSelectedAlbumInSidebar()
        }
        .onChange(of: dataManager.videos) { refreshSidebarCaches() }
        // albums 変更時に自動展開まで行うと、ユーザーが手で閉じたフォルダが
        // バックグラウンドのライブラリ変化をきっかけに勝手に再展開されてしまう。
        // 自動展開は「ユーザーがアルバムを開いた（selection が変わった）」ときだけに限定する。
        .onChange(of: dataManager.albums) { refreshSidebarCaches() }
        // アルバムを開いたときに、それがフォルダの中に畳まれていても選択箇所が
        // ひと目でわかるよう、該当フォルダを自動で展開する。
        .onChange(of: selection) { revealSelectedAlbumInSidebar() }
        .sheet(isPresented: $isShowingAddAlbumSheet) {
            addAlbumSheet
        }
        .appConfirmationPanel(
            "アルバムの削除",
            isPresented: albumDeletionDialogBinding,
            titleVisibility: .visible,
            presenting: albumDeletionRequest
        ) { request in
            Button("アルバムだけ削除して ALL PHOTOS / ALL VIDEOS に残す") {
                performAlbumDeletion(request, contentDisposal: .keep)
            }
            Button("中身をゴミ箱に入れる") {
                performAlbumDeletion(request, contentDisposal: .trash)
            }
            Button("中身ごと完全に削除", role: .destructive) {
                performAlbumDeletion(request, contentDisposal: .delete)
            }
            Button("中身の実ファイルをMacのゴミ箱へ移動", role: .destructive) {
                performAlbumDeletion(request, contentDisposal: .systemTrash)
            }
            Button("キャンセル", role: .cancel) {
                albumDeletionRequest = nil
            }
        } message: { request in
            Text(deletionMessage(for: request))
        }
        .appAlert("新規フォルダを作成", isPresented: $isShowingCreateFolderFromSelectionAlert) {
            TextField("フォルダ名", text: $newFolderNameForSelection)
            Button("作成", action: createFolderFromSelection)
            Button("キャンセル", role: .cancel) { newFolderNameForSelection = "" }
        } message: {
            Text("選択した\(selectedAlbumIDs.count)件のアルバムをこのフォルダの中に移動します．")
        }
        .appAlert("新規アルバムに取り込む", isPresented: $isShowingSidebarFileImportAlbumNameAlert) {
            TextField("アルバム名", text: $newAlbumNameForSidebarFileImport)
            Button("作成して取り込む", action: importSidebarDroppedFiles)
            Button("キャンセル", role: .cancel) { pendingSidebarFileURLs = []; newAlbumNameForSidebarFileImport = "" }
        } message: {
            Text("ドロップした\(pendingSidebarFileURLs.count)件のファイルを，新しく作るアルバムに取り込みます．")
        }
    }

    private func sidebarRowLabel(_ title: String, systemImage: String, count: Int? = nil, isActive: Bool = false, isExpanded: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            // アイコンは線の細い無彩色にして、選ばれている行だけ濃くする（全部が濃いと名前が目立たない）。
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? NeomorphicTheme.ink : NeomorphicTheme.muted)
                .frame(width: sidebarIconWidth)
            Text(title)
                .font(.appBody)
                .foregroundStyle(NeomorphicTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let count {
                sidebarCountBadge(count, tint: NeomorphicTheme.accent)
            }
            if let isExpanded {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NeomorphicTheme.muted)
                    .frame(width: 12)
            }
        }
        .padding(.leading, sidebarRowLeadingPadding)
        .padding(.trailing, sidebarRowTrailingPadding)
        .frame(width: sidebarRowWidth, height: sidebarRowHeight, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: sidebarRowCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: sidebarRowCornerRadius, style: .continuous)
                .fill(isActive ? NeomorphicTheme.selection : Color.clear)
        )
    }

    /// 表紙と2行目（「動画 12本 · 38分」など）つきの行。名前だけでは中身が分からないアルバムを
    /// 見分けやすくするための表示で、設定でオフにすると従来の `sidebarRowLabel` に戻る。
    /// 幅は他の行と同じく固定値で指定する（上の sidebarRowWidth のコメント参照）。
    private func sidebarDetailRowLabel(
        _ title: String,
        summary: AlbumSummary?,
        isFolder: Bool,
        isActive: Bool,
        isExpanded: Bool? = nil,
        selected: Bool? = nil
    ) -> some View {
        HStack(spacing: 10) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? NeomorphicTheme.accent : NeomorphicTheme.muted)
            }
            sidebarCover(summary, isFolder: isFolder)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appBody)
                    .foregroundStyle(NeomorphicTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summary?.detailText(isFolder: isFolder) ?? " ")
                    .font(.appMicro)
                    .foregroundStyle(NeomorphicTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let isExpanded {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NeomorphicTheme.muted)
                    .frame(width: 12)
            }
        }
        .padding(.leading, sidebarRowLeadingPadding - 4)
        .padding(.trailing, sidebarRowTrailingPadding)
        .frame(width: sidebarRowWidth, height: sidebarDetailRowHeight, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: sidebarRowCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: sidebarRowCornerRadius, style: .continuous)
                .fill(isActive ? NeomorphicTheme.selection : Color.clear)
        )
        .help(summary.map { "\(title)\n\($0.detailText(isFolder: isFolder))" } ?? title)
    }

    /// 行の左の表紙。中身がなければフォルダ／アルバムのアイコンを出す。
    /// フォルダは右下に小さなフォルダ印を重ねて、アルバムと見分けられるようにする。
    private func sidebarCover(_ summary: AlbumSummary?, isFolder: Bool) -> some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let item = summary?.coverItems.first {
                CoverThumbnail(item: item, dataManager: dataManager)
            } else {
                Image(systemName: isFolder ? "folder.fill" : "rectangle.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NeomorphicTheme.muted)
            }
        }
        .frame(width: sidebarCoverSize, height: sidebarCoverSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(.black.opacity(0.6)))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private func sidebarPlainLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.appCaptionStrong)
            .foregroundStyle(NeomorphicTheme.ink)
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.appCaptionStrong)
            .foregroundStyle(NeomorphicTheme.muted)
            .padding(.leading, sidebarRowLeadingPadding)
            .padding(.trailing, sidebarRowTrailingPadding)
            .frame(width: sidebarRowWidth, alignment: .leading)
    }

    private func sidebarSelectableRowLabel(_ title: String, systemImage: String, count: Int, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(NeomorphicTheme.muted)
                .frame(width: sidebarIconWidth)
            Text(title)
                .font(.appBody)
                .foregroundStyle(NeomorphicTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            sidebarCountBadge(count, tint: NeomorphicTheme.muted)
        }
        .padding(.leading, sidebarRowLeadingPadding)
        .padding(.trailing, sidebarRowTrailingPadding)
        .frame(width: sidebarRowWidth, height: sidebarRowHeight, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: sidebarRowCornerRadius, style: .continuous))
    }

    private func sidebarCountBadge(_ count: Int, tint: Color) -> some View {
        // 件数は補足情報なので、色付きのカプセルにせず、控えめな数字だけにする
        // （全行に青い太字のバッジが並ぶと、行の名前より数字が目立ってしまう）。
        Text("\(count.formatted())")
            .font(.appMicro)
            .monospacedDigit()
            .foregroundStyle(NeomorphicTheme.muted)
    }

    private func sidebarAlbumRow(album: Album, title: String, systemImage: String) -> AnyView {
        let showsDetails = appSettings.sidebarShowsAlbumDetails

        if isAlbumSelectionMode {
            return AnyView(Button {
                toggleAlbumSelection(album.id)
            } label: {
                if showsDetails {
                    sidebarDetailRowLabel(
                        title,
                        summary: viewModel.albumSummaries[album.id],
                        isFolder: false,
                        isActive: false,
                        selected: selectedAlbumIDs.contains(album.id)
                    )
                } else {
                    sidebarSelectableRowLabel(title, systemImage: systemImage, count: nonTrashedCount(in: album), isSelected: selectedAlbumIDs.contains(album.id))
                }
            }
            .buttonStyle(.plain))
        }

        return AnyView(Button {
            selection = .album(album.id)
            isAlbumSearchFocused = false
        } label: {
            if showsDetails {
                sidebarDetailRowLabel(
                    title,
                    summary: viewModel.albumSummaries[album.id],
                    isFolder: false,
                    isActive: selection == .album(album.id)
                )
            } else {
                sidebarRowLabel(title, systemImage: systemImage, count: nonTrashedCount(in: album), isActive: selection == .album(album.id))
            }
        }
        .buttonStyle(.plain)
        .draggable(AlbumDragPayload(albumIDs: [album.id], sourceFolderPath: nil))
        .appContextMenu {
            Button("フォルダにエクスポート…") {
                exportAlbums(albumIDs: [album.id])
            }
            Divider()
            Button("削除", role: .destructive) {
                requestAlbumDeletion(albumIDs: [album.id])
            }
        })
    }

    private func iconForAlbum(_ album: Album) -> String {
        album.type == .photo ? "photo.on.rectangle.angled" : "folder.fill"
    }

    private func nonTrashedCount(in album: Album) -> Int {
        album.videoIDs.filter { !viewModel.trashedMediaIDs.contains($0) }.count
    }

    private func nonTrashedCount(in node: SidebarAlbumNode) -> Int {
        let ownCount = node.album.map { nonTrashedCount(in: $0) } ?? 0
        let childCount = node.children.reduce(0) { $0 + nonTrashedCount(in: $1) }
        return ownCount + childCount
    }

    /// isPhotoTree: この行が動画ツリーと画像ツリーのどちら側のものか。
    /// ドラッグ&ドロップやフォルダの識別（ハイライト用キー）を型ごとに分離するために使う。
    private func sidebarAlbumNodeRow(_ node: SidebarAlbumNode, isPhotoTree: Bool) -> AnyView {
        if node.children.isEmpty, let album = node.album {
            return sidebarAlbumRow(album: album, title: node.name, systemImage: iconForAlbum(album))
        } else {
            let key = dropKey(forPath: node.id, isPhotoTree: isPhotoTree)
            // SwiftUI 標準の DisclosureGroup を使うと、このビルド環境では中身（アイコン・文字）が
            // 描画位置ごと画面外に飛んでしまう現象があったため、開閉状態を自前の VStack + 条件分岐で
            // 表現している（folderRowLabel 側にシェブロンを描いてタップで開閉する）。
            return AnyView(
                VStack(alignment: .leading, spacing: 2) {
                    folderRowLabel(node, isPhotoTree: isPhotoTree)
                        .appContextMenu {
                            if let album = node.album, album.linkedFolderPath != nil || album.linkedFolderBookmarkData != nil {
                                Button("紐づけフォルダを更新") {
                                    rescanLinkedFolder(albumID: album.id)
                                }
                            } else {
                                Button("フォルダを紐づけ…") {
                                    linkFolderToNode(node, isPhotoTree: isPhotoTree)
                                }
                            }
                            Divider()
                            Button("フォルダにエクスポート…") {
                                exportAlbums(albumIDs: viewModel.albumIDs(in: node))
                            }
                            Divider()
                            Button("削除", role: .destructive) {
                                requestAlbumDeletion(albumIDs: viewModel.albumIDs(in: node))
                            }
                        }

                    if expandedFolderIDs.contains(key) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let album = node.album, nonTrashedCount(in: album) > 0 {
                                sidebarAlbumRow(album: album, title: "このフォルダ内のメディア", systemImage: iconForAlbum(album))
                            }

                            ForEach(node.children) { child in
                                sidebarAlbumNodeRow(child, isPhotoTree: isPhotoTree)
                            }
                        }
                        .padding(.leading, 14)
                    }
                }

            )
        }
    }

    private func linkFolderToNode(_ node: SidebarAlbumNode, isPhotoTree: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "「\(node.id)」に紐づけるFinderフォルダを選択してください"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        Task {
            let albumID: UUID?
            if let existingID = node.album?.id {
                albumID = existingID
            } else {
                albumID = dataManager.createAlbum(name: node.id, type: isPhotoTree ? .photo : .video)
            }

            guard let albumID else { return }
            await dataManager.linkFolder(folderURL: folderURL, to: albumID)
        }
    }

    private func rescanLinkedFolder(albumID: UUID) {
        Task {
            await dataManager.rescanLinkedFolder(albumID: albumID)
        }
    }

    /// 指定したアルバム群のメディア（ゴミ箱を除く）を、選んだフォルダへまとめてエクスポートする。
    /// アルバム名（"/" 区切りの階層含む）とファイル名はサーバー上の登録どおりに再現される
    /// （LibraryViewModel.exportMedia 側で解決する）。
    private func exportAlbums(albumIDs: [UUID]) {
        let targetIDs = Set(albumIDs)
        let videoIDs = dataManager.albums
            .filter { targetIDs.contains($0.id) }
            .flatMap { $0.videoIDs }
            .filter { !viewModel.trashedMediaIDs.contains($0) }
        let uniqueVideoIDs = Array(Set(videoIDs))
        guard !uniqueVideoIDs.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "書き出し先のフォルダを選択してください"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        Task {
            isExportingFromSidebar = true
            sidebarExportCurrent = 0
            sidebarExportTotal = uniqueVideoIDs.count
            let result = await dataManager.exportMedia(videoIDs: uniqueVideoIDs, to: folderURL) { current, total in
                sidebarExportCurrent = current
                sidebarExportTotal = total
            }
            isExportingFromSidebar = false
            sidebarExportResultMessage = result.failedCount > 0
                ? "\(result.successCount)件を書き出しました．\(result.failedCount)件は失敗しました．"
                : "\(result.successCount)件を書き出しました．"
            showSidebarExportResultAlert = true
        }
    }

    private func dropKey(forPath path: String, isPhotoTree: Bool) -> String {
        SidebarViewModel.folderKey(path: path, isPhoto: isPhotoTree)
    }

    @ViewBuilder
    private func folderRowLabel(_ node: SidebarAlbumNode, isPhotoTree: Bool) -> some View {
        let key = dropKey(forPath: node.id, isPhotoTree: isPhotoTree)
        let showsDetails = appSettings.sidebarShowsAlbumDetails
        let summary = viewModel.folderSummaries[key]
        Group {
            if isAlbumSelectionMode {
                Group {
                    if showsDetails {
                        sidebarDetailRowLabel(node.name, summary: summary, isFolder: true, isActive: false, selected: isAlbumNodeSelected(node))
                    } else {
                        sidebarSelectableRowLabel(node.name, systemImage: "folder.fill", count: nonTrashedCount(in: node), isSelected: isAlbumNodeSelected(node))
                    }
                }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleAlbumNodeSelection(node)
                    }
            } else {
                Group {
                    if showsDetails {
                        sidebarDetailRowLabel(
                            node.name,
                            summary: summary,
                            isFolder: true,
                            isActive: selection == .folder(path: node.id, isPhoto: isPhotoTree),
                            isExpanded: expandedFolderIDs.contains(key)
                        )
                    } else {
                        sidebarRowLabel(
                            node.name,
                            systemImage: "folder.fill",
                            count: nonTrashedCount(in: node),
                            isActive: selection == .folder(path: node.id, isPhoto: isPhotoTree),
                            isExpanded: expandedFolderIDs.contains(key)
                        )
                    }
                }
                    .contentShape(Rectangle())
                    // 標準の「＞」だけだと当たり判定が小さいため、タイトル行全体のクリックでも開閉できるようにする。
                    // 併せて右ペインにこのフォルダの中身（子フォルダ・子アルバムの表紙）を出す。
                    .onTapGesture {
                        selection = .folder(path: node.id, isPhoto: isPhotoTree)
                        if expandedFolderIDs.contains(key) { expandedFolderIDs.remove(key) } else { expandedFolderIDs.insert(key) }
                    }
                    .draggable(AlbumDragPayload(albumIDs: viewModel.albumIDs(in: node), sourceFolderPath: node.id))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTargetFolderID == key ? NeomorphicTheme.accent.opacity(0.12) : Color.clear)
        )
        // 既存フォルダへドラッグしたアルバム（単体・別フォルダごと）を受け取る。
        // 動画ツリー/画像ツリーをまたぐドロップは handleAlbumDrop 内の型チェックで無視される。
        .dropDestination(for: AlbumDragPayload.self) { payloads, _ in
            handleAlbumDrop(payloads, ontoFolderPath: node.id, restrictToPhoto: isPhotoTree)
        } isTargeted: { targeted in
            dropTargetFolderID = targeted ? key : (dropTargetFolderID == key ? nil : dropTargetFolderID)
        }
    }

    /// ドロップされたアルバム（単体 or フォルダごと）を指定フォルダパス配下へ移動する。
    /// folderPath が空文字ならルート直下（フォルダの外）へ出す。自分自身・自分の子孫フォルダへの
    /// ドロップは循環を避けるため無視する。restrictToPhoto でドロップ先の型を指定し、動画アルバムが
    /// 画像ツリーへ（またはその逆）紛れ込まないようにする（動画/画像は棲み分ける）。
    /// nil はルート（フォルダの外）へのドロップ用で、型を問わずそのまま戻す。
    @discardableResult
    private func handleAlbumDrop(_ payloads: [AlbumDragPayload], ontoFolderPath folderPath: String, restrictToPhoto: Bool? = nil) -> Bool {
        for payload in payloads {
            if let sourcePath = payload.sourceFolderPath,
               folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                continue
            }

            let targetIDs = Set(payload.albumIDs)
            var renames: [UUID: String] = [:]
            for album in dataManager.albums where targetIDs.contains(album.id) {
                if let restrictToPhoto, (album.type == .photo) != restrictToPhoto { continue }
                renames[album.id] = newAlbumName(for: album, movingTo: folderPath, draggedFolderPath: payload.sourceFolderPath)
            }
            dataManager.renameAlbums(renames)
        }
        return true
    }

    /// 移動後の新しいアルバム名を計算する。
    /// - フォルダごとのドラッグなら、そのフォルダ自身の相対パス構造を保ったまま移動先へ付け替える
    ///   （Finderでフォルダを移動したときと同様、フォルダ自身の名前は保たれる）。
    /// - 単体アルバムのドラッグなら、末尾の名前だけを残して移動先直下に置く。
    private func newAlbumName(for album: Album, movingTo folderPath: String, draggedFolderPath: String?) -> String {
        let relative: String
        if let draggedFolderPath,
           album.name == draggedFolderPath || album.name.hasPrefix(draggedFolderPath + "/") {
            let parentPath = draggedFolderPath.components(separatedBy: "/").dropLast().joined(separator: "/")
            let stripLength = parentPath.isEmpty ? 0 : parentPath.count + 1
            relative = String(album.name.dropFirst(stripLength))
        } else {
            relative = album.name.components(separatedBy: "/").last ?? album.name
        }
        return folderPath.isEmpty ? relative : "\(folderPath)/\(relative)"
    }

    private func createFolderFromSelection() {
        let name = newFolderNameForSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderNameForSelection = ""
        guard !name.isEmpty, !selectedAlbumIDs.isEmpty else { return }

        let targetIDs = selectedAlbumIDs
        var renames: [UUID: String] = [:]
        for album in dataManager.albums where targetIDs.contains(album.id) {
            renames[album.id] = "\(name)/\(album.name)"
        }
        dataManager.renameAlbums(renames)

        selectedAlbumIDs.removeAll()
        isAlbumSelectionMode = false
    }

    private var albumDeletionDialogBinding: Binding<Bool> {
        Binding(
            get: { albumDeletionRequest != nil },
            set: { isPresented in
                if !isPresented {
                    albumDeletionRequest = nil
                }
            }
        )
    }

    private func toggleAlbumSelection(_ albumID: UUID) {
        if selectedAlbumIDs.contains(albumID) {
            selectedAlbumIDs.remove(albumID)
        } else {
            selectedAlbumIDs.insert(albumID)
        }
    }

    private func toggleAlbumNodeSelection(_ node: SidebarAlbumNode) {
        let ids = Set(viewModel.albumIDs(in: node))
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: selectedAlbumIDs) {
            selectedAlbumIDs.subtract(ids)
        } else {
            selectedAlbumIDs.formUnion(ids)
        }
    }

    private func isAlbumNodeSelected(_ node: SidebarAlbumNode) -> Bool {
        let ids = Set(viewModel.albumIDs(in: node))
        return !ids.isEmpty && ids.isSubset(of: selectedAlbumIDs)
    }

    private func requestAlbumDeletion(albumIDs: [UUID]) {
        let ids = orderedDeletableAlbumIDs(from: albumIDs)
        guard !ids.isEmpty else { return }
        albumDeletionRequest = AlbumDeletionRequest(albumIDs: ids)
    }

    private func requestSelectedAlbumDeletion() {
        requestAlbumDeletion(albumIDs: Array(selectedAlbumIDs))
    }

    private func orderedDeletableAlbumIDs(from albumIDs: [UUID]) -> [UUID] {
        let targetIDs = Set(albumIDs)
        return dataManager.albums
            .filter {
                targetIDs.contains($0.id) &&
                $0.name != LibraryViewModel.allVideosAlbumName &&
                $0.name != LibraryViewModel.allPhotosAlbumName
            }
            .map { $0.id }
    }

    private func deletionMessage(for request: AlbumDeletionRequest) -> String {
        let albums = albums(for: request)
        let mediaCount = Set(albums.flatMap { $0.videoIDs }).count
        let targetDescription: String
        if albums.count == 1, let album = albums.first {
            targetDescription = "「\(album.name)」"
        } else {
            targetDescription = "\(albums.count)件のアルバム"
        }

        return "\(targetDescription)を削除します．\nアルバムだけ削除する場合，\(mediaCount)件の中身は ALL PHOTOS / ALL VIDEOS に残ります．\n中身をアプリ内のゴミ箱へ入れる場合，後から元に戻せます．\n中身ごと完全に削除する場合，アプリ管理内のファイルは復元できません．\nMacのゴミ箱へ移動する場合，リンク元を含む実ファイルも移動します．"
    }

    private func albums(for request: AlbumDeletionRequest) -> [Album] {
        let ids = Set(request.albumIDs)
        return dataManager.albums.filter { ids.contains($0.id) }
    }

    private func performAlbumDeletion(_ request: AlbumDeletionRequest, contentDisposal: LibraryViewModel.AlbumContentDisposal) {
        let ids = orderedDeletableAlbumIDs(from: request.albumIDs)
        dataManager.deleteAlbums(albumIDs: ids, contentDisposal: contentDisposal)

        if case .album(let selectedID) = selection, ids.contains(selectedID) {
            selection = .home
        }

        selectedAlbumIDs.subtract(ids)
        if selectedAlbumIDs.isEmpty {
            isAlbumSelectionMode = false
        }
        albumDeletionRequest = nil
    }

    private func exitAlbumSelectionMode() {
        isAlbumSelectionMode = false
        selectedAlbumIDs.removeAll()
    }

    /// 現在選択中のアルバムが、畳まれたフォルダの中に隠れていないよう祖先フォルダを展開する。
    /// DisclosureGroup は閉じたままだと選択ハイライトが見えず「今どこを見ているか」が
    /// わからなくなるため、アルバムを開くたびに呼ぶ。
    private func revealSelectedAlbumInSidebar() {
        // フォルダ画面のタイル／パンくずから移動したときも、そのフォルダがサイドバー上で
        // 畳まれたままにならないよう祖先を開く（自分自身は開かない＝行の再クリックで畳める）。
        if case .folder(let path, let isPhoto) = selection {
            var ancestor = ""
            for part in path.components(separatedBy: "/").dropLast() where !part.isEmpty {
                ancestor += (ancestor.isEmpty ? "" : "/") + part
                expandedFolderIDs.insert(dropKey(forPath: ancestor, isPhotoTree: isPhoto))
            }
            return
        }

        guard case .album(let albumID) = selection else { return }
        if let path = viewModel.folderPath(containing: albumID, in: viewModel.videoAlbumNodes) {
            for folderID in path { expandedFolderIDs.insert(dropKey(forPath: folderID, isPhotoTree: false)) }
        }
        if let path = viewModel.folderPath(containing: albumID, in: viewModel.photoAlbumNodes) {
            for folderID in path { expandedFolderIDs.insert(dropKey(forPath: folderID, isPhotoTree: true)) }
        }
    }

    /// dataManager.videos / .albums の変化に追従してキャッシュを更新する。
    /// selection の変化だけではここは呼ばれない（body 内で直接計算していないため）。
    private func refreshSidebarCaches() {
        viewModel.refresh(
            videos: dataManager.videos,
            albums: dataManager.albums
        )
    }

    private var addAlbumSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(NeomorphicTheme.muted)
                .padding(.top, 6)

            VStack(spacing: 4) {
                Text("新規アルバム")
                    .font(.appTitle)
                Text("名前とタイプを選んで作成します")
                    .font(.appCaption)
                    .foregroundStyle(NeomorphicTheme.muted)
            }

            TextField("アルバム名", text: $newAlbumName)
                .textFieldStyle(.roundedBorder)

            FlatSegmentedControl(
                options: [AlbumType.video, AlbumType.photo],
                title: { $0 == .video ? "動画" : "画像" },
                selection: $newAlbumType,
                width: 272
            )
            .accessibilityLabel("タイプ")

            HStack {
                Button("キャンセル") {
                    isShowingAddAlbumSheet = false
                    newAlbumName = ""
                    newAlbumType = .video
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("作成") {
                    dataManager.createAlbum(name: newAlbumName, type: newAlbumType)
                    isShowingAddAlbumSheet = false
                    newAlbumName = ""
                    newAlbumType = .video
                }
                .buttonStyle(AppActionButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(newAlbumName.isEmpty || newAlbumName == LibraryViewModel.allVideosAlbumName || newAlbumName == LibraryViewModel.allPhotosAlbumName)
            }
            .padding(.top, 4)

            Divider()

            Button(action: importAlbumFromFolder) {
                Label("フォルダをインポートして作成", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppActionButtonStyle())
            .help("フォルダを選ぶと，そのフォルダ名でアルバムを作成し中身を一括インポートします")
        }
        .padding(24)
        .frame(width: 320)
        .appSheet()
    }

    /// フォルダを選んで、そのフォルダ名のアルバムを作成しつつ中身を一括インポートする。
    /// サイドバーへのドラッグ＆ドロップと同じ挙動（混在時は同じ確認アラートを使う）。
    private func importAlbumFromFolder() {
        // 「新規アルバム」シートを表示したまま NSOpenPanel（別のモーダル）を重ねて開くと、
        // モーダル同士が競合してパネルが正しく開かない／即座にキャンセル扱いになることがある。
        // そのため先にシートを閉じ、閉じるアニメーションが終わるのを少し待ってからパネルを開く。
        isShowingAddAlbumSheet = false
        newAlbumName = ""
        newAlbumType = .video

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "アルバムとしてインポートするフォルダを選択してください"

            guard panel.runModal() == .OK, let folderURL = panel.url else {
                print("⚠️ [IMPORT-BTN] パネルがキャンセルされたか，フォルダURLが取得できませんでした")
                return
            }
            print("📥 [IMPORT-BTN] フォルダ選択: \(folderURL.path)")

            let counts = dataManager.scanFolder(folderURL: folderURL)
            print("📥 [IMPORT-BTN] フォルダ内訳: 動画=\(counts.videoCount)件 画像=\(counts.photoCount)件")
            if counts.videoCount > 0 && counts.photoCount > 0 {
                sidebarMixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                pendingSidebarFolderURL = folderURL
                showSidebarMixedContentAlert = true
                return
            }
            if counts.videoCount == 0 && counts.photoCount == 0 {
                print("⚠️ [IMPORT-BTN] フォルダ内に対応するメディアが見つかりませんでした: \(folderURL.path)")
            }

            let albumType: AlbumType = counts.photoCount > 0 ? .photo : .video
            Task {
                print("📥 [IMPORT-BTN] importFolder開始: \(folderURL.path) as \(albumType)")
                await dataManager.importFolder(folderURL: folderURL, as: albumType)
                print("📥 [IMPORT-BTN] importFolder完了: \(folderURL.path)")
            }
        }
    }

    private func handleDropOnSidebar(providers: [NSItemProvider]) -> Bool {
        print("📥 [DROP] サイドバーへのドロップを受け取りました: providers=\(providers.count)")
        loadDroppedURLs(from: providers) { urls in
            print("📥 [DROP] URL解決結果: \(urls.count)件 \(urls.map { $0.path })")
            var folderURLs: [URL] = []
            var fileURLs: [URL] = []
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    print("⚠️ [DROP] fileExists=false: \(url.path)")
                    continue
                }
                if isDirectory.boolValue { folderURLs.append(url) } else { fileURLs.append(url) }
            }
            print("📥 [DROP] 分類結果: フォルダ=\(folderURLs.count)件 ファイル=\(fileURLs.count)件")

            guard !folderURLs.isEmpty || !fileURLs.isEmpty else {
                print("⚠️ [DROP] フォルダ・ファイルどちらも見つからなかったため何もしません")
                return
            }

            if folderURLs.count == 1, fileURLs.isEmpty, let folderURL = folderURLs.first {
                let counts = dataManager.scanFolder(folderURL: folderURL)
                print("📥 [DROP] フォルダ内訳: 動画=\(counts.videoCount)件 画像=\(counts.photoCount)件")
                if counts.videoCount > 0 && counts.photoCount > 0 {
                    self.sidebarMixedContentInfo = "動画: \(counts.videoCount)件, 画像: \(counts.photoCount)件"
                    self.pendingSidebarFolderURL = folderURL
                    self.showSidebarMixedContentAlert = true
                    return
                }
                if counts.videoCount == 0 && counts.photoCount == 0 {
                    print("⚠️ [DROP] フォルダ内に対応するメディアが見つかりませんでした: \(folderURL.path)")
                }
            }

            if !folderURLs.isEmpty {
                Task {
                    for folderURL in folderURLs {
                        let counts = dataManager.scanFolder(folderURL: folderURL)
                        let albumType: AlbumType = counts.photoCount > 0 ? .photo : .video
                        print("📥 [DROP] importFolder開始: \(folderURL.path) as \(albumType)")
                        await dataManager.importFolder(folderURL: folderURL, as: albumType)
                        print("📥 [DROP] importFolder完了: \(folderURL.path)")
                    }
                }
            }

            // フォルダではなく個別ファイル（写真・動画）を直接ドロップした場合は、
            // 取り込み先のアルバム名が自明ではないため、名前を入力してもらってから新規アルバムに取り込む。
            if !fileURLs.isEmpty {
                print("📥 [DROP] 個別ファイルのアルバム名入力アラートを表示します")
                self.pendingSidebarFileURLs = fileURLs
                self.newAlbumNameForSidebarFileImport = ""
                self.isShowingSidebarFileImportAlbumNameAlert = true
            }
        }
        return true
    }

    private func importSidebarDroppedFiles() {
        let name = newAlbumNameForSidebarFileImport.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = pendingSidebarFileURLs
        pendingSidebarFileURLs = []
        newAlbumNameForSidebarFileImport = ""
        guard !name.isEmpty, !urls.isEmpty,
              let newAlbumID = dataManager.createAlbum(name: name, type: .mixed) else { return }
        Task { await dataManager.importMediaFiles(from: urls, to: newAlbumID) }
    }

    private func loadDroppedURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
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
                let url = Self.resolveDroppedURL(from: item)
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

    private static func resolveDroppedURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let itemURL = item as? URL {
            url = itemURL
        } else if let itemURL = item as? NSURL {
            url = itemURL as URL
        } else {
            url = nil
        }

        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}
