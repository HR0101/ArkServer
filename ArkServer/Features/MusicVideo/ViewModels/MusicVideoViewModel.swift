// ArkServer/Features/MusicVideo/ViewModels/MusicVideoViewModel.swift

import AVFoundation
import Combine
import Foundation

/// 作成の進み具合。
enum MusicVideoPhase: Equatable {
  case idle
  case analyzingMusic
  case analyzingSources(completed: Int, total: Int)
  case composing
  case ready
  case exporting(progress: Double)
}

/// 「指定の動画に差し替え」のメニューに出す動画。
struct MusicVideoPoolVideo: Identifiable, Equatable {
  let id: UUID
  let name: String
}

/// 音楽に合わせた映像(HMV)の作成を進める。
/// 曲の解析・素材の解析・カット割り・編集・プレビュー・書き出しの状態をここが持ち、画面を切り替えても保たれる。
@MainActor
final class MusicVideoViewModel: ObservableObject {
  // MARK: 入力(変更すると設定として保存する)
  @Published private(set) var musicURL: URL?
  @Published var selectedAlbumIDs: Set<UUID> = [] { didSet { selectionDidChange() } }
  @Published var selectedVideoIDs: Set<UUID> = [] { didSet { selectionDidChange() } }
  @Published var includeFavorites = false { didSet { selectionDidChange() } }
  @Published var cutStyle: MusicVideoCutStyle = .standard { didSet { savePreferences() } }
  @Published var renderPreset: MusicVideoRenderPreset = .landscapeFullHD { didSet { savePreferences() } }
  @Published var exportQuality: MusicVideoExportQuality = .high { didSet { savePreferences() } }
  @Published private(set) var musicFolderURL: URL?
  @Published private(set) var recentMusicURLs: [URL] = []
  /// 選んだ素材のうち、条件(動画・ゴミ箱外・長さ)を満たす動画の本数。ファイルの存在は確認していない。
  @Published private(set) var candidateCount = 0

  // MARK: 結果
  @Published private(set) var analysis: MusicAnalysis?
  @Published private(set) var plan: CutPlan?
  @Published private(set) var phase: MusicVideoPhase = .idle
  @Published private(set) var playbackTime: Double = 0
  @Published var errorMessage: String?
  @Published var resultMessage: String?
  /// 実際に使った動画の本数。
  @Published private(set) var usedVideoCount = 0
  /// 選ばれていたが、実ファイルが見つからなかった動画の本数。
  @Published private(set) var missingFileCount = 0
  /// 素材の解析の残り時間の目安（秒）。
  @Published private(set) var estimatedRemaining: TimeInterval?

  // MARK: 編集
  @Published private(set) var selectedCutIndex: Int?
  @Published private(set) var isApplyingEdit = false
  @Published private(set) var excludedVideoIDs: Set<UUID> = []
  @Published private(set) var poolVideos: [MusicVideoPoolVideo] = []
  @Published private(set) var undoDepth = 0
  @Published private(set) var redoDepth = 0

  let player = AVPlayer()

  private weak var dataManager: LibraryViewModel?
  private var libraryObservation: AnyCancellable?
  private let preferencesStore = MusicVideoPreferencesStore()
  private var preferences = MusicVideoPreferences()
  private var isRestoringPreferences = false

  private var pool: [SourceMotionProfile] = []
  /// `pool` を作ったときの素材の組み合わせ。変わっていなければ作り直しで再解析しない。
  private var poolSourceIDs: Set<UUID> = []
  private var sourceURLs: [UUID: URL] = [:]
  private var sourceItems: [UUID: VideoItem] = [:]
  private var seed: UInt64 = UInt64.random(in: 0...UInt64.max)
  private var editCounter: UInt64 = 0
  private var composed: MusicVideoComposition?
  private var undoStack: [CutPlan] = []
  private var redoStack: [CutPlan] = []
  private var workTask: Task<Void, Never>?
  private var editTask: Task<Void, Never>?
  private var timeObserver: Any?

  private static let undoLimit = 50

  // MARK: - 状態の判定

  var isWorking: Bool {
    switch phase {
    case .idle, .ready: return false
    default: return true
    }
  }

  var musicTitle: String? {
    musicURL?.deletingPathExtension().lastPathComponent
  }

  /// 「映像を作る」を押せない理由。押せるときは nil。
  var generateBlocker: String? {
    if musicURL == nil { return "曲を選んでください" }
    if analysis == nil { return "曲を解析しています…" }
    if candidateCount == 0 { return "素材の動画を選んでください" }
    return nil
  }

  var canGenerate: Bool { generateBlocker == nil && !isWorking }
  var canExport: Bool { composed != nil && plan != nil && !isWorking && !isApplyingEdit }
  var canEdit: Bool { plan != nil && !isWorking && !isApplyingEdit }
  var canUndo: Bool { canEdit && undoDepth > 0 }
  var canRedo: Bool { canEdit && redoDepth > 0 }

  var selectedCut: PlannedCut? {
    guard let plan, let index = selectedCutIndex, plan.cuts.indices.contains(index) else { return nil }
    return plan.cuts[index]
  }

  /// 前回使った曲（今開いている曲とは別のもの）。
  var lastMusicURL: URL? {
    recentMusicURLs.first { $0 != musicURL }
  }

  init() {
    let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      MainActor.assumeIsolated {
        self?.playbackTime = time.seconds.isFinite ? time.seconds : 0
      }
    }
  }

  deinit {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
  }

  // MARK: - ライブラリとの接続・設定の復元

  /// 画面が最初に開いたときに呼ぶ。保存した設定を復元し、ライブラリの変化を見て素材の件数を更新する。
  func attach(dataManager: LibraryViewModel) {
    guard self.dataManager !== dataManager else { return }
    self.dataManager = dataManager
    restorePreferences(dataManager: dataManager)
    libraryObservation = dataManager.$videos
      .combineLatest(dataManager.$albums)
      .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
      .sink { [weak self] _, _ in
        MainActor.assumeIsolated { self?.recountCandidates() }
      }
  }

  private func restorePreferences(dataManager: LibraryViewModel) {
    var stored = preferencesStore.load()
    // ライブラリがまだ読み込まれていないときは、選択を捨てずにそのまま使う。
    if !dataManager.videos.isEmpty {
      stored = stored.pruned(
        validAlbumIDs: Set(dataManager.albums.map(\.id)),
        validVideoIDs: Set(dataManager.videos.map(\.id))
      )
    }
    preferences = stored
    isRestoringPreferences = true
    cutStyle = stored.cutStyle
    renderPreset = stored.renderPreset
    exportQuality = stored.exportQuality
    selectedAlbumIDs = Set(stored.selectedAlbumIDs)
    selectedVideoIDs = Set(stored.selectedVideoIDs)
    includeFavorites = stored.includeFavorites
    isRestoringPreferences = false
    musicFolderURL = stored.musicFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    refreshRecentMusic()
    recountCandidates()
  }

  private func savePreferences() {
    guard !isRestoringPreferences else { return }
    preferences.cutStyle = cutStyle
    preferences.renderPreset = renderPreset
    preferences.exportQuality = exportQuality
    preferences.selectedAlbumIDs = Array(selectedAlbumIDs)
    preferences.selectedVideoIDs = Array(selectedVideoIDs)
    preferences.includeFavorites = includeFavorites
    preferencesStore.save(preferences)
  }

  private func selectionDidChange() {
    guard !isRestoringPreferences else { return }
    recountCandidates()
    savePreferences()
  }

  private func recountCandidates() {
    guard let dataManager else { candidateCount = 0; return }
    candidateCount = MusicVideoSourceSelection.candidateIDs(
      videos: dataManager.videos,
      albums: dataManager.albums,
      selectedAlbumIDs: selectedAlbumIDs,
      selectedVideoIDs: selectedVideoIDs,
      includeFavorites: includeFavorites
    ).count
  }

  private func refreshRecentMusic() {
    recentMusicURLs = preferences.recentMusicPaths
      .map { URL(fileURLWithPath: $0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  func clearSourceSelection() {
    isRestoringPreferences = true
    selectedAlbumIDs = []
    selectedVideoIDs = []
    includeFavorites = false
    isRestoringPreferences = false
    selectionDidChange()
  }

  func setMusicFolder(_ url: URL) {
    musicFolderURL = url
    preferences.musicFolderPath = url.path
    preferencesStore.save(preferences)
  }

  // MARK: - 音楽

  func chooseMusic(_ url: URL) {
    cancelWork()
    clearResult()
    musicURL = url
    analysis = nil
    preferences.recordRecentMusic(url.path)
    preferencesStore.save(preferences)
    refreshRecentMusic()
    phase = .analyzingMusic
    workTask = Task { [weak self] in
      do {
        let result = try await BeatAnalyzer().analyze(url: url)
        guard let self, !Task.isCancelled else { return }
        self.analysis = result
        self.phase = .idle
      } catch is CancellationError {
        self?.phase = .idle
      } catch {
        guard let self else { return }
        self.musicURL = nil
        self.phase = .idle
        self.errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - 作成

  /// 選んだ素材から映像を作る。素材の組み合わせが前回と同じなら、解析済みの動きを使い回す。
  func generate(dataManager: LibraryViewModel, newSeed: Bool = true) {
    guard let musicURL, let analysis, !isWorking else { return }
    let resolved = resolveSources(dataManager: dataManager)
    let sources = resolved.sources
    guard !sources.isEmpty else {
      errorMessage = "使える素材動画がありません．選んだ動画のファイルが見つからないか，除外した動画だけが残っています．"
      return
    }
    missingFileCount = resolved.missing
    if newSeed { seed = UInt64.random(in: 0...UInt64.max) }
    clearResult()

    let seed = self.seed
    let style = cutStyle
    let render = renderPreset.settings
    let sourceIDs = Set(sources.map(\.videoID))
    let reusablePool = (sourceIDs == poolSourceIDs && !pool.isEmpty) ? pool : nil
    let cacheDirectory = dataManager.appRootURL.appendingPathComponent("MusicVideoCache")
    let items = resolved.items

    // 二重に開始されないよう、タスクを作る前に作業中の状態にしておく。
    phase = reusablePool == nil
      ? .analyzingSources(completed: 0, total: min(sources.count, ClipPoolBuilder().maxVideos))
      : .composing
    estimatedRemaining = nil
    let startedAt = Date()

    workTask = Task { [weak self] in
      do {
        let motion: [SourceMotionProfile]
        if let reusablePool {
          motion = reusablePool
        } else {
          var builder = ClipPoolBuilder()
          builder.cacheDirectory = cacheDirectory
          motion = try await builder.build(sources: sources, seed: seed) { completed, total in
            await MainActor.run {
              self?.phase = .analyzingSources(completed: completed, total: total)
              self?.updateEstimate(completed: completed, total: total, since: startedAt)
            }
          }
        }
        try Task.checkCancellation()

        self?.phase = .composing
        self?.estimatedRemaining = nil
        var planner = CutPlanner()
        planner.style = style
        let cutPlan = try planner.plan(analysis: analysis, pool: motion, seed: seed)
        let urls = Dictionary(uniqueKeysWithValues: sources.map { ($0.videoID, $0.url) })
        let result = try await MusicVideoComposer().makeComposition(
          plan: cutPlan,
          sourceURLs: urls,
          audioURL: musicURL,
          render: render
        )
        try Task.checkCancellation()

        guard let self else { return }
        self.pool = motion
        self.poolSourceIDs = sourceIDs
        self.sourceURLs = urls
        self.sourceItems = items
        self.undoStack = []
        self.redoStack = []
        self.syncHistoryDepth()
        self.editCounter = 0
        self.usedVideoCount = Set(cutPlan.cuts.map(\.videoID)).count
        self.poolVideos = Self.makePoolVideos(pool: motion, items: items)
        self.plan = cutPlan
        self.composed = result
        self.selectedCutIndex = nil
        self.player.replaceCurrentItem(with: result.makePlayerItem())
        await self.player.seek(to: .zero)
        self.phase = .ready
      } catch is CancellationError {
        self?.phase = .idle
        self?.estimatedRemaining = nil
      } catch {
        self?.phase = .idle
        self?.estimatedRemaining = nil
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  /// 同じ素材で、別のカット割りを作る。
  func regenerate(dataManager: LibraryViewModel) {
    generate(dataManager: dataManager, newSeed: true)
  }

  private func updateEstimate(completed: Int, total: Int, since start: Date) {
    // 最初の数本は結果のキャッシュが効いて速いことがあるので、ある程度進んでから見積もる。
    guard completed >= 3, completed < total else { estimatedRemaining = nil; return }
    let perVideo = Date().timeIntervalSince(start) / Double(completed)
    let remaining = perVideo * Double(total - completed)
    estimatedRemaining = remaining >= 5 ? remaining : nil
  }

  private static func makePoolVideos(pool: [SourceMotionProfile], items: [UUID: VideoItem]) -> [MusicVideoPoolVideo] {
    var seen = Set<UUID>()
    var videos: [MusicVideoPoolVideo] = []
    for profile in pool where seen.insert(profile.videoID).inserted {
      videos.append(MusicVideoPoolVideo(id: profile.videoID, name: items[profile.videoID]?.originalFilename ?? "（不明な動画）"))
    }
    return videos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // MARK: - カットの編集

  func selectCut(at time: Double) {
    guard let plan else { return }
    selectCut(index: plan.cutIndex(at: time))
  }

  func selectCut(index: Int?) {
    guard let plan else { return }
    guard let index, plan.cuts.indices.contains(index) else {
      selectedCutIndex = nil
      return
    }
    selectedCutIndex = index
    seek(to: plan.cuts[index].timelineStart)
  }

  func selectAdjacentCut(by step: Int) {
    guard let plan, !plan.cuts.isEmpty else { return }
    let current = selectedCutIndex ?? (plan.cutIndex(at: playbackTime) ?? 0)
    selectCut(index: min(max(0, current + step), plan.cuts.count - 1))
  }

  /// 選んでいるカットだけを、別の素材区間にする。
  func replaceSelectedCut() {
    guard let index = selectedCutIndex else { return }
    applyEdit { planner, plan, analysis, pool, seed, excluded in
      try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: seed, excluding: excluded)
    }
  }

  /// 選んでいるカットの動画を使っているカットを、すべて別の動画にする。
  func replaceAllUsesOfSelectedVideo() {
    guard let video = selectedCut?.videoID else { return }
    applyEdit { planner, plan, analysis, pool, seed, excluded in
      try planner.replaceAllCuts(usingVideo: video, in: plan, analysis: analysis, pool: pool, seed: seed, excluding: excluded)
    }
  }

  /// 選んでいるカットの動画を、以後の候補から外す(今のカット割りでの使用もすべて差し替える)。
  func excludeSelectedVideo() {
    guard let video = selectedCut?.videoID else { return }
    excludedVideoIDs.insert(video)
    applyEdit { planner, plan, analysis, pool, seed, excluded in
      try planner.replaceAllCuts(usingVideo: video, in: plan, analysis: analysis, pool: pool, seed: seed, excluding: excluded)
    }
  }

  func clearExclusions() {
    excludedVideoIDs = []
  }

  /// 選んでいるカットを、指定した動画の区間にする。
  func replaceSelectedCut(withVideo video: UUID) {
    guard let index = selectedCutIndex else { return }
    applyEdit { planner, plan, analysis, pool, seed, _ in
      try planner.replaceCut(at: index, in: plan, analysis: analysis, pool: pool, seed: seed, forcing: video)
    }
  }

  func undo() {
    guard canUndo, let current = plan, let previous = undoStack.popLast() else { return }
    redoStack.append(current)
    syncHistoryDepth()
    recompose(previous)
  }

  func redo() {
    guard canRedo, let current = plan, let next = redoStack.popLast() else { return }
    undoStack.append(current)
    syncHistoryDepth()
    recompose(next)
  }

  private func syncHistoryDepth() {
    undoDepth = undoStack.count
    redoDepth = redoStack.count
  }

  private func applyEdit(
    _ transform: (CutPlanner, CutPlan, MusicAnalysis, [SourceMotionProfile], UInt64, Set<UUID>) throws -> CutPlan
  ) {
    guard canEdit, let current = plan, let analysis else { return }
    editCounter += 1
    let editSeed = seed &+ editCounter &* 0xD1B5_4A32_D192_ED03
    do {
      var planner = CutPlanner()
      planner.style = cutStyle
      let edited = try transform(planner, current, analysis, pool, editSeed, excludedVideoIDs)
      guard edited != current else { return }
      undoStack.append(current)
      if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
      redoStack = []
      syncHistoryDepth()
      recompose(edited)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// カット割りを入れ替えて合成し直し、再生位置と再生状態を保ったままプレイヤーを差し替える。
  private func recompose(_ newPlan: CutPlan) {
    guard let musicURL else { return }
    let render = renderPreset.settings
    let urls = sourceURLs
    isApplyingEdit = true
    editTask?.cancel()
    editTask = Task { [weak self] in
      do {
        let result = try await MusicVideoComposer().makeComposition(
          plan: newPlan, sourceURLs: urls, audioURL: musicURL, render: render
        )
        guard let self, !Task.isCancelled else { return }
        let time = self.player.currentTime()
        let wasPlaying = self.player.timeControlStatus != .paused
        self.plan = newPlan
        self.composed = result
        self.usedVideoCount = Set(newPlan.cuts.map(\.videoID)).count
        self.player.replaceCurrentItem(with: result.makePlayerItem())
        await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { self.player.play() }
        self.isApplyingEdit = false
      } catch is CancellationError {
        self?.isApplyingEdit = false
      } catch {
        self?.isApplyingEdit = false
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - 書き出し

  /// 書き出して「HMV」アルバムに追加する。
  func exportToLibrary(dataManager: LibraryViewModel) {
    guard let musicTitle else { return }
    let fileName = Self.outputFileName(musicTitle: musicTitle)
    export { url in
      guard let albumID = self.hmvAlbumID(in: dataManager) else {
        throw MusicVideoComposerError.exportFailed("「HMV」アルバムを作成できませんでした．")
      }
      let added = await dataManager.importMedia(from: url, to: albumID, customFilename: fileName)
      guard added else { throw MusicVideoComposerError.exportFailed("ライブラリへ追加できませんでした．") }
      return "「\(Self.hmvAlbumName)」アルバムに \(fileName) を追加しました．"
    }
  }

  /// 書き出して、選んだ場所にファイルとして保存する(ライブラリには追加しない)。
  func exportToFile(at destination: URL) {
    export { url in
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: url, to: destination)
      return "\(destination.lastPathComponent) を保存しました．"
    }
  }

  var suggestedFileName: String {
    Self.outputFileName(musicTitle: musicTitle ?? "music")
  }

  private func export(finish: @escaping @MainActor (URL) async throws -> String) {
    guard let composed, canExport else { return }
    player.pause()
    phase = .exporting(progress: 0)
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("hmv-\(UUID().uuidString).mp4")
    let quality = exportQuality

    workTask = Task { [weak self] in
      defer { try? FileManager.default.removeItem(at: temporaryURL) }
      do {
        try await MusicVideoComposer().export(composed, to: temporaryURL, quality: quality) { fraction in
          await MainActor.run { self?.phase = .exporting(progress: fraction) }
        }
        try Task.checkCancellation()
        let message = try await finish(temporaryURL)
        self?.phase = .ready
        self?.resultMessage = message
      } catch is CancellationError {
        self?.phase = .ready
      } catch {
        self?.phase = .ready
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  private func hmvAlbumID(in dataManager: LibraryViewModel) -> UUID? {
    if let existing = dataManager.albums.first(where: { $0.name == Self.hmvAlbumName && $0.type == .video }) {
      return existing.id
    }
    return dataManager.createAlbum(name: Self.hmvAlbumName, type: .video)
  }

  static let hmvAlbumName = "HMV"

  static func outputFileName(musicTitle: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    // ファイル名に使えない文字を取り除く。
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
    let safeTitle = musicTitle.components(separatedBy: invalid).joined(separator: "_")
    return "HMV_\(safeTitle)_\(formatter.string(from: date)).mp4"
  }

  // MARK: - 素材の解決

  /// 選択内容から、実際に使える動画(実ファイルがあり、除外していない)を集める。映像を作る直前にだけ呼ぶ。
  func resolveSources(dataManager: LibraryViewModel) -> (sources: [ClipPoolSource], items: [UUID: VideoItem], missing: Int) {
    let ids = MusicVideoSourceSelection.candidateIDs(
      videos: dataManager.videos,
      albums: dataManager.albums,
      selectedAlbumIDs: selectedAlbumIDs,
      selectedVideoIDs: selectedVideoIDs,
      includeFavorites: includeFavorites
    )
    let wanted = Set(ids).subtracting(excludedVideoIDs)
    var sources: [ClipPoolSource] = []
    var items: [UUID: VideoItem] = [:]
    var missing = 0
    for item in dataManager.videos where wanted.contains(item.id) {
      guard let url = dataManager.fileURL(for: item) else { missing += 1; continue }
      sources.append(ClipPoolSource(videoID: item.id, url: url, duration: item.duration))
      items[item.id] = item
    }
    return (sources, items, missing)
  }

  /// 編集パネルのサムネイルや名前に使う、素材の動画情報。
  func sourceItem(for id: UUID) -> VideoItem? {
    sourceItems[id]
  }

  // MARK: - 再生・状態

  func seek(to seconds: Double) {
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func pausePlayback() {
    player.pause()
  }

  func cancelWork() {
    workTask?.cancel()
    workTask = nil
    if isWorking { phase = composed == nil ? .idle : .ready }
    estimatedRemaining = nil
  }

  private func clearResult() {
    editTask?.cancel()
    isApplyingEdit = false
    player.pause()
    player.replaceCurrentItem(with: nil)
    plan = nil
    composed = nil
    selectedCutIndex = nil
    playbackTime = 0
  }

  func clearError() { errorMessage = nil }
  func clearResultMessage() { resultMessage = nil }
}
