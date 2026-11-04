import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Combine
import Darwin
import Dispatch
import ImageIO
import UniformTypeIdentifiers
import Vision

struct LibraryStorageEnvironment {
  let moviesDirectory: () -> URL?
  let downloadsDirectory: () -> URL?
  let createDirectory: (URL) throws -> Void
  let moveFileToSystemTrash: (URL) throws -> Void

  init(
    moviesDirectory: @escaping () -> URL?,
    downloadsDirectory: @escaping () -> URL?,
    createDirectory: @escaping (URL) throws -> Void,
    moveFileToSystemTrash: @escaping (URL) throws -> Void = { url in
      var resultingURL: NSURL?
      try FileManager.default.trashItem(
        at: url,
        resultingItemURL: &resultingURL
      )
    }
  ) {
    self.moviesDirectory = moviesDirectory
    self.downloadsDirectory = downloadsDirectory
    self.createDirectory = createDirectory
    self.moveFileToSystemTrash = moveFileToSystemTrash
  }

  /// 環境変数 `ARKSERVER_DATA_PARENT` があれば、ライブラリと退避ファイルの置き場を、その下に切り替える。
  /// 自動テスト用: テスト用に起動したアプリが、実際のライブラリ(`~/Movies`)を開かず、
  /// 使用中のアプリとロックを取り合わないようにする。指定が無ければ、ふだんと同じ場所を使う。
  private static var dataParentOverride: URL? {
    guard let path = ProcessInfo.processInfo.environment["ARKSERVER_DATA_PARENT"], !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static let live = LibraryStorageEnvironment(
    moviesDirectory: {
      if let override = dataParentOverride { return override.appendingPathComponent("Movies", isDirectory: true) }
      return FileManager.default.urls(
        for: .moviesDirectory,
        in: .userDomainMask
      ).first
    },
    downloadsDirectory: {
      if let override = dataParentOverride { return override.appendingPathComponent("Downloads", isDirectory: true) }
      return FileManager.default.urls(
        for: .downloadsDirectory,
        in: .userDomainMask
      ).first
    },
    createDirectory: { url in
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
      )
    }
  )
}

struct LibraryStorageInitializationError: Equatable {
  enum Stage: Equatable {
    case moviesDirectoryLookup
    case downloadsDirectoryLookup
    case directoryCreation
  }

  let stage: Stage
  let locationName: String
  let targetPath: String
  let reason: String

  var recoverySuggestion: String {
    "フォルダの読み書き権限，ディスクの空き容量，保存先ボリュームの接続状態を確認し，アプリを再起動してください．"
  }

  static func directoryLookup(
    stage: Stage,
    locationName: String,
    fallbackURL: URL
  ) -> LibraryStorageInitializationError {
    LibraryStorageInitializationError(
      stage: stage,
      locationName: locationName,
      targetPath: fallbackURL.path,
      reason: "macOSから保存先URLを取得できませんでした．"
    )
  }

  static func directoryCreation(
    at url: URL,
    error: Error
  ) -> LibraryStorageInitializationError {
    let nsError = error as NSError
    return LibraryStorageInitializationError(
      stage: .directoryCreation,
      locationName: "ライブラリ保存先",
      targetPath: url.path,
      reason: "\(nsError.localizedDescription)（\(nsError.domain): \(nsError.code)）"
    )
  }
}

private struct LibraryStoragePaths {
  let appRootURL: URL
  let videoStorageURL: URL
  let downloadStorageURL: URL
  let thumbnailStorageURL: URL
  let proxyStorageURL: URL
  let dataFileURL: URL

  static func make(
    moviesDirectory: URL,
    downloadsDirectory: URL
  ) -> LibraryStoragePaths {
    let appRootURL = moviesDirectory.appendingPathComponent(
      "MacVideoServerData"
    )
    return LibraryStoragePaths(
      appRootURL: appRootURL,
      videoStorageURL: appRootURL.appendingPathComponent("Videos"),
      downloadStorageURL: downloadsDirectory.appendingPathComponent(
        "VideoServerForMac_Media"
      ),
      thumbnailStorageURL: appRootURL.appendingPathComponent("Thumbnails"),
      proxyStorageURL: appRootURL.appendingPathComponent("Proxies"),
      dataFileURL: appRootURL.appendingPathComponent("library.json")
    )
  }

  static let unavailable = make(
    moviesDirectory: URL(fileURLWithPath: "/dev/null"),
    downloadsDirectory: URL(fileURLWithPath: "/dev/null")
  )

  var directoriesToPrepare: [URL] {
    [
      appRootURL,
      videoStorageURL,
      downloadStorageURL,
      thumbnailStorageURL,
      proxyStorageURL,
    ]
  }
}



@MainActor
class LibraryViewModel: ObservableObject {
    @Published var videos: [VideoItem] = [] {
        didSet {
            snapshotLibrary.value = LibrarySnapshotData(videos: videos, albums: albums)
            cachedExistingSourcePaths = nil
        }
    }

    /// `existingImportedSourcePaths()` の結果キャッシュ。リンクフォルダが数百件あると、
    /// アルバムごとに毎回 videos 全件を resolvingSymlinksInPath() し直すコストが
    /// 「アルバム数 × 動画数」で効いてきて起動時/定期スキャン時にメインスレッドが固まるため、
    /// videos が変化しない限り使い回す（変化した時だけ videos の didSet で無効化する）。
    var cachedExistingSourcePaths: Set<String>?
    @Published var albums: [Album] = [] {
        didSet { snapshotLibrary.value = LibrarySnapshotData(videos: videos, albums: albums) }
    }

    /// HTTPルート（ワーカースレッド）用の読み取り専用スナップショット。
    /// videos/albums の didSet で常に同期される（配列の代入は CoW なので軽い）。
    nonisolated let snapshotLibrary = LockedBox<LibrarySnapshotData>(LibrarySnapshotData(videos: [], albums: []))
    @Published var duplicateCheckStates: [UUID: DuplicateCheckState] = [:]
    @Published var isDuplicateCheckRunning = false
    @Published var linkedFolderConflicts: [LinkedFolderConflict] = []
    /// 実ファイルの移動など，削除処理の一部が失敗した場合に画面へ通知する内容です．
    @Published var mediaDeletionNotice: String?
    /// お気に入りの変更を、クライアントと共有している保管庫（websync.json）へ流すための橋渡し。
    /// ライブラリ側からクライアント共有の保管庫を直接触らずに済ませるため、AppViewModel が繋ぐ。
    var favoriteChangeHandler: (([UUID], Bool) -> Void)?
    let duplicateCheckStatus = DuplicateCheckStatus()

    /// 自動重複チェック（バックグラウンドで定期的に走るもの）のオン/オフ。手動チェック（アルバム内の「重複チェック」ボタン）には影響しない。
    @Published var isAutoDuplicateCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoDuplicateCheckEnabled, forKey: "autoDuplicateCheckEnabled")
        }
    }

    // MARK: - ユーザー設定（詳細設定シートから変更できる項目）

    /// インポート時にファイルをアプリの管理フォルダへコピーする（true）か、元の場所を参照するだけ（false, 既定）か。
    /// コピーにすれば元フォルダを消してもサーバー内に実体が残るが、ディスク容量を消費する。
    @Published var importCopiesFiles: Bool {
        didSet { UserDefaults.standard.set(importCopiesFiles, forKey: "importCopiesFiles") }
    }

    /// ゴミ箱の自動削除期限（日数）。0 = 自動削除しない（既定）。
    @Published var trashAutoDeleteDays: Int {
        didSet { UserDefaults.standard.set(trashAutoDeleteDays, forKey: "trashAutoDeleteDays") }
    }

    /// 起動時にリンク切れメディア（元ファイルが見つからないデータ）を自動整理するか。既定はオフ。
    /// 外付けドライブのメディアを参照している場合、未接続時に誤って消えるためオフを推奨。
    @Published var autoCleanupMissingFilesEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCleanupMissingFilesEnabled, forKey: "autoCleanupMissingFilesEnabled") }
    }

    /// 自動重複チェックの実行間隔（秒）。既定30秒。
    @Published var duplicateCheckIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(duplicateCheckIntervalSeconds, forKey: "duplicateCheckIntervalSeconds") }
    }

    /// 一括インポートの並列処理数。既定4。
    @Published var importConcurrency: Int {
        didSet { UserDefaults.standard.set(importConcurrency, forKey: "importConcurrency") }
    }

    /// エクスポート時にアルバムの階層構造をフォルダとして再現する（true, 既定）か、フラットに書き出す（false）か。
    @Published var exportPreservesAlbumStructure: Bool {
        didSet { UserDefaults.standard.set(exportPreservesAlbumStructure, forKey: "exportPreservesAlbumStructure") }
    }

    // HTTPルート（ワーカースレッド）から実ファイル属性を読むため、isolation に依らず参照できるようにする。
    nonisolated let appRootURL: URL
    nonisolated let videoStorageURL: URL
    nonisolated let downloadStorageURL: URL
    let thumbnailStorageURL: URL
    let proxyStorageURL: URL
    let dataFileURL: URL
    let storageEnvironment: LibraryStorageEnvironment

    @Published private(set) var storageInitializationError: LibraryStorageInitializationError?

    var isStorageReady: Bool {
        storageInitializationError == nil
    }

    var isReadyForOperations: Bool {
        isStorageReady && !isSecondaryInstance
    }

    /// library.json の現行スキーマ世代。フィールドを追加したら上げる。
    nonisolated static let librarySchemaVersion = 3

    nonisolated static let allVideosAlbumName = "ALL VIDEOS"
    nonisolated static let allPhotosAlbumName = "ALL PHOTOS"
    static let duplicateCheckVersion = "duplicate-v3-exact"
    static let storageRefreshStartupDelayNanoseconds: UInt64 = 45_000_000_000
    static let duplicateCheckStartupDelayNanoseconds: UInt64 = 90_000_000_000
    static let linkedFolderStartupDelayNanoseconds: UInt64 = 150_000_000_000
    static let linkedFolderScanSpacingNanoseconds: UInt64 = 250_000_000
    static let maintenanceStartupDelayNanoseconds: UInt64 = 15_000_000_000

    var proxyQueue: [(sourceURL: URL, preset: String, destinationURL: URL)] = []
    var isGeneratingProxy = false
    var duplicateAutoCheckTask: Task<Void, Never>?
    var linkedFolderScanTasks: [UUID: Task<Void, Never>] = [:]
    var initialLinkedFolderScanTask: Task<Void, Never>?

    /// リンクフォルダの手動更新（ホーム画面のボタン）の進捗。ギャラリーを巻き込んで
    /// 再描画しないよう本体とは別の ObservableObject に分離している。
    let linkedFolderScanStatus = LinkedFolderScanStatus()

    // key: "<videoID>_<quality>", 値: 0...1 の進捗、nil = 生成していない
    var proxyProgressMap: [String: Double] = [:]
    /// オンデマンド変換の直近の失敗理由です。明示的に再試行するまで保持します。
    var proxyFailureMap: [String: String] = [:]

    var pendingSaveTask: Task<Void, Never>?
    var libraryLoadTask: Task<Void, Never>?
    var symlinkRepairTask: Task<Void, Never>?
    var startupMaintenanceTask: Task<Void, Never>?
    var saveGeneration = 0

    @Published var isLibraryLoaded = false

    /// 並び替え用ファイルメタデータの遅延キャッシュです．
    nonisolated let fileMetadataCache = LockedBox<[UUID: VideoFileMetadata]>([:])

    /// ホーム画面に表示する使用容量です．ディスクI/Oを避けるため定期更新します．
    @Published var totalStorageSizeText: String = "計算中…"
    var storageSizeRefreshTask: Task<Void, Never>?

    /// 同じライブラリを開いている別インスタンスが既に存在する場合 true。
    /// このとき保存系は一切行わず、起動直後にユーザーへ通知して終了する。
    private(set) var isSecondaryInstance = false

    /// 排他ロックを取得する。取得したファイル記述子は意図的に開いたままにし、
    /// プロセス終了（クラッシュ含む）でOSが自動解放するのに任せる。
    nonisolated static func acquireInstanceLock(at url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else { return true } // ロックファイル自体を作れない環境では起動を妨げない
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        return true
    }

    convenience init() {
        self.init(storageEnvironment: .live)
    }

    init(storageEnvironment: LibraryStorageEnvironment) {
        self.storageEnvironment = storageEnvironment
        self.isAutoDuplicateCheckEnabled = UserDefaults.standard.object(forKey: "autoDuplicateCheckEnabled") as? Bool ?? true
        self.importCopiesFiles = UserDefaults.standard.object(forKey: "importCopiesFiles") as? Bool ?? false
        self.trashAutoDeleteDays = UserDefaults.standard.object(forKey: "trashAutoDeleteDays") as? Int ?? 0
        self.autoCleanupMissingFilesEnabled = UserDefaults.standard.object(forKey: "autoCleanupMissingFilesEnabled") as? Bool ?? false
        self.duplicateCheckIntervalSeconds = UserDefaults.standard.object(forKey: "duplicateCheckIntervalSeconds") as? Int ?? 30
        self.importConcurrency = UserDefaults.standard.object(forKey: "importConcurrency") as? Int ?? 4
        self.exportPreservesAlbumStructure = UserDefaults.standard.object(forKey: "exportPreservesAlbumStructure") as? Bool ?? true

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let paths: LibraryStoragePaths
        let initializationError: LibraryStorageInitializationError?
        if let moviesDirectory = storageEnvironment.moviesDirectory() {
            if let downloadsDirectory = storageEnvironment.downloadsDirectory() {
                paths = LibraryStoragePaths.make(
                    moviesDirectory: moviesDirectory,
                    downloadsDirectory: downloadsDirectory
                )
                initializationError = nil
            } else {
                paths = .unavailable
                initializationError = .directoryLookup(
                    stage: .downloadsDirectoryLookup,
                    locationName: "ダウンロードフォルダ",
                    fallbackURL: homeDirectory.appendingPathComponent("Downloads")
                )
            }
        } else {
            paths = .unavailable
            initializationError = .directoryLookup(
                stage: .moviesDirectoryLookup,
                locationName: "ムービーフォルダ",
                fallbackURL: homeDirectory.appendingPathComponent("Movies")
            )
        }

        self.appRootURL = paths.appRootURL
        self.videoStorageURL = paths.videoStorageURL
        self.downloadStorageURL = paths.downloadStorageURL
        self.thumbnailStorageURL = paths.thumbnailStorageURL
        self.proxyStorageURL = paths.proxyStorageURL
        self.dataFileURL = paths.dataFileURL
        self.storageInitializationError = initializationError

        guard initializationError == nil else { return }
        guard prepareStorageDirectories(paths.directoriesToPrepare) else {
            return
        }

        // 二重起動の検出。Xcodeからの実行と/Applications版は別アプリとして同時起動でき、
        // 両方が同じ library.json をデバウンス保存すると後勝ちでサイレントにデータが失われる。
        // flock はプロセス終了（クラッシュ含む）で自動解放されるため、確実に片方だけが書ける。
        isSecondaryInstance = !Self.acquireInstanceLock(at: appRootURL.appendingPathComponent(".instance.lock"))
        if isSecondaryInstance {
            DispatchQueue.main.async {
                Self.presentDuplicateInstanceAlertAndQuit()
            }
            return
        }

        startLoadingData()

        // 保存はデバウンスされているため、終了時に保留中の分を確実に書き込む
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.libraryLoadTask?.cancel()
                self?.symlinkRepairTask?.cancel()
                self?.startupMaintenanceTask?.cancel()
                self?.cancelPendingLinkedFolderScans()
                self?.flushPendingSave()
            }
        }
    }

    /// 二重起動側のインスタンスで警告を出し、確実に終了する。
    ///
    /// このインスタンスはライブラリを読み込まず何も保存しないので、強制終了しても失われるものはない。
    /// 「OK」が押せない・終了が効かない場合でも、プロセスが残り続けないようにする。
    private static func presentDuplicateInstanceAlertAndQuit() {
        // 主スレッドが詰まっていても動くよう、別のキューから強制終了を予約しておく。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + duplicateInstanceAutoQuitSeconds) {
            exit(0)
        }
        // Xcode などから起動すると、アプリが前面に出ずアラートが他のウィンドウの後ろに残ることがある。
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Ark Server は既に起動しています"
        alert.informativeText = "別のインスタンス（例: Xcodeからの実行と通常起動）が同じライブラリを開いています．データの二重書き込みによる消失を防ぐため，このインスタンスは終了します．（\(Int(duplicateInstanceAutoQuitSeconds))秒たつと自動で終了します）"
        alert.alertStyle = .warning
        alert.runModal()

        NSApplication.shared.terminate(nil)
        // terminate が取り消された・止まった場合の保険。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { exit(0) }
    }

    /// 二重起動の警告を出してから、操作がなくても自動で終了するまでの秒数。
    private static let duplicateInstanceAutoQuitSeconds: Double = 30

    private func prepareStorageDirectories(_ directories: [URL]) -> Bool {
        for directory in directories {
            do {
                try storageEnvironment.createDirectory(directory)
            } catch {
                storageInitializationError = .directoryCreation(
                    at: directory,
                    error: error
                )
                return false
            }
        }
        return true
    }

    nonisolated func getStorageUsage() async -> (videosSize: Int64, proxiesSize: Int64, downloadsSize: Int64, appTotalSize: Int64) {
        let videoStorageURL = self.videoStorageURL
        let proxyStorageURL = self.proxyStorageURL
        let downloadStorageURL = self.downloadStorageURL
        let appRootURL = self.appRootURL

        return await Task.detached(priority: .utility) {
            var vSize: Int64 = 0
            var pSize: Int64 = 0
            var dSize: Int64 = 0
            var totalSize: Int64 = 0

            if let urls = try? FileManager.default.contentsOfDirectory(at: videoStorageURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if res?.isSymbolicLink == false { vSize += Int64(res?.fileSize ?? 0) }
                }
            }
            if let urls = try? FileManager.default.contentsOfDirectory(at: proxyStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                    pSize += Int64(res?.fileSize ?? 0)
                }
            }
            if let urls = try? FileManager.default.contentsOfDirectory(at: downloadStorageURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for url in urls {
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey])
                    dSize += Int64(res?.fileSize ?? 0)
                }
            }
            if let enumerator = FileManager.default.enumerator(at: appRootURL, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let res = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if res?.isSymbolicLink == false { totalSize += Int64(res?.fileSize ?? 0) }
                }
            }
            return (vSize, pSize, dSize, totalSize)
        }.value
    }

    func openAppRootFolderInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appRootURL.path)
    }

    func openTempFolderInFinder() {
        let tempDir = FileManager.default.temporaryDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tempDir.path)
    }
}
