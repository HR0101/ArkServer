import SwiftUI

struct MediaShortcutSettingsSection: View {
    @AppStorage(MediaShortcutSettings.versionKey) private var settingsVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            category("一覧", actions: MediaShortcutAction.libraryActions)
            category("動画", actions: MediaShortcutAction.videoActions)
            category("差分切り替え再生", actions: MediaShortcutAction.variantActions)
            category("画像", actions: MediaShortcutAction.photoActions)

            if hasDuplicateAssignments {
                Label("同じキーが複数の操作に割り当てられています．画面ごとの先に判定された操作が優先されます．", systemImage: "exclamationmark.triangle")
                    .font(.appCaption)
                    .foregroundStyle(NeomorphicTheme.caution)
            }

            SettingsGroup {
                SettingsRow(title: "既定値に戻す", detail: "すべてのショートカットキーを初期の割り当てに戻します．") {
                    Button("戻す") {
                        MediaShortcutSettings.resetDefaults()
                    }
                    .buttonStyle(.quiet)
                }
            }
        }
    }

    private func category(_ title: String, actions: [MediaShortcutAction]) -> some View {
        SettingsSection(title: title) {
            SettingsGroup {
                ForEach(actions) { action in
                    MediaShortcutAssignmentRow(action: action)
                }
            }
        }
    }

    private var hasDuplicateAssignments: Bool {
        _ = settingsVersion
        let libraryDuplicates = hasDuplicateKeys(in: MediaShortcutAction.libraryActions)
        // 差分切り替え再生は動画のキーもそのまま使うので、まとめて重複を見る。
        let videoDuplicates = hasDuplicateKeys(in: MediaShortcutAction.videoActions + MediaShortcutAction.variantActions)
        let photoDuplicates = hasDuplicateKeys(in: MediaShortcutAction.photoActions)
        return libraryDuplicates || videoDuplicates || photoDuplicates
    }

    private func hasDuplicateKeys(in actions: [MediaShortcutAction]) -> Bool {
        let rawValues = actions.flatMap { MediaShortcutSettings.keys(for: $0).map(\.rawValue) }
        return Set(rawValues).count != rawValues.count
    }
}

private struct MediaShortcutAssignmentRow: View {
    let action: MediaShortcutAction
    @AppStorage(MediaShortcutSettings.versionKey) private var settingsVersion = 0
    @FocusState private var isCaptureFocused: Bool
    @State private var isCapturing = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // セクション名（一覧・動画・画像…）と重なる「一覧: 」のような接頭辞は省く。
            Text(action.settingsTitle.components(separatedBy: ": ").last ?? action.settingsTitle)
                .font(.appBody.weight(.medium))
                .foregroundStyle(NeomorphicTheme.ink)
            Spacer(minLength: 12)
            FlowLayout(spacing: 6) {
                ForEach(keys) { key in
                    HStack(spacing: 4) {
                        Text(key.displayName)
                            .font(.appMonoCaption.weight(.medium))
                        Button {
                            MediaShortcutSettings.removeKey(key, for: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .disabled(keys.count <= 1)
                        .help(keys.count <= 1 ? "少なくとも1つのキーが必要です" : "このキーを削除")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(NeomorphicTheme.control, in: Capsule())
                }
            }
            Button {
                isCapturing = true
                DispatchQueue.main.async {
                    isCaptureFocused = true
                }
            } label: {
                Label(isCapturing ? "キーを押してください" : "キーを追加", systemImage: isCapturing ? "keyboard" : "plus.circle")
                    .font(.appCaption)
            }
            .buttonStyle(.quiet)
            .help(isCapturing ? "登録したいキーを押してください．Escでキャンセルします．" : "キーを押して追加")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .focusable()
        .focused($isCaptureFocused)
        .background(
            Rectangle()
                .fill(isCapturing ? NeomorphicTheme.accent.opacity(0.12) : Color.clear)
        )
        .onKeyPress(phases: .down, action: captureKeyPress)
        .onChange(of: settingsVersion) { _, _ in
            // UserDefaults の配列変更を設定行へ伝播させるための依存関係です。
        }
    }

    private var keys: [MediaShortcutKey] {
        _ = settingsVersion
        return MediaShortcutSettings.keys(for: action)
    }

    private func captureKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard isCapturing else { return .ignored }

        if press.key == .escape {
            isCapturing = false
            isCaptureFocused = false
            return .handled
        }

        guard let key = MediaShortcutKey.captured(from: press) else {
            return .handled
        }

        MediaShortcutSettings.addKey(key, for: action)
        isCapturing = false
        isCaptureFocused = false
        return .handled
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 13.0, *) {
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                GridRow {
                    content
                }
            }
        }
    }
}
