// ArkServer/Features/MusicVideo/Views/MusicVideoFullScreenPresenter.swift

import AppKit
import SwiftUI

/// 全画面のウィンドウ。枠の無い窓なので、そのままではキー入力を受けられない。受けられるようにして、Esc で閉じる。
private final class FullScreenWindow: NSWindow {
  var onCancel: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// Esc。
  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }
}

/// プレビューを、画面全体を覆うウィンドウで開く。
///
/// macOS 標準の全画面(`toggleFullScreen`)は使わない。アプリ本体の窓が全画面になっているとき、
/// 2つ目の窓は全画面に入れず、小さな窓のまま残ってしまう(`windowDidFailToEnterFullScreen`)。
/// 画面と同じ大きさの枠なしウィンドウをメニューバーとDockより上に出せば、本体が全画面でもそうでなくても、同じように全画面になる。
/// 全画面をやめる(Esc・F・ダブルクリック・操作部のボタン)と、ウィンドウを閉じて、元の画面へ戻る。
@MainActor
final class MusicVideoFullScreenPresenter: NSObject, NSWindowDelegate {
  private var window: FullScreenWindow?
  /// 全画面を開く前に操作していた窓。閉じたあと、ここへ操作を戻す。
  private weak var previousKeyWindow: NSWindow?
  private var screenObserver: NSObjectProtocol?

  var isPresented: Bool { window != nil }

  func present(viewModel: MusicVideoViewModel) {
    // 映像ができていないときや、すでに開いているときは、何もしない(開いていれば前面に出す)。
    guard viewModel.plan != nil else { return }
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }

    // 元の画面(いま操作しているウィンドウ)があるディスプレイを覆う。(置かないと、別のディスプレイに出ることがある)
    previousKeyWindow = NSApp.keyWindow
    guard let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }

    let content = MusicVideoFullScreenView(viewModel: viewModel) { [weak self] in self?.close() }
    let window = FullScreenWindow(
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    window.title = "プレビュー"
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.isOpaque = true
    window.hasShadow = false
    window.animationBehavior = .none
    // メニューバーとDockの上に出す。本体が全画面(別のSpace)のときも、そのSpaceの上に重ねる。
    window.level = .mainMenu + 1
    window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
    // 別のアプリに切り替えたときは隠れて、戻ると出る(他のアプリの上に居座らない)。
    window.hidesOnDeactivate = true
    window.contentView = NSHostingView(rootView: content)
    window.delegate = self
    window.onCancel = { [weak self] in self?.close() }
    self.window = window

    // ディスプレイの接続が変わったときは、覆う大きさを合わせ直す。
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.fitToScreen() }
    }

    window.setFrame(screen.frame, display: true)
    NSApp.activate(ignoringOtherApps: true)
    window.orderFrontRegardless()
    window.makeKey()
  }

  func close() {
    window?.close()
  }

  /// 覆うディスプレイの大きさに合わせる。ディスプレイが無くなっていたら、閉じる。
  private func fitToScreen() {
    guard let window else { return }
    guard let screen = window.screen ?? NSScreen.main else {
      close()
      return
    }
    window.setFrame(screen.frame, display: true)
  }

  // MARK: NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    // 閉じる前に押されたキーの入力が残らないよう、元の窓へ操作を戻す。
    let previous = previousKeyWindow
    window = nil
    previousKeyWindow = nil
    if let previous, previous.isVisible { previous.makeKeyAndOrderFront(nil) }
  }
}
