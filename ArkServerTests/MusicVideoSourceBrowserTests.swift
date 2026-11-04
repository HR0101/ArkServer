// ArkServerTests/MusicVideoSourceBrowserTests.swift

import Foundation
import Testing
@testable import ArkServer

/// 素材を選ぶ画面の、一覧の絞り込み・並べ替え・表紙・「アルバムで選択済み」の判定。
@Suite
@MainActor
struct MusicVideoSourceBrowserTests {
  private func video(
    _ name: String,
    duration: Double = 30,
    daysAgo: Double = 0,
    favorite: Bool = false,
    trashed: Bool = false,
    type: MediaType = .video,
    id: UUID = UUID()
  ) -> VideoItem {
    VideoItem(
      id: id, originalFilename: name, internalFilename: "", duration: duration,
      importDate: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
      creationDate: nil, fileHash: "", mediaType: type, isFavorite: favorite, isInTrash: trashed
    )
  }

  private func entry(_ name: String, count: Int, daysAgo: Double = 0, cover: UUID? = nil) -> MusicVideoAlbumEntry {
    let components = name.components(separatedBy: "/")
    return MusicVideoAlbumEntry(
      id: UUID(), name: name, title: components.last ?? name,
      parent: components.count > 1 ? components.dropLast().joined(separator: " / ") : "",
      count: count, totalDuration: Double(count) * 30,
      latestImport: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
      coverVideoID: cover
    )
  }

  // MARK: アルバム

  @Test
  func albumsAreSortedByNameCountOrRecency() {
    let rows = [entry("b", count: 5, daysAgo: 1), entry("a", count: 9, daysAgo: 5), entry("c", count: 2, daysAgo: 0)]

    func names(_ order: MusicVideoAlbumOrder) -> [String] {
      MusicVideoSourceBrowser.albums(rows, order: order, hidesEmpty: false, onlyIDs: nil, query: "").map(\.name)
    }
    #expect(names(.name) == ["a", "b", "c"])
    #expect(names(.count) == ["a", "b", "c"])    // 9, 5, 2
    #expect(names(.recent) == ["c", "b", "a"])   // 新しい順
  }

  @Test
  func albumNamesSortNaturallyAndByHierarchy() {
    let rows = [entry("x/10", count: 1), entry("x/2", count: 1), entry("a/z", count: 1)]
    let names = MusicVideoSourceBrowser.albums(rows, order: .name, hidesEmpty: false, onlyIDs: nil, query: "").map(\.name)
    // 階層の名前から順に、数字は桁の大きさではなく数として並ぶ(2 の次が 10)。
    #expect(names == ["a/z", "x/2", "x/10"])
  }

  @Test
  func albumsCanHideEmptyOnesAndFilterBySelectionAndQuery() {
    let empty = entry("empty", count: 0)
    let kept = entry("Summer trip", count: 3)
    let other = entry("Winter", count: 4)
    let rows = [empty, kept, other]

    #expect(MusicVideoSourceBrowser.albums(rows, order: .name, hidesEmpty: true, onlyIDs: nil, query: "").map(\.name) == ["Summer trip", "Winter"])
    #expect(MusicVideoSourceBrowser.albums(rows, order: .name, hidesEmpty: false, onlyIDs: nil, query: "").count == 3)
    // 選択中のみ
    #expect(MusicVideoSourceBrowser.albums(rows, order: .name, hidesEmpty: true, onlyIDs: [other.id], query: "").map(\.name) == ["Winter"])
    // 検索は、大文字小文字を区別せず、前後の空白を無視する。
    #expect(MusicVideoSourceBrowser.albums(rows, order: .name, hidesEmpty: true, onlyIDs: nil, query: "  summer ").map(\.name) == ["Summer trip"])
    #expect(MusicVideoSourceBrowser.albums(rows, order: .name, hidesEmpty: true, onlyIDs: nil, query: "nothing").isEmpty)
  }

  @Test
  func savedSortOrdersKeepTheirStoredValues() {
    // 以前の版が `AppStorage` に保存した文字列を、そのまま読める(並べ替えの設定が初期化されない)。
    #expect(MusicVideoAlbumOrder(rawValue: "名前") == .name)
    #expect(MusicVideoAlbumOrder(rawValue: "件数の多い順") == .count)
    #expect(MusicVideoAlbumOrder(rawValue: "最近追加した順") == .recent)
    #expect(MusicVideoVideoOrder(rawValue: "追加が新しい順") == .recent)
    #expect(MusicVideoVideoOrder(rawValue: "長い順") == .longest)
    #expect(MusicVideoVideoOrder(rawValue: "名前") == .name)
  }

  // MARK: 動画

  @Test
  func videosFilterByLengthFavoritesSelectionAndQuery() {
    let short = video("short", duration: 3)
    let normal = video("Beach day", duration: 20)
    let favorite = video("Party", duration: 40, favorite: true)
    let all = [short, normal, favorite]

    func ids(minimum: Double = 1, favoritesOnly: Bool = false, only: Set<UUID>? = nil, query: String = "") -> [UUID] {
      MusicVideoSourceBrowser.videos(all, order: .name, minimumLength: minimum, favoritesOnly: favoritesOnly, onlyIDs: only, query: query).map(\.id)
    }
    #expect(ids().count == 3)
    #expect(Set(ids(minimum: 5)) == [normal.id, favorite.id])      // 5秒以上
    #expect(Set(ids(minimum: 30)) == [favorite.id])                // 30秒以上
    #expect(ids(favoritesOnly: true) == [favorite.id])
    #expect(ids(only: [short.id, normal.id]).count == 2)           // 選択中のみ
    #expect(ids(query: "beach") == [normal.id])                    // 検索
    #expect(ids(minimum: 5, favoritesOnly: true, query: "par") == [favorite.id])   // 組み合わせ
  }

  @Test
  func videosAreSortedByRecencyLengthOrName() {
    let old = video("b-old", duration: 10, daysAgo: 30)
    let recent = video("c-recent", duration: 20, daysAgo: 1)
    let long = video("a-long", duration: 90, daysAgo: 10)
    let all = [old, recent, long]

    func names(_ order: MusicVideoVideoOrder) -> [String] {
      MusicVideoSourceBrowser.videos(all, order: order, minimumLength: 1, favoritesOnly: false, onlyIDs: nil, query: "").map(\.originalFilename)
    }
    #expect(names(.recent) == ["c-recent", "a-long", "b-old"])
    #expect(names(.longest) == ["a-long", "c-recent", "b-old"])
    #expect(names(.name) == ["a-long", "b-old", "c-recent"])
  }

  @Test
  func onlyVideosOutsideTheTrashCanBeUsed() {
    let ok = video("ok")
    let trashed = video("trashed", trashed: true)
    let photo = video("photo", type: .photo)
    let usable = MusicVideoSourceBrowser.usableVideos([ok, trashed, photo])
    #expect(usable.map(\.id) == [ok.id])
  }

  // MARK: アルバムの中身・表紙・選択済みの判定

  @Test
  func albumContentsKeepTheAlbumOrderAndSkipUnusableItems() {
    let first = video("first"), second = video("second"), trashed = video("trashed", trashed: true)
    let photo = video("photo", type: .photo)
    let byID = Dictionary(uniqueKeysWithValues: [first, second, trashed, photo].map { ($0.id, $0) })
    // アルバムの並びは second → first。存在しない ID や、ゴミ箱・写真は飛ばす。
    let album = Album(id: UUID(), name: "mix", videoIDs: [second.id, trashed.id, UUID(), photo.id, first.id], type: .mixed)

    let inside = MusicVideoSourceBrowser.videos(in: album, from: byID)
    #expect(inside.map(\.originalFilename) == ["second", "first"])
  }

  @Test
  func albumEntryUsesTheFirstUsableVideoAsTheCover() {
    let trashed = video("trashed", trashed: true)
    let photo = video("photo", type: .photo)
    let cover = video("cover")
    let later = video("later")
    let videos = [trashed, photo, cover, later]
    let withCover = Album(id: UUID(), name: "with cover", videoIDs: [trashed.id, photo.id, cover.id, later.id], type: .mixed)
    let onlyTrash = Album(id: UUID(), name: "only trash", videoIDs: [trashed.id], type: .video)

    let entries = MusicVideoAlbumEntry.entries(albums: [withCover, onlyTrash], videos: videos)
    #expect(entries.first { $0.name == "with cover" }?.coverVideoID == cover.id)
    #expect(entries.first { $0.name == "with cover" }?.count == 2)
    #expect(entries.first { $0.name == "only trash" }?.coverVideoID == nil)   // 使える動画が無ければ表紙なし
  }

  @Test
  func videosInSelectedAlbumsAreReportedForTheAlbumBadge() {
    let a = video("a"), b = video("b"), c = video("c"), trashed = video("trashed", trashed: true)
    let byID = Dictionary(uniqueKeysWithValues: [a, b, c, trashed].map { ($0.id, $0) })
    let albumOne = Album(id: UUID(), name: "one", videoIDs: [a.id, trashed.id], type: .video)
    let albumTwo = Album(id: UUID(), name: "two", videoIDs: [b.id], type: .video)
    let unselected = Album(id: UUID(), name: "three", videoIDs: [c.id], type: .video)
    let albums = [albumOne, albumTwo, unselected]

    let ids = MusicVideoSourceBrowser.videoIDs(inAlbums: albums, selected: [albumOne.id, albumTwo.id], from: byID)
    #expect(ids == [a.id, b.id])   // 選んでいないアルバムの c と、ゴミ箱の動画は入らない
    #expect(MusicVideoSourceBrowser.videoIDs(inAlbums: albums, selected: [], from: byID).isEmpty)
  }
}
