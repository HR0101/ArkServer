// ArkServer/Features/MusicVideo/Views/MusicVideoSourcePickerView.swift

import SwiftUI

/// 素材にする動画を選ぶ画面。ポップアップではなく、ミュージックビデオの画面いっぱいに出す。
///
/// 左にアルバム(表紙つき)、右に動画のサムネイルを並べる。
/// アルバムは、チェックで「アルバムごと素材にする」、行を押すと「右にそのアルバムの動画を出す」。
/// 動画は、サムネイルを見ながら1本ずつ選べる。数百のアルバムや千本以上の動画から探せるよう、
/// 検索・並べ替え・絞り込みを備える。
struct MusicVideoSourcePickerView: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  @ObservedObject var dataManager: LibraryViewModel
  let close: () -> Void

  /// 右に出す動画の範囲。
  private enum Scope: Hashable {
    case all
    case album(UUID)
  }

  @State private var scope: Scope = .all
  @State private var albumSearch = ""
  @State private var videoSearch = ""
  @AppStorage("musicVideo.picker.albumOrder") private var albumOrder: MusicVideoAlbumOrder = .name
  @AppStorage("musicVideo.picker.videoOrder") private var videoOrder: MusicVideoVideoOrder = .recent
  @AppStorage("musicVideo.picker.hideEmpty") private var hidesEmptyAlbums = true
  @AppStorage("musicVideo.picker.minimumLength") private var minimumLength = 5.0
  @State private var onlySelected = false
  @State private var favoritesOnly = false

  @State private var albumRows: [MusicVideoAlbumEntry] = []
  /// 素材にできる動画(動画だけ・ゴミ箱外)。ライブラリが変わったときだけ作り直す。
  @State private var allVideos: [VideoItem] = []
  @State private var videosByID: [UUID: VideoItem] = [:]
  /// 選んだアルバムに入っている動画。「アルバムで選択済み」の印に使う。
  @State private var albumVideoIDs: Set<UUID> = []

  private static let albumPaneWidth: CGFloat = 340

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(NeomorphicTheme.separator)
      HStack(spacing: 0) {
        albumPane
        Divider().overlay(NeomorphicTheme.separator)
        videoPane
      }
      Divider().overlay(NeomorphicTheme.separator)
      footer
    }
    .background(NeomorphicTheme.canvas)
    .foregroundStyle(NeomorphicTheme.ink)
    .onAppear {
      viewModel.pausePlayback()
      rebuild()
    }
    .onChange(of: dataManager.albums) { rebuild() }
    .onChange(of: dataManager.videos) { rebuild() }
    .onChange(of: viewModel.selectedAlbumIDs) { updateAlbumVideoIDs() }
  }

  // MARK: - 上の帯

  private var header: some View {
    HStack(spacing: 16) {
      Button(action: close) {
        Label("戻る", systemImage: "chevron.left")
      }
      .buttonStyle(.quiet)
      .keyboardShortcut(.cancelAction)
      .help("ミュージックビデオの画面へ戻ります（Esc）")
      .accessibilityIdentifier("musicvideo.sourceBack")

      VStack(alignment: .leading, spacing: 2) {
        Text("素材を選ぶ")
          .font(.appTitle)
        Text("アルバムと動画は，どちらも組み合わせて選べます")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
      }
      Spacer(minLength: 12)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  // MARK: - 左: アルバム

  private var visibleAlbums: [MusicVideoAlbumEntry] {
    MusicVideoSourceBrowser.albums(
      albumRows,
      order: albumOrder,
      hidesEmpty: hidesEmptyAlbums,
      onlyIDs: nil,
      query: albumSearch
    )
  }

  private var albumPane: some View {
    let rows = visibleAlbums
    return VStack(spacing: 0) {
      VStack(spacing: 8) {
        searchField("アルバム名で検索", text: $albumSearch)
        HStack(spacing: 10) {
          AppChoicePicker("並べ替え", selection: $albumOrder) {
            ForEach(MusicVideoAlbumOrder.allCases) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
          Toggle("空を隠す", isOn: $hidesEmptyAlbums)
            .fixedSize()
            .help("動画が1本もないアルバムを一覧から隠します")
          Spacer(minLength: 0)
          AppChoiceMenu {
            Button("表示中のアルバムをすべて選ぶ") { viewModel.selectedAlbumIDs.formUnion(rows.map(\.id)) }
            Button("表示中のアルバムの選択を外す") { viewModel.selectedAlbumIDs.subtract(rows.map(\.id)) }
          } label: {
            Text("まとめて")
          }

          .buttonStyle(.quiet)
          .menuIndicator(.visible)
          .fixedSize()
        }
        .font(.appCaption)
      }
      .padding(12)

      Divider().overlay(NeomorphicTheme.separator)

      ScrollView {
        LazyVStack(spacing: 2) {
          allVideosRow
          if rows.isEmpty {
            Text("条件に合うアルバムがありません")
              .font(.appCaption)
              .foregroundStyle(NeomorphicTheme.muted)
              .padding(.top, 24)
          }
          ForEach(rows) { albumRow($0) }
        }
        .padding(8)
      }
    }
    .frame(width: Self.albumPaneWidth)
    .background(NeomorphicTheme.sidebar)
  }

  private var allVideosRow: some View {
    let isScope = scope == .all
    return Button {
      scope = .all
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "film.stack")
          .font(.system(size: 15))
          .foregroundStyle(NeomorphicTheme.muted)
          .frame(width: 28 + 64 + 10 - 28, height: 36)
        Text("すべての動画")
          .font(.appBodyStrong)
        Spacer(minLength: 4)
        Text(allVideos.count.formatted())
          .font(.appCaption.monospacedDigit())
          .foregroundStyle(NeomorphicTheme.muted)
      }
      .padding(.leading, 34)
      .padding(.trailing, 8)
      .padding(.vertical, 4)
      .background(rowBackground(isScope))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("すべての動画 \(allVideos.count)本")
    .accessibilityAddTraits(isScope ? .isSelected : [])
  }

  private func albumRow(_ entry: MusicVideoAlbumEntry) -> some View {
    let isSelected = viewModel.selectedAlbumIDs.contains(entry.id)
    let isScope = scope == .album(entry.id)
    return HStack(spacing: 0) {
      // 左のチェック: アルバムごと素材にする。
      Button {
        toggleAlbum(entry.id)
      } label: {
        checkmark(isSelected)
          .frame(width: 34, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isSelected ? "このアルバムを素材から外す" : "このアルバムごと素材にする")
      .accessibilityLabel("\(entry.title)を素材にする")
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      // 行: 右に、このアルバムの動画を出す。
      Button {
        scope = .album(entry.id)
      } label: {
        HStack(spacing: 10) {
          thumbnail(for: entry.coverVideoID, width: 64, height: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
              .font(.appBody)
              .lineLimit(1)
              .truncationMode(.middle)
            if !entry.parent.isEmpty {
              Text(entry.parent)
                .font(.appMicro)
                .foregroundStyle(NeomorphicTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
          Spacer(minLength: 4)
          Text(entry.count.formatted())
            .font(.appCaption.monospacedDigit())
            .foregroundStyle(NeomorphicTheme.muted)
        }
        .padding(.trailing, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(entry.title) \(entry.count)本")
    }
    .padding(.vertical, 2)
    .background(rowBackground(isScope))
  }

  private func rowBackground(_ isScope: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(isScope ? NeomorphicTheme.selection : Color.clear)
  }

  private func toggleAlbum(_ id: UUID) {
    if viewModel.selectedAlbumIDs.contains(id) {
      viewModel.selectedAlbumIDs.remove(id)
    } else {
      viewModel.selectedAlbumIDs.insert(id)
    }
  }

  // MARK: - 右: 動画

  /// 右に出す動画のもと(範囲で決まる)。
  private var scopeVideos: [VideoItem] {
    switch scope {
    case .all:
      return allVideos
    case .album(let id):
      guard let album = dataManager.albums.first(where: { $0.id == id }) else { return allVideos }
      return MusicVideoSourceBrowser.videos(in: album, from: videosByID)
    }
  }

  private var scopeTitle: String {
    if case .album(let id) = scope, let entry = albumRows.first(where: { $0.id == id }) { return entry.title }
    return "すべての動画"
  }

  private var visibleVideos: [VideoItem] {
    MusicVideoSourceBrowser.videos(
      scopeVideos,
      order: videoOrder,
      minimumLength: minimumLength,
      favoritesOnly: favoritesOnly,
      onlyIDs: onlySelected ? viewModel.selectedVideoIDs.union(albumVideoIDs) : nil,
      query: videoSearch
    )
  }

  private var videoPane: some View {
    let videos = visibleVideos
    return VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(scopeTitle)
            .font(.appHeadline)
            .lineLimit(1)
            .truncationMode(.middle)
          Text("\(videos.count.formatted())本")
            .font(.appCaption.monospacedDigit())
            .foregroundStyle(NeomorphicTheme.muted)
          Spacer(minLength: 8)
          if case .album(let id) = scope {
            let isSelected = viewModel.selectedAlbumIDs.contains(id)
            Button(isSelected ? "アルバムの選択を外す" : "このアルバムごと選ぶ") { toggleAlbum(id) }
              .buttonStyle(.quiet)
          }
          AppChoiceMenu {
            Button("表示中の動画をすべて選ぶ") { viewModel.selectedVideoIDs.formUnion(videos.map(\.id)) }
            Button("表示中の動画の選択を外す") { viewModel.selectedVideoIDs.subtract(videos.map(\.id)) }
          } label: {
            Text("まとめて")
          }

          .buttonStyle(.quiet)
          .menuIndicator(.visible)
          .fixedSize()
        }

        // 幅が広ければ1段、狭ければ2段にする(検索欄がつぶれないように、検索欄には最小の幅を持たせる)。
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            searchField("動画名で検索", text: $videoSearch)
              .frame(minWidth: 200)
            videoOrderPicker
            minimumLengthPicker
            videoToggles
          }
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
              searchField("動画名で検索", text: $videoSearch)
                .frame(minWidth: 160)
              videoOrderPicker
              minimumLengthPicker
            }
            HStack(spacing: 12) { videoToggles }
          }
        }
        .font(.appCaption)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)

      Divider().overlay(NeomorphicTheme.separator)

      if videos.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 28, weight: .light))
          Text("条件に合う動画がありません")
            .font(.appBody)
        }
        .foregroundStyle(NeomorphicTheme.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 176, maximum: 260), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 16
          ) {
            ForEach(videos) { videoCard($0) }
          }
          .padding(20)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var videoOrderPicker: some View {
    AppChoicePicker("並べ替え", selection: $videoOrder) {
      ForEach(MusicVideoVideoOrder.allCases) { Text($0.rawValue).tag($0) }
    }
    .labelsHidden()
    .fixedSize()
  }

  private var minimumLengthPicker: some View {
    AppChoicePicker("長さ", selection: $minimumLength) {
      Text("すべての長さ").tag(1.0)
      Text("5秒以上").tag(5.0)
      Text("10秒以上").tag(10.0)
      Text("30秒以上").tag(30.0)
    }
    .labelsHidden()
    .fixedSize()
  }

  @ViewBuilder
  private var videoToggles: some View {
    Toggle("お気に入りのみ", isOn: $favoritesOnly)
      .fixedSize()
    Toggle("選択中のみ", isOn: $onlySelected)
      .fixedSize()
  }

  private func videoCard(_ video: VideoItem) -> some View {
    let individually = viewModel.selectedVideoIDs.contains(video.id)
    let viaAlbum = albumVideoIDs.contains(video.id)
    let isSelected = individually || viaAlbum
    return Button {
      // アルバムごと選んでいる動画は、ここでは外せない(アルバムの選択を外す)。
      guard !viaAlbum else { return }
      if individually { viewModel.selectedVideoIDs.remove(video.id) } else { viewModel.selectedVideoIDs.insert(video.id) }
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Color.clear
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .overlay { MusicVideoSourceThumbnail(video: video, dataManager: dataManager) }
          .overlay(alignment: .topLeading) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 18))
              .foregroundStyle(.white)
              .opacity(isSelected ? (viaAlbum && !individually ? 0.75 : 1) : 0.7)
              .shadow(color: .black.opacity(0.55), radius: 2)
              .padding(8)
          }
          .overlay(alignment: .topTrailing) {
            if video.isFavorite {
              Image(systemName: "heart.fill")
                .font(.appMicro)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2)
                .padding(8)
            }
          }
          .overlay(alignment: .bottomLeading) {
            if viaAlbum {
              badge("アルバム")
                .padding(6)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            badge(durationText(video.duration))
              .padding(6)
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(isSelected ? NeomorphicTheme.ink : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1)
          }
        Text(video.originalFilename)
          .font(.appCaption)
          .lineLimit(2)
          .truncationMode(.middle)
          .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
          .multilineTextAlignment(.leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(viaAlbum ? "アルバムごと選んでいます．外すには、左でアルバムの選択を外してください" : video.originalFilename)
    .accessibilityLabel(video.originalFilename)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// サムネイルの上に重ねる、読みやすい小さな札。
  private func badge(_ text: String) -> some View {
    Text(text)
      .font(.appMicro.monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.black.opacity(0.62)))
  }

  // MARK: - 下の帯

  private var footer: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("使える動画 \(viewModel.candidateCount.formatted())本")
          .font(.appBodyStrong)
        Text(summaryDetail)
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
      }
      Spacer()
      Button("すべて解除") { viewModel.clearSourceSelection() }
        .disabled(viewModel.selectedAlbumIDs.isEmpty && viewModel.selectedVideoIDs.isEmpty && !viewModel.includeFavorites)
      Button("完了", action: close)
        .buttonStyle(AppActionButtonStyle(isPrimary: true))
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("musicvideo.sourceDone")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .background(NeomorphicTheme.canvas)
  }

  private var summaryDetail: String {
    var parts: [String] = []
    if !viewModel.selectedAlbumIDs.isEmpty { parts.append("アルバム \(viewModel.selectedAlbumIDs.count)個") }
    if !viewModel.selectedVideoIDs.isEmpty { parts.append("動画 \(viewModel.selectedVideoIDs.count)本") }
    if viewModel.includeFavorites { parts.append("お気に入り") }
    let selection = parts.isEmpty ? "まだ何も選ばれていません" : parts.joined(separator: "・")
    let limit = viewModel.sourceLimit
    return viewModel.candidateCount > limit
      ? "\(selection)（解析は無作為に選ぶ\(limit)本まで）"
      : selection
  }

  // MARK: - 共通の部品

  private func searchField(_ prompt: String, text: Binding<String>) -> some View {
    TextField(prompt, text: text)
      .textFieldStyle(.roundedBorder)
  }

  /// 選択の印。色を付けず、選択中は文字色・未選択は控えめな色にする。
  private func checkmark(_ isSelected: Bool) -> some View {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
      .font(.system(size: 16))
      .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
  }

  /// 動画のサムネイル。動画が無いとき(空のアルバム)は、枠だけを出す。
  @ViewBuilder
  private func thumbnail(for id: UUID?, width: CGFloat, height: CGFloat) -> some View {
    if let id, let item = videosByID[id] {
      MusicVideoSourceThumbnail(video: item, dataManager: dataManager)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(NeomorphicTheme.control)
        .frame(width: width, height: height)
        .overlay {
          Image(systemName: "film")
            .font(.appMicro)
            .foregroundStyle(NeomorphicTheme.muted)
        }
    }
  }

  private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  // MARK: - 一覧の作成

  private func rebuild() {
    allVideos = MusicVideoSourceBrowser.usableVideos(dataManager.videos)
    videosByID = Dictionary(allVideos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    albumRows = MusicVideoAlbumEntry.entries(albums: dataManager.albums, videos: dataManager.videos)
    // 見ていたアルバムが無くなっていたら、すべての動画へ戻す。
    if case .album(let id) = scope, !dataManager.albums.contains(where: { $0.id == id }) { scope = .all }
    updateAlbumVideoIDs()
  }

  private func updateAlbumVideoIDs() {
    albumVideoIDs = MusicVideoSourceBrowser.videoIDs(
      inAlbums: dataManager.albums,
      selected: viewModel.selectedAlbumIDs,
      from: videosByID
    )
  }
}

// MARK: - サムネイル

/// 動画のサムネイルを、枠いっぱいに(縦横比を保って、はみ出しは切り落として)出す。
/// `MacVideoThumbnailView` は正方形で出す部品なので、16:9 の枠には使えない。画像だけを取り出して使う。
/// 読み込みのキャッシュ(メモリ・ディスク)と同時生成数の制限は、`MacVideoThumbnailView` と共有している。
private struct MusicVideoSourceThumbnail: View {
  let video: VideoItem
  let dataManager: LibraryViewModel
  @EnvironmentObject private var appSettings: AppSettings
  @State private var image: NSImage?

  var body: some View {
    Color.clear
      .overlay {
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        } else {
          LinearGradient(
            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
      }
      .clipped()
      .task(id: video.id) {
        image = await MacVideoThumbnailView.loadThumbnail(
          for: video,
          dataManager: dataManager,
          thumbnailOption: appSettings.thumbnailOption,
          customThumbnailTime: appSettings.customThumbnailTime
        )
      }
  }
}
