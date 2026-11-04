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

/// 取り消し・やり直しの1段階。カット割りと、それを作ったときの設定。
private struct PlanSnapshot {
  var plan: CutPlan
  var settings: MusicVideoPlanSettings
}

/// 調整項目を変えたときの、作り直しの範囲。値が大きいほど大がかり。
private enum TuningEffect: Int {
  /// 合成だけをやり直す(カット割りはそのまま)。
  case composition = 0
  /// カット割りを作り直す(素材の解析は使い回す)。
  case plan = 1
}

/// 音楽に合わせた映像（ミュージックビデオ）の作成を進める。
/// 曲の解析・素材の解析・カット割り・編集・プレビュー・書き出しの状態をここが持ち、画面を切り替えても保たれる。
@MainActor
final class MusicVideoViewModel: ObservableObject {
  // MARK: 入力(変更すると設定として保存する)
  @Published private(set) var musicURL: URL?
  @Published var selectedAlbumIDs: Set<UUID> = [] { didSet { selectionDidChange() } }
  @Published var selectedVideoIDs: Set<UUID> = [] { didSet { selectionDidChange() } }
  @Published var includeFavorites = false { didSet { selectionDidChange() } }
  // 調整項目。映像ができているときは、変えると少し待ってから(250ms)、自動で反映する。
  @Published var cutStyle: MusicVideoCutStyle = .standard {
    didSet {
      guard cutStyle != oldValue else { return }
      savePreferences()
      tuningDidChange(.plan, title: "カットの細かさ")
    }
  }
  @Published var renderPreset: MusicVideoRenderPreset = .landscapeFullHD {
    didSet {
      guard renderPreset != oldValue else { return }
      savePreferences()
      tuningDidChange(.composition, title: "画面サイズ")
    }
  }
  @Published var exportQuality: MusicVideoExportQuality = .high { didSet { savePreferences() } }
  /// カット割りに効く項目(最短・最長のカット長、動きの合わせ方、動画のばらけ具合、切り替えのタイミング)。
  @Published var cutTuning = MusicVideoCutTuning() {
    didSet {
      guard cutTuning != oldValue else { return }
      savePreferences()
      tuningDidChange(.plan, title: Self.changedTitle(from: oldValue, to: cutTuning))
    }
  }
  /// 見た目と音に効く項目(画面の合わせ方、切り替え効果、フェード)。
  @Published var lookTuning = MusicVideoLookTuning() {
    didSet {
      guard lookTuning != oldValue else { return }
      savePreferences()
      tuningDidChange(.composition, title: Self.changedTitle(from: oldValue, to: lookTuning))
    }
  }
  /// 解析に使う素材動画の本数。素材の解析が要るので、変えたあとは「作り直す」で反映する。
  @Published var sourceLimit = MusicVideoSourceLimit.standard {
    didSet {
      guard sourceLimit != oldValue else { return }
      savePreferences()
    }
  }
  @Published private(set) var musicFolderURL: URL?
  @Published private(set) var recentMusicURLs: [URL] = []
  /// 選んだ素材のうち、条件(動画・ゴミ箱外・長さ)を満たす動画の本数。ファイルの存在は確認していない。
  @Published private(set) var candidateCount = 0

  // MARK: 結果
  /// 曲全体の解析結果。
  @Published private(set) var fullAnalysis: MusicAnalysis?
  /// いまのカット割りを作った範囲の解析結果。曲の一部だけを使うときは、その範囲に切り出したもの。
  @Published private(set) var analysis: MusicAnalysis?
  /// 映像にする曲の範囲。nil なら曲の全体。
  @Published private(set) var musicRange: MusicRange?
  @Published private(set) var plan: CutPlan?
  /// いまのカット割りの結果を表す数値(カット数・平均の長さ・使った動画の本数・動きの一致度)。
  @Published private(set) var planStats: MusicVideoPlanStats?
  /// 直前に調整項目を変えたときの、結果の違い。「作り直す」や曲の変更で消える。
  @Published private(set) var lastChangeNote: String?
  @Published private(set) var phase: MusicVideoPhase = .idle
  @Published private(set) var playbackTime: Double = 0
  /// 映像を再生中か(読み込み待ちも含む)。
  @Published private(set) var isPlaying = false
  /// 映像の音を消しているか。
  @Published var isMuted = false { didSet { player.isMuted = isMuted } }
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
  /// 曲を選ぶときの試聴。
  let preview = MusicPreviewPlayer()

  private weak var dataManager: LibraryViewModel?
  private var libraryObservation: AnyCancellable?
  private let preferencesStore: MusicVideoPreferencesStore
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
  private var undoStack: [PlanSnapshot] = []
  private var redoStack: [PlanSnapshot] = []
  /// `pool` を作ったときの、素材の本数の上限。
  private var poolSourceLimit = MusicVideoSourceLimit.standard
  /// いまのカット割りを作ったときの設定。取り消しで元に戻す設定の基準になる。
  private var appliedSettings: MusicVideoPlanSettings?
  /// 取り消し・やり直しで設定を戻している間は、設定の変更を反映の対象にしない。
  private var isRestoringSettings = false
  private var pendingEffect: TuningEffect?
  private var pendingTitle: String?
  private var tuningTask: Task<Void, Never>?
  private var workTask: Task<Void, Never>?
  private var editTask: Task<Void, Never>?
  private var timeObserver: Any?
  private var playingObservation: AnyCancellable?

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

  /// 映像にする長さ(秒)。曲の一部だけを使うときは、その長さ。
  var targetDuration: Double? { musicRange?.length ?? fullAnalysis?.duration }

  /// いま画面で選んでいる、カット割りに効く設定。
  var currentSettings: MusicVideoPlanSettings {
    MusicVideoPlanSettings(cutStyle: cutStyle, cutTuning: cutTuning, musicRange: musicRange)
  }

  /// 素材の本数を変えたのに、いまの映像にはまだ反映されていないか。
  /// 選んだ動画が両方の上限以下なら、本数は変わらないので反映の必要はない。
  var sourceLimitNeedsRebuild: Bool {
    plan != nil && min(candidateCount, sourceLimit) != min(candidateCount, poolSourceLimit)
  }

  /// 曲全体の解析結果を `range` に切り出したもの。nil なら曲の全体。
  private func trimmedAnalysis(for range: MusicRange?) -> MusicAnalysis? {
    guard let fullAnalysis else { return nil }
    return range.map { fullAnalysis.trimmed(to: $0) } ?? fullAnalysis
  }
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

  /// - Parameter preferencesStore: 設定の保存先。テストでは、実際の設定を書き換えないよう別の保存先を渡す。
  init(preferencesStore: MusicVideoPreferencesStore = MusicVideoPreferencesStore()) {
    self.preferencesStore = preferencesStore
    let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      MainActor.assumeIsolated {
        self?.playbackTime = time.seconds.isFinite ? time.seconds : 0
      }
    }
    playingObservation = player.publisher(for: \.timeControlStatus)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        MainActor.assumeIsolated { self?.isPlaying = status != .paused }
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
    // 基本は横。縦は一時的な選択なので、保存されていても、同じ画質の横に読み替える。
    renderPreset = stored.renderPreset.landscapeEquivalent
    exportQuality = stored.exportQuality
    cutTuning = stored.cutTuning
    lookTuning = stored.lookTuning
    sourceLimit = stored.sourceLimit
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
    // 縦は保存しない(開き直したときは横から始める)。
    preferences.renderPreset = renderPreset.landscapeEquivalent
    preferences.exportQuality = exportQuality
    preferences.cutTuning = cutTuning
    preferences.lookTuning = lookTuning
    preferences.sourceLimit = sourceLimit
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
    preview.stop()
    cancelWork()
    clearResult()
    musicURL = url
    analysis = nil
    fullAnalysis = nil
    musicRange = nil
    preferences.recordRecentMusic(url.path)
    preferencesStore.save(preferences)
    refreshRecentMusic()
    phase = .analyzingMusic
    workTask = Task { [weak self] in
      do {
        let result = try await BeatAnalyzer().analyze(url: url)
        guard let self, !Task.isCancelled else { return }
        self.fullAnalysis = result
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
    guard let musicURL, let fullAnalysis, !isWorking else { return }
    // 反映待ちの調整は捨てる(これから、いまの設定でまとめて作る)。
    tuningTask?.cancel()
    pendingEffect = nil
    pendingTitle = nil
    // 曲の一部だけを使うときは、その範囲に切り出した解析結果で作る。
    let analysis = trimmedAnalysis(for: musicRange) ?? fullAnalysis
    preview.stop()
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
    let tuning = cutTuning
    let look = lookTuning
    let settings = currentSettings
    let sourceLimit = self.sourceLimit
    let render = renderPreset.settings
    let sourceIDs = Set(sources.map(\.videoID))
    // 素材の組み合わせも、素材の本数の上限も前回と同じなら、解析済みの動きを使い回す。
    let reusablePool = (sourceIDs == poolSourceIDs && sourceLimit == poolSourceLimit && !pool.isEmpty) ? pool : nil
    let cacheDirectory = dataManager.appRootURL.appendingPathComponent("MusicVideoCache")
    let items = resolved.items

    // 二重に開始されないよう、タスクを作る前に作業中の状態にしておく。
    phase = reusablePool == nil
      ? .analyzingSources(completed: 0, total: min(sources.count, sourceLimit))
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
          builder.maxVideos = sourceLimit
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
        let planner = CutPlanner(style: style, tuning: tuning)
        let cutPlan = try planner.plan(analysis: analysis, pool: motion, seed: seed)
        let urls = Dictionary(uniqueKeysWithValues: sources.map { ($0.videoID, $0.url) })
        let result = try await MusicVideoComposer().makeComposition(
          plan: cutPlan,
          sourceURLs: urls,
          audioURL: musicURL,
          render: render,
          look: look,
          audioStart: settings.musicRange?.start ?? 0
        )
        try Task.checkCancellation()

        guard let self else { return }
        self.pool = motion
        self.poolSourceIDs = sourceIDs
        self.poolSourceLimit = sourceLimit
        self.analysis = analysis
        self.appliedSettings = settings
        self.lastChangeNote = nil
        self.planStats = MusicVideoPlanStats(plan: cutPlan, pool: motion, analysis: analysis)
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
    redoStack.append(snapshot(of: current))
    restore(previous)
  }

  func redo() {
    guard canRedo, let current = plan, let next = redoStack.popLast() else { return }
    undoStack.append(snapshot(of: current))
    restore(next)
  }

  private func snapshot(of plan: CutPlan) -> PlanSnapshot {
    PlanSnapshot(plan: plan, settings: appliedSettings ?? currentSettings)
  }

  /// カット割りと、それを作ったときの設定を、そろえて元へ戻す。
  private func restore(_ snapshot: PlanSnapshot) {
    tuningTask?.cancel()
    pendingEffect = nil
    pendingTitle = nil
    applySettings(snapshot.settings)
    appliedSettings = snapshot.settings
    lastChangeNote = nil
    syncHistoryDepth()
    recompose(snapshot.plan, analysis: trimmedAnalysis(for: snapshot.settings.musicRange))
  }

  /// 設定だけを戻す。設定の変更として反映し直さない。
  private func applySettings(_ settings: MusicVideoPlanSettings) {
    isRestoringSettings = true
    cutStyle = settings.cutStyle
    cutTuning = settings.cutTuning
    musicRange = settings.musicRange
    isRestoringSettings = false
    savePreferences()
  }

  // MARK: - 調整項目の反映

  /// 映像の曲の範囲を決める。曲の全体と同じなら範囲なしになる。開始は、曲の拍にそろえる。
  func setMusicRange(start: Double, end: Double) {
    guard let fullAnalysis, !isWorking else { return }
    let snappedStart = start <= 0 ? 0 : fullAnalysis.nearestBeat(to: start)
    let newRange = MusicRange.clamped(start: snappedStart, end: end, songDuration: fullAnalysis.duration)
    guard newRange != musicRange else { return }
    musicRange = newRange
    tuningDidChange(.plan, title: "曲の範囲")
  }

  /// 調整項目が変わった。映像ができているときだけ、少し待ってから反映する(つまみを動かしている間の連続した変更をまとめる)。
  private func tuningDidChange(_ effect: TuningEffect, title: String) {
    guard !isRestoringPreferences, !isRestoringSettings, plan != nil else { return }
    if (pendingEffect?.rawValue ?? -1) < effect.rawValue { pendingEffect = effect }
    pendingTitle = title
    tuningTask?.cancel()
    tuningTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      self?.applyPendingTuning()
    }
  }

  /// 反映待ちの調整を適用する。乱数の種は変えないので、変えた項目だけの違いが出る。
  private func applyPendingTuning() {
    guard let effect = pendingEffect, let current = plan, !isWorking else { return }
    let title = pendingTitle ?? "設定"
    pendingEffect = nil
    pendingTitle = nil

    switch effect {
    case .composition:
      lastChangeNote = "「\(title)」を変えました．カット割りはそのままで、見た目と音だけが変わります．"
      recompose(current)

    case .plan:
      let settings = currentSettings
      guard let newAnalysis = trimmedAnalysis(for: settings.musicRange) else { return }
      let activePool = pool.filter { !excludedVideoIDs.contains($0.videoID) }
      do {
        let planner = CutPlanner(style: settings.cutStyle, tuning: settings.cutTuning)
        let newPlan = try planner.plan(analysis: newAnalysis, pool: activePool, seed: seed)

        let before = planStats ?? MusicVideoPlanStats(plan: current, pool: activePool, analysis: analysis)
        let after = MusicVideoPlanStats(plan: newPlan, pool: activePool, analysis: newAnalysis)
        lastChangeNote = MusicVideoChangeSummary(title: title, before: before, after: after).text

        // 設定を変えたカット割りも、取り消しで元の設定ごと戻せるようにする。
        undoStack.append(snapshot(of: current))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack = []
        appliedSettings = settings
        syncHistoryDepth()
        selectedCutIndex = nil
        recompose(newPlan, analysis: newAnalysis)
      } catch {
        // 作れなかったときは、設定を直前の状態へ戻す。
        if let appliedSettings { applySettings(appliedSettings) }
        lastChangeNote = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  private static func changedTitle(from old: MusicVideoCutTuning, to new: MusicVideoCutTuning) -> String {
    if old.minimumCutDuration != new.minimumCutDuration { return "最短のカット長" }
    if old.maximumCutDuration != new.maximumCutDuration { return "最長のカット長" }
    if old.motionMatching != new.motionMatching { return "動きの合わせ方" }
    if old.variety != new.variety { return "動画のばらけ具合" }
    return "切り替えのタイミング"
  }

  private static func changedTitle(from old: MusicVideoLookTuning, to new: MusicVideoLookTuning) -> String {
    if old.fitMode != new.fitMode { return "画面の合わせ方" }
    if old.transition != new.transition { return "切り替え効果" }
    return "フェード"
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
      let planner = CutPlanner(style: cutStyle, tuning: cutTuning)
      let edited = try transform(planner, current, analysis, pool, editSeed, excludedVideoIDs)
      guard edited != current else { return }
      undoStack.append(snapshot(of: current))
      if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
      redoStack = []
      syncHistoryDepth()
      recompose(edited)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// カット割りを入れ替えて合成し直し、再生位置と再生状態を保ったままプレイヤーを差し替える。
  /// - Parameter newAnalysis: カット割りを作った範囲の解析結果。曲の範囲を変えたときだけ渡す。
  private func recompose(_ newPlan: CutPlan, analysis newAnalysis: MusicAnalysis? = nil) {
    guard let musicURL else { return }
    let render = renderPreset.settings
    let look = lookTuning
    let audioStart = appliedSettings?.musicRange?.start ?? 0
    let urls = sourceURLs
    isApplyingEdit = true
    editTask?.cancel()
    editTask = Task { [weak self] in
      do {
        let result = try await MusicVideoComposer().makeComposition(
          plan: newPlan, sourceURLs: urls, audioURL: musicURL, render: render, look: look, audioStart: audioStart
        )
        guard let self, !Task.isCancelled else { return }
        let time = self.player.currentTime()
        let wasPlaying = self.player.timeControlStatus != .paused
        if let newAnalysis { self.analysis = newAnalysis }
        self.plan = newPlan
        self.planStats = MusicVideoPlanStats(plan: newPlan, pool: self.pool, analysis: self.analysis)
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

  /// 書き出して、利用者が選んだアルバムに追加する。追加先は呼び出しのたびに利用者が決める。
  /// 新しいアルバムは，書き出しが終わって追加する直前に作る(途中で中止しても空のアルバムが残らない)。
  func exportToLibrary(dataManager: LibraryViewModel, destination: MusicVideoExportDestination) {
    guard let musicTitle else { return }
    let fileName = Self.outputFileName(musicTitle: musicTitle)
    export { url in
      try await Self.addToLibrary(url, fileName: fileName, destination: destination, dataManager: dataManager)
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
    preview.stop()
    player.pause()
    phase = .exporting(progress: 0)
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("musicvideo-\(UUID().uuidString).mp4")
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

  /// 書き出した動画を追加先のアルバムへ入れ，完了メッセージを返す。
  private static func addToLibrary(
    _ url: URL,
    fileName: String,
    destination: MusicVideoExportDestination,
    dataManager: LibraryViewModel
  ) async throws -> String {
    let albumID: UUID
    var createdAlbum = false
    switch destination {
    case .existing(let id):
      guard dataManager.albums.contains(where: { $0.id == id }) else {
        throw MusicVideoComposerError.exportFailed("選んだアルバムが見つかりません．ライブラリで削除された可能性があります．")
      }
      albumID = id
    case .new(let name):
      switch MusicVideoExportAlbumName.validate(name, existingNames: dataManager.albums.map(\.name)) {
      case .failure(let problem):
        throw MusicVideoComposerError.exportFailed(problem.message)
      case .success(let validName):
        guard let id = dataManager.createAlbum(name: validName, type: .video) else {
          throw MusicVideoComposerError.exportFailed("アルバムを作成できませんでした．")
        }
        albumID = id
        createdAlbum = true
      }
    }

    let added = await dataManager.importMedia(from: url, to: albumID, customFilename: fileName)
    guard added else {
      // 追加に失敗したときは，このために作ったアルバムを残さない。
      if createdAlbum { dataManager.deleteAlbum(albumID: albumID) }
      throw MusicVideoComposerError.exportFailed("ライブラリへ追加できませんでした．")
    }
    let title = dataManager.albums.first { $0.id == albumID }?.displayTitle ?? "選んだ"
    return "「\(title)」アルバムに \(fileName) を追加しました．"
  }

  static func outputFileName(musicTitle: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    // ファイル名に使えない文字を取り除く。
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
    let safeTitle = musicTitle.components(separatedBy: invalid).joined(separator: "_")
    return "MusicVideo_\(safeTitle)_\(formatter.string(from: date)).mp4"
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

  // MARK: 再生の操作(小さなプレビューと全画面で共通)

  /// 完成映像の長さ(秒)。映像がまだ無ければ 0。
  var playbackDuration: Double { plan?.duration ?? 0 }

  /// いま再生している位置にあるカットの番号(1から)。
  var currentCutNumber: Int? {
    plan?.cutIndex(at: playbackTime).map { $0 + 1 }
  }

  /// 再生/一時停止。終わりまで再生していたら、先頭から再生し直す。曲の試聴が鳴っていれば止める。
  func togglePlayback() {
    guard plan != nil else { return }
    if player.timeControlStatus != .paused {
      player.pause()
      return
    }
    preview.stop()
    if playbackTime >= playbackDuration - 0.05 { seek(to: 0) }
    player.play()
  }

  /// 再生位置を `seconds` 秒だけ動かす(負なら戻る)。映像の範囲に収める。
  func skip(by seconds: Double) {
    guard plan != nil else { return }
    seek(to: min(max(0, playbackTime + seconds), max(0, playbackDuration - 0.05)))
  }

  /// `direction` が正なら次のカットの頭へ、負なら前へ移る。
  /// カットの途中(頭から1秒より後)で戻るときは、まずそのカットの頭へ戻る。
  func skipToCut(_ direction: Int) {
    guard let plan, !plan.cuts.isEmpty else { return }
    // 再生位置は1/600秒に丸められるので、カットの頭に移ったあとでも、頭よりごくわずかに手前になることがある。
    // 手前のカットと取り違えないよう、判定には少し余裕(20ms。最短のカットより十分短い)を持たせる。
    let current = plan.cutIndex(at: playbackTime + 0.02) ?? 0
    let start = plan.cuts[current].timelineStart
    let target: Int
    if direction > 0 {
      target = min(current + 1, plan.cuts.count - 1)
    } else if playbackTime - start > 1.0 {
      target = current
    } else {
      target = max(current - 1, 0)
    }
    seek(to: plan.cuts[target].timelineStart)
  }

  /// つまみを動かしている間の移動。コマ単位までは合わせず、軽く動かす(離したときに `seek(to:)` で合わせる)。
  func scrub(to seconds: Double) {
    guard plan != nil else { return }
    let target = min(max(0, seconds), max(0, playbackDuration - 0.05))
    let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
    player.seek(
      to: CMTime(seconds: target, preferredTimescale: 600),
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    )
  }

  /// 曲の試聴を始める/止める。映像のプレビューが鳴っていれば止める。
  /// いま選んでいる曲なら、解析した盛り上がりから聞く区間を決める。
  func togglePreview(_ url: URL) {
    pausePlayback()
    preview.toggle(url, analysis: url == musicURL ? analysis : nil)
  }

  /// 画面を離れるときなど、映像のプレビューも曲の試聴も止める。
  func stopAllPlayback() {
    player.pause()
    preview.stop()
  }

  func cancelWork() {
    workTask?.cancel()
    workTask = nil
    if isWorking { phase = composed == nil ? .idle : .ready }
    estimatedRemaining = nil
  }

  private func clearResult() {
    editTask?.cancel()
    tuningTask?.cancel()
    pendingEffect = nil
    pendingTitle = nil
    planStats = nil
    lastChangeNote = nil
    appliedSettings = nil
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
