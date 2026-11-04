import SwiftUI

// MARK: - ラフ画・線画の抽出と一括削除
//
// アルバムの画像を走査して「ラフ画・線画らしい」ものを集め、
// 目で確かめてから消せるようにする。自動判定に外れはあるので、
// 見つけたものを黙って消すことはせず、必ずこの画面を挟む。

struct SketchCleanupView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: LibraryViewModel
    /// 消したあとに一覧側の選択を片付けてもらうための通知。
    var onFinish: () -> Void = {}

    @StateObject private var model = SketchCleanupViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    private let thumbnailSide: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 980, minHeight: 520, idealHeight: 680)
        .appSheet()
        .onAppear { model.scan(items: items, dataManager: dataManager) }
        .onDisappear { model.cancelScan() }
        .sheet(isPresented: $showDeleteConfirmation) {
            MediaDeletionConfirmationSheet(
                items: model.selectedItems,
                dataManager: dataManager,
                onMoveToAppTrash: {
                    apply { dataManager.moveToTrash(videoIDs: $0) }
                },
                onDeleteCompletely: {
                    apply { dataManager.deleteVideos(videoIDs: $0) }
                },
                onMoveToSystemTrash: {
                    apply { dataManager.moveMediaFilesToSystemTrash(videoIDs: $0) }
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("ラフ画・線画の抽出", systemImage: "scribble.variable")
                .font(.appHeadline)
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            VStack(spacing: 14) {
                ProgressView(value: model.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text("判定中… \(model.scannedCount) / \(model.totalCount)")
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleCandidates.isEmpty {
            ContentUnavailableView(
                "該当する画像はありません",
                systemImage: "checkmark.circle",
                description: Text(model.candidates.isEmpty
                    ? "このアルバムには判定できる画像がありませんでした．"
                    : "「きびしさ」を下げると候補が増えます．")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(model.visibleCandidates) { candidate in
                        candidateCell(candidate)
                    }
                }
                .padding(14)
            }
        }
    }

    private func candidateCell(_ candidate: SketchCleanupViewModel.Candidate) -> some View {
        let isSelected = model.selectedIDs.contains(candidate.id)
        return VStack(spacing: 5) {
            MacVideoThumbnailView(videoItem: candidate.item, dataManager: dataManager, showsPlayGlyph: false)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                      lineWidth: isSelected ? 3 : 1)
                )
                .overlay(alignment: .topLeading) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(candidate.judgement.kind.displayName) \(Int(candidate.judgement.score * 100))%")
                        .font(.appMicroStrong)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
                .opacity(isSelected ? 1 : 0.55)

            Text(candidate.item.originalFilename)
                .font(.appMicro)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: thumbnailSide)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(candidate.id) }
        .help(candidate.item.originalFilename)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("きびしさ")
                    .font(.appCaption)
                Slider(value: $model.threshold, in: 0.3...0.95)
                    .frame(width: 200)
                Text("\(Int(model.threshold * 100))%")
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 38, alignment: .leading)
                FlatSegmentedControl(
                    options: Array(SketchCleanupViewModel.KindFilter.allCases),
                    title: { $0.displayName },
                    selection: $model.kindFilter,
                    width: 240
                )
                Spacer()
            }

            HStack(spacing: 10) {
                Text("\(model.visibleCandidates.count)件が該当 / \(model.selectedIDs.count)件を選択中")
                    .font(.appBody)
                if model.unreadableCount > 0 {
                    Text("読み取れなかった画像: \(model.unreadableCount)件")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("すべて選択") { model.selectAllVisible() }
                    .disabled(model.visibleCandidates.isEmpty)
                Button("選択を解除") { model.deselectAll() }
                    .disabled(model.selectedIDs.isEmpty)
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("選択した\(model.selectedIDs.count)件を削除", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedIDs.isEmpty || model.isScanning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func apply(_ action: ([UUID]) -> Void) {
        let ids = model.selectedItems.map(\.id)
        guard !ids.isEmpty else { return }
        action(ids)
        onFinish()
        dismiss()
    }
}
