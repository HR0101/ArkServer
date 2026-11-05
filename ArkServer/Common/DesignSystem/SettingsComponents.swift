// ArkServer/Common/DesignSystem/SettingsComponents.swift

import AppKit
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
    Toggle(isOn: $isOn) { EmptyView() }
      .toggleStyle(AppToggleStyle())
      .accessibilityLabel(title)
      .controlSize(.small)
  }
}

// MARK: - アプリ共通の選択パネル

private struct AppChoiceDismissKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}

private struct AppChoiceNestedKey: EnvironmentKey {
  static let defaultValue = false
}

private extension EnvironmentValues {
  var appChoiceDismiss: (() -> Void)? {
    get { self[AppChoiceDismissKey.self] }
    set { self[AppChoiceDismissKey.self] = newValue }
  }
  var appChoiceIsNested: Bool {
    get { self[AppChoiceNestedKey.self] }
    set { self[AppChoiceNestedKey.self] = newValue }
  }
}

/// 標準メニューの代わりに使う。入れ子は同じパネルの中で展開する。
struct AppChoiceMenu<Content: View, Label: View>: View {
  var title: String? = nil
  @ViewBuilder var content: Content
  @ViewBuilder var label: Label
  @Environment(\.appChoiceIsNested) private var isNested
  @State private var isPresented = false
  @State private var isExpanded = false

  var body: some View {
    if isNested {
      VStack(alignment: .leading, spacing: 4) {
        AppChoiceRowButton(action: { isExpanded.toggle() }) {
          HStack(spacing: 12) {
            label
            Spacer(minLength: 8)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(NeomorphicTheme.muted)
          }
        }
        if isExpanded {
          AppChoiceItems(content: { content })
            .padding(.leading, 12)
        }
      }
    } else {
      Button { isPresented.toggle() } label: {
        HStack(spacing: 8) {
          label
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(NeomorphicTheme.muted)
        }
      }
      .buttonStyle(.quiet)
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        AppChoiceSurface(close: { isPresented = false }) {
          if let title { Text(title) } else { label }
        } content: {
          AppChoiceItems(content: { content })
        }
        .environment(\.appChoiceDismiss, { isPresented = false })
        .environment(\.appChoiceIsNested, true)
      }
    }
  }
}

extension AppChoiceMenu where Label == Text {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
    self.label = Text(title)
  }
}

/// .tagをそのまま使い，既存の選択値・Binding・任意値の選択を保つ。
struct AppChoicePicker<SelectionValue: Hashable, Content: View>: View {
  let title: String
  @Binding var selection: SelectionValue
  @ViewBuilder var content: Content
  @Environment(\.appChoiceIsNested) private var isNested

  init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
    self.title = title
    self._selection = selection
    self.content = content()
  }

  var body: some View {
    Group(subviews: content) { options in
      let selected = options.first { $0.containerValues.hasTag(selection) }
      VStack(alignment: .leading, spacing: 4) {
        if isNested {
          Text(title)
            .font(.appCaptionStrong)
            .foregroundStyle(NeomorphicTheme.muted)
            .padding(.horizontal, 12)
        }
        AppChoiceMenu(title: title) {
          ForEach(options) { option in
            if let value = option.containerValues.tag(for: SelectionValue.self) {
              AppChoicePickerRow(value: value, selection: $selection) { option }
            }
          }
        } label: {
          if let selected { selected } else { Text(title) }
        }
      }
      .accessibilityLabel(title)
    }
  }
}

private struct AppChoicePickerRow<Value: Hashable, Label: View>: View {
  let value: Value
  @Binding var selection: Value
  @ViewBuilder var label: Label
  @Environment(\.appChoiceDismiss) private var dismissPanel

  var body: some View {
    AppChoiceRowButton(isSelected: selection == value, action: {
      selection = value
      dismissPanel?()
    }) {
      HStack(spacing: 12) {
        label
        Spacer(minLength: 8)
        Group {
          if selection == value {
            Image(systemName: "checkmark")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(NeomorphicTheme.accent)
          } else {
            Color.clear
          }
        }
        .frame(width: 16, height: 16)
      }
    }
    .accessibilityAddTraits(selection == value ? .isSelected : [])
  }
}

/// セクション・動的な行・条件付き項目を展開し，見出しの階層を保つ。
private struct AppChoiceItems<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(sections: content) { section in
        VStack(alignment: .leading, spacing: 4) {
          if !section.header.isEmpty {
            ForEach(section.header) { header in
              header
                .font(.appCaptionStrong)
                .foregroundStyle(NeomorphicTheme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
            }
          }
          ForEach(section.content) { item in
            item.frame(maxWidth: .infinity, alignment: .leading)
          }
          if !section.footer.isEmpty {
            ForEach(section.footer) { footer in
              footer.font(.appCaption).foregroundStyle(NeomorphicTheme.muted)
            }
          }
        }
      }
    }
    .font(.appBody)
    .buttonStyle(AppChoiceActionStyle())
    .toggleStyle(AppToggleStyle(isCheckbox: true))
    .labelStyle(.titleAndIcon)
  }
}

private struct AppChoiceSurface<Header: View, Content: View>: View {
  let close: () -> Void
  @ViewBuilder var header: Header
  @ViewBuilder var content: Content
  @State private var contentHeight: CGFloat = 44
  private let maximumHeight: CGFloat = 420

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        header
          .font(.appBodyStrong)
          .lineLimit(2)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .medium))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("選択パネルを閉じる")
      }
      .padding(16)
      Divider().overlay(NeomorphicTheme.separator)
      ScrollView {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
      }
      .frame(height: min(maximumHeight, max(44, contentHeight)))
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: 340)
    .background(NeomorphicTheme.canvas)
    .foregroundStyle(NeomorphicTheme.ink)
    .tint(NeomorphicTheme.accent)
    .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
    .background(AppChoiceFocusBridge())
    .onKeyPress(.escape) { close(); return .handled }
    .onKeyPress(.downArrow) {
      NSApp.keyWindow?.selectNextKeyView(nil)
      return .handled
    }
    .onKeyPress(.upArrow) {
      NSApp.keyWindow?.selectPreviousKeyView(nil)
      return .handled
    }
  }
}

/// パネルを閉じてから，元のButtonの処理を一度だけ実行する。
private struct AppChoiceActionStyle: PrimitiveButtonStyle {
  @Environment(\.appChoiceDismiss) private var dismissPanel

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    let row = AppChoiceRowButton(role: configuration.role, action: {
      dismissPanel?()
      DispatchQueue.main.async { configuration.trigger() }
    }) { configuration.label }
    if configuration.role == .cancel {
      row.keyboardShortcut(.cancelAction)
    } else {
      row
    }
  }
}

// MARK: - 右クリックと確認の選択パネル

extension View {
  func appContextMenu<Choices: View>(@ViewBuilder content: @escaping () -> Choices) -> some View {
    modifier(AppContextChoiceModifier(choices: content))
  }

  func appAlert<Actions: View, Message: View>(
    _ title: String, isPresented: Binding<Bool>,
    @ViewBuilder actions: @escaping () -> Actions,
    @ViewBuilder message: @escaping () -> Message
  ) -> some View {
    sheet(isPresented: isPresented) {
      AppChoiceDialog(title: title, close: { isPresented.wrappedValue = false }, actions: actions, message: message)
    }
  }

  func appConfirmationPanel<Actions: View, Message: View>(
    _ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
    @ViewBuilder actions: @escaping () -> Actions,
    @ViewBuilder message: @escaping () -> Message
  ) -> some View {
    appAlert(title, isPresented: isPresented, actions: actions, message: message)
  }

  func appConfirmationPanel<Data, Actions: View, Message: View>(
    _ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
    presenting data: Data?,
    @ViewBuilder actions: @escaping (Data) -> Actions,
    @ViewBuilder message: @escaping (Data) -> Message
  ) -> some View {
    sheet(isPresented: isPresented) {
      if let data {
        AppChoiceDialog(title: title, close: { isPresented.wrappedValue = false }) {
          actions(data)
        } message: {
          message(data)
        }
      }
    }
  }
}

private struct AppChoiceDialog<Actions: View, Message: View>: View {
  let title: String
  let close: () -> Void
  @ViewBuilder var actions: Actions
  @ViewBuilder var message: Message

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(title)
        .font(.appTitle)
        .foregroundStyle(NeomorphicTheme.ink)
        .accessibilityAddTraits(.isHeader)
      message
        .font(.appBody)
        .foregroundStyle(NeomorphicTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
      Divider().overlay(NeomorphicTheme.separator)
      AppChoiceItems(content: { actions })
        .textFieldStyle(.roundedBorder)
        .environment(\.appChoiceDismiss, close)
        .environment(\.appChoiceIsNested, true)
    }
    .padding(24)
    .frame(width: 480)
    .background(NeomorphicTheme.canvas)
    .tint(NeomorphicTheme.accent)
    .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
    .interactiveDismissDisabled()
  }
}

private struct AppContextChoiceModifier<Choices: View>: ViewModifier {
  @ViewBuilder var choices: Choices
  @State private var isPresented = false
  @State private var anchor = UnitPoint.center

  func body(content: Content) -> some View {
    content
      .overlay {
        AppRightClickAnchor { point in
          anchor = point
          isPresented = true
        }
      }
      .popover(isPresented: $isPresented, attachmentAnchor: .point(anchor), arrowEdge: .top) {
        AppChoiceSurface(close: { isPresented = false }) {
          Text("項目の操作")
        } content: {
          AppChoiceItems(content: { choices })
        }
        .environment(\.appChoiceDismiss, { isPresented = false })
        .environment(\.appChoiceIsNested, true)
      }
  }
}

/// 左クリック・ドラッグ・スクロールは元のビューへ渡し，右クリックだけを受け取る。
private struct AppRightClickAnchor: NSViewRepresentable {
  let open: (UnitPoint) -> Void

  func makeNSView(context: Context) -> AnchorView { AnchorView(open: open) }
  func updateNSView(_ view: AnchorView, context: Context) { view.open = open }

  final class AnchorView: NSView {
    var open: (UnitPoint) -> Void

    init(open: @escaping (UnitPoint) -> Void) {
      self.open = open
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent else { return nil }
      let isContextClick = event.type == .rightMouseDown || event.type == .rightMouseUp
        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
      return isContextClick ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) { showPanel(for: event) }
    override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control) { showPanel(for: event) }
    }

    private func showPanel(for event: NSEvent) {
      guard bounds.width > 0, bounds.height > 0 else { return }
      let point = convert(event.locationInWindow, from: nil)
      let x = min(1, max(0, point.x / bounds.width))
      let y = min(1, max(0, point.y / bounds.height))
      open(UnitPoint(x: x, y: isFlipped ? y : 1 - y))
    }
  }
}

// MARK: - 時刻の選択

struct AppTimePicker: View {
  let title: String
  @Binding var selection: Date
  @State private var errorMessage: String?

  init(_ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents = .hourAndMinute) {
    self.title = title
    self._selection = selection
  }

  private var hour: Int { Calendar.current.component(.hour, from: selection) }
  private var minute: Int { Calendar.current.component(.minute, from: selection) }

  var body: some View {
    AppChoiceMenu(title: title) {
      HStack(spacing: 12) {
        timeField("時", value: Binding(get: { hour }, set: { setTime(hour: $0, minute: minute) }), range: 0...23)
        Text(":").font(.appMonoBody).foregroundStyle(NeomorphicTheme.muted)
        timeField("分", value: Binding(get: { minute }, set: { setTime(hour: hour, minute: $0) }), range: 0...59)
      }
      .padding(8)
      if let errorMessage {
        Text(errorMessage).font(.appCaption).foregroundStyle(.red)
      }
    } label: {
      HStack(spacing: 12) {
        Text(title)
        Spacer(minLength: 0)
        Text(String(format: "%02d:%02d", hour, minute)).font(.appMonoBody)
      }
    }
  }

  private func timeField(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
    HStack(spacing: 8) {
      TextField(label, value: value, format: .number.grouping(.never))
        .textFieldStyle(.plain)
        .font(.appTitle.monospacedDigit())
        .multilineTextAlignment(.center)
        .frame(width: 44)
        .accessibilityLabel(label)
      Text(label).font(.appCaption).foregroundStyle(NeomorphicTheme.muted)
      VStack(spacing: 4) {
        Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) } label: {
          Image(systemName: "chevron.up").frame(width: 20, height: 16)
        }
        .disabled(value.wrappedValue >= range.upperBound)
        .accessibilityLabel("\(label)を増やす")
        Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) } label: {
          Image(systemName: "chevron.down").frame(width: 20, height: 16)
        }
        .disabled(value.wrappedValue <= range.lowerBound)
        .accessibilityLabel("\(label)を減らす")
      }
      .font(.system(size: 9, weight: .medium))
      .buttonStyle(.plain)
    }
    .padding(8)
    .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 8))
  }

  private func setTime(hour: Int, minute: Int) {
    guard (0...23).contains(hour), (0...59).contains(minute) else { return }
    let second = Calendar.current.component(.second, from: selection)
    guard let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: selection) else {
      errorMessage = "時刻を設定できませんでした．別の時刻を選んでください．"
      return
    }
    errorMessage = nil
    selection = date
  }
}

/// 数値の増減ボタンも共通の面で描く。元のBindingまたは増減コールバックを使う。
struct AppNumberStepper<Label: View>: View {
  let onIncrement: () -> Void
  let onDecrement: () -> Void
  var canIncrement = true
  var canDecrement = true
  @ViewBuilder var label: Label

  init(onIncrement: @escaping () -> Void, onDecrement: @escaping () -> Void, @ViewBuilder label: () -> Label) {
    self.onIncrement = onIncrement
    self.onDecrement = onDecrement
    self.label = label()
  }

  init<Value: Strideable>(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1, @ViewBuilder label: () -> Label) {
    onIncrement = { value.wrappedValue = min(bounds.upperBound, value.wrappedValue.advanced(by: step)) }
    onDecrement = { value.wrappedValue = max(bounds.lowerBound, value.wrappedValue.advanced(by: -step)) }
    canIncrement = value.wrappedValue < bounds.upperBound
    canDecrement = value.wrappedValue > bounds.lowerBound
    self.label = label()
  }

  var body: some View {
    HStack(spacing: 8) {
      label
      VStack(spacing: 2) {
        Button(action: onIncrement) { Image(systemName: "chevron.up").frame(width: 24, height: 16) }
          .disabled(!canIncrement)
          .accessibilityLabel("値を増やす")
        Button(action: onDecrement) { Image(systemName: "chevron.down").frame(width: 24, height: 16) }
          .disabled(!canDecrement)
          .accessibilityLabel("値を減らす")
      }
      .font(.system(size: 9, weight: .medium))
      .buttonStyle(.plain)
      .background(NeomorphicTheme.control, in: RoundedRectangle(cornerRadius: 4))
    }
  }
}

extension AppNumberStepper where Label == Text {
  init<Value: Strideable>(_ title: String, value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1) {
    self.init(value: value, in: bounds, step: step) { Text(title) }
  }
}

/// パネル以外の決定・キャンセル操作も，同じ面と輪郭で統一する。
struct AppActionButtonStyle: ButtonStyle {
  var isPrimary = false
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    let isDestructive = configuration.role == .destructive
    let foreground: Color = isPrimary
      ? (isDestructive ? .white : NeomorphicTheme.canvas)
      : (isDestructive ? .red : NeomorphicTheme.ink)
    let background: Color = isPrimary
      ? (isDestructive ? .red : NeomorphicTheme.ink)
      : (isHovering ? NeomorphicTheme.controlSelected : NeomorphicTheme.control)
    return configuration.label
      .font(.appCaptionStrong)
      .foregroundStyle(foreground)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(background, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
      .onHover { isHovering = $0 }
  }
}

private struct AppChoiceRowButton<Label: View>: View {
  var role: ButtonRole? = nil
  var isSelected = false
  let action: () -> Void
  @ViewBuilder var label: Label
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false
  @FocusState private var isFocused: Bool

  var body: some View {
    Button(role: role, action: action) {
      label
        .font(.appBody)
        .foregroundStyle(role == .destructive ? Color.red : NeomorphicTheme.ink)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 36)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(isHovering || isFocused || isSelected ? NeomorphicTheme.control : .clear)
        )
        .overlay(alignment: .leading) {
          if isHovering || isFocused || isSelected {
            RoundedRectangle(cornerRadius: 1)
              .fill(NeomorphicTheme.accent)
              .frame(width: 2, height: 16)
              .padding(.leading, 2)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isEnabled ? 1 : 0.4)
    }
    .buttonStyle(.plain)
    .focusable(isEnabled)
    .focusEffectDisabled()
    .focused($isFocused)
    .onHover { isHovering = $0 }
    .onKeyPress(.return) {
      guard isEnabled else { return .ignored }
      action()
      return .handled
    }
  }
}

/// 既存のToggleのBindingとラベルを保ち，スイッチとチェックを共通の輪郭で描く。
struct AppToggleStyle: ToggleStyle {
  var isCheckbox = false

  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 8) {
        if isCheckbox { indicator(configuration.isOn) }
        configuration.label
        if !isCheckbox {
          Spacer(minLength: 8)
          indicator(configuration.isOn)
        }
      }
      .font(.appBody)
      .foregroundStyle(NeomorphicTheme.ink)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? "オン" : "オフ")
  }

  private func indicator(_ isOn: Bool) -> some View {
    ZStack(alignment: isCheckbox ? .center : (isOn ? .trailing : .leading)) {
      RoundedRectangle(cornerRadius: isCheckbox ? 4 : 6)
        .fill(isOn ? NeomorphicTheme.ink : NeomorphicTheme.control)
      RoundedRectangle(cornerRadius: isCheckbox ? 4 : 6)
        .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
      if isCheckbox {
        if isOn {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NeomorphicTheme.canvas)
        }
      } else {
        RoundedRectangle(cornerRadius: 3)
          .fill(isOn ? NeomorphicTheme.canvas : NeomorphicTheme.muted)
          .frame(width: 14, height: 14)
          .padding(3)
      }
    }
    .frame(width: isCheckbox ? 20 : 36, height: 20)
    .accessibilityHidden(true)
  }
}

private struct AppChoiceFocusBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> FocusView { FocusView() }
  func updateNSView(_ view: FocusView, context: Context) {}

  final class FocusView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      DispatchQueue.main.async { [weak window] in
        window?.makeKey()
        window?.selectNextKeyView(nil)
      }
    }
  }
}
