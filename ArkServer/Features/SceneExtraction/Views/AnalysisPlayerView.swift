// ArkServer/Features/SceneExtraction/Views/AnalysisPlayerView.swift

import SwiftUI

struct AnalysisPlayerView: View {
  @ObservedObject var viewModel: SceneExtractionViewModel

  private let seekInterval = 5.0
  private let playerCornerRadius: CGFloat = 10

  var body: some View {
    VStack(spacing: 12) {
      playerSurface
      playbackControls
      seekSlider
      CandidateTimelineView(
        duration: viewModel.duration,
        currentTime: viewModel.currentTime,
        candidates: viewModel.candidates,
        selectedCandidateID: viewModel.selectedCandidateID,
        isGroundTruthModeEnabled: viewModel.isGroundTruthModeEnabled,
        onSeek: { viewModel.seek(to: $0) },
        onSelectCandidate: viewModel.selectCandidate,
        onAddGroundTruth: addGroundTruth
      )
    }
  }

  private var playerSurface: some View {
    ZStack {
      Color.black

      if viewModel.videoDocument != nil {
        PlayerLayerContainerView(player: viewModel.player)
      } else if viewModel.isLoadingVideo {
        ProgressView("動画を読み込んでいます")
          .tint(.white)
          .foregroundStyle(.white)
      } else {
        ContentUnavailableView(
          "動画が選択されていません",
          systemImage: "film",
          description: Text("ライブラリで動画を選び，「シーン抽出」を実行してください．")
        )
        .foregroundStyle(.white.opacity(0.8))
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: playerCornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: playerCornerRadius, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
    )
  }

  private var playbackControls: some View {
    HStack(spacing: 14) {
      Button {
        viewModel.seek(by: -seekInterval)
      } label: {
        Label("5秒戻る", systemImage: "gobackward.5")
          .labelStyle(.iconOnly)
      }

      Button {
        viewModel.stepFrame(by: -1)
      } label: {
        Label("1コマ戻る", systemImage: "backward.frame")
          .labelStyle(.iconOnly)
      }

      Button {
        viewModel.togglePlayback()
      } label: {
        Label(
          viewModel.isPlaying ? "一時停止" : "再生",
          systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
        )
        .labelStyle(.iconOnly)
        .font(.appTitle)
      }
      .keyboardShortcut(.space, modifiers: [])

      Button {
        viewModel.stepFrame(by: 1)
      } label: {
        Label("1コマ進む", systemImage: "forward.frame")
          .labelStyle(.iconOnly)
      }

      Button {
        viewModel.seek(by: seekInterval)
      } label: {
        Label("5秒進む", systemImage: "goforward.5")
          .labelStyle(.iconOnly)
      }

      Spacer()

      Text("\(timeText(viewModel.currentTime)) / \(timeText(viewModel.duration))")
        .font(.appMonoBody)
        .foregroundStyle(NeomorphicTheme.muted)
    }
    .buttonStyle(.borderless)
    // 操作アイコンは青でなく文字色にする（青は進捗・選択の目印だけに使う）。
    .tint(NeomorphicTheme.ink)
    .foregroundStyle(NeomorphicTheme.ink)
    .disabled(viewModel.videoDocument == nil)
  }

  private var seekSlider: some View {
    Slider(
      value: Binding(
        get: { viewModel.currentTime },
        set: { viewModel.seek(to: $0) }
      ),
      in: 0...max(0.001, viewModel.duration)
    )
    .disabled(viewModel.videoDocument == nil)
    .accessibilityLabel("再生位置")
  }

  private func addGroundTruth(at time: Double) {
    viewModel.seek(to: time)
    viewModel.addGroundTruthAtCurrentTime()
  }

  private func timeText(_ seconds: Double) -> String {
    let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
    let hours = Int(safeSeconds) / 3_600
    let minutes = Int(safeSeconds) % 3_600 / 60
    let remainingSeconds = Int(safeSeconds) % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
  }
}
