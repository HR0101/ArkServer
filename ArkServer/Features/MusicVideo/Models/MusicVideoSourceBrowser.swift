// ArkServer/Features/MusicVideo/Models/MusicVideoSourceBrowser.swift

import Foundation

// 素材を選ぶ画面の、一覧の絞り込みと並べ替え。画面から切り離して、テストできるようにしてある。

/// アルバム一覧の並べ替え。値の文字列は、保存済みの設定(`musicVideo.picker.albumOrder`)と同じにしてある。
nonisolated enum MusicVideoAlbumOrder: String, CaseIterable, Identifiable, Sendable {
  case name = "名前"
  case count = "件数の多い順"
  case recent = "最近追加した順"
  var id: String { rawValue }
}

/// 動画一覧の並べ替え。値の文字列は、保存済みの設定(`musicVideo.picker.videoOrder`)と同じにしてある。
nonisolated enum MusicVideoVideoOrder: String, CaseIterable, Identifiable, Sendable {
  case recent = "追加が新しい順"
  case longest = "長い順"
  case name = "名前"
  var id: String { rawValue }
}

nonisolated enum MusicVideoSourceBrowser {
  /// アルバム一覧。
  /// - Parameters:
  ///   - hidesEmpty: 動画が1本もないアルバムを隠す。
  ///   - onlyIDs: 指定すると、そのアルバムだけに絞る(「選択中のみ」)。nil なら絞らない。
  ///   - query: 名前か階層に含まれる語。空なら絞らない。
  static func albums(
    _ rows: [MusicVideoAlbumEntry],
    order: MusicVideoAlbumOrder,
    hidesEmpty: Bool,
    onlyIDs: Set<UUID>?,
    query: String
  ) -> [MusicVideoAlbumEntry] {
    var result = rows
    if hidesEmpty { result = result.filter { $0.count > 0 } }
    if let onlyIDs { result = result.filter { onlyIDs.contains($0.id) } }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { result = result.filter { $0.matches(query: trimmed) } }
    switch order {
    case .name:
      func key(_ entry: MusicVideoAlbumEntry) -> String { entry.parent + "/" + entry.title }
      result.sort { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    case .count:
      result.sort { $0.count > $1.count }
    case .recent:
      result.sort { $0.latestImport > $1.latestImport }
    }
    return result
  }

  /// 動画一覧。
  /// - Parameters:
  ///   - minimumLength: これより短い動画は出さない(秒)。
  ///   - onlyIDs: 指定すると、その動画だけに絞る(「選択中のみ」)。nil なら絞らない。
  static func videos(
    _ items: [VideoItem],
    order: MusicVideoVideoOrder,
    minimumLength: Double,
    favoritesOnly: Bool,
    onlyIDs: Set<UUID>?,
    query: String
  ) -> [VideoItem] {
    var result = items.filter { $0.duration >= minimumLength }
    if favoritesOnly { result = result.filter(\.isFavorite) }
    if let onlyIDs { result = result.filter { onlyIDs.contains($0.id) } }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { result = result.filter { $0.originalFilename.localizedCaseInsensitiveContains(trimmed) } }
    switch order {
    case .recent:
      result.sort { $0.importDate > $1.importDate }
    case .longest:
      result.sort { $0.duration > $1.duration }
    case .name:
      result.sort { $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending }
    }
    return result
  }

  /// 素材にできる動画(動画で、ゴミ箱の外)。
  static func usableVideos(_ videos: [VideoItem]) -> [VideoItem] {
    videos.filter { $0.mediaType == .video && !$0.isInTrash }
  }

  /// アルバムに入っている動画(動画で、ゴミ箱の外)。アルバムの並びのまま。
  static func videos(in album: Album, from videosByID: [UUID: VideoItem]) -> [VideoItem] {
    album.videoIDs.compactMap { id in
      guard let item = videosByID[id], item.mediaType == .video, !item.isInTrash else { return nil }
      return item
    }
  }

  /// 選んだアルバムに入っている動画の ID。「アルバムで選択済み」の印に使う。
  static func videoIDs(inAlbums albums: [Album], selected: Set<UUID>, from videosByID: [UUID: VideoItem]) -> Set<UUID> {
    var ids = Set<UUID>()
    for album in albums where selected.contains(album.id) {
      for item in videos(in: album, from: videosByID) { ids.insert(item.id) }
    }
    return ids
  }
}
