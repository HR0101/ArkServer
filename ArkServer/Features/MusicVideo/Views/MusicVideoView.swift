// ArkServer/Features/MusicVideo/Views/MusicVideoView.swift

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// 曲を選ぶと、ライブラリの動画から曲に合わせた映像を自動で作る画面。
///
/// 設定画面のように、中央の1列に「セクション名 + 行をまとめた面」を縦に並べる。
/// 結果ができたら、プレビューとカットの編集を一番上に出す。実行ボタンは下に固定して常に見せる。
struct MusicVideoView: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  @ObservedObject var dataManager: LibraryViewModel

  @State private var isDropTargeted = false
  @State private var isShowingSourcePicker = false
  @State private var isShowingMusicPicker = false

  private static let topAnchor = "musicvideo.top"

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            // 見出しは列の左端にそろえる（LibraryPageHeader は左右に24の余白を持つ）。
            LibraryPageHeader(
              title: "ミュージックビデオ",
              subtitle: "曲を選ぶと，ライブラリの動画を曲の盛り上がりに合わせて自動で編集します"
            )
            .padding(.horizontal, -24)
            .id(Self.topAnchor)

            if viewModel.plan != nil {
              previewSection
              MusicVideoCutEditorView(viewModel: viewModel, dataManager: dataManager)
            }
            musicSection
            sourceSection
            finishSection
          }
          .frame(maxWidth: musicVideoColumnWidth)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 24)
          .padding(.bottom, 28)
        }
        // 映像ができたら、一番上のプレビューが見えるようにする。
        .onChange(of: viewModel.plan != nil) { _, hasPlan in
          if hasPlan { withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) } }
        }
      }

      actionBar
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
    .onDisappear { viewModel.pausePlayback() }
    .sheet(isPresented: $isShowingSourcePicker) {
      MusicVideoSourcePickerSheet(viewModel: viewModel, dataManager: dataManager)
    }
    .sheet(isPresented: $isShowingMusicPicker) {
      MusicVideoMusicPickerSheet(viewModel: viewModel)
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

  // MARK: - プレビュー

  private var previewSection: some View {
    MVSection(title: "プレビュー") {
      VStack(spacing: 12) {
        // 縦横比を保った枠（背景・角丸は枠そのものに付け、外側の frame で最大の高さだけ制限する）。
        Color.clear
          .aspectRatio(previewAspectRatio, contentMode: .fit)
          .overlay { VideoPlayer(player: viewModel.player) }
          .background(
            RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous)
              .fill(NeomorphicTheme.card)
          )
          .clipShape(RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous))
          .frame(maxWidth: .infinity, maxHeight: 340)

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
            Text("濃い背景ほど盛り上がる部分です．上の短い線がカットの切り替え，下の短い線が拍です．")
              .font(.appCaption)
              .foregroundStyle(NeomorphicTheme.muted)
          }
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
    MVSection(title: "曲") {
      MVRowGroup {
        MVRow(title: viewModel.musicTitle ?? "曲を選んでください", detail: musicDetail) {
          HStack(spacing: 8) {
            if viewModel.phase == .analyzingMusic { ProgressView().controlSize(.small) }
            Button("フォルダから…") { isShowingMusicPicker = true }
              .buttonStyle(.mvSmall)
              .help("曲を置いてあるフォルダから探して選びます")
              .accessibilityIdentifier("musicvideo.musicFolder")
            Button("ファイル…") { chooseMusicFile() }
              .buttonStyle(.mvSmall)
              .help("曲のファイルを1つ選びます")
              .accessibilityIdentifier("musicvideo.musicFile")
            if !viewModel.recentMusicURLs.isEmpty { recentMenu }
          }
          .disabled(viewModel.isWorking)
        }
        if viewModel.musicURL == nil, let last = viewModel.lastMusicURL {
          MVRow(title: "前回の曲", detail: last.deletingPathExtension().lastPathComponent) {
            Button("開く") { viewModel.chooseMusic(last) }
              .buttonStyle(.mvSmall)
              .disabled(viewModel.isWorking)
              .accessibilityIdentifier("musicvideo.openLastMusic")
          }
        }
        if let analysis = viewModel.analysis {
          MVRow(title: "テンポと拍") {
            Text("\(formatTime(analysis.duration))・\(Int(analysis.tempo.rounded())) BPM・拍 \(analysis.beats.count)個")
              .font(.appBody.monospacedDigit())
              .foregroundStyle(NeomorphicTheme.muted)
          }
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
    .buttonStyle(.mvSmall)
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
    MVSection(title: "素材") {
      MVRowGroup {
        MVRow(
          title: viewModel.candidateCount == 0 ? "素材がまだ選ばれていません" : "使える動画 \(viewModel.candidateCount.formatted())本",
          detail: sourceDetail
        ) {
          HStack(spacing: 8) {
            if !(viewModel.selectedAlbumIDs.isEmpty && viewModel.selectedVideoIDs.isEmpty) {
              Button("解除") { viewModel.clearSourceSelection() }
                .buttonStyle(.mvSmall)
                .help("アルバムと動画の選択をすべて外します")
            }
            Button("選ぶ…") { isShowingSourcePicker = true }
              .buttonStyle(.mvSmall)
              .accessibilityIdentifier("musicvideo.chooseSource")
          }
          .disabled(viewModel.isWorking)
        }
        MVRow(title: "お気に入りを含める", detail: "お気に入りにした動画も素材に加えます．") {
          MVSwitch(title: "お気に入りを含める", isOn: $viewModel.includeFavorites)
            .disabled(viewModel.isWorking)
        }
      }
    }
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
    var text = parts.joined(separator: "・")
    let limit = ClipPoolBuilder().maxVideos
    if viewModel.candidateCount > limit {
      text += (text.isEmpty ? "" : "\n") + "解析は無作為に選んだ\(limit)本までです．"
    }
    return text.isEmpty ? "アルバムや動画を選んでください．" : text
  }

  // MARK: - 仕上がり

  private var finishSection: some View {
    MVSection(title: "仕上がり") {
      MVRowGroup {
        MVRow(title: "カットの細かさ", detail: "静かな所は長く，盛り上がる所は細かく切り替えます．") {
          FlatSegmentedControl(
            options: MusicVideoCutStyle.allCases,
            title: \.displayName,
            selection: $viewModel.cutStyle,
            width: 210
          )
        }
        MVRow(title: "画面サイズ") {
          Picker("画面サイズ", selection: $viewModel.renderPreset) {
            ForEach(MusicVideoRenderPreset.allCases, id: \.self) { preset in
              Text(preset.displayName).tag(preset)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        MVRow(title: "書き出しの画質", detail: exportSizeText) {
          Picker("書き出しの画質", selection: $viewModel.exportQuality) {
            ForEach(MusicVideoExportQuality.allCases, id: \.self) { quality in
              Text(quality.displayName).tag(quality)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      .disabled(viewModel.isWorking)
    }
  }

  /// 選んだ画質での、ファイルサイズの目安。曲の長さが分かっていれば、全体の大きさも出す。
  private var exportSizeText: String {
    let render = viewModel.renderPreset.settings
    let perMinute = viewModel.exportQuality.estimatedMegabytesPerMinute(for: render)
    var text = "1分あたり約\(Int(perMinute.rounded()))MB"
    if let duration = viewModel.analysis?.duration {
      text += "・この曲で約\(Int((perMinute * duration / 60).rounded()))MB"
    }
    return text
  }

  // MARK: - 下に固定する実行の帯

  private var actionBar: some View {
    VStack(spacing: 0) {
      Divider().overlay(NeomorphicTheme.separator)
      HStack(spacing: 12) {
        statusView
          .frame(maxWidth: .infinity, alignment: .leading)

        if viewModel.isWorking {
          Button("中止") { viewModel.cancelWork() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("musicvideo.cancel")
        } else {
          if viewModel.plan != nil {
            Button("ファイルに保存…") { saveToFile() }
              .buttonStyle(.bordered)
              .controlSize(.large)
              .disabled(!viewModel.canExport)
              .accessibilityIdentifier("musicvideo.saveFile")
            Button("「HMV」に追加") { viewModel.exportToLibrary(dataManager: dataManager) }
              .buttonStyle(.bordered)
              .controlSize(.large)
              .disabled(!viewModel.canExport)
              .help("書き出して「HMV」アルバムに追加します")
              .accessibilityIdentifier("musicvideo.exportLibrary")
          }
          Button(viewModel.plan == nil ? "映像を作る" : "作り直す") {
            viewModel.generate(dataManager: dataManager)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!viewModel.canGenerate)
          .help(viewModel.plan == nil ? "曲に合わせて映像を作ります" : "別のカット割りで作り直します")
          .accessibilityIdentifier("musicvideo.generate")
        }
      }
      .frame(maxWidth: musicVideoColumnWidth)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    }
    .background(NeomorphicTheme.canvas)
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
