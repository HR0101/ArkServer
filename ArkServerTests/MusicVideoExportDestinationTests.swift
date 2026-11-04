// ArkServerTests/MusicVideoExportDestinationTests.swift

import Foundation
import Testing
@testable import ArkServer

// MARK: - 新しいアルバム名の検査

@Suite
struct MusicVideoExportAlbumNameTests {
  @Test
  func acceptsAndTrimsAnOrdinaryName() {
    #expect(MusicVideoExportAlbumName.validate("  旅行の曲  ", existingNames: []) == .success("旅行の曲"))
  }

  @Test
  func acceptsHierarchyWithSlash() {
    #expect(MusicVideoExportAlbumName.validate("作品/2026", existingNames: ["作品"]) == .success("作品/2026"))
  }

  @Test
  func rejectsEmptyOrBlankNames() {
    #expect(MusicVideoExportAlbumName.validate("", existingNames: []) == .failure(.empty))
    #expect(MusicVideoExportAlbumName.validate("  \n ", existingNames: []) == .failure(.empty))
  }

  @Test
  func rejectsNamesTheLibraryUsesInternally() {
    #expect(MusicVideoExportAlbumName.validate("ALL VIDEOS", existingNames: []) == .failure(.reserved))
    #expect(MusicVideoExportAlbumName.validate(" ALL PHOTOS ", existingNames: []) == .failure(.reserved))
  }

  @Test
  func rejectsEmptyHierarchyComponents() {
    #expect(MusicVideoExportAlbumName.validate("/a", existingNames: []) == .failure(.emptyComponent))
    #expect(MusicVideoExportAlbumName.validate("a/", existingNames: []) == .failure(.emptyComponent))
    #expect(MusicVideoExportAlbumName.validate("a//b", existingNames: []) == .failure(.emptyComponent))
    #expect(MusicVideoExportAlbumName.validate("a/ /b", existingNames: []) == .failure(.emptyComponent))
  }

  @Test
  func rejectsNamesAlreadyInTheLibraryIgnoringCase() {
    #expect(MusicVideoExportAlbumName.validate("Trip", existingNames: ["Trip"]) == .failure(.alreadyExists))
    #expect(MusicVideoExportAlbumName.validate("trip", existingNames: ["Trip"]) == .failure(.alreadyExists))
    #expect(MusicVideoExportAlbumName.validate(" Trip ", existingNames: ["Trip"]) == .failure(.alreadyExists))
  }

  @Test
  func everyProblemHasAMessage() {
    let problems: [MusicVideoExportAlbumName.Problem] = [.empty, .reserved, .emptyComponent, .alreadyExists]
    for problem in problems {
      #expect(!problem.message.isEmpty)
    }
  }
}

// MARK: - アルバム一覧の組み立て

@Suite
@MainActor
struct MusicVideoAlbumEntryTests {
  private func video(
    _ id: UUID = UUID(),
    duration: Double = 10,
    importedAt: Date,
    mediaType: MediaType = .video,
    isInTrash: Bool = false
  ) -> VideoItem {
    VideoItem(
      id: id,
      originalFilename: "\(id.uuidString).mp4",
      internalFilename: "\(id.uuidString).mp4",
      duration: duration,
      importDate: importedAt,
      creationDate: nil,
      fileHash: id.uuidString,
      mediaType: mediaType,
      isInTrash: isInTrash
    )
  }

  @Test
  func countsOnlyVideosOutsideTheTrashAndLeavesPhotoAlbumsOut() {
    let early = Date(timeIntervalSince1970: 1_000)
    let late = Date(timeIntervalSince1970: 2_000)
    let a = video(duration: 30, importedAt: early)
    let b = video(duration: 20, importedAt: late)
    let trashed = video(duration: 99, importedAt: late, isInTrash: true)
    let photo = video(duration: 0, importedAt: late, mediaType: .photo)

    let albums = [
      Album(id: UUID(), name: "旅行", videoIDs: [a.id, b.id, trashed.id, photo.id], type: .video),
      Album(id: UUID(), name: "写真だけ", videoIDs: [photo.id], type: .photo),
    ]
    let entries = MusicVideoAlbumEntry.entries(albums: albums, videos: [a, b, trashed, photo])

    #expect(entries.count == 1)
    #expect(entries[0].title == "旅行")
    #expect(entries[0].count == 2)
    #expect(entries[0].totalDuration == 50)
    #expect(entries[0].latestImport == late)
  }

  @Test
  func keepsEmptyAlbumsSoTheyCanBeChosenAsDestinations() {
    let entries = MusicVideoAlbumEntry.entries(
      albums: [Album(id: UUID(), name: "空", videoIDs: [], type: .video)],
      videos: []
    )

    #expect(entries.map(\.count) == [0])
    #expect(entries[0].latestImport == .distantPast)
    #expect(entries[0].isSelectableDestination)
  }

  @Test
  func splitsHierarchyIntoTitleAndParent() {
    let entries = MusicVideoAlbumEntry.entries(
      albums: [Album(id: UUID(), name: "作品/2026/春", videoIDs: [], type: .mixed)],
      videos: []
    )

    #expect(entries[0].name == "作品/2026/春")
    #expect(entries[0].title == "春")
    #expect(entries[0].parent == "作品 / 2026")
  }

  @Test
  func systemAlbumsAreNotSelectableAsDestinations() {
    let entries = MusicVideoAlbumEntry.entries(
      albums: [
        Album(id: UUID(), name: LibraryViewModel.allVideosAlbumName, videoIDs: [], type: .video),
        Album(id: UUID(), name: "自作", videoIDs: [], type: .video),
      ],
      videos: []
    )

    #expect(entries.filter(\.isSelectableDestination).map(\.name) == ["自作"])
  }

  @Test
  func searchMatchesTitleOrParentAndIgnoresCase() {
    let entry = MusicVideoAlbumEntry.entries(
      albums: [Album(id: UUID(), name: "Works/Spring Trip", videoIDs: [], type: .video)],
      videos: []
    )[0]

    #expect(entry.matches(query: ""))
    #expect(entry.matches(query: "  "))
    #expect(entry.matches(query: "spring"))
    #expect(entry.matches(query: "WORKS"))
    #expect(!entry.matches(query: "winter"))
  }
}
