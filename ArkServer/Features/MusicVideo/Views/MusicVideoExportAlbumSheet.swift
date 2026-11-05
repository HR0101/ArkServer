// ArkServer/Features/MusicVideo/Views/MusicVideoExportAlbumSheet.swift

import SwiftUI

/// 書き出した動画を入れるアルバムを選ぶシート。追加のたびに利用者が選ぶ(アプリは追加先を決めない)。
/// 既存のアルバムから探すか，名前を付けて新しいアルバムを作る。
struct MusicVideoExportAlbumSheet: View {
  @ObservedObject var dataManager: LibraryViewModel
  /// 追加するファイルの名前。何を追加するのかをヘッダーで示す。
  let fileName: String
  let onConfirm: (MusicVideoExportDestination) -> Void
  @Environment(\.dismiss) private var dismiss

  private enum Choice: Hashable {
    case existing(UUID)
    case newAlbum
  }

  private enum Order: String, CaseIterable, Identifiable {
    case name = "名前"
    case recent = "最近追加した順"
    var id: String { rawValue }
  }

  @State private var choice: Choice?
  @State private var newName = ""
  @State private var searchText = ""
  @AppStorage("musicVideo.exportPicker.order") private var order: Order = .name
  @State private var entries: [MusicVideoAlbumEntry] = []
  @FocusState private var isNameFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      SheetHeader(
        icon: "rectangle.stack.badge.plus",
        title: "追加先のアルバムを選ぶ",
        subtitle: "\(fileName) を入れるアルバムを選んでください"
      )
      .padding(20)

      HStack(spacing: 12) {
        TextField("アルバム名で検索", text: $searchText)
          .textFieldStyle(.roundedBorder)
        AppChoicePicker("並べ替え", selection: $order) {
          ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
        }
        .frame(width: 210)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 12)

      Divider()

      List {
        newAlbumRow
        ForEach(visibleEntries) { entry in
          albumRow(entry)
        }
      }
      .listStyle(.plain)

      Divider()
      footer
        .padding(16)
    }
    .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 580)
    .appSheet()
    .onAppear(perform: rebuild)
    .onChange(of: dataManager.albums) { rebuild() }
    .onChange(of: dataManager.videos) { rebuild() }
  }

  // MARK: - 一覧

  private var visibleEntries: [MusicVideoAlbumEntry] {
    var rows = entries.filter { $0.isSelectableDestination && $0.matches(query: searchText) }
    switch order {
    case .name:
      rows.sort { ($0.parent + "/" + $0.title).localizedStandardCompare($1.parent + "/" + $1.title) == .orderedAscending }
    case .recent:
      rows.sort { $0.latestImport > $1.latestImport }
    }
    return rows
  }

  private var newAlbumRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        choice = .newAlbum
        isNameFocused = true
      } label: {
        HStack(spacing: 10) {
          radio(choice == .newAlbum)
          Text("新しいアルバムを作る")
            .font(.appBody)
          Spacer(minLength: 8)
          Image(systemName: "plus")
            .font(.appCaption)
            .foregroundStyle(NeomorphicTheme.muted)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("musicvideo.exportAlbum.new")
      .accessibilityAddTraits(choice == .newAlbum ? .isSelected : [])

      if choice == .newAlbum {
        VStack(alignment: .leading, spacing: 4) {
          TextField("アルバム名（「/」で階層を作れます）", text: $newName)
            .textFieldStyle(.roundedBorder)
            .focused($isNameFocused)
            .onSubmit(confirm)
            .accessibilityIdentifier("musicvideo.exportAlbum.newName")
          if let message = newNameMessage {
            Text(message)
              .font(.appMicro)
              .foregroundStyle(.red)
          }
        }
        .padding(.leading, 28)
      }
    }
    .padding(.vertical, 4)
  }

  private func albumRow(_ entry: MusicVideoAlbumEntry) -> some View {
    let isSelected = choice == .existing(entry.id)
    return Button {
      choice = .existing(entry.id)
    } label: {
      HStack(spacing: 10) {
        radio(isSelected)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title)
            .font(.appBody)
            .lineLimit(1)
            .truncationMode(.middle)
          if !entry.parent.isEmpty {
            Text(entry.parent)
              .font(.appMicro)
              .foregroundStyle(NeomorphicTheme.muted)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
        Spacer(minLength: 8)
        Text("\(entry.count)本")
          .font(.appCaption.monospacedDigit())
          .foregroundStyle(NeomorphicTheme.muted)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(entry.title) \(entry.count)本")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// 選択の印。素材を選ぶシートと同じく，色を付けず，選択中は文字色・未選択は控えめな色にする。
  private func radio(_ isSelected: Bool) -> some View {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
      .font(.system(size: 15))
      .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
      .frame(width: 18)
  }

  // MARK: - 下の帯

  private var footer: some View {
    HStack(spacing: 12) {
      Text(summary)
        .font(.appCaption)
        .foregroundStyle(NeomorphicTheme.muted)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("キャンセル") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("musicvideo.exportAlbum.cancel")
      Button("書き出して追加") { confirm() }
        .buttonStyle(AppActionButtonStyle(isPrimary: true))
        .keyboardShortcut(.defaultAction)
        .disabled(destination == nil)
        .accessibilityIdentifier("musicvideo.exportAlbum.confirm")
    }
  }

  private var summary: String {
    switch choice {
    case .none:
      return "アルバムを選んでください"
    case .newAlbum:
      if case .success(let name) = nameResult { return "新しいアルバム「\(name)」を作って追加します" }
      return "新しいアルバムの名前を入力してください"
    case .existing(let id):
      guard let entry = entries.first(where: { $0.id == id }) else { return "アルバムを選んでください" }
      return "「\(entry.title)」に追加します"
    }
  }

  // MARK: - 選択と確定

  private var nameResult: Result<String, MusicVideoExportAlbumName.Problem> {
    MusicVideoExportAlbumName.validate(newName, existingNames: dataManager.albums.map(\.name))
  }

  /// 入力があるのに使えないときだけ理由を出す(何も入力していない間は黙っている)。
  private var newNameMessage: String? {
    guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    if case .failure(let problem) = nameResult { return problem.message }
    return nil
  }

  /// いま確定できる追加先。選んでいない・名前が使えない・選んだアルバムが消えたときは nil。
  private var destination: MusicVideoExportDestination? {
    switch choice {
    case .none:
      return nil
    case .newAlbum:
      if case .success(let name) = nameResult { return .new(name: name) }
      return nil
    case .existing(let id):
      return entries.contains(where: { $0.id == id }) ? .existing(albumID: id) : nil
    }
  }

  private func confirm() {
    guard let destination else { return }
    dismiss()
    onConfirm(destination)
  }

  private func rebuild() {
    entries = MusicVideoAlbumEntry.entries(albums: dataManager.albums, videos: dataManager.videos)
  }
}
