// ArkServer/Features/SceneExtraction/Views/CandidateTimelineView.swift

import SwiftUI

struct CandidateTimelineView: View {
  let duration: Double
  let currentTime: Double
  let candidates: [CandidateSegment]
  let selectedCandidateID: UUID?
  let isGroundTruthModeEnabled: Bool
  let onSeek: (Double) -> Void
  let onSelectCandidate: (CandidateSegment) -> Void
  let onAddGroundTruth: (Double) -> Void

  private let timelineHeight: CGFloat = 54
  private let markerMinimumWidth: CGFloat = 4

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width

      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(NeomorphicTheme.control)

        timelineTicks(width: width)

        ForEach(candidates) { candidate in
          candidateMarker(candidate, width: width)
        }

        Rectangle()
          .fill(Color.white)
          .frame(width: 2)
          .offset(x: xPosition(for: currentTime, width: width))
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .gesture(
        SpatialTapGesture().onEnded { value in
          let selectedTime = time(for: value.location.x, width: width)
          if isGroundTruthModeEnabled {
            onAddGroundTruth(selectedTime)
          } else {
            onSeek(selectedTime)
          }
        }
      )
    }
    .frame(height: timelineHeight)
    .accessibilityLabel("解析タイムライン")
    .accessibilityValue(timeText(currentTime))
  }

  @ViewBuilder
  private func timelineTicks(width: CGFloat) -> some View {
    ForEach(0..<5, id: \.self) { index in
      let fraction = Double(index) / 4
      let tickTime = duration * fraction
      VStack(spacing: 2) {
        Rectangle()
          .fill(.white.opacity(0.2))
          .frame(width: 1, height: 28)
        Text(timeText(tickTime))
          .font(.appMonoMicro)
          .foregroundStyle(NeomorphicTheme.muted)
      }
      .offset(x: max(0, xPosition(for: tickTime, width: width) - 18))
      .allowsHitTesting(false)
    }
  }

  private func candidateMarker(_ candidate: CandidateSegment, width: CGFloat) -> some View {
    let startX = xPosition(for: candidate.startTime, width: width)
    let endX = xPosition(for: candidate.endTime, width: width)
    let markerWidth = max(markerMinimumWidth, endX - startX)
    let isSelected = candidate.id == selectedCandidateID

    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(markerColor(for: candidate).opacity(isSelected ? 0.75 : 0.45))
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
        )
      Rectangle()
        .fill(markerColor(for: candidate))
        .frame(width: 2)
        .offset(x: max(0, xPosition(for: candidate.peakTime, width: width) - startX))
    }
    .frame(width: markerWidth, height: 32)
    .offset(x: startX)
    .contentShape(Rectangle())
    .onTapGesture {
      onSelectCandidate(candidate)
    }
    .help("候補ピーク \(timeText(candidate.peakTime))")
  }

  private func markerColor(for candidate: CandidateSegment) -> Color {
    switch candidate.userLabel {
    case .accepted:
      return NeomorphicTheme.online
    case .rejected:
      return NeomorphicTheme.negative
    case .uncertain:
      return NeomorphicTheme.caution
    case nil:
      // 未判定の候補は色を付けず、判定済みの色（緑・赤・琥珀）だけが目立つようにする。
      return NeomorphicTheme.ink.opacity(0.65)
    }
  }

  private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
    guard duration > 0 else { return 0 }
    let fraction = min(max(0, time / duration), 1)
    return width * fraction
  }

  private func time(for xPosition: CGFloat, width: CGFloat) -> Double {
    guard width > 0, duration > 0 else { return 0 }
    return duration * min(max(0, xPosition / width), 1)
  }

  private func timeText(_ seconds: Double) -> String {
    let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
    let hours = Int(safeSeconds) / 3_600
    let minutes = Int(safeSeconds) % 3_600 / 60
    let remainingSeconds = Int(safeSeconds) % 60
    if hours > 0 {
      return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
  }
}
