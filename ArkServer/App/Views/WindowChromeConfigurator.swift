import AppKit
import SwiftUI

/// macOS標準のタイトルバーをコンテンツと同じ背景に重ねるためのViewです．
struct WindowChromeConfigurator: NSViewRepresentable {
  let isToolbarHidden: Bool

  func makeNSView(context: Context) -> WindowChromeView {
    let view = WindowChromeView()
    view.isToolbarHidden = isToolbarHidden
    return view
  }

  func updateNSView(_ nsView: WindowChromeView, context: Context) {
    nsView.isToolbarHidden = isToolbarHidden
    nsView.applyWindowChrome()
  }
}

final class WindowChromeView: NSView {
  var isToolbarHidden = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyWindowChrome()
  }

  func applyWindowChrome() {
    guard let window else { return }
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.appearance = NSAppearance(
      named: NeomorphicTheme.isDarkBase ? .darkAqua : .aqua
    )
    // 下地は単色なので、透過ウィンドウにはしない（角の表示も安定する）。
    window.isOpaque = true
    window.backgroundColor = NSColor(NeomorphicTheme.rail)
    window.toolbarStyle = .unifiedCompact
    window.toolbar?.isVisible = !isToolbarHidden
  }
}
