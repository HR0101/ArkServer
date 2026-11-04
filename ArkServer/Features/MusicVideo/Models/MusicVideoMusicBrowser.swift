// ArkServer/Features/MusicVideo/Models/MusicVideoMusicBrowser.swift

import Foundation
import UniformTypeIdentifiers

// 曲を選ぶ画面の、フォルダの走査と、一覧の絞り込み・並べ替え。画面から切り離して、テストできるようにしてある。

/// 曲のファイル1つぶん。
nonisolated struct MusicVideoMusicFile: Identifiable, Hashable, Sendable {
  let url: URL
  let size: Int64
  let modified: Date
  /// 選んだフォルダからの相対の場所("/" 区切り)。選んだフォルダの直下なら空。
  let folder: String

  var id: URL { url }
  var title: String { url.deletingPathExtension().lastPathComponent }
}

/// 曲一覧の並べ替え。値の文字列は、保存済みの設定(`musicVideo.musicPicker.order`)と同じにしてある。
nonisolated enum MusicVideoMusicOrder: String, CaseIterable, Identifiable, Sendable {
  case name = "名前"
  case recent = "新しい順"
  var id: String { rawValue }
}

/// 左に並べるフォルダ1つぶん。階層の途中のフォルダも含み、数は、その下(サブフォルダ)の曲も合わせた数。
nonisolated struct MusicVideoMusicFolder: Identifiable, Hashable, Sendable {
  /// 選んだフォルダからの相対の場所("/" 区切り)。
  let path: String
  let count: Int

  var id: String { path }
  var components: [String] { path.split(separator: "/").map(String.init) }
  /// 表示名(階層の最後)。
  var name: String { components.last ?? path }
  /// 階層の深さ(直下のフォルダが 0)。
  var depth: Int { max(0, components.count - 1) }
}

nonisolated enum MusicVideoMusicBrowser {
  /// これを超える曲は、先頭からここまでだけ集める(巨大なフォルダで固まらないように)。
  static let fileLimit = 2000

  /// フォルダの中(サブフォルダも含む)の音声ファイルを集める。隠しファイルとパッケージの中は除く。
  static func scan(folder: URL, limit: Int = fileLimit) -> (files: [MusicVideoMusicFile], hitLimit: Bool) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let enumerator = FileManager.default.enumerator(
      at: folder,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return ([], false) }

    let rootComponents = folder.standardizedFileURL.pathComponents
    var found: [MusicVideoMusicFile] = []
    for case let url as URL in enumerator {
      guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { continue }
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      found.append(MusicVideoMusicFile(
        url: url,
        size: Int64(values?.fileSize ?? 0),
        modified: values?.contentModificationDate ?? .distantPast,
        folder: relativeFolder(of: url, root: rootComponents)
      ))
      if found.count >= limit { return (found, true) }
    }
    return (found, false)
  }

  /// `url` のあるフォルダの、選んだフォルダからの相対の場所。選んだフォルダの外にあるように見えるとき(別名の道筋など)は空にする。
  static func relativeFolder(of url: URL, root: [String]) -> String {
    let parent = url.deletingLastPathComponent().standardizedFileURL.pathComponents
    guard parent.count >= root.count, Array(parent.prefix(root.count)) == root else { return "" }
    return parent.dropFirst(root.count).joined(separator: "/")
  }

  /// その場所(`folder`)とその下のフォルダにある曲か。`folder` が nil なら、すべて。
  static func isIn(_ file: MusicVideoMusicFile, folder: String?) -> Bool {
    guard let folder, !folder.isEmpty else { return true }
    return file.folder == folder || file.folder.hasPrefix(folder + "/")
  }

  /// 曲一覧。`folder` はその場所とその下に絞る。`query` は曲名に含まれる語(大文字小文字は区別しない)。
  static func visible(
    _ files: [MusicVideoMusicFile],
    folder: String?,
    order: MusicVideoMusicOrder,
    query: String
  ) -> [MusicVideoMusicFile] {
    var result = files.filter { isIn($0, folder: folder) }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { result = result.filter { $0.title.localizedCaseInsensitiveContains(trimmed) } }
    switch order {
    case .name: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    case .recent: result.sort { $0.modified > $1.modified }
    }
    return result
  }

  /// 曲のあるフォルダの一覧(階層の途中も含む)。階層の順に並ぶ。選んだフォルダの直下の曲は、どのフォルダにも入らない。
  static func folders(in files: [MusicVideoMusicFile]) -> [MusicVideoMusicFolder] {
    var counts: [String: Int] = [:]
    for file in files where !file.folder.isEmpty {
      var path = ""
      for part in file.folder.split(separator: "/") {
        path = path.isEmpty ? String(part) : path + "/" + part
        counts[path, default: 0] += 1
      }
    }
    return counts
      .map { MusicVideoMusicFolder(path: $0.key, count: $0.value) }
      .sorted { lhs, rhs in
        // 親の次にその子が来るよう、階層の部品ごとに自然順で比べる。
        for (left, right) in zip(lhs.components, rhs.components) where left != right {
          return left.localizedStandardCompare(right) == .orderedAscending
        }
        return lhs.components.count < rhs.components.count
      }
  }
}
