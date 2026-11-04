// ArkServer/Features/SceneExtraction/Views/SceneExtractionView.swift

import AppKit
import SwiftUI

struct SceneExtractionView: View {
  @ObservedObject var viewModel: SceneExtractionViewModel
  let onClose: () -> Void
  @AppStorage("sceneExtraction.tutorialVersion") private var seenTutorialVersion = 0
  @State private var isShowingTutorial = false

  private let minimumPlayerWidth: CGFloat = 560
  private let minimumChartWidth: CGFloat = 360
  private let candidateListHeight: CGFloat = 310

  var body: some View {
    VStack(spacing: 14) {
      header
      if let progress = viewModel.analysisProgress {
        HStack(spacing: 10) {
          ProgressView(value: progress.fractionCompleted)
          Text("\(progress.stage.displayName) \(Int(progress.fractionCompleted * 100))％")
            .font(.appCaption)
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .trailing)
        }
      }
      outputControls

      HSplitView {
        AnalysisPlayerView(viewModel: viewModel)
          .frame(minWidth: minimumPlayerWidth)

        VStack(spacing: 12) {
          FeatureScoreChartView(features: viewModel.features)
          ScrollView {
            SceneExtractionSettingsView(settings: $viewModel.settings)
          }
          .frame(maxHeight: 330)
        }
        .frame(minWidth: minimumChartWidth)
      }

      CandidateListView(
        candidates: viewModel.candidates,
        selectedCandidateID: viewModel.selectedCandidateID,
        canExport: viewModel.outputDirectoryURL != nil && !viewModel.isExportingClip,
        onSelect: viewModel.selectCandidate,
        onPreview: viewModel.previewCandidate,
        onReview: viewModel.reviewCandidate,
        onUpdateStart: viewModel.updateCandidateStart,
        onUpdateEnd: viewModel.updateCandidateEnd,
        onExport: viewModel.exportClip
      )
      .frame(height: candidateListHeight)
    }
    .padding(16)
    .background(NeomorphicTheme.background)
    .navigationTitle("シーン抽出")
    .task {
      if seenTutorialVersion < SceneExtractionTutorialContent.currentVersion {
        isShowingTutorial = true
      }
    }
    .sheet(
      isPresented: $isShowingTutorial,
      onDismiss: {
        seenTutorialVersion = SceneExtractionTutorialContent.currentVersion
      }
    ) {
      SceneExtractionTutorialView()
    }
    .appAlert(
      "処理に失敗しました",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("OK", role: .cancel) {
        viewModel.clearError()
      }
    } message: {
      Text(viewModel.errorMessage ?? "不明なエラーです．")
    }
    .appAlert(
      "処理が完了しました",
      isPresented: Binding(
        get: { viewModel.lastOperationMessage != nil },
        set: { if !$0 { viewModel.lastOperationMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {
        viewModel.lastOperationMessage = nil
      }
    } message: {
      Text(viewModel.lastOperationMessage ?? "")
    }
  }

  private var outputControls: some View {
    HStack(spacing: 10) {
      Button {
        selectOutputDirectory()
      } label: {
        Label("ComfyUI出力先", systemImage: "folder.badge.gearshape")
      }

      Text(viewModel.outputDirectoryURL?.path ?? "出力先が選択されていません")
        .font(.appCaption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      if viewModel.isExportingClip || viewModel.isExportingDataset {
        ProgressView()
          .controlSize(.small)
      }

      if viewModel.isExportingClip {
        Text("クリップを作成中です．完了後に最終MP4が表示されます．")
          .font(.appCaption)
          .foregroundStyle(.secondary)

        Button(role: .cancel) {
          viewModel.cancelClipExport()
        } label: {
          Label("書き出しをキャンセル", systemImage: "xmark.circle")
        }
      }

      Button {
        viewModel.exportDataset()
      } label: {
        Label("JSON・CSVを保存", systemImage: "tablecells")
      }
      .disabled(
        viewModel.videoDocument == nil
          || viewModel.outputDirectoryURL == nil
          || viewModel.isExportingClip
          || viewModel.isExportingDataset
      )
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Button {
        onClose()
      } label: {
        Label("ライブラリへ戻る", systemImage: "chevron.backward")
      }

      if viewModel.isAnalyzing {
        Button(role: .cancel) {
          viewModel.cancelAnalysis()
        } label: {
          Label("解析をキャンセル", systemImage: "xmark.circle")
        }
      } else {
        Button {
          viewModel.startAnalysis()
        } label: {
          Label("候補を解析", systemImage: "waveform.path.ecg")
        }
        // この画面の主役の操作なので、ここだけ青の塗りにする。
        .buttonStyle(AppActionButtonStyle(isPrimary: true))
        .tint(NeomorphicTheme.accent)
        .disabled(viewModel.videoDocument == nil || viewModel.isLoadingVideo)
      }

      Toggle("GTラベル付与モード", isOn: $viewModel.isGroundTruthModeEnabled)
        .toggleStyle(AppToggleStyle())

      Button {
        viewModel.addGroundTruthAtCurrentTime()
      } label: {
        Label("現在位置を正解にする", systemImage: "checkmark.seal")
      }
      .disabled(!viewModel.isGroundTruthModeEnabled || viewModel.videoDocument == nil)

      Button {
        isShowingTutorial = true
      } label: {
        Label("使い方", systemImage: "questionmark.circle")
      }

      Spacer()

      if let document = viewModel.videoDocument {
        VStack(alignment: .trailing, spacing: 2) {
          Text(document.url.lastPathComponent)
            .font(.appHeadline)
            .lineLimit(1)
          Text(metadataText(document))
            .font(.appCaption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func selectOutputDirectory() {
    let panel = NSOpenPanel()
    panel.title = "ComfyUIのinputフォルダを選択"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    viewModel.setOutputDirectory(url)
  }

  private func metadataText(_ document: VideoDocument) -> String {
    let audioText = document.hasAudioTrack ? "音声あり" : "音声なし"
    return String(
      format: "%d×%d・%.2ffps・%@",
      document.resolutionWidth,
      document.resolutionHeight,
      document.nominalFrameRate,
      audioText
    )
  }
}
