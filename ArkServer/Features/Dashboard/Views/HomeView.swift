import AppKit
import Charts
import SwiftUI

// MARK: - HomeView（ダッシュボード）
struct HomeView: View {
    @ObservedObject var dataManager: LibraryViewModel
    @ObservedObject var webServerManager: ServerViewModel
    @ObservedObject private var duplicateCheckStatus: DuplicateCheckStatus
    @ObservedObject private var linkedFolderScanStatus: LinkedFolderScanStatus
    @StateObject private var systemMonitor = DashboardViewModel()
    @EnvironmentObject private var appSettings: AppSettings

    @State private var isShowingAccessLog = false
    @State private var isShowingStorageManager = false
    @State private var logFilter: Int = 0 // 0: 全て, 1: 動画本体, 2: サムネ, 3: その他
    /// ページ見出しの2行目に出す、ライブラリの規模（「動画 1,038本 · 画像 26,529枚 · アルバム 513」）。
    @State private var librarySummary = ""

    init(dataManager: LibraryViewModel, webServerManager: ServerViewModel) {
        self.dataManager = dataManager
        self.webServerManager = webServerManager
        self.duplicateCheckStatus = dataManager.duplicateCheckStatus
        self.linkedFolderScanStatus = dataManager.linkedFolderScanStatus
    }

    /// 2列にするときの、1列あたりの最低幅。サーバーカードの「停止中」と「開始」が省略されない幅。
    private static let homeColumnMinWidth: CGFloat = 400
    /// ページ周囲の余白（4pt刻み）。
    private static let homePagePadding: CGFloat = 32

    /// 接続に必要な「サーバーの状態」を先頭に置く左の列。
    private var leftColumn: some View {
        VStack(spacing: DS.cardSpacing) {
            ServerHeroCard(webServerManager: webServerManager)
            connectionCard
            scheduleCard
            duplicateCheckCard
            storageCard
        }
    }

    private var rightColumn: some View {
        VStack(spacing: DS.cardSpacing) {
            securityCard
            resourcesCard
            linkedFolderCard
            if !dataManager.linkedFolderConflicts.isEmpty {
                linkedFolderConflictCard
            }
            logsCard
        }
    }

    var body: some View {
        ZStack {
            NeomorphicHomeBackground()
            ScrollView {
                VStack(spacing: DS.cardSpacing) {
                    LibraryPageHeader(title: "ホーム", subtitle: librarySummary)
                      .padding(.horizontal, -24)

                    // カードごとの高さが異なるため，行の高さを強制するLazyVGridは使わない。
                    // 左右のカラムを独立して積むことで，縦長カードの横に空白が残らない。
                    // 接続に必要な「サーバーの状態」と「PIN認証」を各カラムの先頭に置く
                    // （以前の「設定の概要」は，すぐ下の設定カードと同じ項目の繰り返しだったので廃止）。
                    // 各列には、サーバー状態と「開始/停止」が文字で読める最低幅(homeColumnMinWidth)を確保する。
                    // 2列分の幅がないときは、同じ順序のまま1列に積む（サイドバー表示つきの最小ウィンドウ幅など）。
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: DS.cardSpacing) {
                            leftColumn
                                .frame(minWidth: Self.homeColumnMinWidth, maxWidth: .infinity, alignment: .top)
                            rightColumn
                                .frame(minWidth: Self.homeColumnMinWidth, maxWidth: .infinity, alignment: .top)
                        }
                        VStack(spacing: DS.cardSpacing) {
                            leftColumn
                            rightColumn
                        }
                    }
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, Self.homePagePadding)
                .padding(.vertical, Self.homePagePadding)
                .frame(maxWidth: .infinity)
            }
        }
        // ウィンドウを開いた直後に最初の入力欄（ポート番号）が自動で選択されないようにする。
        .background(InitialFirstResponderClearer())
        .tint(NeomorphicTheme.accent)
        .foregroundStyle(NeomorphicTheme.ink)
        .preferredColorScheme(appSettings.neomorphicDarkBase ? .dark : .light)
        .sheet(isPresented: $isShowingAccessLog) {
            AccessLogView(webServerManager: webServerManager)
        }
        // 重複チェックの件数キャッシュは自動チェックのループ（起動から90秒後に開始，オフなら初回のみ）でしか
        // 作られないため，それまでホームが 0/0 のままになり「今すぐすべてチェック」も押せない．
        // ホームを開いたとき・ライブラリの読み込みが終わったときに一度作っておく．
        .onAppear(perform: refreshDuplicateCheckCountsIfNeeded)
        .onAppear(perform: refreshLibrarySummary)
        .onChange(of: dataManager.isLibraryLoaded) { refreshDuplicateCheckCountsIfNeeded() }
        .onChange(of: dataManager.videos) { refreshLibrarySummary() }
        .onChange(of: dataManager.albums) { refreshLibrarySummary() }
        .sheet(isPresented: $isShowingStorageManager) {
            StorageManagerView(dataManager: dataManager)
        }
    }

    /// 1回の走査で本数・枚数を数える（ホームは1秒ごとに再描画されるので、body の中では数えない）。
    private func refreshLibrarySummary() {
        var videoCount = 0
        var photoCount = 0
        for item in dataManager.videos where !item.isInTrash {
            if item.mediaType == .video { videoCount += 1 } else { photoCount += 1 }
        }
        let albumCount = [false, true].reduce(0) {
            $0 + SidebarViewModel.treeAlbums(from: dataManager.albums, isPhoto: $1).count
        }
        librarySummary = "動画 \(videoCount.formatted())本 · 画像 \(photoCount.formatted())枚 · アルバム \(albumCount.formatted())"
    }

    // MARK: 重複チェックカード
    private func refreshDuplicateCheckCountsIfNeeded() {
        guard dataManager.isLibraryLoaded, !dataManager.isDuplicateCheckRunning else { return }
        dataManager.refreshDuplicateCheckAlbumCaches()
    }

    private var duplicateCheckCard: some View {
        let checkedAlbums = duplicateCheckStatus.checkedAlbums
        let uncheckedAlbums = duplicateCheckStatus.uncheckedAlbums
        let totalCount = checkedAlbums.count + uncheckedAlbums.count

        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "checkmark.seal.fill", tint: NeomorphicTheme.accent, title: "重複メディアの確認", subtitle: "同じファイルがないかアルバムごとに確認")

            SettingToggleRow(title: "バックグラウンドで自動チェック", isOn: $dataManager.isAutoDuplicateCheckEnabled)
            .help("オフにすると，インポート後などにバックグラウンドで自動実行される重複チェックを停止します．アルバム内の「重複チェック」ボタンによる手動実行には影響しません．")

            HStack(spacing: 10) {
                DuplicateCheckCountBadge(title: "チェック済み", count: checkedAlbums.count)
                DuplicateCheckCountBadge(title: "未チェック", count: uncheckedAlbums.count)
            }

            if totalCount == 0 {
                Text("対象アルバムはありません．")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if duplicateCheckStatus.isAutoChecking {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: duplicateCheckStatus.progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(NeomorphicTheme.accent)
                    Text(duplicateCheckStatus.statusMessage)
                        .font(.appMicro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text(duplicateCheckStatus.statusMessage)
                    .font(.appMicro)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await dataManager.checkAllAlbumsForDuplicatesNow() }
            } label: {
                Label("今すぐすべてチェック", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            // 補助の操作は塗りつぶさない（青い全幅ボタンが並ぶと、本当の主役である「開始」が埋もれる）。
            .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)
            .disabled(duplicateCheckStatus.isAutoChecking || dataManager.isDuplicateCheckRunning || totalCount == 0)
            .help("自動チェックのオン/オフに関わらず，対象アルバムの重複をまとめて今すぐチェックします．")

            Divider()

            duplicateAlbumList(title: "未チェック", albums: uncheckedAlbums, emptyMessage: "未チェックのアルバムはありません．")
            duplicateAlbumList(title: "チェック済み", albums: checkedAlbums, emptyMessage: "チェック済みのアルバムはありません．")
        }
        .dashboardCard()
    }

    // MARK: リンクフォルダ更新カード
    private var linkedFolderCard: some View {
        let count = dataManager.linkedFolderCount
        let status = linkedFolderScanStatus
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "folder.badge.gearshape", tint: NeomorphicTheme.accent, title: "リンクフォルダ", subtitle: "元フォルダの変更をライブラリへ反映")

            SettingRow(label: "リンク中のフォルダ") {
                Text("\(count)フォルダ")
                    .font(.appBodyStrong)
                    .monospacedDigit()
            }

            if status.isScanning {
                linkedFolderScanProgress(status)
            } else {
                Text("紐づけたフォルダに追加・削除したメディアは，下のボタンを押したときに取り込まれます．")
                    .font(.appMicro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if count > 0 && !status.statusMessage.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.appMicro)
                            .foregroundStyle(.green)
                        Text(status.statusMessage)
                            .font(.appMicro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            Button {
                Task { await dataManager.rescanAllLinkedFolders() }
            } label: {
                Label(status.isScanning ? "更新中…" : "リンクフォルダを更新", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            // 補助の操作は塗りつぶさない（青い全幅ボタンが並ぶと、本当の主役である「開始」が埋もれる）。
            .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)
            .disabled(status.isScanning || count == 0)

            if count == 0 {
                Text("フォルダを紐づけるには，アルバムを開いてツールバーの「フォルダ紐づけ」を使ってください．")
                    .font(.appMicro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashboardCard()
    }

    /// リンクフォルダ更新中の進捗表示（スピナー・進捗バー・現在のフォルダ名・件数）。
    @ViewBuilder
    private func linkedFolderScanProgress(_ status: LinkedFolderScanStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("リンクフォルダを更新中…")
                    .font(.appCaptionStrong)
                Spacer()
                if status.totalCount > 0 {
                    Text("\(min(status.processedCount + 1, status.totalCount)) / \(status.totalCount)")
                        .font(.appMonoMicro)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(status.processedCount), total: Double(max(status.totalCount, 1)))
                .progressViewStyle(.linear)
                .tint(NeomorphicTheme.accent)

            if let name = status.currentFolderName {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.appMicro)
                        .foregroundStyle(.cyan)
                    Text(name)
                        .font(.appMicro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if status.processedItemsInCurrentFolder > 0 {
                        Text("\(status.processedItemsInCurrentFolder)件取り込み")
                            .font(.appMonoMicro)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cyan.opacity(0.1))
        )
    }

    // MARK: フォルダ紐づけ候補カード
    private var linkedFolderConflictCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                icon: "folder.badge.questionmark",
                tint: .yellow,
                title: "フォルダ紐づけ候補",
                subtitle: "同名フォルダの選択"
            )

            ForEach(dataManager.linkedFolderConflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.fill")
                            .foregroundStyle(.yellow)
                            .font(.appCaption)
                        Text(conflict.albumName)
                            .font(.appCaptionStrong)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }

                    ForEach(conflict.candidates) { candidate in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.folderPath)
                                    .font(.appMicro)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(candidate.folderPath)
                                Text("\(candidate.matchCount)件一致")
                                    .font(.appMicro)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                dataManager.confirmLinkedFolderCandidate(candidate)
                            } label: {
                                Label("選択", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(NeomorphicTheme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(NeomorphicTheme.cardBorder, lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.vertical, 2)

                if conflict.id != dataManager.linkedFolderConflicts.last?.id {
                    Divider()
                }
            }
        }
        .dashboardCard()
    }

    private func duplicateAlbumList(title: String, albums: [Album], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.appMicroStrong)
                .foregroundStyle(.secondary)

            if albums.isEmpty {
                Text(emptyMessage)
                    .font(.appMicro)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(albums.prefix(5)) { album in
                    HStack(spacing: 8) {
                        Text(album.name)
                            .font(.appCaption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(album.videoIDs.count)件")
                            .font(.appMonoMicro)
                            .foregroundStyle(.secondary)
                    }
                }

                if albums.count > 5 {
                    Text("ほか\(albums.count - 5)件")
                        .font(.appMicro)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 接続設定カード
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "network", tint: .blue, title: "接続・自動停止の設定", subtitle: "ポート番号とアプリを終了するまでの時間")

            SettingRow(label: "ポート番号") {
                HStack(spacing: 6) {
                    TextField("8080", value: $webServerManager.targetPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.center)
                        .disabled(webServerManager.isRunning)

                    Button(action: { webServerManager.targetPort = 8080 }) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(webServerManager.isRunning)
                    .help("デフォルト(8080)に戻す")
                }
            }

            if webServerManager.isRunning {
              Text("接続・自動停止の設定は，サーバーを停止すると変更できます．")
                .font(.appCaption)
                .foregroundStyle(NeomorphicTheme.muted)
            }

            Divider()

            SettingToggleRow(title: "自動停止タイマー", isOn: $webServerManager.autoStopEnabled)
            .disabled(webServerManager.isRunning)

            if webServerManager.autoStopEnabled {
                SettingRow(label: "サーバー開始から終了まで") {
                    HStack(spacing: 5) {
                        TextField("分", value: $webServerManager.autoStopIntervalMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                            .multilineTextAlignment(.trailing)
                            .disabled(webServerManager.isRunning)
                        Text("分")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.autoStopEnabled)
        .dashboardCard()
    }

    // MARK: スケジュールカード
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "calendar.badge.clock", tint: NeomorphicTheme.accent, title: "起動・停止スケジュール", subtitle: "毎日決まった時刻に自動で起動・終了")

            SettingToggleRow(title: "毎日決まった時間に起動/停止", isOn: $webServerManager.scheduleEnabled)

            if webServerManager.scheduleEnabled {
                Divider()

                AppTimePicker("起動時刻", selection: $webServerManager.scheduleStartTime, displayedComponents: .hourAndMinute)
                    .font(.appCaption)
                AppTimePicker("停止時刻", selection: $webServerManager.scheduleStopTime, displayedComponents: .hourAndMinute)
                    .font(.appCaption)

                Button(action: { webServerManager.applySchedule() }) {
                    Label("このスケジュールを適用", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)

                Text("適用時に管理者パスワードの入力を求められます（スリープからの自動起床設定のため）．停止時刻になるとアプリは完全終了します．")
                    .font(.appMicro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !webServerManager.scheduleStatusMessage.isEmpty {
                    Text(webServerManager.scheduleStatusMessage)
                        .font(.appMicro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.scheduleEnabled)
        .dashboardCard()
    }

    // MARK: セキュリティカード
    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "lock.shield.fill", tint: NeomorphicTheme.accent, title: "PIN認証", subtitle: "接続する端末に入力する6桁の番号")

            SettingToggleRow(title: "PIN認証を必須にする", isOn: $webServerManager.authEnabled)
            .help("オンにすると，Web・iOSアプリからのアクセスにPINが必要になります．")

            if webServerManager.authEnabled {
                SettingRow(label: "接続PIN") {
                    HStack(spacing: 8) {
                        CopyableText(
                            text: webServerManager.authPIN,
                            font: .system(size: 20, weight: .semibold, design: .monospaced),
                            tint: NeomorphicTheme.ink
                        )
                        Button(action: { webServerManager.regeneratePIN() }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .help("PINを再生成する")
                    }
                }
                Text("このPINをiPhoneアプリ・ブラウザで入力してください．")
                    .font(.appMicro)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("認証が無効です．同じWi-Fi内の誰でもアクセスできます．")
                        .font(.appMicro)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NeomorphicTheme.accent.opacity(0.12))
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: webServerManager.authEnabled)
        .dashboardCard()
    }

    // MARK: システムリソースカード
    private var resourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "gauge.with.dots.needle.50percent", tint: .orange, title: "Macの使用状況", subtitle: "Mac全体のCPU・メモリ使用率")

            HStack(spacing: 24) {
                ResourceGauge(label: "CPU", value: systemMonitor.cpuUsage, tint: NeomorphicTheme.ink)
                ResourceGauge(label: "メモリ", value: systemMonitor.memoryUsage, tint: NeomorphicTheme.ink)
                Spacer()
            }

            Chart {
                ForEach(systemMonitor.cpuHistory) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("CPU(%)", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(NeomorphicTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("CPU(%)", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [NeomorphicTheme.accent.opacity(0.35), NeomorphicTheme.accent.opacity(0.0)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    AxisValueLabel()
                        .font(.appMicro.monospacedDigit())
                }
            }
            .frame(height: 90)

            Text("CPU使用率の推移（0〜100％）")
              .font(.appCaption)
              .foregroundStyle(NeomorphicTheme.muted)
        }
        .dashboardCard()
    }

    // MARK: ストレージカード
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "internaldrive.fill", tint: NeomorphicTheme.accent, title: "ライブラリの容量", subtitle: "登録済みメディアの件数と合計サイズ")

            SettingRow(label: "総アイテム数") {
                Text("\(dataManager.videos.count)件")
                    .font(.appBodyStrong)
                    .monospacedDigit()
            }
            SettingRow(label: "使用容量") {
                Text(dataManager.totalStorageSizeText)
                    .font(.appBodyStrong)
                    .monospacedDigit()
            }

            Divider()

            Button(action: { isShowingStorageManager = true }) {
                Label("ストレージ管理を開く", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppActionButtonStyle())
            .tint(NeomorphicTheme.ink)
        }
        .dashboardCard()
    }

    // MARK: リアルタイム通信ログカード
    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "network.badge.shield.half.filled", tint: NeomorphicTheme.accent, title: "最近のアクセス", subtitle: "端末からの通信履歴（接続台数ではありません）")
                Spacer()
                Button("すべて見る") { isShowingAccessLog = true }
                    .font(.appMicroStrong)
                    .buttonStyle(.plain)
                    .foregroundStyle(NeomorphicTheme.muted)
            }

            FlatSegmentedControl(
                options: [0, 1, 2, 3],
                title: { ["すべて", "動画本体", "サムネ", "その他"][$0] },
                selection: $logFilter,
                width: 320
            )
            .padding(.bottom, 4)

            let filteredLogs = webServerManager.accessLogs.filter { entry in
                switch logFilter {
                case 1: return entry.path.hasPrefix("/video/")
                case 2: return entry.path.hasPrefix("/thumbnail/")
                case 3: return !entry.path.hasPrefix("/video/") && !entry.path.hasPrefix("/thumbnail/")
                default: return true
                }
            }

            if filteredLogs.isEmpty {
                Text("まだアクセスがありません")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredLogs.prefix(15)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.date.formatted(.dateTime.hour().minute().second()))
                                .font(.appMonoMicro)
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .leading)

                            Image(systemName: entry.authorized ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(entry.authorized ? .green : .red)
                                .font(.appMicro)

                            Text(entry.method)
                                .font(.appMonoMicro.weight(.medium))
                                .foregroundStyle(entry.method == "GET" ? .blue : .purple)
                                .frame(width: 36, alignment: .leading)

                            Text(entry.path)
                                .font(.appMicro)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.path)

                            Spacer(minLength: 5)

                            Text(entry.ip)
                                .font(.appMonoMicro)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(NeomorphicTheme.surface)
                        )
                    }
                }
                .frame(maxHeight: 240, alignment: .top)
                .clipped()
            }
        }
        .dashboardCard()
    }
}
