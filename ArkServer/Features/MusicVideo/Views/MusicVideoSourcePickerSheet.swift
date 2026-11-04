// ArkServer/Features/MusicVideo/Views/MusicVideoSourcePickerSheet.swift

import SwiftUI

/// 素材にする動画を選ぶシート。アルバム単位と動画単位のどちらでも、まとめて選べる。
/// 数百のアルバムや千本以上の動画から探せるよう、検索・並べ替え・絞り込みを備える。
struct MusicVideoSourcePickerSheet: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  @ObservedObject var dataManager: LibraryViewModel
  @Environment(\.dismiss) private var dismiss

  private enum Tab: String, CaseIterable, Hashable {
    case albums = "アルバム"
    case videos = "動画"
  }

  enum AlbumOrder: String, CaseIterable, Identifiable {
    case name = "名前"
    case count = "件数の多い順"
    case recent = "最近追加した順"
    var id: String { rawValue }
  }

  enum VideoOrder: String, CaseIterable, Identifiable {
    case recent = "追加が新しい順"
    case longest = "長い順"
    case name = "名前"
    var id: String { rawValue }
  }

  @State private var tab: Tab = .albums
  @State private var searchText = ""
  @AppStorage("musicVideo.picker.albumOrder") private var albumOrder: AlbumOrder = .name
  @AppStorage("musicVideo.picker.videoOrder") private var videoOrder: VideoOrder = .recent
  @AppStorage("musicVideo.picker.hideEmpty") private var hidesEmptyAlbums = true
  @AppStorage("musicVideo.picker.minimumLength") private var minimumLength = 5.0
  @State private var onlySelected = false
  @State private var favoritesOnly = false
  @State private var albumRows: [MusicVideoAlbumEntry] = []
  /// 動画タブの一覧(動画だけ・ゴミ箱外)。ライブラリが変わったときだけ作り直す。
  @State private var allVideos: [VideoItem] = []

  private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(spacing: 0) {
      SheetHeader(
        icon: "film.stack",
        title: "素材を選ぶ",
        subtitle: "アルバムと動画は，どちらも組み合わせて選べます"
      )
      .padding(20)

      controls
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

      Divider()

      Group {
        switch tab {
        case .albums: albumList
        case .videos: videoList
        }
      }

      Divider()
      footer
        .padding(16)
    }
    .frame(minWidth: 760, idealWidth: 800, minHeight: 620, idealHeight: 700)
    .appSheet()
    .onAppear(perform: rebuild)
    .onChange(of: dataManager.albums) { rebuild() }
    .onChange(of: dataManager.videos) { rebuild() }
  }

  // MARK: - 操作部

  private var controls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        FlatSegmentedControl(
          options: Tab.allCases,
          title: { tab in
            switch tab {
            case .albums: return "アルバム（\(viewModel.selectedAlbumIDs.count)）"
            case .videos: return "動画（\(viewModel.selectedVideoIDs.count)）"
            }
          },
          selection: $tab,
          width: 280
        )
        TextField(tab == .albums ? "アルバム名で検索" : "動画名で検索", text: $searchText)
          .textFieldStyle(.roundedBorder)
      }
      HStack(spacing: 14) {
        switch tab {
        case .albums:
          Picker("並べ替え", selection: $albumOrder) {
            ForEach(AlbumOrder.allCases) { Text($0.rawValue).tag($0) }
          }
          .frame(width: 210)
          Toggle("空を隠す", isOn: $hidesEmptyAlbums)
            .fixedSize()
            .help("動画が1本もないアルバムを一覧から隠します")
        case .videos:
          Picker("並べ替え", selection: $videoOrder) {
            ForEach(VideoOrder.allCases) { Text($0.rawValue).tag($0) }
          }
          .frame(width: 210)
          Picker("長さ", selection: $minimumLength) {
            Text("すべて").tag(1.0)
            Text("5秒以上").tag(5.0)
            Text("10秒以上").tag(10.0)
            Text("30秒以上").tag(30.0)
          }
          .frame(width: 150)
          Toggle("お気に入りのみ", isOn: $favoritesOnly)
            .fixedSize()
        }
        Toggle("選択中のみ", isOn: $onlySelected)
          .fixedSize()
        Spacer(minLength: 0)
        Button("表示中を選択") { selectAllVisible() }
          .help("いま一覧に出ているものをすべて選びます")
        Button("表示中を解除") { deselectAllVisible() }
          .help("いま一覧に出ているものの選択をすべて外します")
      }
      .font(.appCaption)
    }
  }

  // MARK: - アルバム

  private var visibleAlbums: [MusicVideoAlbumEntry] {
    var rows = albumRows
    if hidesEmptyAlbums { rows = rows.filter { $0.count > 0 } }
    if onlySelected { rows = rows.filter { viewModel.selectedAlbumIDs.contains($0.id) } }
    if !query.isEmpty { rows = rows.filter { $0.matches(query: query) } }
    switch albumOrder {
    case .name:
      rows.sort { ($0.parent + "/" + $0.title).localizedStandardCompare($1.parent + "/" + $1.title) == .orderedAscending }
    case .count:
      rows.sort { $0.count > $1.count }
    case .recent:
      rows.sort { $0.latestImport > $1.latestImport }
    }
    return rows
  }

  private var albumList: some View {
    let rows = visibleAlbums
    return Group {
      if rows.isEmpty {
        emptyState("条件に合うアルバムがありません")
      } else {
        List(rows) { row in
          let isSelected = viewModel.selectedAlbumIDs.contains(row.id)
          Button {
            if isSelected { viewModel.selectedAlbumIDs.remove(row.id) } else { viewModel.selectedAlbumIDs.insert(row.id) }
          } label: {
            HStack(spacing: 10) {
              checkmark(isSelected)
              VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                  .font(.appBody)
                  .lineLimit(1)
                  .truncationMode(.middle)
                if !row.parent.isEmpty {
                  Text(row.parent)
                    .font(.appMicro)
                    .foregroundStyle(NeomorphicTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
              }
              Spacer(minLength: 8)
              VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.count)本")
                  .font(.appCaption.monospacedDigit())
                Text(durationText(row.totalDuration))
                  .font(.appMicro.monospacedDigit())
                  .foregroundStyle(NeomorphicTheme.muted)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(row.title) \(row.count)本")
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .listStyle(.plain)
      }
    }
  }

  // MARK: - 動画

  private var visibleVideos: [VideoItem] {
    var items = allVideos.filter { $0.duration >= minimumLength }
    if favoritesOnly { items = items.filter(\.isFavorite) }
    if onlySelected { items = items.filter { viewModel.selectedVideoIDs.contains($0.id) } }
    if !query.isEmpty { items = items.filter { $0.originalFilename.localizedCaseInsensitiveContains(query) } }
    switch videoOrder {
    case .recent:
      items.sort { $0.importDate > $1.importDate }
    case .longest:
      items.sort { $0.duration > $1.duration }
    case .name:
      items.sort { $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending }
    }
    return items
  }

  private var videoList: some View {
    let items = visibleVideos
    return Group {
      if items.isEmpty {
        emptyState("条件に合う動画がありません")
      } else {
        List(items) { video in
          let isSelected = viewModel.selectedVideoIDs.contains(video.id)
          Button {
            if isSelected { viewModel.selectedVideoIDs.remove(video.id) } else { viewModel.selectedVideoIDs.insert(video.id) }
          } label: {
            HStack(spacing: 10) {
              checkmark(isSelected)
              MacVideoThumbnailView(videoItem: video, dataManager: dataManager, showsPlayGlyph: false)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
              Text(video.originalFilename)
                .font(.appBody)
                .lineLimit(2)
                .truncationMode(.middle)
              Spacer(minLength: 8)
              if video.isFavorite {
                Image(systemName: "heart.fill")
                  .font(.appMicro)
                  .foregroundStyle(NeomorphicTheme.muted)
              }
              Text(durationText(video.duration))
                .font(.appMicro.monospacedDigit())
                .foregroundStyle(NeomorphicTheme.muted)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(video.originalFilename)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .listStyle(.plain)
      }
    }
  }

  // MARK: - 共通部品

  /// 選択の印。サイドバーの複数選択と同じく、色を付けず、選択中は文字色・未選択は控えめな色にする。
  private func checkmark(_ isSelected: Bool) -> some View {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
      .font(.system(size: 15))
      .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
      .frame(width: 18)
  }

  private func emptyState(_ message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 28, weight: .light))
      Text(message)
        .font(.appBody)
    }
    .foregroundStyle(NeomorphicTheme.muted)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

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
      Button("完了") { dismiss() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("musicvideo.sourceDone")
    }
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

  private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total >= 3600 { return String(format: "%d時間%02d分", total / 3600, (total % 3600) / 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  // MARK: - 選択の一括操作

  private func selectAllVisible() {
    switch tab {
    case .albums: viewModel.selectedAlbumIDs.formUnion(visibleAlbums.map(\.id))
    case .videos: viewModel.selectedVideoIDs.formUnion(visibleVideos.map(\.id))
    }
  }

  private func deselectAllVisible() {
    switch tab {
    case .albums: viewModel.selectedAlbumIDs.subtract(visibleAlbums.map(\.id))
    case .videos: viewModel.selectedVideoIDs.subtract(visibleVideos.map(\.id))
    }
  }

  // MARK: - 一覧の作成

  private func rebuild() {
    let videos = dataManager.videos
    allVideos = videos.filter { $0.mediaType == .video && !$0.isInTrash }

    albumRows = MusicVideoAlbumEntry.entries(albums: dataManager.albums, videos: videos)
  }
}
