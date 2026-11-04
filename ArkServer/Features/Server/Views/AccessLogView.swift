import SwiftUI

struct AccessLogView: View {
    @ObservedObject var webServerManager: ServerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var logFilter: Int = 0 // 0: 全て, 1: 動画本体, 2: サムネ, 3: その他

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SheetHeader(
                    icon: "list.bullet.rectangle",
                    title: "アクセスログ",
                    subtitle: "直近 \(webServerManager.accessLogs.count) 件のリクエスト"
                )
                FlatSegmentedControl(
                    options: [0, 1, 2, 3],
                    title: { ["すべて", "動画本体", "サムネ", "その他"][$0] },
                    selection: $logFilter,
                    width: 260
                )

                Button("クリア") { webServerManager.accessLogs.removeAll() }
                    .disabled(webServerManager.accessLogs.isEmpty)
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            let filteredLogs = webServerManager.accessLogs.filter { entry in
                switch logFilter {
                case 1: return entry.path.hasPrefix("/video/")
                case 2: return entry.path.hasPrefix("/thumbnail/")
                case 3: return !entry.path.hasPrefix("/video/") && !entry.path.hasPrefix("/thumbnail/")
                default: return true
                }
            }

            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "まだアクセスがありません",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("選択した条件に一致するリクエストはありません")
                )
            } else {
                Table(filteredLogs) {
                    TableColumn("時刻") { entry in
                        Text(AccessLogView.timeFormatter.string(from: entry.date))
                            .font(.appMonoCaption)
                    }
                    .width(110)
                    TableColumn("IP") { entry in
                        Text(entry.ip).font(.appMonoCaption)
                    }
                    .width(110)
                    TableColumn("メソッド") { entry in
                        Text(entry.method)
                            .font(.appMicroStrong)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NeomorphicTheme.control))
                            .foregroundStyle(NeomorphicTheme.ink)
                    }
                    .width(64)
                    TableColumn("パス") { entry in
                        Text(entry.path).font(.appCaption).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("認証") { entry in
                        Text(entry.authorized ? "許可" : "拒否")
                            .font(.appMicroStrong)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((entry.authorized ? NeomorphicTheme.online : Color.red).opacity(0.15)))
                            .foregroundStyle(entry.authorized ? NeomorphicTheme.online : .red)
                    }
                    .width(48)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 680, height: 480)
        .appSheet()
    }
}
