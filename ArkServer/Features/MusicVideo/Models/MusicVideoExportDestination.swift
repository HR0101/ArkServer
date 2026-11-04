// ArkServer/Features/MusicVideo/Models/MusicVideoExportDestination.swift

import Foundation

/// 「ライブラリに追加」で書き出した動画の追加先。追加のたびに利用者が選ぶ(アプリが勝手に決めない)。
nonisolated enum MusicVideoExportDestination: Equatable, Sendable {
  /// すでにあるアルバムへ追加する。
  case existing(albumID: UUID)
  /// 利用者が名前を付けた新しいアルバムを作って追加する。書き出しが成功した後で作る。
  case new(name: String)
}

/// 新しいアルバム名の検査。アルバムは "/" 区切りの名前でフォルダ階層を表すので，その決まりも確かめる．
nonisolated enum MusicVideoExportAlbumName {
  enum Problem: Error, Equatable, Sendable {
    case empty
    case reserved
    case emptyComponent
    case alreadyExists

    var message: String {
      switch self {
      case .empty: return "アルバム名を入力してください．"
      case .reserved: return "この名前はアプリが使うため，アルバム名にできません．"
      case .emptyComponent: return "「/」の前後には名前が必要です．"
      case .alreadyExists: return "同じ名前のアルバムがすでにあります．"
      }
    }
  }

  /// 前後の空白を除いた名前を返す。使えないときは理由を返す。
  static func validate(_ rawName: String, existingNames: [String]) -> Result<String, Problem> {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return .failure(.empty) }
    if reservedNames.contains(name) { return .failure(.reserved) }
    let components = name.components(separatedBy: "/")
    if components.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      return .failure(.emptyComponent)
    }
    if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      return .failure(.alreadyExists)
    }
    return .success(name)
  }

  /// ライブラリが内部で使う名前。追加先や新規作成の名前にはできない。
  static let reservedNames: Set<String> = [
    LibraryViewModel.allVideosAlbumName,
    LibraryViewModel.allPhotosAlbumName,
  ]
}

/// アルバム一覧の1行ぶん。素材を選ぶシートと追加先を選ぶシートで共通に使う。
nonisolated struct MusicVideoAlbumEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  /// アルバムの完全な名前("/" 区切り)。
  let name: String
  /// 表示用の名前(階層の最後の部分)。
  let title: String
  /// 親の階層(" / " 区切り)。階層がなければ空。
  let parent: String
  /// ゴミ箱以外の動画の本数。
  let count: Int
  let totalDuration: Double
  let latestImport: Date
  /// 表紙に使う動画(アルバムの最初の動画)。動画が1本もなければ nil。
  var coverVideoID: UUID? = nil

  /// 写真だけのアルバムを除いた一覧を作る。表示名(`Album.displayTitle`)がメインアクター上なので，こちらもそうする。
  @MainActor
  static func entries(albums: [Album], videos: [VideoItem]) -> [MusicVideoAlbumEntry] {
    let byID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return albums
      .filter { $0.type != .photo }
      .map { album in
        var count = 0
        var total = 0.0
        var latest = Date.distantPast
        var cover: UUID?
        for id in album.videoIDs {
          guard let item = byID[id], item.mediaType == .video, !item.isInTrash else { continue }
          count += 1
          total += item.duration
          latest = max(latest, item.importDate)
          if cover == nil { cover = item.id }
        }
        let components = album.name.components(separatedBy: "/")
        return MusicVideoAlbumEntry(
          id: album.id,
          name: album.name,
          title: album.displayTitle,
          parent: components.count > 1 ? components.dropLast().joined(separator: " / ") : "",
          count: count,
          totalDuration: total,
          latestImport: latest,
          coverVideoID: cover
        )
      }
  }

  /// 検索語に合うか。名前と階層のどちらかに含まれていればよい。空の検索語はすべて合う。
  func matches(query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    return title.localizedCaseInsensitiveContains(trimmed) || parent.localizedCaseInsensitiveContains(trimmed)
  }

  /// 追加先に選べるアルバム。ライブラリが内部で使う「すべて」系のアルバムは除く。
  var isSelectableDestination: Bool {
    !MusicVideoExportAlbumName.reservedNames.contains(name)
  }
}
