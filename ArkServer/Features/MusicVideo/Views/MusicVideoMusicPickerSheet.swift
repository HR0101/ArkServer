// ArkServer/Features/MusicVideo/Views/MusicVideoMusicPickerSheet.swift

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 曲を置いてあるフォルダから、曲を探して選ぶシート。フォルダは一度選べば覚える。
struct MusicVideoMusicPickerSheet: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  @Environment(\.dismiss) private var dismiss

  struct MusicFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
  }

  enum Order: String, CaseIterable, Identifiable {
    case name = "名前"
    case recent = "新しい順"
    var id: String { rawValue }
  }

  @State private var files: [MusicFile] = []
  @State private var isLoading = false
  @State private var didHitLimit = false
  @State private var searchText = ""
  @AppStorage("musicVideo.musicPicker.order") private var order: Order = .name

  private static let fileLimit = 2000

  private var visibleFiles: [MusicFile] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = query.isEmpty ? files : files.filter { $0.title.localizedCaseInsensitiveContains(query) }
    switch order {
    case .name: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    case .recent: result.sort { $0.modified > $1.modified }
    }
    return result
  }

  var body: some View {
    VStack(spacing: 0) {
      SheetHeader(
        icon: "music.note.list",
        title: "曲を選ぶ",
        subtitle: viewModel.musicFolderURL?.path ?? "曲を置いてあるフォルダを選んでください"
      )
      .padding(20)

      HStack(spacing: 12) {
        TextField("曲名で検索", text: $searchText)
          .textFieldStyle(.roundedBorder)
        Picker("並べ替え", selection: $order) {
          ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
        }
        .frame(width: 180)
        Button("フォルダを選ぶ…", action: chooseFolder)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 12)

      Divider()

      content

      Divider()
      HStack {
        Text(footerText)
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
        Spacer()
        Button("閉じる") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)
    }
    .frame(minWidth: 640, idealWidth: 700, minHeight: 520, idealHeight: 620)
    .appSheet()
    .task(id: viewModel.musicFolderURL) { await load() }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.musicFolderURL == nil {
      placeholder(icon: "folder.badge.plus", message: "「フォルダを選ぶ…」で，曲を置いてあるフォルダを選んでください")
    } else if isLoading {
      VStack(spacing: 10) {
        ProgressView()
        Text("曲を探しています…").font(.appBody).foregroundStyle(NeomorphicTheme.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if visibleFiles.isEmpty {
      placeholder(icon: "music.note", message: files.isEmpty ? "このフォルダに曲が見つかりませんでした" : "条件に合う曲がありません")
    } else {
      List(visibleFiles) { file in
        Button {
          viewModel.chooseMusic(file.url)
          dismiss()
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "music.note")
              .foregroundStyle(NeomorphicTheme.muted)
              .frame(width: 18)
            Text(file.title)
              .font(.appBody)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
              .font(.appMicro.monospacedDigit())
              .foregroundStyle(NeomorphicTheme.muted)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(file.title)
      }
      .listStyle(.plain)
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

  private var footerText: String {
    guard viewModel.musicFolderURL != nil, !isLoading else { return "" }
    let shown = visibleFiles.count
    let base = shown == files.count ? "\(files.count)曲" : "\(shown) / \(files.count)曲"
    return didHitLimit ? "\(base)（多いため先頭\(Self.fileLimit)曲まで）" : base
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
      return
    }
    isLoading = true
    let limit = Self.fileLimit
    let result = await Task.detached(priority: .userInitiated) {
      Self.scan(folder: folder, limit: limit)
    }.value
    guard !Task.isCancelled else { return }
    files = result.files
    didHitLimit = result.hitLimit
    isLoading = false
  }

  /// フォルダの中(サブフォルダも含む)の音声ファイルを集める。
  nonisolated private static func scan(folder: URL, limit: Int) -> (files: [MusicFile], hitLimit: Bool) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let enumerator = FileManager.default.enumerator(
      at: folder,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return ([], false) }

    var found: [MusicFile] = []
    for case let url as URL in enumerator {
      guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { continue }
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      found.append(MusicFile(
        url: url,
        size: Int64(values?.fileSize ?? 0),
        modified: values?.contentModificationDate ?? .distantPast
      ))
      if found.count >= limit { return (found, true) }
    }
    return (found, false)
  }
}
