// ArkServer/Features/MusicVideo/Views/MusicVideoView.swift

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// 曲を選ぶと、ライブラリの動画から曲に合わせた映像を自動で作る画面。
///
/// プレビューと操作パネルを並べ，作成に必要な入力と細かな調整を分ける。
/// 狭い窓では上下に積み，実行ボタンは下に固定して常に見せる。
struct MusicVideoView: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  @ObservedObject var dataManager: LibraryViewModel

  @State private var isDropTargeted = false
  @State private var isShowingSourcePicker = false
  /// 素材・曲を選ぶ画面から戻ったとき、スクロールして見せる欄(`sourceAnchor` か `musicAnchor`)。
  @State private var returnAnchor: String?
  @State private var isShowingMusicPicker = false
  @State private var isShowingExportAlbumPicker = false
  @State private var inspectorPane: MusicVideoInspectorPane = .inputs
  /// プレビューを全画面で開く。
  @State private var fullScreen = MusicVideoFullScreenPresenter()
  /// プレビューの高さが、窓の高さに占める割合。境目をドラッグして変える。次回も保つ。
  @AppStorage("musicVideo.previewHeightRatio") private var previewHeightRatio = 0.55
  @State private var dragStartRatio: Double?

  private static let topAnchor = "musicvideo.top"
  private static let sourceAnchor = "musicvideo.source"
  private static let musicAnchor = "musicvideo.music"

  /// プレビューを上に固定できる窓の高さ。これより低いときは、プレビューも一緒にスクロールする。
  private static let pinnedPreviewMinimumHeight: CGFloat = 640
  private static let previewHeightRatioRange: ClosedRange<Double> = 0.3...0.75
  /// 固定した領域のうち、プレビューの中身以外(余白・見出し・境目)の高さ。
  private static let pinnedPreviewChrome: CGFloat = 14 + 8 + 28 + 10
  /// 横長のプレビューで、動画の下に並べるタイムラインと結果の高さ。
  private static let stackedPreviewExtras: CGFloat = 150
  /// プレビューをスクロールの中に置くとき(窓が低いとき)の中身の高さ。
  private static let inlinePreviewContentHeight: CGFloat = 480
  private static let workspaceMinimumWidth: CGFloat = 1_040
  private static let inspectorWidth: CGFloat = 400
  private static let workspaceMaximumWidth: CGFloat = 1_440

  var body: some View {
    Group {
      if isShowingSourcePicker {
        // 素材を選ぶあいだは、画面全体を使う(ポップアップにしない)。
        MusicVideoSourcePickerView(viewModel: viewModel, dataManager: dataManager) {
          isShowingSourcePicker = false
        }
      } else if isShowingMusicPicker {
        // 曲を選ぶあいだも、画面全体を使う。
        MusicVideoMusicPickerView(viewModel: viewModel) {
          isShowingMusicPicker = false
        }
      } else {
        mainContent
      }
    }
    .background(CommandDeckBackground())
    .navigationTitle("ミュージックビデオ")
    // 設定画面と同じく、スイッチなどの「入」の色は青にする（内容側の既定は文字色の中立色）。
    .tint(NeomorphicTheme.accent)
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
          .strokeBorder(NeomorphicTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
          .padding(8)
          .allowsHitTesting(false)
      }
    }
    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleMusicDrop)
    .onAppear { viewModel.attach(dataManager: dataManager) }
    .onDisappear { viewModel.stopAllPlayback() }
    .sheet(isPresented: $isShowingExportAlbumPicker) {
      MusicVideoExportAlbumSheet(dataManager: dataManager, fileName: viewModel.suggestedFileName) { destination in
        viewModel.exportToLibrary(dataManager: dataManager, destination: destination)
      }
    }
    .alert(
      "処理に失敗しました",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("OK", role: .cancel) { viewModel.clearError() }
    } message: {
      Text(viewModel.errorMessage ?? "不明なエラーです．")
    }
    .alert(
      "書き出しが完了しました",
      isPresented: Binding(
        get: { viewModel.resultMessage != nil },
        set: { if !$0 { viewModel.clearResultMessage() } }
      )
    ) {
      Button("OK", role: .cancel) { viewModel.clearResultMessage() }
    } message: {
      Text(viewModel.resultMessage ?? "")
    }
  }

  /// ミュージックビデオの本体(プレビュー・曲・素材・調整項目)。
  private var mainContent: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        workspaceHeader
        Divider().overlay(NeomorphicTheme.separator)

        if geometry.size.width >= Self.workspaceMinimumWidth {
          HStack(alignment: .top, spacing: 0) {
            ScrollView {
              VStack(alignment: .leading, spacing: 20) {
                if viewModel.plan != nil {
                  previewSection(contentHeight: max(320, geometry.size.height - 240), showsCaption: true)
                  cutEditor
                } else {
                  previewPlaceholder
                    .frame(minHeight: max(360, geometry.size.height - 240))
                }
              }
              .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(NeomorphicTheme.separator)
            inspector(includesPreview: false)
              .frame(width: Self.inspectorWidth)
          }
          .frame(maxWidth: Self.workspaceMaximumWidth)
          .frame(maxWidth: .infinity)
        } else {
          compactWorkspace(height: max(0, geometry.size.height - 140))
        }

        actionBar
      }
    }
  }

  private var workspaceHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("ミュージックビデオ")
          .font(.appTitle)
          .foregroundStyle(NeomorphicTheme.ink)
        Text("曲と素材を選んで，映像をつくる")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 4) {
        Text(viewModel.renderPreset.displayName)
          .font(.appCaptionStrong)
        if let duration = viewModel.targetDuration {
          Text(formatTime(duration))
            .font(.appMonoCaption)
        }
      }
      .foregroundStyle(NeomorphicTheme.muted)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  /// 高さのある窓ではプレビューを固定し，境目のドラッグによるサイズ変更も残す。
  private func compactWorkspace(height: CGFloat) -> some View {
    let pinsPreview = viewModel.plan != nil && height >= Self.pinnedPreviewMinimumHeight
    let pinnedHeight = pinnedRegionHeight(windowHeight: height)
    return VStack(spacing: 0) {
      if pinsPreview {
        VStack(spacing: 0) {
          previewSection(contentHeight: pinnedHeight - Self.pinnedPreviewChrome, showsCaption: false)
            .frame(maxWidth: settingsColumnWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(height: pinnedHeight - 10, alignment: .top)
            .clipped()
          previewResizeHandle(windowHeight: height)
        }
      }
      inspector(includesPreview: !pinsPreview, showsCutEditor: true)
    }
  }

  private func inspector(includesPreview: Bool, showsCutEditor: Bool = false) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        ForEach(MusicVideoInspectorPane.allCases) { pane in
          MusicVideoChoiceButton(title: pane.rawValue, isSelected: inspectorPane == pane) {
            inspectorPane = pane
          }
          .accessibilityIdentifier("musicvideo.pane.\(pane.id)")
        }
      }
      .frame(maxWidth: settingsColumnWidth)
      .padding(16)

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            if includesPreview, viewModel.plan != nil {
              previewSection(contentHeight: Self.inlinePreviewContentHeight, showsCaption: true)
                .id(Self.topAnchor)
            }
            if viewModel.plan != nil, showsCutEditor {
              cutEditor
            }
            if inspectorPane == .inputs {
              musicSection.id(Self.musicAnchor)
              sourceSection.id(Self.sourceAnchor)
            } else {
              MusicVideoTuningSections(viewModel: viewModel, pane: inspectorPane)
            }
          }
          .frame(maxWidth: settingsColumnWidth)
          .frame(maxWidth: .infinity, alignment: .top)
          .padding(20)
          .padding(.bottom, 12)
        }
        .id(inspectorPane)
        .onAppear {
          guard let anchor = returnAnchor else { return }
          returnAnchor = nil
          proxy.scrollTo(anchor, anchor: .top)
        }
        .onChange(of: viewModel.plan != nil) { _, hasPlan in
          if hasPlan, includesPreview {
            proxy.scrollTo(Self.topAnchor, anchor: .top)
          }
        }
      }
    }
  }

  private var cutEditor: some View {
    MusicVideoFoldout(
      title: "カットの編集",
      summary: viewModel.selectedCutIndex.map { "カット \($0 + 1)" } ?? "差し替え・履歴",
      selectedCutIndex: viewModel.selectedCutIndex
    ) {
      MusicVideoCutEditorView(viewModel: viewModel, dataManager: dataManager)
    }
  }

  private var previewPlaceholder: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 24)
      Image(systemName: "play.rectangle")
        .font(.system(size: 48, weight: .ultraLight))
        .foregroundStyle(NeomorphicTheme.muted)
        .accessibilityHidden(true)
      VStack(spacing: 8) {
        Text("ここで仕上がりを確認")
          .font(.appHeadline)
          .foregroundStyle(NeomorphicTheme.ink)
        Text("曲と素材を選んで「映像を作る」を押してください")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .multilineTextAlignment(.center)
      }
      Spacer(minLength: 24)
      HStack(spacing: 16) {
        Label(viewModel.musicTitle ?? "曲を選択", systemImage: viewModel.musicURL == nil ? "circle" : "checkmark.circle")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        Text("素材 \(viewModel.candidateCount.formatted())本")
          .monospacedDigit()
          .fixedSize()
      }
      .font(.appCaption)
      .foregroundStyle(NeomorphicTheme.muted)
    }
    .padding(24)
    .frame(maxWidth: .infinity)
    .background(GlassCardSurface())
  }

  // MARK: - プレビュー

  /// 固定するプレビュー領域の高さ。窓の高さに対する割合で決め、設定の欄が少なくとも300ptは残るようにする。
  private func pinnedRegionHeight(windowHeight: CGFloat) -> CGFloat {
    let wanted = windowHeight * previewHeightRatio
    return min(max(wanted, 260), max(260, windowHeight - 300))
  }

  /// プレビューと設定の境目。ドラッグでプレビューの大きさを変える。
  private func previewResizeHandle(windowHeight: CGFloat) -> some View {
    ZStack {
      Divider().overlay(NeomorphicTheme.separator)
      Capsule()
        .fill(NeomorphicTheme.muted.opacity(0.55))
        .frame(width: 36, height: 4)
    }
    .frame(height: 10)
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { value in
          let start = dragStartRatio ?? previewHeightRatio
          dragStartRatio = start
          let moved = start + Double(value.translation.height / max(windowHeight, 1))
          previewHeightRatio = min(max(moved, Self.previewHeightRatioRange.lowerBound), Self.previewHeightRatioRange.upperBound)
        }
        .onEnded { _ in dragStartRatio = nil }
    )
    .help("ドラッグして、プレビューの大きさを変えます")
    .accessibilityLabel("プレビューの大きさ")
  }

  /// - Parameters:
  ///   - contentHeight: 見出しを除いた、プレビュー部分に使える高さ。
  ///   - showsCaption: タイムラインの下に、見方の説明を出すか。
  private func previewSection(contentHeight: CGFloat, showsCaption: Bool) -> some View {
    SettingsSection(title: "プレビュー") {
      if previewAspectRatio < 1.2 {
        // 縦長・正方形の画面: 動画を高く取り、タイムラインと結果は右に置く(横幅が余るので)。
        let width = min(max(160, contentHeight) * previewAspectRatio, 440)
        HStack(alignment: .top, spacing: 20) {
          Color.clear
            .overlay { previewPlayer }
            .background(previewPlayerBackground)
            .clipShape(previewPlayerShape)
            .frame(width: width, height: width / previewAspectRatio)
          VStack(alignment: .leading, spacing: 12) {
            timelineBlock(showsCaption: true)
            MusicVideoResultSummary(viewModel: viewModel)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      } else {
        // 横長の画面: 動画の下に、タイムラインと結果を並べる。
        VStack(spacing: 12) {
          // 縦横比を保った枠（背景・角丸は枠そのものに付け、外側の frame で最大の高さだけ制限する）。
          Color.clear
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            .overlay { previewPlayer }
            .background(previewPlayerBackground)
            .clipShape(previewPlayerShape)
            .frame(maxWidth: .infinity, maxHeight: max(140, contentHeight - Self.stackedPreviewExtras))
          timelineBlock(showsCaption: showsCaption)
          MusicVideoResultSummary(viewModel: viewModel)
        }
      }
    }
  }

  /// 映像と、再生の操作(再生・スキップ・シーク・ミュート・全画面)。
  private var previewPlayer: some View {
    MusicVideoPlayerPane(viewModel: viewModel) {
      fullScreen.present(viewModel: viewModel)
    }
  }

  private var previewPlayerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
  }

  private var previewPlayerBackground: some View {
    previewPlayerShape.fill(NeomorphicTheme.card)
  }

  @ViewBuilder
  private func timelineBlock(showsCaption: Bool) -> some View {
    if let analysis = viewModel.analysis {
      VStack(alignment: .leading, spacing: 6) {
        MusicTimelineView(
          analysis: analysis,
          plan: viewModel.plan,
          playbackTime: viewModel.playbackTime,
          selectedCutIndex: viewModel.selectedCutIndex,
          onSeek: viewModel.seek(to:),
          onSelect: viewModel.selectCut(at:)
        )
        if showsCaption {
          Text("濃い背景ほど盛り上がる部分です．上の短い線がカットの切り替え，下の短い線が拍です．")
            .font(.appCaption)
            .foregroundStyle(NeomorphicTheme.muted)
        }
      }
    }
  }

  private var previewAspectRatio: CGFloat {
    let size = viewModel.renderPreset.settings.size
    return size.width / size.height
  }

  // MARK: - 曲

  private var musicSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      MusicVideoField(title: "使う曲", detail: musicDetail) {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 12) {
            Image(systemName: "music.note")
              .font(.system(size: 20, weight: .light))
              .foregroundStyle(NeomorphicTheme.muted)
              .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
              Text(viewModel.musicTitle ?? "曲を選んでください")
                .font(.appBodyStrong)
                .foregroundStyle(NeomorphicTheme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
              if let analysis = viewModel.fullAnalysis {
                Text("\(formatTime(analysis.duration)) · \(Int(analysis.tempo.rounded())) BPM · 拍 \(analysis.beats.count)個")
                  .font(.appMicro.monospacedDigit())
                  .foregroundStyle(NeomorphicTheme.muted)
              }
            }
            Spacer(minLength: 0)
            if viewModel.phase == .analyzingMusic { ProgressView().controlSize(.small) }
            if let url = viewModel.musicURL {
              MusicPreviewButton(preview: viewModel.preview, url: url) { viewModel.togglePreview(url) }
            }
          }
          HStack(spacing: 8) {
            Button("フォルダから…") {
              returnAnchor = Self.musicAnchor
              isShowingMusicPicker = true
            }
              .buttonStyle(.quiet)
              .help("曲を置いてあるフォルダから探して選びます")
              .accessibilityIdentifier("musicvideo.musicFolder")
            Button("ファイル…") { chooseMusicFile() }
              .buttonStyle(.quiet)
              .help("曲のファイルを1つ選びます")
              .accessibilityIdentifier("musicvideo.musicFile")
            if !viewModel.recentMusicURLs.isEmpty { recentMenu }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardSurface())
        .disabled(viewModel.isWorking)
      }

      if viewModel.musicURL == nil, let last = viewModel.lastMusicURL {
        MusicVideoField(title: "前回の曲", detail: last.deletingPathExtension().lastPathComponent) {
          HStack(spacing: 8) {
            MusicPreviewButton(preview: viewModel.preview, url: last) { viewModel.togglePreview(last) }
            Button("開く") { viewModel.chooseMusic(last) }
              .buttonStyle(.quiet)
              .disabled(viewModel.isWorking)
              .accessibilityIdentifier("musicvideo.openLastMusic")
          }
        }
      }
      if viewModel.fullAnalysis != nil {
        MusicVideoFoldout(title: "曲の使う範囲", summary: viewModel.musicRange == nil ? "曲全体" : (viewModel.targetDuration.map(formatTime) ?? "")) {
          MusicRangeControl(viewModel: viewModel)
        }
      }
    }
  }

  private var musicDetail: String {
    if viewModel.musicURL == nil { return "mp3 などの曲を選ぶか，この画面へドロップしてください．" }
    return viewModel.phase == .analyzingMusic ? "拍と盛り上がりを解析しています…" : "この曲に合わせて映像を作ります．"
  }

  private var recentMenu: some View {
    Menu {
      ForEach(viewModel.recentMusicURLs, id: \.self) { url in
        Button(url.deletingPathExtension().lastPathComponent) { viewModel.chooseMusic(url) }
      }
    } label: {
      Text("最近")
    }
    .menuStyle(.button)
    .buttonStyle(.quiet)
    .menuIndicator(.visible)
    .fixedSize()
  }

  private func chooseMusicFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    panel.prompt = "選択"
    if let folder = viewModel.musicFolderURL { panel.directoryURL = folder }
    if panel.runModal() == .OK, let url = panel.url {
      viewModel.chooseMusic(url)
    }
  }

  private func handleMusicDrop(_ providers: [NSItemProvider]) -> Bool {
    guard !viewModel.isWorking,
          let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
      return false
    }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
      guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else { return }
      Task { @MainActor in viewModel.chooseMusic(url) }
    }
    return true
  }

  // MARK: - 素材

  private var selectedAlbums: [Album] {
    dataManager.albums
      .filter { viewModel.selectedAlbumIDs.contains($0.id) }
      .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      MusicVideoField(title: "素材の動画") {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(viewModel.candidateCount.formatted())
              .font(.system(size: 32, weight: .medium, design: .monospaced))
              .foregroundStyle(NeomorphicTheme.ink)
            Text("本の動画")
              .font(.appCaption)
              .foregroundStyle(NeomorphicTheme.muted)
            Spacer(minLength: 0)
            Button("選ぶ…") {
              returnAnchor = Self.sourceAnchor
              isShowingSourcePicker = true
            }
            .buttonStyle(.quiet)
            .accessibilityIdentifier("musicvideo.chooseSource")
          }
          Text(sourceDetail ?? "アルバムや動画を選んでください")
            .font(.appCaption)
            .foregroundStyle(NeomorphicTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Toggle("お気に入りを含める", isOn: $viewModel.includeFavorites)
              .toggleStyle(MusicVideoCheckStyle())
            Spacer(minLength: 0)
            if !(viewModel.selectedAlbumIDs.isEmpty && viewModel.selectedVideoIDs.isEmpty) {
              Button("解除") { viewModel.clearSourceSelection() }
                .buttonStyle(.quiet)
                .help("アルバムと動画の選択をすべて外します")
            }
          }
        }
        .padding(16)
        .background(GlassCardSurface())
        .disabled(viewModel.isWorking)
      }
      MusicVideoFoldout(title: "素材の解析本数", summary: "最大\(viewModel.sourceLimit)本") {
        MusicVideoField(title: "解析に使う動画の本数", detail: sourceLimitDetail) {
          MusicVideoChoices(options: MusicVideoSourceLimit.choices, title: { "\($0)本" }, selection: $viewModel.sourceLimit)
            .accessibilityIdentifier("musicvideo.sourceLimit")
        }
        .disabled(viewModel.isWorking)
      }
    }
  }

  /// 選んだ動画が多いときの、解析する本数の説明。変えたあとは「作り直す」で反映する。
  private var sourceLimitDetail: String {
    let candidates = viewModel.candidateCount
    let limit = viewModel.sourceLimit
    var text: String
    if candidates == 0 {
      text = "選んだ動画が多いときは、この本数を無作為に選んで解析します．"
    } else if candidates <= limit {
      text = "選んだ\(candidates.formatted())本をすべて使います．"
    } else {
      text = "選んだ\(candidates.formatted())本のうち、無作為に\(limit)本を使います．多いほど変化に富みますが、初回の解析に時間がかかります（解析済みの動画は次回から速くなります）．"
    }
    if viewModel.sourceLimitNeedsRebuild {
      text += "\n「作り直す」を押すと、この本数で作り直します．"
    }
    return text
  }

  /// 選んだアルバム・動画の内訳(例: 「fontene・acid39 ほかアルバム2個・個別の動画 3本」)。
  private var sourceDetail: String? {
    let albums = selectedAlbums
    var parts: [String] = []
    if !albums.isEmpty {
      let names = albums.prefix(3).map(\.displayTitle).joined(separator: "・")
      parts.append(albums.count > 3 ? "\(names) ほかアルバム\(albums.count - 3)個" : names)
    }
    if !viewModel.selectedVideoIDs.isEmpty { parts.append("個別の動画 \(viewModel.selectedVideoIDs.count)本") }
    let text = parts.joined(separator: "・")
    return text.isEmpty ? "アルバムや動画を選んでください．" : text
  }

  // MARK: - 下に固定する実行の帯

  private var actionBar: some View {
    VStack(spacing: 0) {
      Divider().overlay(NeomorphicTheme.separator)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 24) {
          statusView
            .frame(maxWidth: .infinity, alignment: .leading)
          actionButtons
        }
        VStack(alignment: .leading, spacing: 12) {
          statusView
          HStack {
            Spacer(minLength: 0)
            actionButtons
          }
        }
      }
      .frame(maxWidth: Self.workspaceMaximumWidth)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
    }
    .background(NeomorphicTheme.canvas)
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
        if viewModel.isWorking {
          Button("中止") { viewModel.cancelWork() }
            .buttonStyle(MusicVideoActionStyle())
            .accessibilityIdentifier("musicvideo.cancel")
        } else {
          if viewModel.plan != nil {
            Button("ファイルに保存…") { saveToFile() }
              .buttonStyle(MusicVideoActionStyle())
              .disabled(!viewModel.canExport)
              .accessibilityIdentifier("musicvideo.saveFile")
            Button("ライブラリに追加…") { isShowingExportAlbumPicker = true }
              .buttonStyle(MusicVideoActionStyle())
              .disabled(!viewModel.canExport)
              .help("追加するアルバムを選んで，書き出してライブラリに追加します")
              .accessibilityIdentifier("musicvideo.exportLibrary")
          }
          Button(viewModel.plan == nil ? "映像を作る" : "作り直す") {
            viewModel.generate(dataManager: dataManager)
          }
          .buttonStyle(MusicVideoActionStyle(isPrimary: true))
          .disabled(!viewModel.canGenerate)
          .help(viewModel.plan == nil ? "曲に合わせて映像を作ります" : "別のカット割りで作り直します")
          .accessibilityIdentifier("musicvideo.generate")
        }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private var statusView: some View {
    switch viewModel.phase {
    case .idle:
      if let blocker = viewModel.generateBlocker {
        statusText(blocker)
      } else if viewModel.plan == nil {
        statusText("「映像を作る」を押すと始まります．")
      }
    case .analyzingMusic:
      progressRow("曲を解析中…", value: nil)
    case .analyzingSources(let completed, let total):
      progressRow(
        "素材の動きを解析中 \(completed)/\(total)" + (remainingText.map { "・\($0)" } ?? ""),
        value: total > 0 ? Double(completed) / Double(total) : nil,
        note: completed < total && completed < 3 ? "初回は時間がかかります．結果は保存され，次回から速くなります．" : nil
      )
    case .composing:
      progressRow("カット割りを作って合成中…", value: nil)
    case .ready:
      if let plan = viewModel.plan {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(plan.cuts.count)カット・使った動画 \(viewModel.usedVideoCount)本")
            .font(.appCaption.weight(.medium))
            .foregroundStyle(NeomorphicTheme.ink)
          if viewModel.missingFileCount > 0 {
            Text("ファイルが見つからない動画 \(viewModel.missingFileCount)本は使っていません")
              .font(.appMicro)
              .foregroundStyle(NeomorphicTheme.muted)
          }
        }
      }
    case .exporting(let progress):
      progressRow("書き出し中 \(Int(progress * 100))％", value: progress)
    }
  }

  private func statusText(_ text: String) -> some View {
    Text(text)
      .font(.appCaption)
      .foregroundStyle(NeomorphicTheme.muted)
  }

  private var remainingText: String? {
    guard let remaining = viewModel.estimatedRemaining else { return nil }
    return remaining >= 90 ? "残り約\(Int((remaining / 60).rounded(.up)))分" : "残り約\(Int(remaining.rounded()))秒"
  }

  private func progressRow(_ text: String, value: Double?, note: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(text)
        .font(.appCaption)
        .foregroundStyle(NeomorphicTheme.muted)
        .lineLimit(1)
      if let value {
        ProgressView(value: value)
      } else {
        ProgressView().controlSize(.small)
      }
      if let note {
        Text(note)
          .font(.appMicro)
          .foregroundStyle(NeomorphicTheme.muted)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: 320, alignment: .leading)
  }

  private func saveToFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.nameFieldStringValue = viewModel.suggestedFileName
    panel.canCreateDirectories = true
    panel.prompt = "保存"
    if panel.runModal() == .OK, let url = panel.url {
      viewModel.exportToFile(at: url)
    }
  }

  private func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
