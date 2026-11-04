import SwiftUI


struct StorageManagerView: View {
    @StateObject private var viewModel: StorageViewModel
    @Environment(\.dismiss) var dismiss

    init(dataManager: LibraryViewModel) {
        _viewModel = StateObject(
            wrappedValue: StorageViewModel(libraryViewModel: dataManager)
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            SheetHeader(
                icon: "internaldrive",
                title: "ストレージ管理",
                subtitle: "このアプリがMac内に保存しているデータの内訳"
            )

            // 設定画面と同じ「行を重ねた面」で、内訳（左に名前、右に容量）を見せる。
            SettingsGroup {
                usageBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)

                breakdownRow(
                    color: Self.usageColors[0],
                    label: "取り込み済みメディア",
                    size: viewModel.usage.videosSize
                )
                breakdownRow(
                    color: Self.usageColors[1],
                    label: "軽量版（プロキシ）動画",
                    size: viewModel.usage.proxiesSize
                )
                breakdownRow(
                    color: Self.usageColors[2],
                    label: "退避された元動画",
                    size: viewModel.usage.downloadsSize
                )

                SettingsRow(title: "総使用容量") {
                    Text(viewModel.formatBytes(viewModel.usage.appTotalSize))
                        .font(.appTitle.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(
                            viewModel.usage.appTotalSize > 10_000_000_000
                                ? .red
                                : NeomorphicTheme.ink
                        )
                }
            }

            if viewModel.isOptimizing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.optimizationMessage)
                        .font(.appCaption)
                        .foregroundStyle(NeomorphicTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                SettingsSection(title: "整理") {
                    SettingsGroup {
                        SettingsRow(
                            title: "リンク切れメディアを整理",
                            detail: "Mac上の元ファイルが削除されて「見つかりません」になったデータを一括整理します．"
                        ) {
                            Button("整理", action: viewModel.cleanupMissingFiles)
                                .buttonStyle(.quiet)
                        }
                        SettingsRow(
                            title: "重複動画を検出して削除",
                            detail: "タイトルが違っても内容が完全に一致する動画を自動で整理します．"
                        ) {
                            Button("検出して削除", action: viewModel.removeDuplicates)
                                .buttonStyle(.quiet)
                        }
                        SettingsRow(title: "フォルダを開く") {
                            HStack(spacing: 8) {
                                Button("データ", action: viewModel.openDataFolder)
                                Button("一時キャッシュ", action: viewModel.openTemporaryFolder)
                            }
                            .buttonStyle(.quiet)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540, height: 660)
        .appSheet()
        .onAppear(perform: viewModel.refreshUsage)
        .alert("クリーンアップ完了", isPresented: $viewModel.isShowingResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.resultMessage)
        }
    }

    /// 内訳の3区分。色相ではなく明るさの段階で見分ける（無彩色のまま、凡例と棒を対応づけられる）。
    private static let usageColors: [Color] = [
        NeomorphicTheme.ink.opacity(0.90),
        NeomorphicTheme.ink.opacity(0.55),
        NeomorphicTheme.ink.opacity(0.28),
    ]

    // 内訳を色分けして示す比率バー
    private var usageBar: some View {
        GeometryReader { geo in
            let total = max(
                Double(
                    viewModel.usage.videosSize
                        + viewModel.usage.proxiesSize
                        + viewModel.usage.downloadsSize
                ),
                1
            )
            HStack(spacing: 2) {
                segment(
                    width: geo.size.width * Double(viewModel.usage.videosSize) / total,
                    color: Self.usageColors[0]
                )
                segment(
                    width: geo.size.width * Double(viewModel.usage.proxiesSize) / total,
                    color: Self.usageColors[1]
                )
                segment(
                    width: geo.size.width * Double(viewModel.usage.downloadsSize) / total,
                    color: Self.usageColors[2]
                )
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func segment(width: CGFloat, color: Color) -> some View {
        if width >= 1 {
            Rectangle()
                .fill(color)
                .frame(width: width)
        }
    }

    private func breakdownRow(color: Color, label: String, size: Int64) -> some View {
        SettingsRow(
            title: label,
            leading: {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            },
            control: {
                Text(viewModel.formatBytes(size))
                    .font(.appBodyStrong)
                    .monospacedDigit()
            }
        )
    }

}
