// ArkServer/Features/MusicVideo/Views/MusicVideoFullScreenPresenter.swift

import AppKit
import SwiftUI

/// プレビューを、macOS 標準の全画面ウィンドウで開く。
/// 全画面をやめる(Esc・F・ダブルクリック・操作部のボタン)と、ウィンドウごと閉じて、元の画面へ戻る。
@MainActor
final class MusicVideoFullScreenPresenter: NSObject, NSWindowDelegate {
  private var window: NSWindow?

  var isPresented: Bool { window != nil }

  func present(viewModel: MusicVideoViewModel) {
    // 映像ができていないときや、すでに開いているときは、何もしない(開いていれば前面に出す)。
    guard viewModel.plan != nil else { return }
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }

    let content = MusicVideoFullScreenView(viewModel: viewModel) { [weak self] in self?.close() }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "プレビュー"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.collectionBehavior = [.fullScreenPrimary]
    window.contentView = NSHostingView(rootView: content)
    window.delegate = self
    // 元の画面(いま操作しているウィンドウ)があるディスプレイの中央に置いてから、全画面にする。
    // (置かないと、別のディスプレイで全画面になることがある)
    let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      let size = window.frame.size
      window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    } else {
      window.center()
    }
    self.window = window

    window.makeKeyAndOrderFront(nil)
    window.toggleFullScreen(nil)
  }

  func close() {
    window?.close()
  }

  // MARK: NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    window = nil
  }

  /// 全画面をやめたら、通常サイズのウィンドウは残さず閉じる。
  func windowDidExitFullScreen(_ notification: Notification) {
    close()
  }
}
