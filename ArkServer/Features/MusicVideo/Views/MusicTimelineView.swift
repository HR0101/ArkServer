// ArkServer/Features/MusicVideo/Views/MusicTimelineView.swift

import SwiftUI

/// 曲の盛り上がり・拍・カットの切り替え位置・再生位置を1本の帯に重ねて見せる。
/// クリックやドラッグで再生位置を動かせる。
struct MusicTimelineView: View {
  let analysis: MusicAnalysis
  let plan: CutPlan?
  let playbackTime: Double
  /// 選択中のカットの番号。タイムライン上で強調する。
  var selectedCutIndex: Int? = nil
  /// ドラッグ中に呼ばれる(再生位置を動かす)。
  let onSeek: (Double) -> Void
  /// クリックまたはドラッグの終わりに呼ばれる(その位置のカットを選ぶ)。
  var onSelect: (Double) -> Void = { _ in }

  var body: some View {
    Canvas { context, size in
      draw(in: &context, size: size)
    }
    .frame(height: 96)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(NeomorphicTheme.control)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      // クリック位置は Canvas の実際の幅に対する割合で扱う。
      GeometryReader { proxy in
        Color.clear
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                guard let time = time(at: value.location.x, width: proxy.size.width) else { return }
                onSeek(time)
              }
              .onEnded { value in
                guard let time = time(at: value.location.x, width: proxy.size.width) else { return }
                onSelect(time)
              }
          )
      }
    }
    .accessibilityLabel("曲の盛り上がりとカット位置")
    .help("クリックでそのカットを選択，ドラッグで再生位置を動かせます")
  }

  private func time(at x: CGFloat, width: CGFloat) -> Double? {
    guard analysis.duration > 0, width > 0 else { return nil }
    return min(1, max(0, Double(x / width))) * analysis.duration
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    guard analysis.duration > 0, size.width > 0 else { return }
    let duration = analysis.duration
    func x(_ time: Double) -> CGFloat { CGFloat(time / duration) * size.width }

    // 盛り上がりの段階を、背景の濃さで示す。
    let hop = analysis.energyHop
    var runStart = 0
    for index in 1...max(1, analysis.intensity.count) {
      let isEnd = index >= analysis.intensity.count
      if isEnd || analysis.intensity[index] != analysis.intensity[runStart] {
        guard runStart < analysis.intensity.count else { break }
        let level = analysis.intensity[runStart]
        let rect = CGRect(
          x: x(Double(runStart) * hop),
          y: 0,
          width: max(1, x(Double(min(index, analysis.intensity.count)) * hop) - x(Double(runStart) * hop)),
          height: size.height
        )
        context.fill(Path(rect), with: .color(NeomorphicTheme.accent.opacity(bandOpacity(level))))
        runStart = index
      }
    }

    // 選択中のカット。
    if let plan, let index = selectedCutIndex, plan.cuts.indices.contains(index) {
      let cut = plan.cuts[index]
      let rect = CGRect(
        x: x(cut.timelineStart),
        y: 0,
        width: max(3, x(cut.timelineEnd) - x(cut.timelineStart)),
        height: size.height
      )
      context.fill(Path(rect), with: .color(NeomorphicTheme.accent.opacity(0.35)))
      context.stroke(Path(rect), with: .color(NeomorphicTheme.accent), lineWidth: 1.5)
    }

    // 盛り上がりの曲線。
    if analysis.energy.count > 1 {
      var line = Path()
      for (index, value) in analysis.energy.enumerated() {
        let point = CGPoint(
          x: x(Double(index) * hop),
          y: size.height - 8 - CGFloat(value) * (size.height - 24)
        )
        if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
      }
      context.stroke(line, with: .color(NeomorphicTheme.ink.opacity(0.75)), lineWidth: 1.5)
    }

    // 拍(下端の短い目盛り)。間隔が詰まりすぎるときは間引く。
    var lastBeatX: CGFloat = -10
    for beat in analysis.beats {
      let position = x(beat)
      guard position - lastBeatX >= 3 else { continue }
      lastBeatX = position
      var tick = Path()
      tick.move(to: CGPoint(x: position, y: size.height))
      tick.addLine(to: CGPoint(x: position, y: size.height - 6))
      context.stroke(tick, with: .color(NeomorphicTheme.muted.opacity(0.7)), lineWidth: 1)
    }

    // カットの切り替え位置(上端の目盛り)。
    if let plan {
      var lastCutX: CGFloat = -10
      for cut in plan.cuts.dropFirst() {
        let position = x(cut.timelineStart)
        guard position - lastCutX >= 2 else { continue }
        lastCutX = position
        var mark = Path()
        mark.move(to: CGPoint(x: position, y: 0))
        mark.addLine(to: CGPoint(x: position, y: 10))
        context.stroke(mark, with: .color(NeomorphicTheme.accent), lineWidth: 1)
      }
    }

    // 再生位置。
    if plan != nil {
      let position = x(min(max(0, playbackTime), duration))
      var head = Path()
      head.move(to: CGPoint(x: position, y: 0))
      head.addLine(to: CGPoint(x: position, y: size.height))
      context.stroke(head, with: .color(NeomorphicTheme.ink), lineWidth: 2)
    }
  }

  private func bandOpacity(_ level: MusicIntensity) -> Double {
    switch level {
    case .calm: return 0.06
    case .medium: return 0.14
    case .intense: return 0.26
    }
  }
}
