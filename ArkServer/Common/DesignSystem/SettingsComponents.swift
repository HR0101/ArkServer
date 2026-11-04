// ArkServer/Common/DesignSystem/SettingsComponents.swift

import SwiftUI

// 設定画面のような「見出し + 行をまとめた面」で画面を組むための共通部品（一般的な設定画面の見た目に倣う）。
// 詳細設定ページとミュージックビデオ画面が使う。
//
//   セクション名（控えめな小さい文字）
//   ┌──────────────────────────────────────────┐
//   │ 項目名                          [ 操作 ] │   ← 行：左に項目名と薄い説明、右に操作
//   │ 薄い説明                                 │
//   ├──────────────────────────────────────────┤   ← 行どうしは細い線で区切る
//   │ 項目名                          ( スイッチ ) │
//   └──────────────────────────────────────────┘
//
// アイコン付きの見出しや色付きの面は使わない。色は、スイッチ・決定ボタン・選択中の印だけにする。

/// 画面を中央の1列に収める幅（参考にした設定画面は約730pt）。
let settingsColumnWidth: CGFloat = 760

/// セクション名と、その下の内容。
struct SettingsSection<Content: View>: View {
  let title: String
  var footer: String? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.appBodyStrong)
        .foregroundStyle(NeomorphicTheme.muted)
        .padding(.horizontal, 2)
        .accessibilityAddTraits(.isHeader)
      content
      if let footer {
        Text(footer)
          .font(.appCaption)
          .foregroundStyle(NeomorphicTheme.muted)
          .padding(.horizontal, 2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// 行をまとめる角丸の面。行の間に細い区切り線を入れる。
struct SettingsGroup<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { subviews in
        ForEach(subviews.indices, id: \.self) { index in
          subviews[index]
          if index < subviews.count - 1 {
            Divider().overlay(NeomorphicTheme.separator)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(GlassCardSurface())
    .clipShape(RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous))
  }
}

/// 1行。左に項目名と薄い説明、右に操作。
struct SettingsRow<Leading: View, Control: View>: View {
  let title: String
  var detail: String? = nil
  @ViewBuilder var leading: Leading
  @ViewBuilder var control: Control

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      leading
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.appBodyStrong)
          .foregroundStyle(NeomorphicTheme.ink)
          .lineLimit(2)
        if let detail {
          Text(detail)
            .font(.appCaption)
            .foregroundStyle(NeomorphicTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      control
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 52)
  }
}

extension SettingsRow where Leading == EmptyView {
  init(title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.detail = detail
    self.leading = EmptyView()
    self.control = control()
  }
}

/// 行の右に置く、小さな操作ボタン（「変更」のような見た目）。
struct QuietButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.appCaptionStrong)
      .foregroundStyle(NeomorphicTheme.ink.opacity(isEnabled ? 1 : 0.4))
      .padding(.horizontal, 11)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(configuration.isPressed ? NeomorphicTheme.controlSelected : NeomorphicTheme.control)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension ButtonStyle where Self == QuietButtonStyle {
  static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// 行の右に置く、スイッチ。
struct SettingsSwitch: View {
  let title: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(title, isOn: $isOn)
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
  }
}
