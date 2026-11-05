// ArkServer/Features/MusicVideo/Views/MusicVideoMusicPickerView.swift

import AppKit
import SwiftUI

/// 曲を置いてあるフォルダから、曲を探して選ぶ画面。ポップアップではなく、ミュージックビデオの画面いっぱいに出す。
///
/// 左に、最近使った曲と、フォルダの階層(サブフォルダごとの曲数つき)。右に、曲の一覧。
/// 各行の再生ボタンで試聴でき、行を押すとその曲を使う。フォルダは一度選べば覚える。
struct MusicVideoMusicPickerView: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  /// 試聴の状態。画面の更新を受けるため、ViewModel の中のものをここでも監視する。
  @ObservedObject private var preview: MusicPreviewPlayer
  let close: () -> Void

  @State private var files: [MusicVideoMusicFile] = []
  @State private var folders: [MusicVideoMusicFolder] = []
  @State private var isLoading = false
  @State private var didHitLimit = false
  @State private var searchText = ""
  /// 右に出す曲の範囲(フォルダの相対の場所)。nil なら、すべて。
  @State private var scope: String?
  @State private var hoveredID: URL?
  @AppStorage("musicVideo.musicPicker.order") private var order: MusicVideoMusicOrder = .name

  private static let leftPaneWidth: CGFloat = 320
  private static let recentLimit = 8

  init(viewModel: MusicVideoViewModel, close: @escaping () -> Void) {
    self.viewModel = viewModel
    self.close = close
    _preview = ObservedObject(wrappedValue: viewModel.preview)
  }

  private var visibleFiles: [MusicVideoMusicFile] {
    MusicVideoMusicBrowser.visible(files, folder: scope, order: order, query: searchText)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(NeomorphicTheme.separator)
      HStack(spacing: 0) {
        leftPane
        Divider().overlay(NeomorphicTheme.separator)
        rightPane
      }
      Divider().overlay(NeomorphicTheme.separator)
      footer
    }
    .background(NeomorphicTheme.canvas)
    .foregroundStyle(NeomorphicTheme.ink)
    .task(id: viewModel.musicFolderURL) { await load() }
    // 画面を閉じたら、試聴の音も止める。
    .onDisappear { viewModel.preview.stop() }
  }

  // MARK: - 上の帯

  private var header: some View {
    HStack(spacing: 16) {
      Button(action: close) {
        Label("戻る", systemImage: "chevron.left")
      }
      .buttonStyle(.quiet)
      .keyboardShortcut(.cancelAction)
      .help("ミュージックビデオの画面へ戻ります（Esc）")
      .accessibilityIdentifier("musicvideo.musicBack")

      VStack(alignment: .leading, spacing: 2) {
        Text("曲を選ぶ")
          .font(.appTitle)
        Text(viewModel.musicFolderURL?.path ?? "曲を置いてあるフォルダを選んでください")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 12)
      Button("フォルダを選ぶ…", action: chooseFolder)
        .buttonStyle(.quiet)
        .accessibilityIdentifier("musicvideo.musicChooseFolder")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  // MARK: - 左: 最近使った曲・フォルダ

  private var leftPane: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        let recent = Array(viewModel.recentMusicURLs.prefix(Self.recentLimit))
        if !recent.isEmpty {
          sectionTitle("最近使った曲")
          ForEach(recent, id: \.self) { recentRow($0) }
        }
        if viewModel.musicFolderURL != nil, !isLoading {
          sectionTitle("フォルダ")
          folderRow(path: nil, name: "すべての曲", count: files.count, depth: 0)
          ForEach(folders) { folder in
            folderRow(path: folder.path, name: folder.name, count: folder.count, depth: folder.depth)
          }
        }
      }
      .padding(8)
    }
    .frame(width: Self.leftPaneWidth)
    .background(NeomorphicTheme.sidebar)
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text)
      .font(.appCaptionStrong)
      .foregroundStyle(NeomorphicTheme.muted)
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 4)
      .accessibilityAddTraits(.isHeader)
  }

  /// 最近使った曲: 左の再生ボタンで試聴、行を押すとその曲を使う。
  private func recentRow(_ url: URL) -> some View {
    HStack(spacing: 10) {
      MusicPreviewButton(preview: preview, url: url) { viewModel.togglePreview(url) }
      Button {
        choose(url)
      } label: {
        HStack(spacing: 6) {
          Text(url.deletingPathExtension().lastPathComponent)
            .font(.appBody)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 4)
          if isCurrent(url) {
            Image(systemName: "checkmark")
              .font(.appMicro)
              .foregroundStyle(NeomorphicTheme.muted)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("この曲に合わせて映像を作る")
      .accessibilityLabel("\(url.deletingPathExtension().lastPathComponent)を使う")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
  }

  private func folderRow(path: String?, name: String, count: Int, depth: Int) -> some View {
    let isScope = scope == path
    return Button {
      scope = path
    } label: {
      HStack(spacing: 8) {
        Image(systemName: path == nil ? "music.note.list" : "folder")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .frame(width: 18)
        Text(name)
          .font(path == nil ? .appBodyStrong : .appBody)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Text(count.formatted())
          .font(.appCaption.monospacedDigit())
          .foregroundStyle(NeomorphicTheme.muted)
      }
      .padding(.leading, 10 + CGFloat(depth) * 14)
      .padding(.trailing, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isScope ? NeomorphicTheme.selection : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name) \(count)曲")
    .accessibilityAddTraits(isScope ? .isSelected : [])
  }

  // MARK: - 右: 曲の一覧

  private var scopeTitle: String {
    guard let scope, !scope.isEmpty else { return "すべての曲" }
    return scope.replacingOccurrences(of: "/", with: " / ")
  }

  private var rightPane: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(scopeTitle)
            .font(.appHeadline)
            .lineLimit(1)
            .truncationMode(.head)
          if viewModel.musicFolderURL != nil, !isLoading {
            Text("\(visibleFiles.count.formatted())曲")
              .font(.appCaption.monospacedDigit())
              .foregroundStyle(NeomorphicTheme.muted)
          }
          Spacer(minLength: 8)
        }
        HStack(spacing: 12) {
          TextField("曲名で検索", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160)
          AppChoicePicker("並べ替え", selection: $order) {
            ForEach(MusicVideoMusicOrder.allCases) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        .font(.appCaption)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)

      Divider().overlay(NeomorphicTheme.separator)

      content
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.musicFolderURL == nil {
      VStack(spacing: 14) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 34, weight: .light))
        Text("曲を置いてあるフォルダを選んでください")
          .font(.appBody)
        Button("フォルダを選ぶ…", action: chooseFolder)
          .buttonStyle(AppActionButtonStyle(isPrimary: true))
      }
      .foregroundStyle(NeomorphicTheme.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if isLoading {
      VStack(spacing: 10) {
        ProgressView()
        Text("曲を探しています…").font(.appBody).foregroundStyle(NeomorphicTheme.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if visibleFiles.isEmpty {
      placeholder(icon: "music.note", message: files.isEmpty ? "このフォルダに曲が見つかりませんでした" : "条件に合う曲がありません")
    } else {
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(visibleFiles) { songRow($0) }
        }
        .padding(10)
      }
    }
  }

  /// いま選んでいる曲か。`/var` と `/private/var` のように、同じファイルでも URL の形が違うことがあるので、
  /// 標準化したパスで比べる。
  private func isCurrent(_ url: URL) -> Bool {
    guard let current = viewModel.musicURL else { return false }
    return current.standardizedFileURL.path == url.standardizedFileURL.path
  }

  private func songRow(_ file: MusicVideoMusicFile) -> some View {
    let isCurrent = isCurrent(file.url)
    let isHovered = hoveredID == file.id
    return HStack(spacing: 12) {
      MusicPreviewButton(preview: preview, url: file.url) { viewModel.togglePreview(file.url) }
      Button {
        choose(file.url)
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text(file.title)
              .font(.appBody)
              .lineLimit(1)
              .truncationMode(.middle)
            if !file.folder.isEmpty {
              Text(file.folder.replacingOccurrences(of: "/", with: " / "))
                .font(.appMicro)
                .foregroundStyle(NeomorphicTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
          Spacer(minLength: 8)
          if isCurrent {
            Text("使用中")
              .font(.appMicroStrong)
              .foregroundStyle(NeomorphicTheme.muted)
          }
          if file.modified != .distantPast {
            Text(file.modified.formatted(date: .numeric, time: .omitted))
              .font(.appMicro.monospacedDigit())
              .foregroundStyle(NeomorphicTheme.muted)
          }
          Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            .font(.appMicro.monospacedDigit())
            .foregroundStyle(NeomorphicTheme.muted)
            .frame(width: 64, alignment: .trailing)
          Text("使う")
            .font(.appCaptionStrong)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
              Capsule().fill(isHovered ? NeomorphicTheme.controlSelected : NeomorphicTheme.control)
            )
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("この曲に合わせて映像を作る")
      .accessibilityLabel("\(file.title)を使う")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isHovered ? NeomorphicTheme.hover : Color.clear)
    )
    .onHover { inside in
      if inside { hoveredID = file.id } else if hoveredID == file.id { hoveredID = nil }
    }
  }

  private func placeholder(icon: String, message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon).font(.system(size: 28, weight: .light))
      Text(message).font(.appBody).multilineTextAlignment(.center)
    }
    .foregroundStyle(NeomorphicTheme.muted)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - 下の帯

  private var footer: some View {
    HStack(spacing: 12) {
      Text(footerText)
        .font(.appCaption)
        .foregroundStyle(NeomorphicTheme.muted)
      if let message = preview.failureMessage {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.caution)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(NeomorphicTheme.canvas)
  }

  private var footerText: String {
    guard viewModel.musicFolderURL != nil, !isLoading else { return "" }
    let shown = visibleFiles.count
    let base = shown == files.count ? "\(files.count)曲" : "\(shown) / \(files.count)曲"
    return didHitLimit ? "\(base)（多いため先頭\(MusicVideoMusicBrowser.fileLimit)曲まで）" : base
  }

  // MARK: - 操作

  private func choose(_ url: URL) {
    viewModel.chooseMusic(url)
    close()
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "選択"
    panel.message = "曲を置いてあるフォルダを選んでください（中のフォルダも探します）"
    if let current = viewModel.musicFolderURL { panel.directoryURL = current }
    if panel.runModal() == .OK, let url = panel.url {
      viewModel.setMusicFolder(url)
    }
  }

  private func load() async {
    guard let folder = viewModel.musicFolderURL else {
      files = []
      folders = []
      scope = nil
      return
    }
    isLoading = true
    let limit = MusicVideoMusicBrowser.fileLimit
    let result = await Task.detached(priority: .userInitiated) {
      MusicVideoMusicBrowser.scan(folder: folder, limit: limit)
    }.value
    guard !Task.isCancelled else { return }
    files = result.files
    folders = MusicVideoMusicBrowser.folders(in: result.files)
    didHitLimit = result.hitLimit
    // 見ていたフォルダが、読み直した結果に無ければ、すべてへ戻す。
    if let scope, !folders.contains(where: { $0.path == scope }) { self.scope = nil }
    isLoading = false
  }
}
