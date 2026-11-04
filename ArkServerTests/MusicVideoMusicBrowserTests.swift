// ArkServerTests/MusicVideoMusicBrowserTests.swift

import Foundation
import Testing
@testable import ArkServer

/// 曲を選ぶ画面の、フォルダの走査・絞り込み・並べ替え・フォルダの階層。
@Suite
struct MusicVideoMusicBrowserTests {
  private func file(
    _ name: String,
    folder: String = "",
    daysAgo: Double = 0,
    size: Int64 = 1_000
  ) -> MusicVideoMusicFile {
    let path = (folder.isEmpty ? "" : folder + "/") + name
    return MusicVideoMusicFile(
      url: URL(fileURLWithPath: "/music/" + path),
      size: size,
      modified: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
      folder: folder
    )
  }

  private func write(_ relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
  }

  // MARK: 走査

  @Test
  func scanFindsAudioFilesInSubfoldersAndSkipsOtherFiles() throws {
    let root = try temporaryDirectory("music-scan")
    defer { try? FileManager.default.removeItem(at: root) }
    try write("top.mp3", in: root)
    try write("notes.txt", in: root)                       // 音声ではない
    try write("cover.jpg", in: root)                       // 音声ではない
    try write(".hidden.mp3", in: root)                     // 隠しファイル
    try write("Artist A/one.m4a", in: root)
    try write("Artist A/Album 1/two.wav", in: root)
    try write("Artist A/Album 1/three.mp3", in: root)
    try write("Artist B/four.mp3", in: root)
    try write("Player.app/Contents/Resources/inside.mp3", in: root)   // パッケージの中は見ない

    let result = MusicVideoMusicBrowser.scan(folder: root)
    #expect(!result.hitLimit)

    let titles = Set(result.files.map(\.title))
    #expect(titles == ["top", "one", "two", "three", "four"])

    // 選んだフォルダからの相対の場所が付く。
    func folderOf(_ title: String) -> String? { result.files.first { $0.title == title }?.folder }
    #expect(folderOf("top") == "")
    #expect(folderOf("one") == "Artist A")
    #expect(folderOf("two") == "Artist A/Album 1")
    #expect(folderOf("four") == "Artist B")
    // 大きさも読める。
    #expect(result.files.allSatisfy { $0.size == 1 })
  }

  @Test
  func scanStopsAtTheLimitAndSaysSo() throws {
    let root = try temporaryDirectory("music-limit")
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<6 { try write("song\(index).mp3", in: root) }

    let limited = MusicVideoMusicBrowser.scan(folder: root, limit: 4)
    #expect(limited.files.count == 4)
    #expect(limited.hitLimit)

    let all = MusicVideoMusicBrowser.scan(folder: root, limit: 6)
    #expect(all.files.count == 6)
    #expect(all.hitLimit)   // ちょうど上限に達したときも、これ以上あるかもしれないので、上限として扱う

    let more = MusicVideoMusicBrowser.scan(folder: root, limit: 7)
    #expect(more.files.count == 6)
    #expect(!more.hitLimit)
  }

  @Test
  func scanOfAMissingFolderIsEmpty() {
    let result = MusicVideoMusicBrowser.scan(folder: URL(fileURLWithPath: "/no/such/folder-\(UUID().uuidString)"))
    #expect(result.files.isEmpty)
    #expect(!result.hitLimit)
  }

  @Test
  func relativeFolderIsComputedFromTheChosenFolder() {
    let root = ["/", "Users", "me", "Music"]
    func relative(_ path: String) -> String {
      MusicVideoMusicBrowser.relativeFolder(of: URL(fileURLWithPath: path), root: root)
    }
    #expect(relative("/Users/me/Music/a.mp3") == "")
    #expect(relative("/Users/me/Music/Artist/a.mp3") == "Artist")
    #expect(relative("/Users/me/Music/Artist/Album/a.mp3") == "Artist/Album")
    // 選んだフォルダの外にあるように見えるときは、空にする(落ちない)。
    #expect(relative("/Volumes/Other/a.mp3") == "")
    #expect(relative("/Users/me/MusicOther/a.mp3") == "")
  }

  // MARK: フォルダの階層

  @Test
  func foldersCountSongsIncludingSubfoldersAndOrderParentsBeforeChildren() {
    let files = [
      file("root"),                                       // 直下の曲は、どのフォルダにも入らない
      file("a", folder: "Artist A"),
      file("b", folder: "Artist A/Album 2"),
      file("c", folder: "Artist A/Album 10"),
      file("d", folder: "Artist A/Album 10"),
      file("e", folder: "Artist B")
    ]
    let folders = MusicVideoMusicBrowser.folders(in: files)

    #expect(folders.map(\.path) == [
      "Artist A", "Artist A/Album 2", "Artist A/Album 10",   // 親の次に子。数字は数として並ぶ(2 の次が 10)
      "Artist B"
    ])
    // 数は、その下の曲も合わせた数。
    #expect(folders.map(\.count) == [4, 1, 2, 1])
    #expect(folders.map(\.depth) == [0, 1, 1, 0])
    #expect(folders[1].name == "Album 2")
  }

  @Test
  func aFolderScopeIncludesItsSubfoldersButNotSimilarlyNamedSiblings() {
    let inside = file("inside", folder: "A")
    let nested = file("nested", folder: "A/B")
    let sibling = file("sibling", folder: "AB")          // 名前が "A" で始まるだけの別のフォルダ
    let root = file("root")
    let files = [inside, nested, sibling, root]

    func titles(_ folder: String?) -> Set<String> {
      Set(MusicVideoMusicBrowser.visible(files, folder: folder, order: .name, query: "").map(\.title))
    }
    #expect(titles("A") == ["inside", "nested"])
    #expect(titles("A/B") == ["nested"])
    #expect(titles("AB") == ["sibling"])
    #expect(titles(nil) == ["inside", "nested", "sibling", "root"])
    #expect(titles("") == ["inside", "nested", "sibling", "root"])
  }

  // MARK: 絞り込みと並べ替え

  @Test
  func songsAreSortedByNaturalNameOrByRecency() {
    let files = [
      file("Track 10", daysAgo: 1),
      file("Track 2", daysAgo: 5),
      file("Another", daysAgo: 0)
    ]
    func titles(_ order: MusicVideoMusicOrder) -> [String] {
      MusicVideoMusicBrowser.visible(files, folder: nil, order: order, query: "").map(\.title)
    }
    #expect(titles(.name) == ["Another", "Track 2", "Track 10"])
    #expect(titles(.recent) == ["Another", "Track 10", "Track 2"])
  }

  @Test
  func searchIgnoresCaseAndSurroundingSpaces() {
    let files = [file("Summer Night"), file("Winter"), file("夏の終わり")]
    func titles(_ query: String) -> [String] {
      MusicVideoMusicBrowser.visible(files, folder: nil, order: .name, query: query).map(\.title)
    }
    #expect(titles("  summer ") == ["Summer Night"])
    #expect(titles("夏") == ["夏の終わり"])
    #expect(titles("nothing").isEmpty)
    #expect(titles("   ").count == 3)   // 空白だけなら絞らない
  }

  @Test
  func searchAndFolderScopeCombine() {
    let files = [
      file("love song", folder: "Pop"),
      file("love ballad", folder: "Rock"),
      file("other", folder: "Pop")
    ]
    let result = MusicVideoMusicBrowser.visible(files, folder: "Pop", order: .name, query: "love")
    #expect(result.map(\.title) == ["love song"])
  }

  @Test
  func savedSortOrderKeepsItsStoredValue() {
    // 以前の版が `AppStorage` に保存した文字列を、そのまま読める。
    #expect(MusicVideoMusicOrder(rawValue: "名前") == .name)
    #expect(MusicVideoMusicOrder(rawValue: "新しい順") == .recent)
  }
}
