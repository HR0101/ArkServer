import AppKit
import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(
                icon: "arrow.down.circle",
                title: "ソフトウェアアップデート",
                subtitle: "現在のバージョン: \(updater.currentVersion)（ビルド \(updater.currentBuild)）"
            )

            Divider().overlay(NeomorphicTheme.separator)

            switch updater.state {
            case .idle:
                statusCard(
                    icon: "arrow.clockwise.circle",
                    iconColor: NeomorphicTheme.muted,
                    title: "最新バージョンを確認できます",
                    detail: "GitHub Releases から公開済みの最新バージョンを確認します。"
                ) {
                    HStack(spacing: 10) {
                        Spacer()
                        Button("アップデートを確認") { updater.check(manual: true) }
                            .buttonStyle(UpdateAccentButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }

            case .checking:
                statusCard(
                    icon: nil,
                    iconColor: NeomorphicTheme.accent,
                    title: "アップデートを確認中…",
                    detail: "最新リリースの情報を取得しています。"
                ) {
                    EmptyView()
                }

            case .available(let release):
                availableView(for: release)

            case .upToDate:
                statusCard(
                    icon: "checkmark.circle.fill",
                    iconColor: NeomorphicTheme.online,
                    title: "現在のバージョンは最新です",
                    detail: "お使いの Ark Server（\(updater.currentVersion)）は最新バージョンです。"
                ) {
                    HStack(spacing: 10) {
                        Spacer()
                        Button("再確認") { updater.check(manual: true) }
                            .buttonStyle(AppActionButtonStyle())
                        Button("閉じる") { updater.remindLater() }
                            .buttonStyle(UpdateAccentButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }

            case .noRelease:
                statusCard(
                    icon: "shippingbox",
                    iconColor: NeomorphicTheme.muted,
                    title: "公開されたリリースはまだありません",
                    detail: "新しいリリースが公開されると、ここから更新できます。"
                ) {
                    HStack(spacing: 10) {
                        Spacer()
                        Button("閉じる") { updater.remindLater() }
                            .buttonStyle(AppActionButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }

            case .downloading(let release):
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(release.tag_name) をダウンロードしています…")
                            .font(.appHeadline)
                            .foregroundStyle(NeomorphicTheme.ink)
                        Spacer()
                        if let progress = updater.progress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.appMonoCaption)
                                .foregroundStyle(NeomorphicTheme.muted)
                        }
                    }
                    if let progress = updater.progress {
                        ProgressView(value: progress)
                            .tint(NeomorphicTheme.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(NeomorphicTheme.accent)
                    }
                    Text("ダウンロード完了後、自動的に検証とインストールへ進みます。")
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassCardSurface())

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button("キャンセル") { updater.cancelDownload() }
                        .buttonStyle(AppActionButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }

            case .installing(let release):
                statusCard(
                    icon: nil,
                    iconColor: NeomorphicTheme.accent,
                    title: "\(release.tag_name) をインストールして再起動しています…",
                    detail: "署名とバンドルを検証し、アプリを置き換えています。完了すると自動的に再起動します。"
                ) {
                    EmptyView()
                }

            case .downloaded(let url):
                statusCard(
                    icon: "arrow.down.doc.fill",
                    iconColor: NeomorphicTheme.accent,
                    title: "ダウンロードが完了しました",
                    detail: "保存ファイル: \(url.lastPathComponent)\n「このDMGから今すぐアップデート」を押すと、現在のアプリを自動で置き換えて再起動します（ライブラリの保存場所は変わりません）。"
                ) {
                    HStack(spacing: 10) {
                        Button("Finderで表示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(AppActionButtonStyle())
                        Spacer()
                        Button("このDMGから今すぐアップデート") {
                            updater.install(dmgURL: url)
                        }
                        .buttonStyle(UpdateAccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }

            case .failed(let message):
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    iconColor: NeomorphicTheme.negative,
                    title: "アップデートを完了できませんでした",
                    detail: message
                ) {
                    HStack(spacing: 8) {
                        Button("リリースページを開く") { updater.openReleases() }
                            .buttonStyle(AppActionButtonStyle())
                        Button("再確認") { updater.check(manual: true) }
                            .buttonStyle(AppActionButtonStyle())
                        Spacer()
                        if let release = updater.availableRelease, release.downloadURL != nil {
                            Button("DMGのみ保存") { updater.download(release) }
                                .buttonStyle(AppActionButtonStyle())
                            Button("今すぐアップデートを再試行") { updater.install(release) }
                                .buttonStyle(UpdateAccentButtonStyle())
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity, alignment: .topLeading)
        .appSheet()
        .environment(\.colorScheme, NeomorphicTheme.isDarkBase ? .dark : .light)
    }

    @ViewBuilder
    private func availableView(for release: AppRelease) -> some View {
        let notes = FormattedReleaseNotes.parse(release.body)

        // バージョン概要カード
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新しいバージョンが利用可能です")
                    .font(.appHeadline)
                    .foregroundStyle(NeomorphicTheme.ink)
                Text("「今すぐアップデート」を押すと、最新版をダウンロードしてアプリを自動で置き換え、再起動します。")
                    .font(.appCaption)
                    .foregroundStyle(NeomorphicTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text(updater.currentVersion)
                    .font(.appMonoCaption)
                    .foregroundStyle(NeomorphicTheme.muted)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NeomorphicTheme.muted)
                Text(release.tag_name)
                    .font(.appMonoBody.weight(.semibold))
                    .foregroundStyle(NeomorphicTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(NeomorphicTheme.accent.opacity(0.14))
                    )
            }
            .fixedSize()
        }
        .padding(14)
        .background(GlassCardSurface())

        // リリースノート見出し行
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("更新内容")
                .font(.appBodyStrong)
                .foregroundStyle(NeomorphicTheme.ink)
            if notes.changeCount > 0 {
                Text("\(notes.changeCount)件")
                    .font(.appMicroStrong.monospacedDigit())
                    .foregroundStyle(NeomorphicTheme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(NeomorphicTheme.control))
            }
            Spacer()
            if let compareURL = notes.compareURL {
                Button {
                    NSWorkspace.shared.open(compareURL)
                } label: {
                    HStack(spacing: 3) {
                        Text("変更差分")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.quiet)
            }
            Button {
                updater.openReleases()
            } label: {
                HStack(spacing: 3) {
                    Text("リリースページ")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.quiet)
        }

        // 整形済みリリースノート一覧
        ScrollView {
            if notes.isEmpty {
                Text("リリースノートはありません。")
                    .font(.appBody)
                    .foregroundStyle(NeomorphicTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(notes.sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = section.title {
                                Text(title)
                                    .font(.appCaptionStrong)
                                    .foregroundStyle(NeomorphicTheme.muted)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 6)
                            }
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                ReleaseNoteRowView(item: item)
                                if index < section.items.count - 1 {
                                    Divider()
                                        .overlay(NeomorphicTheme.separator)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(GlassCardSurface())
        .clipShape(RoundedRectangle(cornerRadius: DS.cardCornerRadius, style: .continuous))

        // 下部アクションバー
        HStack(spacing: 8) {
            Button("後で") { updater.remindLater() }
                .buttonStyle(AppActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("このバージョンをスキップ") { updater.skip(release) }
                .buttonStyle(AppActionButtonStyle())

            Spacer(minLength: 12)

            if release.downloadURL != nil {
                Button("DMGのみ保存") { updater.download(release) }
                    .buttonStyle(AppActionButtonStyle())
                Button {
                    updater.install(release)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                        Text("今すぐアップデート")
                    }
                }
                .buttonStyle(UpdateAccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("installUpdateButton")
            } else {
                Button("リリースページを開く") { updater.openReleases() }
                    .buttonStyle(UpdateAccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func statusCard<Actions: View>(
        icon: String?,
        iconColor: Color,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 24, height: 24)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.appHeadline)
                        .foregroundStyle(NeomorphicTheme.ink)
                    Text(detail)
                        .font(.appBody)
                        .foregroundStyle(NeomorphicTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardSurface())

        Spacer(minLength: 0)

        actions()
    }
}

private struct ReleaseNoteRowView: View {
    let item: FormattedReleaseNotes.Item

    var body: some View {
        switch item.kind {
        case .change(let category):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                categoryBadge(for: category)
                    .frame(width: 48, alignment: .leading)

                Text(Self.inlineMarkdown(item.text))
                    .font(.appBody)
                    .foregroundStyle(category == .internalChange ? NeomorphicTheme.muted : NeomorphicTheme.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let prNumber = item.pullNumber {
                    if let prURL = item.pullURL {
                        Button {
                            NSWorkspace.shared.open(prURL)
                        } label: {
                            Text("#\(prNumber)")
                                .font(.appMonoMicro)
                                .foregroundStyle(NeomorphicTheme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Pull Request #\(prNumber) を開く")
                    } else {
                        Text("#\(prNumber)")
                            .font(.appMonoMicro)
                            .foregroundStyle(NeomorphicTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

        case .paragraph:
            Text(Self.inlineMarkdown(item.text))
                .font(.appBody)
                .foregroundStyle(NeomorphicTheme.ink)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func categoryBadge(for category: FormattedReleaseNotes.Category) -> some View {
        if let label = category.label {
            let style = badgeColors(for: category)
            Text(label)
                .font(.appMicroStrong)
                .foregroundStyle(style.foreground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(style.background)
                )
        } else {
            Text("•")
                .font(.appBodyStrong)
                .foregroundStyle(NeomorphicTheme.accent)
                .padding(.leading, 6)
        }
    }

    private func badgeColors(for category: FormattedReleaseNotes.Category) -> (foreground: Color, background: Color) {
        switch category {
        case .feature:
            return (NeomorphicTheme.accent, NeomorphicTheme.accent.opacity(0.15))
        case .fix:
            return (NeomorphicTheme.online, NeomorphicTheme.online.opacity(0.15))
        case .improvement:
            return (NeomorphicTheme.ink, NeomorphicTheme.controlSelected)
        case .docs, .internalChange, .general:
            return (NeomorphicTheme.muted, NeomorphicTheme.control)
        }
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }
}

private struct UpdateAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appCaptionStrong)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NeomorphicTheme.accent.opacity(isHovering ? 0.88 : 1.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        SettingsSection(title: "バージョン") {
            SettingsGroup {
                SettingsRow(title: "現在のバージョン") {
                    Text("\(updater.currentVersion)（ビルド \(updater.currentBuild)）")
                        .font(.appBody.monospacedDigit())
                        .foregroundStyle(NeomorphicTheme.muted)
                }
                SettingsRow(title: "起動時に自動でアップデートを確認") {
                    SettingsSwitch(title: "起動時に自動でアップデートを確認", isOn: $updater.automaticallyChecks)
                }
                SettingsRow(title: "最終確認") {
                    Group {
                        if let date = updater.lastCheck {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text("未確認")
                        }
                    }
                    .font(.appBody.monospacedDigit())
                    .foregroundStyle(NeomorphicTheme.muted)
                }
                SettingsRow(title: updater.isBusy ? "アップデートの状況" : "アップデートを確認") {
                    HStack(spacing: 8) {
                        if case .available(let release) = updater.state, release.downloadURL != nil {
                            Button("今すぐアップデート") {
                                updater.showWindow()
                                updater.install(release)
                            }
                            .tint(NeomorphicTheme.accent)
                            .accessibilityIdentifier("settingsInstallUpdateButton")
                        }
                        AppUpdateAvailabilityButton()
                        Button(updater.isBusy ? "状況を表示" : "今すぐ確認") {
                            updater.check(manual: true)
                        }
                        .buttonStyle(.quiet)
                    }
                }
            }
        }
    }
}

/// Observes update availability independently of the library and playback views.
struct AppUpdateAvailabilityButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if case .available(let release) = updater.state {
            Button {
                updater.showWindow()
            } label: {
                Label("アップデート可能", systemImage: "arrow.down.circle.fill")
            }
            .labelStyle(.titleAndIcon)
            .tint(NeomorphicTheme.accent)
            .help("新しいバージョン \(release.tag_name) の詳細と自動アップデートを表示")
            .accessibilityIdentifier("updateAvailableButton")
        }
    }
}
