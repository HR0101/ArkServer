// ArkServer/Features/MusicVideo/Views/MusicVideoPlayerViews.swift

import AppKit
import AVKit
import SwiftUI

// プレビューの映像と、再生の操作部。小さなプレビュー(MusicVideoPlayerPane)と全画面(MusicVideoFullScreenView)で、
// 同じ操作部(MusicVideoPlayerControls)を使う。映像の上に重ねるので、色は背景のテーマに依らず白と黒にする。

// MARK: - 映像の表示

/// クリックとダブルクリックを、AppKit の `clickCount` で受ける `AVPlayerView`。
/// (SwiftUI のダブルタップは、1回タップの操作と一緒に付けると検知されないことがあるため)
/// 上に重ねた SwiftUI の操作部(ボタンなど)は、SwiftUI 側が先に受けるので、そのまま押せる。
private final class ClickableAVPlayerView: AVPlayerView {
  var onClick: (() -> Void)?
  var onDoubleClick: (() -> Void)?
  /// 下の端から、この高さまでは、クリックを受けずに通す(上に重ねた操作部のボタンが押せるように)。
  var passThroughBottom: CGFloat = 0

  override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2 {
      onDoubleClick?()
    } else {
      onClick?()
    }
  }

  /// 表示面の中のクリックは、AVPlayerView の内部の部品ではなく、このビューが受ける。
  /// ただし、操作部が重なっている下の帯は受けずに通し、SwiftUI のボタンに任せる。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    let distanceFromBottom = isFlipped ? bounds.height - local.y : local.y
    return distanceFromBottom < passThroughBottom ? nil : self
  }

  /// ウィンドウが前面でなくても、最初のクリックをそのまま操作として受ける。
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// キーは SwiftUI のショートカットで受ける(AVPlayerView 標準のキー操作は使わない)。
  override var acceptsFirstResponder: Bool { false }
}

/// 操作部を持たない、映像だけの表示面。操作は自前の操作部で行う(AVKit 標準の操作部にはスキップなどが無いため)。
/// - Parameters:
///   - onClick: 映像をクリックしたとき。
///   - onDoubleClick: ダブルクリックしたとき。1回目のクリックで `onClick` も呼ばれている。
struct MusicVideoPlayerSurface: NSViewRepresentable {
  let player: AVPlayer
  /// 下の端から、この高さまでは、操作部が重なっているのでクリックを通す。操作部が隠れているときは 0。
  var passThroughBottom: CGFloat = 0
  var onClick: () -> Void = {}
  var onDoubleClick: () -> Void = {}

  func makeNSView(context: Context) -> AVPlayerView {
    let view = ClickableAVPlayerView()
    view.controlsStyle = .none
    view.videoGravity = .resizeAspect
    view.showsFullScreenToggleButton = false
    view.player = player
    view.onClick = onClick
    view.onDoubleClick = onDoubleClick
    view.passThroughBottom = passThroughBottom
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
    guard let view = view as? ClickableAVPlayerView else { return }
    view.onClick = onClick
    view.onDoubleClick = onDoubleClick
    view.passThroughBottom = passThroughBottom
  }
}

// MARK: - 小さなプレビュー

/// 映像と、その下に重ねる操作部。一時停止中かマウスを乗せたときだけ操作部を出す。
/// クリックで再生/一時停止、ダブルクリックで全画面。
struct MusicVideoPlayerPane: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  let onFullScreen: () -> Void
  @State private var isHovering = false
  /// 操作部の高さ(操作部が出ているあいだ、表示面はその帯のクリックを通す)。
  @State private var controlsHeight: CGFloat = 0

  private var showsControls: Bool { isHovering || !viewModel.isPlaying }

  var body: some View {
    ZStack(alignment: .bottom) {
      MusicVideoPlayerSurface(
        player: viewModel.player,
        passThroughBottom: showsControls ? controlsHeight : 0,
        onClick: { viewModel.togglePlayback() },
        onDoubleClick: {
          // 1回目のクリックで切り替えた再生/一時停止を戻してから、全画面にする。
          viewModel.togglePlayback()
          onFullScreen()
        }
      )
      if showsControls {
        MusicVideoPlayerControls(viewModel: viewModel, style: .compact, isFullScreen: false, onToggleFullScreen: onFullScreen)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
          .transition(.opacity)
      }
    }
    .onHover { isHovering = $0 }
    .animation(.easeInOut(duration: 0.15), value: showsControls)
  }
}

// MARK: - 操作部

enum MusicVideoPlayerControlsStyle {
  /// 小さなプレビュー用。幅が狭くても収まるよう、段を分ける。
  case compact
  /// 全画面用。1段に並べる。
  case full
}

/// シークバーと、再生・スキップ・ミュート・全画面の操作。
struct MusicVideoPlayerControls: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  let style: MusicVideoPlayerControlsStyle
  let isFullScreen: Bool
  let onToggleFullScreen: () -> Void

  private var isFull: Bool { style == .full }

  var body: some View {
    VStack(spacing: isFull ? 12 : 6) {
      MusicVideoSeekBar(
        duration: viewModel.playbackDuration,
        time: viewModel.playbackTime,
        cutStarts: viewModel.plan?.cuts.map(\.timelineStart) ?? [],
        onScrub: { viewModel.scrub(to: $0) },
        onCommit: { viewModel.seek(to: $0) }
      )
      if isFull {
        fullRow
      } else {
        compactRows
      }
    }
    .padding(.horizontal, isFull ? 28 : 12)
    .padding(.top, isFull ? 44 : 30)
    .padding(.bottom, isFull ? 24 : 10)
    .background(
      LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
    )
    .foregroundStyle(.white)
  }

  // MARK: 並べ方

  private var compactRows: some View {
    VStack(spacing: 4) {
      HStack(spacing: 4) {
        timeLabel
        Spacer(minLength: 4)
        muteButton(size: 13)
        fullScreenButton(size: 13)
      }
      transport(buttonSize: 15, playSize: 22, spacing: 8)
    }
  }

  private var fullRow: some View {
    HStack(spacing: 18) {
      timeLabel
        .frame(minWidth: 120, alignment: .leading)
      Spacer(minLength: 8)
      transport(buttonSize: 22, playSize: 34, spacing: 22)
      Spacer(minLength: 8)
      cutLabel
        .frame(minWidth: 120, alignment: .trailing)
      muteButton(size: 18)
      fullScreenButton(size: 18)
    }
  }

  private func transport(buttonSize: CGFloat, playSize: CGFloat, spacing: CGFloat) -> some View {
    HStack(spacing: spacing) {
      iconButton("backward.end.fill", label: "前のカット（,）", size: buttonSize, id: "musicvideo.player.previousCut") {
        viewModel.skipToCut(-1)
      }
      iconButton("gobackward.10", label: "10秒戻る（J）", size: buttonSize, id: "musicvideo.player.back10") {
        viewModel.skip(by: -10)
      }
      iconButton(
        viewModel.isPlaying ? "pause.fill" : "play.fill",
        label: viewModel.isPlaying ? "一時停止（スペース）" : "再生（スペース）",
        size: playSize,
        id: "musicvideo.player.playPause"
      ) {
        viewModel.togglePlayback()
      }
      iconButton("goforward.10", label: "10秒進む（L）", size: buttonSize, id: "musicvideo.player.forward10") {
        viewModel.skip(by: 10)
      }
      iconButton("forward.end.fill", label: "次のカット（.）", size: buttonSize, id: "musicvideo.player.nextCut") {
        viewModel.skipToCut(1)
      }
    }
  }

  private func muteButton(size: CGFloat) -> some View {
    iconButton(
      viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
      label: viewModel.isMuted ? "音を出す（M）" : "音を消す（M）",
      size: size,
      id: "musicvideo.player.mute"
    ) {
      viewModel.isMuted.toggle()
    }
  }

  private func fullScreenButton(size: CGFloat) -> some View {
    iconButton(
      isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
      label: isFullScreen ? "全画面をやめる（F・Esc・ダブルクリック）" : "全画面で見る（ダブルクリック）",
      size: size,
      id: "musicvideo.player.fullScreen",
      action: onToggleFullScreen
    )
  }

  private func iconButton(
    _ symbol: String,
    label: String,
    size: CGFloat,
    id: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size))
        .frame(width: size + 10, height: size + 8)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  // MARK: 文字

  private var timeLabel: some View {
    Text("\(Self.clock(viewModel.playbackTime)) / \(Self.clock(viewModel.playbackDuration))")
      .font(.appCaption.monospacedDigit())
      .lineLimit(1)
  }

  private var cutLabel: some View {
    Group {
      if let number = viewModel.currentCutNumber, let total = viewModel.plan?.cuts.count {
        Text("カット \(number)/\(total)")
      }
    }
    .font(.appCaption.monospacedDigit())
    .lineLimit(1)
  }

  static func clock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

// MARK: - シークバー

/// 再生位置を示し、クリックやドラッグで動かせる細い棒。カットの切り替え位置に印を付ける。
struct MusicVideoSeekBar: View {
  let duration: Double
  let time: Double
  let cutStarts: [Double]
  /// ドラッグしている間、続けて呼ばれる(軽く動かす)。
  let onScrub: (Double) -> Void
  /// クリックまたはドラッグの終わりに呼ばれる(正確な位置へ合わせる)。
  let onCommit: (Double) -> Void

  @State private var dragTime: Double?

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      let shown = dragTime ?? time
      let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.28))
          .frame(height: 4)
        Capsule()
          .fill(Color.white)
          .frame(width: max(4, width * fraction), height: 4)
        Canvas { context, size in
          drawCutMarks(in: &context, size: size)
        }
        .allowsHitTesting(false)
        Circle()
          .fill(Color.white)
          .frame(width: dragTime == nil ? 10 : 14, height: dragTime == nil ? 10 : 14)
          .offset(x: width * fraction - (dragTime == nil ? 5 : 7))
          .shadow(color: .black.opacity(0.4), radius: 2)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let target = seconds(at: value.location.x, width: width)
            dragTime = target
            onScrub(target)
          }
          .onEnded { value in
            let target = seconds(at: value.location.x, width: width)
            dragTime = nil
            onCommit(target)
          }
      )
    }
    .frame(height: 20)
    .accessibilityElement()
    .accessibilityLabel("再生位置")
    .accessibilityValue("\(MusicVideoPlayerControls.clock(time)) / \(MusicVideoPlayerControls.clock(duration))")
  }

  private func seconds(at x: CGFloat, width: CGFloat) -> Double {
    guard duration > 0 else { return 0 }
    return min(max(Double(x / width), 0), 1) * duration
  }

  /// カットの切り替え位置に、短い縦線を引く。間隔が詰まりすぎる所は間引く。
  private func drawCutMarks(in context: inout GraphicsContext, size: CGSize) {
    guard duration > 0 else { return }
    var lastX = -10.0
    for start in cutStarts where start > 0 {
      let x = start / duration * size.width
      guard x - lastX >= 3 else { continue }
      lastX = x
      let rect = CGRect(x: x - 0.5, y: size.height / 2 - 5, width: 1, height: 10)
      context.fill(Path(rect), with: .color(.white.opacity(0.45)))
    }
  }
}

// MARK: - 全画面

/// 全画面のウィンドウの中身。映像を画面いっぱいに出し、操作部は、しばらく動かさないと隠れる。
struct MusicVideoFullScreenView: View {
  @ObservedObject var viewModel: MusicVideoViewModel
  let close: () -> Void

  @State private var controlsVisible = true
  @State private var hideTask: Task<Void, Never>?
  @State private var controlsHeight: CGFloat = 0

  var body: some View {
    ZStack {
      Color.black
      MusicVideoPlayerSurface(
        player: viewModel.player,
        passThroughBottom: controlsVisible ? controlsHeight : 0,
        onClick: { viewModel.togglePlayback() },
        onDoubleClick: {
          viewModel.togglePlayback()
          close()
        }
      )

      VStack(spacing: 0) {
        Spacer()
        MusicVideoPlayerControls(viewModel: viewModel, style: .full, isFullScreen: true, onToggleFullScreen: close)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
      }
      .opacity(controlsVisible ? 1 : 0)
      .allowsHitTesting(controlsVisible)
      .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }
    .ignoresSafeArea()
    .onContinuousHover { phase in
      if case .active = phase { revealControls() }
    }
    .onAppear(perform: revealControls)
    .onChange(of: viewModel.isPlaying) { revealControls() }
    // 映像が無くなった(作り直しなど)ときは、全画面を閉じる。
    .onChange(of: viewModel.plan == nil) { _, isGone in
      if isGone { close() }
    }
    .background(shortcuts)
    // Esc。ウィンドウ側(`cancelOperation`)でも受けているが、SwiftUI のビューが先に受けた場合に備える。
    .onExitCommand(perform: close)
    .accessibilityIdentifier("musicvideo.fullScreen")
  }

  /// 操作部を出し、再生中なら少し待って隠す(一時停止中は出したままにする)。
  private func revealControls() {
    controlsVisible = true
    hideTask?.cancel()
    guard viewModel.isPlaying else { return }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled, viewModel.isPlaying else { return }
      controlsVisible = false
      NSCursor.setHiddenUntilMouseMoves(true)
    }
  }

  /// キーボードの操作。全画面のウィンドウの中だけで効く(ほかの画面の入力とぶつからない)。
  private var shortcuts: some View {
    ZStack {
      shortcut(.space) { viewModel.togglePlayback() }
      shortcut("k") { viewModel.togglePlayback() }
      shortcut(.leftArrow) { viewModel.skip(by: -5) }
      shortcut(.rightArrow) { viewModel.skip(by: 5) }
      shortcut(",") { viewModel.skipToCut(-1) }
      shortcut(".") { viewModel.skipToCut(1) }
      shortcut("j") { viewModel.skip(by: -10) }
      shortcut("l") { viewModel.skip(by: 10) }
      shortcut("m") { viewModel.isMuted.toggle() }
      shortcut("f") { close() }
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }

  private func shortcut(
    _ key: KeyEquivalent,
    modifiers: EventModifiers = [],
    action: @escaping () -> Void
  ) -> some View {
    Button("", action: {
      action()
      revealControls()
    })
    .keyboardShortcut(key, modifiers: modifiers)
  }
}
