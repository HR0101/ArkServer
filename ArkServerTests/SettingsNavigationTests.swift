// ArkServerTests/SettingsNavigationTests.swift

import Foundation
import Testing
@testable import ArkServer

@Suite(.serialized)
struct SettingsNavigationTests {
  @Test
  func everyPaneIsListedExactlyOnceUnderOneGroup() {
    let grouped = SettingsPane.grouped
    let listed = grouped.flatMap(\.panes)

    #expect(listed.count == SettingsPane.allCases.count)
    #expect(Set(listed) == Set(SettingsPane.allCases))
    // どの項目も、自分が属する見出しの下に並ぶ。
    for entry in grouped {
      #expect(entry.panes.allSatisfy { $0.group == entry.group })
      #expect(!entry.panes.isEmpty)
    }
    // 項目名とアイコンは空でなく、重複もしない。
    #expect(SettingsPane.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    #expect(Set(SettingsPane.allCases.map(\.title)).count == SettingsPane.allCases.count)
  }

  @Test @MainActor
  func openingSettingsRemembersWhereYouWereAndClosingGoesBack() {
    var routing = SettingsRouting()
    let albumID = UUID()

    let opened = routing.opening(from: .album(albumID), pane: .appearance)

    #expect(opened == .settings(.appearance))
    #expect(routing.closing() == .album(albumID))
  }

  @Test @MainActor
  func switchingPanesInsideSettingsKeepsTheOriginalReturnPoint() {
    var routing = SettingsRouting()

    _ = routing.opening(from: .favorites, pane: .connection)
    let second = routing.opening(from: .settings(.connection), pane: .shortcuts)
    let third = routing.opening(from: second, pane: .data)

    #expect(third == .settings(.data))
    // 設定の中で何度項目を切り替えても、戻り先は最初の「お気に入り」のまま。
    #expect(routing.closing() == .favorites)
  }

  @Test @MainActor
  func returnsHomeWhenNothingWasSelectedAndRemembersANewPlaceNextTime() {
    var routing = SettingsRouting()

    _ = routing.opening(from: nil, pane: .connection)
    #expect(routing.closing() == .home)

    // 一度閉じたあと、別の画面から開き直したら、その画面へ戻る。
    _ = routing.opening(from: .trash, pane: .export)
    #expect(routing.closing() == .trash)
  }

  @Test @MainActor
  func recognisesWhetherASelectionIsInsideSettings() {
    #expect(SettingsRouting.isSettings(.settings(.updates)))
    #expect(!SettingsRouting.isSettings(.home))
    #expect(!SettingsRouting.isSettings(.musicVideo))
    #expect(!SettingsRouting.isSettings(nil))
  }
}
