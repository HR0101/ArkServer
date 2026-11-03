// ArkServer/Features/MusicVideo/Views/MusicVideoCutEditorView.swift

import SwiftUI

/// 選んだカットの内容と、そのカットだけを直す操作。設定画面と同じ「行をまとめた面」で並べる。
struct MusicVideoCutEditorView: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  @ObservedObject var dataManager: LibraryViewModel

  var body: some View {
    MVSection(title: "カットの編集") {
      MVRowGroup {
        if let cut = viewModel.selectedCut, let plan = viewModel.plan, let index = viewModel.selectedCutIndex {
          MVRow(
            title: viewModel.sourceItem(for: cut.videoID)?.originalFilename ?? "（不明な動画）",
            detail: "カット \(index + 1) / \(plan.cuts.count)・\(fineTime(cut.timelineStart)) から \(String(format: "%.2f", cut.duration)) 秒・\(cut.intensity.displayName)\n元動画の \(fineTime(cut.sourceStart)) 付近を使用",
            leading: { thumbnail(for: cut) },
            control: { EmptyView() }
          )
          MVRow(title: "このカット", detail: "同じ長さのまま，別の映像に差し替えます．") {
            HStack(spacing: 8) {
              Button("差し替える") { viewModel.replaceSelectedCut() }
                .buttonStyle(.mvSmall)
                .accessibilityIdentifier("musicvideo.replaceCut")
              moreMenu
            }
            .disabled(!viewModel.canEdit)
          }
        } else {
          MVRow(
            title: "カットを選んでください",
            detail: "上のタイムラインをクリックすると，その位置のカットを選べます．選んだカットだけを差し替えられます．"
          ) {
            EmptyView()
          }
        }
        MVRow(title: "移動と履歴") {
          HStack(spacing: 8) {
            Button {
              viewModel.selectAdjacentCut(by: -1)
            } label: {
              Image(systemName: "chevron.left")
            }
            .buttonStyle(.mvSmall)
            .help("前のカット")
            .accessibilityLabel("前のカット")
            Button {
              viewModel.selectAdjacentCut(by: 1)
            } label: {
              Image(systemName: "chevron.right")
            }
            .buttonStyle(.mvSmall)
            .help("次のカット")
            .accessibilityLabel("次のカット")

            if viewModel.isApplyingEdit {
              ProgressView().controlSize(.small)
            }

            Button("元に戻す") { viewModel.undo() }
              .buttonStyle(.mvSmall)
              .disabled(!viewModel.canUndo)
              .accessibilityIdentifier("musicvideo.undo")
            Button("やり直す") { viewModel.redo() }
              .buttonStyle(.mvSmall)
              .disabled(!viewModel.canRedo)
          }
          .disabled(viewModel.plan == nil)
        }
        if !viewModel.excludedVideoIDs.isEmpty {
          MVRow(
            title: "除外した動画 \(viewModel.excludedVideoIDs.count)本",
            detail: "次に映像を作るときも使いません．"
          ) {
            Button("除外を解除") { viewModel.clearExclusions() }
              .buttonStyle(.mvSmall)
          }
        }
      }
    }
  }

  private var moreMenu: some View {
    Menu {
      Button("この動画を使っているカットをすべて差し替え") { viewModel.replaceAllUsesOfSelectedVideo() }
      Button("この動画を外す（以後も使わない）") { viewModel.excludeSelectedVideo() }
      Divider()
      Menu("指定の動画に差し替え") {
        ForEach(viewModel.poolVideos) { video in
          Button(video.name) { viewModel.replaceSelectedCut(withVideo: video.id) }
        }
      }
    } label: {
      Text("その他")
    }
    .menuStyle(.button)
    .buttonStyle(.mvSmall)
    .menuIndicator(.visible)
    .fixedSize()
  }

  @ViewBuilder
  private func thumbnail(for cut: PlannedCut) -> some View {
    Group {
      if let item = viewModel.sourceItem(for: cut.videoID) {
        MacVideoThumbnailView(videoItem: item, dataManager: dataManager, showsPlayGlyph: false)
      } else {
        Rectangle().fill(NeomorphicTheme.control)
      }
    }
    .frame(width: 96, height: 54)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func fineTime(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let rest = seconds - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, rest)
  }
}
