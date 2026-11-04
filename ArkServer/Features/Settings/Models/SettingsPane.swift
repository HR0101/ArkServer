// ArkServer/Features/Settings/Models/SettingsPane.swift

import Foundation

/// 設定ページの項目（左のサイドバーに並ぶ1つ1つ）。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
  case connection
  case appearance
  case data
  case protection
  case performance
  case export
  case updates
  case shortcuts

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connection: return "接続・認証"
    case .appearance: return "外観"
    case .data: return "データの安全"
    case .protection: return "サーバー保護"
    case .performance: return "パフォーマンス"
    case .export: return "エクスポート"
    case .updates: return "アップデート"
    case .shortcuts: return "ショートカットキー"
    }
  }

  var symbol: String {
    switch self {
    case .connection: return "wifi"
    case .appearance: return "circle.lefthalf.filled"
    case .data: return "externaldrive"
    case .protection: return "lock.shield"
    case .performance: return "speedometer"
    case .export: return "square.and.arrow.up"
    case .updates: return "arrow.triangle.2.circlepath"
    case .shortcuts: return "keyboard"
    }
  }

  /// サイドバーでの見出しのまとまり。
  enum Group: String, CaseIterable, Identifiable {
    case general = "基本"
    case library = "ライブラリとサーバー"
    case app = "アプリ"
    var id: String { rawValue }
  }

  var group: Group {
    switch self {
    case .connection, .appearance: return .general
    case .data, .protection, .performance, .export: return .library
    case .updates, .shortcuts: return .app
    }
  }

  /// サイドバーに出す順の、(見出し, 項目) の一覧。
  static var grouped: [(group: Group, panes: [SettingsPane])] {
    Group.allCases.map { group in (group, allCases.filter { $0.group == group }) }
  }
}

/// 設定ページを開いたときに「元いた画面」を覚え、閉じるときに戻す。
///
/// 設定の中で項目を切り替えても、戻り先は最初に開いたときの画面のまま。
struct SettingsRouting: Equatable {
  private(set) var returnSelection: NavigationSelection = .home

  /// `current` から設定を開くときの、新しい選択を返す。すでに設定の中なら、戻り先は変えない。
  mutating func opening(from current: NavigationSelection?, pane: SettingsPane) -> NavigationSelection {
    if !Self.isSettings(current) {
      returnSelection = current ?? .home
    }
    return .settings(pane)
  }

  /// 設定を閉じたあとに出す選択。
  func closing() -> NavigationSelection {
    returnSelection
  }

  static func isSettings(_ selection: NavigationSelection?) -> Bool {
    if case .settings = selection { return true }
    return false
  }
}
