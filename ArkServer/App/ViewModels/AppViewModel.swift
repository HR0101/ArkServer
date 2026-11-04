import Combine
import Foundation

/// アプリ全体で共有する機能別ViewModelを生成し，画面遷移を管理します．
///
/// 各機能のViewModelはこの型が所有し，View側で直接生成しません．
/// 子ViewModelは必要なViewが個別に監視し，ルート画面への一括通知は行いません．
@MainActor
final class AppViewModel: ObservableObject {
  @Published var selection: NavigationSelection? = .home
  @Published var isShowingStorageManager = false
  @Published var isShowingAccessLog = false
  @Published var sceneExtractionNavigationError: String?
  @Published private(set) var isServerRunning = false
  @Published private(set) var currentServerURL: String?

  let dataManager: LibraryViewModel
  /// 差分動画の探索結果。再生でライブラリ画面ごと差し替わっても、
  /// 見つけたグループと選んだ組み合わせを持ち越せるようここが持つ。
  let variantFinder = VariantVideoViewModel()
  let webServerManager: ServerViewModel
  let playbackCoordinator: PlaybackCoordinator
  let remotePlaybackSession: RemotePlaybackSession
  let appSettings: AppSettings
  /// 視聴位置と再生履歴。実体はサーバーの WebSyncStore なので
  /// ブラウザ UI・iPhone・Android と同じ記録を共有する。
  let watchState: WatchStateStore
  /// 自動再生・リピート・シャッフル・再生速度（端末ごとの好みなので同期しない）。
  let playbackSettings = PlaybackSettings()
  /// シーン抽出画面の再生位置，解析結果，GTラベルを画面切替後も保持します．
  let sceneExtraction = SceneExtractionViewModel()
  /// ミュージックビデオ作成の曲・素材・プレビューを画面切替後も保持します．
  let musicVideo = MusicVideoViewModel()

  private var cancellables = Set<AnyCancellable>()
  private var sceneExtractionReturnSelection: NavigationSelection = .home
  private var settingsRouting = SettingsRouting()

  convenience init() {
    self.init(
      dataManager: LibraryViewModel(),
      playbackCoordinator: PlaybackCoordinator(),
      appSettings: AppSettings()
    )
  }

  init(
    dataManager: LibraryViewModel,
    playbackCoordinator: PlaybackCoordinator,
    appSettings: AppSettings
  ) {
    self.dataManager = dataManager
    self.playbackCoordinator = playbackCoordinator
    let remotePlaybackSession = RemotePlaybackSession(
      playbackCoordinator: playbackCoordinator
    )
    self.remotePlaybackSession = remotePlaybackSession
    // watchState が同じ syncStore を握るため、先にローカル変数で受けてから self へ入れる。
    let webServerManager = ServerViewModel(
      dataManager: dataManager,
      remotePlaybackSession: remotePlaybackSession
    )
    self.webServerManager = webServerManager
    self.appSettings = appSettings
    self.watchState = WatchStateStore(store: webServerManager.syncStore)

    webServerManager.$serverStartTime
      .map { $0 != nil }
      .removeDuplicates()
      .assign(to: &$isServerRunning)

    webServerManager.$serverURL
      .removeDuplicates()
      .assign(to: &$currentServerURL)

    bridgeFavorites()
  }

  // MARK: - 詳細設定ページ

  /// 詳細設定のページを開きます．元の画面は覚えておき，`closeSettings()` で戻します．
  func openSettings(_ pane: SettingsPane = .connection) {
    selection = settingsRouting.opening(from: selection, pane: pane)
  }

  /// 詳細設定を閉じて，開く前の画面へ戻します．
  func closeSettings() {
    selection = settingsRouting.closing()
  }

  /// レールの歯車用．設定中なら戻り，そうでなければ開きます．
  func toggleSettings() {
    if SettingsRouting.isSettings(selection) { closeSettings() } else { openSettings() }
  }

  /// ライブラリ内の動画を解析画面へ渡します．
  func openSceneExtraction(for item: VideoItem) {
    guard item.mediaType == .video else {
      sceneExtractionNavigationError = "画像はシーン抽出できません．動画を1本選択してください．"
      return
    }
    guard !item.isInTrash else {
      sceneExtractionNavigationError = "ゴミ箱内の動画は解析できません．先に元へ戻してください．"
      return
    }
    guard let url = dataManager.fileURL(for: item) else {
      sceneExtractionNavigationError = "動画の実ファイルが見つかりません．リンク元や保存先を確認してください．"
      return
    }

    if selection != .sceneExtraction {
      sceneExtractionReturnSelection = selection ?? .home
    }
    selection = .sceneExtraction
    Task {
      await sceneExtraction.loadVideo(from: url)
    }
  }

  /// 解析結果を保持したまま，元のライブラリ画面へ戻します．
  func closeSceneExtraction() {
    sceneExtraction.pause()
    selection = sceneExtractionReturnSelection
  }

  /// お気に入りの保管場所を1つに束ねる。
  ///
  /// Mac 本体は `library.json` の `VideoItem.isFavorite`、ブラウザ / iOS / Android は
  /// `websync.json` の `favorites` と、これまで別々の場所に持っていた。
  /// そのため iPhone で付けたお気に入りが Mac に出ず、逆も出なかった。
  /// ここで双方向に橋渡しして、どこで付けても全部に出るようにする。
  private func bridgeFavorites() {
    // Mac 側の付け外しを保管庫へ送る。
    dataManager.favoriteChangeHandler = { [weak self] ids, isFavorite in
      self?.watchState.setFavorite(videoIDs: ids, isFavorite: isFavorite)
    }

    // ライブラリを読み終えた時点で1回だけ突き合わせる。
    dataManager.$videos
      .filter { !$0.isEmpty }
      .first()
      .sink { [weak self] videos in
        // videos の通知を受けている最中に videos を書き換えると入れ子の送信になる。
        // 次のループへ送って、素直な一方通行にしておく。
        Task { @MainActor [weak self] in
          guard let self else { return }
          // まず、保管庫がまだ知らない Mac のお気に入りを送る。
          // これをやらないと、次の取り込みで「保管庫にない＝欠損」のまま取り残される。
          let unshared = videos
            .filter { $0.isFavorite && !$0.isInTrash && self.watchState.favorites[$0.id] == nil }
            .map(\.id)
          if !unshared.isEmpty {
            self.watchState.setFavorite(videoIDs: unshared, isFavorite: true)
          }
          // 保管庫が知っている分は保管庫を正とする（あちらだけが変更時刻を持っているため）。
          self.dataManager.applyFavoriteMarks(self.watchState.favorites)
        }
      }
      .store(in: &cancellables)

    // 以後、他の端末が /sync を書いたら Mac の一覧も追従する。
    // Mac 自身の変更でもここへ流れてくるが、その時は差分が無いので何も起きない。
    watchState.$favorites
      .dropFirst()
      .sink { [weak self] marks in
        self?.dataManager.applyFavoriteMarks(marks)
      }
      .store(in: &cancellables)
  }
}
