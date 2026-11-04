// ArkServer/Features/Settings/Views/SettingsSidebarView.swift

import SwiftUI

/// 設定ページの左側。アルバムのサイドバーの代わりに出る、項目の一覧。
/// 選ばれている行は、色を付けず、少し明るい角丸の面にする（一般的な設定画面の選択表示と同じ）。
struct SettingsSidebarView: View {
  let selected: SettingsPane
  let onSelect: (SettingsPane) -> Void
  let onBack: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(NeomorphicTheme.muted)
        .help("元の画面へ戻る")
        .accessibilityLabel("設定を閉じて戻る")
        .accessibilityIdentifier("settings.back")

        Text("設定")
          .font(.appTitle)
          .foregroundStyle(NeomorphicTheme.ink)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.top, 14)
      .padding(.bottom, 10)

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(SettingsPane.grouped, id: \.group) { entry in
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.group.rawValue)
                .font(.appCaption)
                .foregroundStyle(NeomorphicTheme.muted)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
              ForEach(entry.panes) { pane in
                row(pane)
              }
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func row(_ pane: SettingsPane) -> some View {
    let isSelected = pane == selected
    return Button {
      onSelect(pane)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: pane.symbol)
          .font(.system(size: 13))
          .foregroundStyle(isSelected ? NeomorphicTheme.ink : NeomorphicTheme.muted)
          .frame(width: 18)
        Text(pane.title)
          .font(.appBody)
          .foregroundStyle(NeomorphicTheme.ink)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? NeomorphicTheme.selection : Color.clear)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
  }
}
