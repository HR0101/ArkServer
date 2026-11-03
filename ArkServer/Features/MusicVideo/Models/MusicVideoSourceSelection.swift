// ArkServer/Features/MusicVideo/Models/MusicVideoSourceSelection.swift

import Foundation

/// 素材として選ばれた動画を、ライブラリの内容から決める純粋ロジック。
/// 選び方は1つの集合に統合する: 選んだアルバムの動画 ∪ 個別に選んだ動画 ∪ お気に入り。
///
/// 実ファイルの存在確認はしない(ここは画面の件数表示でも使うため、ファイルアクセスを伴わない)。
/// ファイルの確認は、映像を作る直前にだけ行う。
nonisolated enum MusicVideoSourceSelection {
  /// 素材として使える最短の長さ（秒）。これより短い動画は1カットも取れない。
  static let defaultMinimumDuration = 1.0

  static func candidateIDs(
    videos: [VideoItem],
    albums: [Album],
    selectedAlbumIDs: Set<UUID>,
    selectedVideoIDs: Set<UUID>,
    includeFavorites: Bool,
    minimumDuration: Double = defaultMinimumDuration
  ) -> [UUID] {
    guard !selectedAlbumIDs.isEmpty || !selectedVideoIDs.isEmpty || includeFavorites else { return [] }

    var chosen = selectedVideoIDs
    for album in albums where selectedAlbumIDs.contains(album.id) {
      chosen.formUnion(album.videoIDs)
    }
    return videos.compactMap { item in
      guard item.mediaType == .video, !item.isInTrash, item.duration >= minimumDuration else { return nil }
      guard chosen.contains(item.id) || (includeFavorites && item.isFavorite) else { return nil }
      return item.id
    }
  }
}
