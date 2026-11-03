// ArkServer/Features/MusicVideo/Models/MusicVideoPreferences.swift

import Foundation

/// ミュージックビデオ画面の設定。次に開いたときに同じ状態から始められるよう保存する。
nonisolated struct MusicVideoPreferences: Codable, Equatable, Sendable {
  var cutStyle: MusicVideoCutStyle = .standard
  var renderPreset: MusicVideoRenderPreset = .landscapeFullHD
  var exportQuality: MusicVideoExportQuality = .high
  var selectedAlbumIDs: [UUID] = []
  var selectedVideoIDs: [UUID] = []
  var includeFavorites = false
  /// 曲を探すフォルダ。
  var musicFolderPath: String?
  /// 最近使った曲(新しい順)。
  var recentMusicPaths: [String] = []

  static let recentMusicLimit = 8

  /// 最近使った曲の先頭に加える。同じ曲は1つにまとめ、上限を超えた古いものを捨てる。
  mutating func recordRecentMusic(_ path: String) {
    recentMusicPaths.removeAll { $0 == path }
    recentMusicPaths.insert(path, at: 0)
    if recentMusicPaths.count > Self.recentMusicLimit {
      recentMusicPaths.removeLast(recentMusicPaths.count - Self.recentMusicLimit)
    }
  }

  /// ライブラリからなくなったアルバム・動画の選択を取り除く。
  func pruned(validAlbumIDs: Set<UUID>, validVideoIDs: Set<UUID>) -> MusicVideoPreferences {
    var result = self
    result.selectedAlbumIDs = selectedAlbumIDs.filter { validAlbumIDs.contains($0) }
    result.selectedVideoIDs = selectedVideoIDs.filter { validVideoIDs.contains($0) }
    return result
  }

  // 後から項目を足しても、古い保存データを読めるようにする(無い項目は既定値)。
  private enum CodingKeys: String, CodingKey {
    case cutStyle, renderPreset, exportQuality, selectedAlbumIDs, selectedVideoIDs, includeFavorites
    case musicFolderPath, recentMusicPaths
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cutStyle = try container.decodeIfPresent(MusicVideoCutStyle.self, forKey: .cutStyle) ?? .standard
    renderPreset = try container.decodeIfPresent(MusicVideoRenderPreset.self, forKey: .renderPreset) ?? .landscapeFullHD
    exportQuality = try container.decodeIfPresent(MusicVideoExportQuality.self, forKey: .exportQuality) ?? .high
    selectedAlbumIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedAlbumIDs) ?? []
    selectedVideoIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedVideoIDs) ?? []
    includeFavorites = try container.decodeIfPresent(Bool.self, forKey: .includeFavorites) ?? false
    musicFolderPath = try container.decodeIfPresent(String.self, forKey: .musicFolderPath)
    recentMusicPaths = try container.decodeIfPresent([String].self, forKey: .recentMusicPaths) ?? []
  }
}

/// `MusicVideoPreferences` を UserDefaults に読み書きする。壊れた保存データは既定値に戻す。
nonisolated struct MusicVideoPreferencesStore: @unchecked Sendable {
  var defaults: UserDefaults = .standard
  var key = "musicVideo.preferences"

  func load() -> MusicVideoPreferences {
    guard let data = defaults.data(forKey: key),
          let decoded = try? JSONDecoder().decode(MusicVideoPreferences.self, from: data) else {
      return MusicVideoPreferences()
    }
    return decoded
  }

  func save(_ preferences: MusicVideoPreferences) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: key)
  }
}
