import SwiftUI

// MARK: - 似ているメディアの検出と一括削除
//
// 「重複チェック」がファイルの中身の完全一致だけを見るのに対し、こちらは見た目の近さで探す。
// 書き出し直し・解像度違い・軽い加工違いなど、ファイルとしては別物になってしまうものが対象。
// 似ているだけで別物のこともあるので、必ずこの画面で目視してから消す。

struct SimilarMediaView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: LibraryViewModel
    var onFinish: () -> Void = {}

    @StateObject private var model = SimilarMediaViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    private let thumbnailSide: CGFloat = 116

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1020, minHeight: 540, idealHeight: 700)
        .appSheet()
        .onAppear {
            model.configure { dataManager.fileMetadata(for: $0).size }
            model.scan(items: items, dataManager: dataManager)
        }
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
            Label("似ているメディアの整理", systemImage: "square.on.square.dashed")
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
                Text("\(model.scanStage.title)… \(model.scannedCount) / \(model.totalCount)")
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            ContentUnavailableView(
                "似ているメディアはありません",
                systemImage: "checkmark.circle",
                description: Text("「似ている度合い」をゆるめると候補が増えます．")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        groupRow(group, at: index)
                    }
                }
                .padding(14)
            }
        }
    }

    private func groupRow(_ group: SimilarMediaViewModel.Group, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(group.items.count)件が似ています")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                if group.hasAudioDifferences {
                    Label("音声が異なる版を含みます", systemImage: "waveform.badge.exclamationmark")
                        .font(.appMicroStrong)
                        .foregroundStyle(.orange)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.items) { item in
                        candidateCell(item, group: group, groupIndex: index)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    private func candidateCell(_ item: VideoItem, group: SimilarMediaViewModel.Group, groupIndex: Int) -> some View {
        let isKept = group.keepIDs.contains(item.id)
        let isSelected = model.selectedIDs.contains(item.id)
        return VStack(spacing: 4) {
            MacVideoThumbnailView(videoItem: item, dataManager: dataManager, showsPlayGlyph: false)
                .frame(width: thumbnailSide, height: thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isKept ? Color.green : (isSelected ? Color.red : Color.secondary.opacity(0.25)),
                            lineWidth: isKept || isSelected ? 3 : 1
                        )
                )
                .overlay(alignment: .bottomLeading) {
                    Text(isKept ? "残す候補" : (isSelected ? "削除" : "対象外"))
                        .font(.appMicroStrong)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isKept ? Color.green : (isSelected ? Color.red : Color.gray)))
                        .padding(5)
                }
                .opacity(isSelected ? 1 : 0.75)
                .onTapGesture { model.toggle(item.id, inGroupAt: groupIndex) }

            Button(item.mediaType == .photo ? "これを残す" : "この音声版を残す") {
                model.setKeep(item.id, inGroupAt: groupIndex)
            }
                .font(.appMicro)
                .buttonStyle(.plain)
                .foregroundStyle(isKept ? NeomorphicTheme.muted : NeomorphicTheme.ink)
                .disabled(isKept)

            Text(item.originalFilename)
                .font(.appMicro)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: thumbnailSide)
                .foregroundStyle(.secondary)

            if let details = model.details(for: item) {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        if details.pixelWidth > 0, details.pixelHeight > 0 {
                            Text("\(details.pixelWidth)×\(details.pixelHeight)")
                        }
                        if details.fileSize > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: details.fileSize, countStyle: .file))
                        }
                    }
                    if details.videoBitrate > 0 {
                        Text(String(format: "映像 %.1f Mbps", details.videoBitrate / 1_000_000))
                    }
                }
                .font(.appMicro.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: thumbnailSide)
            }

            audioBadge(for: item, in: group)
        }
        .help(item.originalFilename)
    }

    @ViewBuilder
    private func audioBadge(for item: VideoItem, in group: SimilarMediaViewModel.Group) -> some View {
        let status = model.audioStatus(for: item, in: group)
        switch status {
        case .notApplicable:
            EmptyView()
        case .matched:
            metadataBadge("音声一致", systemImage: "waveform", color: .green)
        case .different:
            let number = (group.audioGroupByItemID[item.id] ?? 0) + 1
            metadataBadge("音声版 \(number)", systemImage: "waveform.badge.exclamationmark", color: .orange)
        case .noAudio:
            metadataBadge("音声なし", systemImage: "speaker.slash", color: .secondary)
        case .unreadable:
            metadataBadge("音声未確認", systemImage: "questionmark.circle", color: .secondary)
        }
    }

    private func metadataBadge(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.appMicroStrong)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .frame(width: thumbnailSide)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("似ている度合い")
                    .font(.appCaption)
                Slider(value: $model.maxDistance, in: 0...16, step: 1)
                    .frame(width: 200)
                Text("±\(Int(model.maxDistance))")
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 38, alignment: .leading)
                Text("小さいほど「ほぼ同じ」だけに絞られます．音声・尺・画質が一致する動画は再圧縮差も補完します")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("\(model.groups.count)グループ / \(model.selectedIDs.count)件を削除対象")
                    .font(.appBody)
                if model.unreadableCount > 0 {
                    Text("照合できなかった項目: \(model.unreadableCount)件")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("選択した\(model.selectedIDs.count)件を削除", systemImage: "trash")
                }
                .buttonStyle(AppActionButtonStyle(isPrimary: true))
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
