import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ソフトウェアアップデート").font(.appTitle)
            Text("現在のバージョン: \(updater.currentVersion)（ビルド \(updater.currentBuild)）")
                .foregroundStyle(.secondary)
            switch updater.state {
            case .idle:
                Text("最新バージョンを確認できます。")
                Button("アップデートを確認") { updater.check(manual: true) }
            case .checking:
                ProgressView("アップデートを確認中…")
            case .available(let release):
                Text("\(release.tag_name) に更新できます。全ての処理が終わってからアプリを終了し、ダウンロードしたアプリに差し替えてください。")
                ScrollView {
                    Text(release.body.flatMap { $0.isEmpty ? nil : $0 } ?? "リリースノートはありません。")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(height: 180)
                HStack {
                    if release.downloadURL != nil {
                        Button("更新をダウンロード") { updater.download(release) }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("リリースページを開く") { updater.openReleases() }
                }
                HStack {
                    Button("後で") { updater.remindLater() }
                    Button("このバージョンをスキップ") { updater.skip(release) }
                }
                Text("後で更新する場合は、このウィンドウを閉じてください。")
                    .font(.caption).foregroundStyle(.secondary)
            case .upToDate:
                Text("現在のバージョンは最新です。")
            case .noRelease:
                Text("公開されたリリースはまだありません。")
            case .downloading:
                if let progress = updater.progress {
                    ProgressView(value: progress) { Text("ダウンロード中…") }
                } else {
                    ProgressView("ダウンロード中…")
                }
                Button("キャンセル") { updater.cancelDownload() }
            case .downloaded(let url):
                Text("ダウンロードしました: \(url.lastPathComponent)")
                Text("サーバーを停止し、インポート・解析・書き出しの完了を確認してから通常の終了操作を行ってください。DMGを開き、現在のアプリを差し替えて起動すると更新が完了します。ライブラリの保存場所は変わりません。")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                HStack {
                    Button("再試行") { updater.check(manual: true) }
                    Button("リリースページを開く") { updater.openReleases() }
                }
            }
        }
        .padding(24)
        .frame(width: 620, alignment: .leading)
        .frame(minHeight: 200)
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
            .help("新しいバージョン \(release.tag_name) の詳細を表示")
            .accessibilityIdentifier("updateAvailableButton")
        }
    }
}
