// ArkServer/Features/MusicVideo/Views/MusicPreviewButton.swift

import SwiftUI

/// 曲の横に置く、試聴の再生/停止ボタン。再生中は、まわりに進み具合を出す。
struct MusicPreviewButton: View {
  @ObservedObject var preview: MusicPreviewPlayer
  let url: URL
  let action: () -> Void

  var body: some View {
    let isPlaying = preview.isPlaying(url)
    let failed = preview.failedURL == url

    Button(action: action) {
      ZStack {
        Circle().fill(NeomorphicTheme.control)
        if isPlaying {
          Circle()
            .trim(from: 0, to: preview.progress)
            .stroke(NeomorphicTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        Image(systemName: failed ? "exclamationmark.triangle.fill" : (isPlaying ? "stop.fill" : "play.fill"))
          .font(.system(size: 10))
          .foregroundStyle(failed ? NeomorphicTheme.caution : NeomorphicTheme.ink)
      }
      .frame(width: 26, height: 26)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(helpText(isPlaying: isPlaying, failed: failed))
    .accessibilityLabel(isPlaying ? "試聴を止める" : "試聴する")
    .accessibilityIdentifier("musicvideo.preview")
  }

  private func helpText(isPlaying: Bool, failed: Bool) -> String {
    if failed, let message = preview.failureMessage { return message }
    return isPlaying ? "試聴を止める" : "15秒ほど試聴する"
  }
}
