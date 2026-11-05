import AppKit
import SwiftUI

// MARK: - 差分動画を探して切り替え再生へ渡す
//
// 「似ているものを探す」が消す候補を挙げる画面なのに対し、こちらは残すのが前提。
// 同じ尺・同じ動きで絵だけが違うものを束にして見せ、選んだぶんを差分切り替え再生へ送る。

struct VariantVideoView: View {
    let items: [VideoItem]
    @ObservedObject var dataManager: LibraryViewModel
    /// 開いた時点の親ウィンドウの大きさ。ここへ合わせて開く。
    var hostWindowSize: CGSize?
    /// ツールバーのどちらの入口から開いたか．画面内でも切り替えられる．
    var initialSearchMode: VariantVideoViewModel.SearchMode = .normal
    /// sheet ではなく ContentView のオーバーレイとして表示するため、閉じ方は呼び出し側へ任せる。
    var onClose: () -> Void

    /// 探索結果は `AppViewModel` が持つ。プレイヤーはこの画面の上へ重なり、
    /// 見つけたグループと選んだ組み合わせもこの View ごとそのまま残る。
    @EnvironmentObject private var model: VariantVideoViewModel
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    /// サムネイルの一辺。広いウィンドウでは大きく見たいので、その場で変えられるようにする。
    @AppStorage("variantFinder.thumbnailSide") private var thumbnailSide: Double = 168
    /// 同時にデコードし続けられる本数の上限（`PlaybackCoordinator.playVariantSwitch` と揃える）。
    private let maxPlayableCount = 9

    /// 親ウィンドウをほぼ埋めるオーバーレイの大きさ。
    private var overlaySize: CGSize {
        let host = hostWindowSize ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: max(960, host.width - 56), height: max(640, host.height - 56))
    }

    /// グループの札を横に並べる。縦一列に積むと、ウィンドウを広げても右側が余るだけになる
    /// （1グループはたいてい数本なので、1行ぶんの幅しか使わない）。
    /// 札1枚にタイルが2〜3個入る幅を下限にして、広ければ札の数を増やす。
    private var groupColumns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSide * 2.3 + 48), spacing: 14, alignment: .top)]
    }

    /// 札の中でタイルを敷き詰める。`maximum` に幅を持たせておくと、
    /// 割り切れないぶんをタイル側が吸ってくれて右端に隙間が残らない。
    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSide, maximum: thumbnailSide * 1.45), spacing: 10, alignment: .top)]
    }

    var body: some View {
        finder
            .frame(
                minWidth: overlaySize.width, idealWidth: overlaySize.width,
                minHeight: overlaySize.height, idealHeight: overlaySize.height
            )
    }

    private var finder: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.scan(
                items: items,
                dataManager: dataManager,
                initialSearchMode: initialSearchMode
            )
        }
        .onDisappear { model.cancelScan() }
        // 再生中もこの View は背後に残るので onAppear は再度呼ばれない。
        // プレイヤーを閉じた時点で、中断した照合と削除後の顔ぶれ確認を再開する。
        .onChange(of: coordinator.mode) { oldMode, newMode in
            guard oldMode != nil, newMode == nil else { return }
            model.scan(items: items, dataManager: dataManager)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(
                model.searchMode == .normal ? "差分動画を探す" : "強制差分候補を探す",
                systemImage: model.searchMode == .normal
                    ? "rectangle.on.rectangle.angled"
                    : "link.badge.plus"
            )
                .font(.appHeadline)
            Text(model.searchMode == .normal
                 ? "尺が揃っていて，絵だけが違うものを束にします"
                 : "尺を問わず，一部に同じ場面が続く動画を探します")
                .font(.appCaption)
                .foregroundStyle(.secondary)
            Spacer()
            AppChoicePicker(
                "探索方法",
                selection: Binding(
                    get: { model.searchMode },
                    set: { model.setSearchMode($0) }
                )
            ) {
                Text("通常差分").tag(VariantVideoViewModel.SearchMode.normal)
                Text("一部一致").tag(VariantVideoViewModel.SearchMode.partial)
            }

            .tint(NeomorphicTheme.ink)
            .frame(width: 190)
            Button {
                model.rescan()
            } label: {
                Label("探し直す", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
            .help("取り込み直したファイルを拾わせたいときに，フレームの照合をやり直します")
            Button("閉じる") { onClose() }
                // 背後の View に付いたショートカットもプレイヤー越しに反応するため、
                // 再生中は外して Esc が探索画面まで閉じないようにする。
                .keyboardShortcut(coordinator.isPlayingOverVariantFinder ? nil : .cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        // 前回の指紋が残っていれば走査中でも先に一覧が出る。待たずに再生へ進めるようにする。
        if model.isScanning && model.groups.isEmpty {
            VStack(spacing: 14) {
                ProgressView(value: model.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text(progressDescription)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                Text(progressDetailDescription)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                Button("中止") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            ContentUnavailableView {
                Label(
                    model.searchMode == .normal
                        ? "差分動画は見つかりませんでした"
                        : "強制差分候補は見つかりませんでした",
                    systemImage: "rectangle.on.rectangle.slash"
                )
            } description: {
                Text(emptyDescription)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if model.isScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(compactProgressDescription)
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("中止") { model.cancelScan() }
                            .font(.appCaption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.25))
                }
                ScrollView {
                    LazyVGrid(columns: groupColumns, alignment: .leading, spacing: 14) {
                        ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                            groupRow(group, at: index)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    /// グループ1つぶんの札。横に並べるので、見出しを1行に詰め込まず縦に組む。
    private func groupRow(_ group: VariantVideoViewModel.Group, at index: Int) -> some View {
        let selectedCount = group.selectedIDs.count
        let isPlayable = (2...maxPlayableCount).contains(selectedCount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(groupTitle(group))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("すべて選ぶ") { model.selectAll(inGroupAt: index) }
                    .font(.appCaption)
                    .buttonStyle(.plain)
                    .foregroundStyle(NeomorphicTheme.ink)
                    .disabled(selectedCount == group.items.count)
            }

            if let stats = group.stats {
                Text(evidenceText(stats))
                    .font(.appMicro.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help("絵の差はフレームどうしのハミング距離（小さいほど似ている），名前の近さは 0〜1．名前の近さはしきい値を上下させる補助に使っています")
            } else if let score = group.partialMatchScore {
                Text(String(format: "一部一致の絵の差 %.1f ・ 小さいほど近い", score))
                    .font(.appMicro.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    candidateCell(item, group: group, groupIndex: index)
                }
            }

            Button {
                play(group.selectedItems, alignmentMode: group.alignmentMode)
            } label: {
                Label(
                    group.alignmentMode == .content
                        ? "強制差分再生（\(selectedCount)本）"
                        : "切り替え再生（\(selectedCount)本）",
                    systemImage: "rectangle.on.rectangle.angled"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppActionButtonStyle(isPrimary: true))
            .controlSize(.small)
            .disabled(!isPlayable)
            .help(isPlayable
                  ? (group.alignmentMode == .content
                     ? "共通場面へ一度だけ合わせ，その後は自由に切り替えます"
                     : "選んだ差分を同期再生し，一定間隔／キー操作で切り替えます")
                  : "2〜\(maxPlayableCount)本を選んでください")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    private func candidateCell(_ item: VideoItem, group: VariantVideoViewModel.Group, groupIndex: Int) -> some View {
        let isSelected = group.selectedIDs.contains(item.id)
        return VStack(spacing: 5) {
            MacVideoThumbnailView(videoItem: item, dataManager: dataManager, showsPlayGlyph: false)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isSelected ? 3 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                        .padding(6)
                }
                .opacity(isSelected ? 1 : 0.6)
                .onTapGesture { model.toggle(item.id, inGroupAt: groupIndex) }

            Text(item.originalFilename)
                .font(.appMicro)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
        }
        .help(item.originalFilename)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.searchMode == .normal {
                normalSearchControls
            } else {
                HStack(spacing: 10) {
                    Text("最小尺差")
                        .font(.appCaption)
                    AppNumberStepper(
                        value: $model.minimumPartialDurationDifference,
                        in: 1...120,
                        step: 1
                    ) {
                        Text("\(Int(model.minimumPartialDurationDifference))秒以上")
                            .font(.appCaption.monospacedDigit())
                            .frame(width: 66, alignment: .leading)
                    }
                    .disabled(model.isScanning)
                    Text("通常差分と重ならず，この尺差以上ある動画ペアだけを表示します")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Text("サムネイル")
                    .font(.appCaption)
                Slider(value: $thumbnailSide, in: 110...320, step: 2)
                    .frame(width: 150)
                Text("\(Int(thumbnailSide))px")
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 46, alignment: .leading)

                Text(model.searchMode == .normal
                     ? "\(model.groups.count)グループ / \(model.totalGroupedCount)本"
                     : "\(model.groups.count)組の強制差分候補")
                    .font(.appBody)
                if model.unreadableCount > 0 {
                    Text("フレームを読めなかった項目: \(model.unreadableCount)件")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var normalSearchControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("尺の許容差")
                    .font(.appCaption)
                Slider(value: $model.durationTolerance, in: 0...2, step: 0.05)
                    .frame(width: 150)
                Text(String(format: "±%.2f秒", model.durationTolerance))
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 62, alignment: .leading)

                Text("似ている度合い")
                    .font(.appCaption)
                Slider(value: $model.maxAverageDistance, in: 2...20, step: 1)
                    .frame(width: 150)
                Text("±\(Int(model.maxAverageDistance))")
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 34, alignment: .leading)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("タイトルの効き")
                    .font(.appCaption)
                Slider(value: $model.titleInfluence, in: 0...8, step: 1)
                    .frame(width: 150)
                Text("±\(Int(model.titleInfluence))")
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 34, alignment: .leading)
                Text(titleInfluenceHint)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// 名前が近いほど「似ている度合い」を何点ぶん甘く見るか、を実際の数字で見せる。
    private var titleInfluenceHint: String {
        guard model.titleInfluence > 0 else {
            return "0 ならファイル名を見ず，絵だけで判定します"
        }
        let loose = VariantVideoDetector.effectiveThreshold(
            base: model.maxAverageDistance, titleSimilarity: 1, influence: model.titleInfluence)
        let tight = VariantVideoDetector.effectiveThreshold(
            base: model.maxAverageDistance, titleSimilarity: 0, influence: model.titleInfluence)
        return String(format: "名前がそっくりなら %.0f まで，まるで違えば %.0f までに絞ります", loose, tight)
    }

    private func evidenceText(_ stats: VariantVideoDetector.GroupStats) -> String {
        String(
            format: "絵の差 %.1f〜%.1f ・ 名前の近さ %.2f〜%.2f",
            stats.frameDistance.lowerBound, stats.frameDistance.upperBound,
            stats.titleSimilarity.lowerBound, stats.titleSimilarity.upperBound
        )
    }

    private var scanScopeDescription: String {
        model.searchMode == .normal
            ? "尺が揃った動画だけを対象にしています"
            : "尺で候補を落とさず，動画全体を2秒間隔で調べています"
    }

    private var progressDescription: String {
        switch model.scanPhase {
        case .idle:
            return "探索を準備中…"
        case .extractingFrames:
            return "フレーム取得中… \(model.scannedCount) / \(model.totalCount)本"
        case .comparingCandidates:
            return "候補比較中… \(model.comparedPairCount) / \(model.totalPairCount)組"
        }
    }

    private var progressDetailDescription: String {
        switch model.scanPhase {
        case .idle:
            return scanScopeDescription
        case .extractingFrames:
            return model.reusedCount > 0
                ? "\(model.reusedCount)件は取得済みの指紋をそのまま使っています"
                : scanScopeDescription
        case .comparingCandidates:
            return "取得した時間列指紋を動画ペアごとに照合しています"
        }
    }

    private var compactProgressDescription: String {
        switch model.scanPhase {
        case .idle:
            return "探索を準備中…"
        case .extractingFrames:
            return "残り \(max(0, model.totalCount - model.scannedCount))本のフレームを取得中… 見つかったぶんは先に選べます"
        case .comparingCandidates:
            return "候補比較中… \(model.comparedPairCount) / \(model.totalPairCount)組"
        }
    }

    private var emptyDescription: String {
        model.searchMode == .normal
            ? "尺の許容差か似ている度合いをゆるめると候補が増えます．"
            : "十分長く続く共通場面があり，かつ指定した尺差以上ある動画だけを表示します．最小尺差を下げると候補が増えます．"
    }

    private func groupTitle(_ group: VariantVideoViewModel.Group) -> String {
        guard group.alignmentMode == .content else {
            return "\(group.items.count)本の差分 ・ \(formatDuration(group.duration))"
        }
        let shared = formatDuration(group.sharedDuration ?? 0)
        let durations = group.items.map { formatDuration($0.duration) }.joined(separator: " / ")
        return "共通 \(shared) ・ 尺 \(durations)"
    }

    private func play(
        _ videos: [VideoItem],
        alignmentMode: VariantPlaybackAlignmentMode
    ) {
        guard videos.count >= 2 else { return }
        // フレームの展開は重いので、再生している間は止める。
        // 途中まで作った指紋は残るため、閉じたときに続きから進む。
        model.cancelScan()
        if alignmentMode == .content {
            coordinator.playContentAlignedVariantSwitch(videos)
        } else {
            coordinator.playVariantSwitch(videos)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
