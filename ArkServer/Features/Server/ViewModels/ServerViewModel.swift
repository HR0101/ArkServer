import Foundation
import Swifter
import AVFoundation
import AppKit
import Darwin
import Combine
import MediaServerKit


class ServerViewModel: NSObject, ObservableObject, NetServiceDelegate {
    let server = HttpServer()
    private var netService: NetService?

    weak var dataManager: LibraryViewModel?
    /// 差分動画の探索。HTTP のワーカースレッドから触るので isolation の外に置く。
    let variantScanner: VariantScanService
    let remotePlaybackSession: RemotePlaybackSession

    @Published var statusMessage: String = "停止中"
    @Published var serverURL: String?
    var isRunning: Bool { serverStartTime != nil }

    @Published var serverStartTime: Date? {
        didSet { snapshotServerStartTime.value = serverStartTime }
    }
    /// /server/status ルート（ワーカースレッド）用のミラー。メインスレッドを経由せず読める。
    nonisolated let snapshotServerStartTime = LockedBox<Date?>(nil)
    @Published var uptimeString: String = "00:00:00"
    private var timerCancellable: AnyCancellable?

    @Published var autoStopEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStopEnabled, forKey: "autoStopEnabled")
        }
    }
    @Published var autoStopIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(autoStopIntervalMinutes, forKey: "autoStopIntervalMinutes")
        }
    }

    @Published var scheduleEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "scheduleEnabled")
            if !scheduleEnabled { removeSchedule() }
        }
    }
    @Published var scheduleStartTime: Date {
        didSet { UserDefaults.standard.set(scheduleStartTime, forKey: "scheduleStartTime") }
    }
    @Published var scheduleStopTime: Date {
        didSet { UserDefaults.standard.set(scheduleStopTime, forKey: "scheduleStopTime") }
    }
    @Published var scheduleStatusMessage: String = ""


    @Published var targetPort: Int {
        didSet {
            UserDefaults.standard.set(targetPort, forKey: "serverPort")
        }
    }

    @Published var authEnabled: Bool = true {
        didSet {
            authEnabledCache = authEnabled
            UserDefaults.standard.set(authEnabled, forKey: "authEnabled")
        }
    }
    @Published var authPIN: String = "" {
        didSet {
            authPINCache = authPIN
            UserDefaults.standard.set(authPIN, forKey: "authPIN")
        }
    }
    /// 認証をオフにしていても、削除系API（完全削除・アルバム削除・サーバー停止）には
    /// PINを要求するか。オンなら同一LAN上の第三者が閲覧はできても消すことはできない。
    @Published var requirePINForDeletion: Bool = true {
        didSet {
            requirePINForDeletionCache = requirePINForDeletion
            UserDefaults.standard.set(requirePINForDeletion, forKey: "requirePINForDeletion")
        }
    }

    /// Bonjour で公開するサーバー表示名。空ならコンピュータ名（ユーザー名）を使う。
    /// 変更はサーバーの再起動後に反映される。
    @Published var serverDisplayName: String = "" {
        didSet { UserDefaults.standard.set(serverDisplayName, forKey: "serverDisplayName") }
    }

    /// 設定画面で選べるアップロード上限（GB）。Swifter はリクエスト本体をすべてメモリに読み込んでから
    /// ハンドラを呼ぶため，搭載メモリを超える上限はメモリ枯渇を招くだけで意味がない。
    /// 搭載メモリの半分を超える選択肢は出さない（最低でも 1 GB は残す）。
    static let uploadLimitOptionsGB: [Int] = {
        let halfMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) / 2
        let options = [1, 2, 4, 8, 16, 32].filter { $0 <= halfMemoryGB }
        return options.isEmpty ? [1] : options
    }()

    /// 保存値や旧既定値（20 GB）が選択肢にないときは，それ以下で最大の選択肢に丸める。
    static func clampedUploadLimitGB(_ value: Int) -> Int {
        uploadLimitOptionsGB.last(where: { $0 <= value }) ?? uploadLimitOptionsGB[0]
    }

    /// アップロード受け入れの上限（GB）。ディスク枯渇とメモリ枯渇の防止用。
    @Published var maxUploadGB: Int = 20 {
        didSet {
            maxUploadBytesCache = maxUploadGB * 1_073_741_824
            UserDefaults.standard.set(maxUploadGB, forKey: "maxUploadGB")
        }
    }

    // バックグラウンドスレッドから安全に読むためのスナップショット
    private var authEnabledCache = true
    private var authPINCache = ""
    private var requirePINForDeletionCache = true
    private var maxUploadBytesCache = 21_474_836_480

    @Published var accessLogs: [AccessLogEntry] = []
    private let maxAccessLogs = 200

    var maxUploadBytes: Int { maxUploadBytesCache }

    /// ブラウザクライアントの視聴位置・お気に入り・履歴の同期保管庫。
    /// lazy var にしないのは、複数の HTTP ワーカースレッドから同時に初回アクセスされうるため。
    let syncStore: WebSyncStore

    /// PWAのホーム画面アイコンとして配信するPNGです。
    /// AppKitの画像変換をHTTPワーカースレッドで行わないよう、初期化時に生成します。
    let pwaIconData: Data

    init(
        dataManager: LibraryViewModel,
        remotePlaybackSession: RemotePlaybackSession
    ) {
        self.dataManager = dataManager
        self.variantScanner = VariantScanService(directory: dataManager.appRootURL)
        self.remotePlaybackSession = remotePlaybackSession
        // init は main で走るので @MainActor な LibraryViewModel の appRootURL をここで読んでおく。
        // 以後 WebSyncStore は LibraryViewModel に一切依存せず、ワーカースレッドから直接叩ける。
        self.syncStore = WebSyncStore(
            rootURL: dataManager.appRootURL,
            persistenceEnabled: dataManager.isReadyForOperations
        )
        self.pwaIconData = NSApplication.shared.applicationIconImage.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]) ?? Data()

        let savedPort = UserDefaults.standard.integer(forKey: "serverPort")
        self.targetPort = savedPort == 0 ? 8080 : savedPort

        self.autoStopEnabled = UserDefaults.standard.bool(forKey: "autoStopEnabled")
        let savedInterval = UserDefaults.standard.integer(forKey: "autoStopIntervalMinutes")
        self.autoStopIntervalMinutes = savedInterval == 0 ? 60 : savedInterval

        self.scheduleEnabled = UserDefaults.standard.bool(forKey: "scheduleEnabled")
        let cal = Calendar.current
        self.scheduleStartTime = (UserDefaults.standard.object(forKey: "scheduleStartTime") as? Date)
            ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        self.scheduleStopTime = (UserDefaults.standard.object(forKey: "scheduleStopTime") as? Date)
            ?? cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()

        let authEnabledValue = UserDefaults.standard.object(forKey: "authEnabled") as? Bool ?? true
        self.authEnabled = authEnabledValue
        let savedPIN = UserDefaults.standard.string(forKey: "authPIN") ?? ""
        let pin = savedPIN.isEmpty ? String(format: "%06d", Int.random(in: 0...999999)) : savedPIN
        self.authPIN = pin

        let requirePINForDeletionValue = UserDefaults.standard.object(forKey: "requirePINForDeletion") as? Bool ?? true
        self.requirePINForDeletion = requirePINForDeletionValue
        self.serverDisplayName = UserDefaults.standard.string(forKey: "serverDisplayName") ?? ""
        let savedMaxUploadGB = Self.clampedUploadLimitGB(
            UserDefaults.standard.object(forKey: "maxUploadGB") as? Int ?? 20
        )
        self.maxUploadGB = savedMaxUploadGB

        // didSet は init 中に発火しないため、キャッシュと永続化を手動で行う
        self.authEnabledCache = authEnabledValue
        self.authPINCache = pin
        self.requirePINForDeletionCache = requirePINForDeletionValue
        self.maxUploadBytesCache = savedMaxUploadGB * 1_073_741_824
        UserDefaults.standard.set(pin, forKey: "authPIN")

        super.init()
        print("✅ [LIFECYCLE] ServerViewModel initialized.")
        setupRoutes()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionOrAppTermination),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        if scheduleEnabled && isWithinScheduleWindow(Date()) {
            startServer()
        }
    }

    deinit {
        print("🛑 [LIFECYCLE] ServerViewModel deinitialized.")
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Auth & Access Log
    func regeneratePIN() {
        authPIN = String(format: "%06d", Int.random(in: 0...999999))
    }

    private func extractPIN(from request: HttpRequest) -> String? {
        if let header = request.headers["x-auth-pin"], !header.isEmpty { return header }
        if let q = request.queryParams.first(where: { $0.0 == "pin" })?.1, !q.isEmpty { return q }
        if let cookie = request.headers["cookie"] {
            for part in cookie.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0] == "pin", !kv[1].isEmpty { return kv[1] }
            }
        }
        return nil
    }

    // MARK: - 総当たり攻撃対策
    // IP ごとに連続失敗回数を記録し、一定回数を超えたら指数バックオフでロックアウトする。
    // 状態と判定は MediaServerKit の PINLockoutTracker に集約。
    // 5回目以降は失敗のたびに 30s → 60s → 120s … 最大 1 時間ロックする。
    // 通常の認証と削除時のみPINの両方が、必ずこの tracker を通ること。
    private let pinLockout = PINLockoutTracker()

    /// PIN の一致とロックアウトを検証する。
    /// PIN が無いリクエスト（ログイン前の初回アクセス等）は失敗としてカウントしない。
    private func checkPIN(_ request: HttpRequest) -> Bool {
        guard let pin = extractPIN(from: request) else { return false }
        return pinLockout.verify(pin: pin, expected: authPINCache, ip: request.address ?? "unknown")
    }

    private func isAuthorized(_ request: HttpRequest) -> Bool {
        if !authEnabledCache { return true }
        return checkPIN(request)
    }

    /// アクセスログに残すパスから認証情報を取り除く。
    /// AsyncImage / AVPlayer はヘッダーを付けられないため、クライアントは PIN を
    /// URLクエリで送ってくる。request.path をそのまま記録すると PIN が平文で
    /// アクセスログ画面に並んでしまう（画面共有・スクリーンショットで漏れる）。
    nonisolated private static func sanitizedLogPath(_ path: String) -> String {
        guard let qIndex = path.firstIndex(of: "?") else { return path }
        let base = String(path[..<qIndex])
        let query = path[path.index(after: qIndex)...]
        let masked = query.split(separator: "&").map { pair -> String in
            pair.hasPrefix("pin=") ? "pin=****" : String(pair)
        }.joined(separator: "&")
        return base + "?" + masked
    }

    func logAccess(_ request: HttpRequest, authorized: Bool) {
        let ip = request.address ?? "unknown"
        let method = request.method
        let path = Self.sanitizedLogPath(request.path)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.accessLogs.insert(AccessLogEntry(date: Date(), ip: ip, method: method, path: path, authorized: authorized), at: 0)
            if self.accessLogs.count > self.maxAccessLogs {
                self.accessLogs.removeLast(self.accessLogs.count - self.maxAccessLogs)
            }
        }
    }

    /// 認証チェック付きでルートハンドラを包む
    func protected(_ handler: @escaping (HttpRequest) -> HttpResponse) -> (HttpRequest) -> HttpResponse {
        return { [weak self] request in
            guard let self = self else { return .internalServerError }
            let ok = self.isAuthorized(request)
            self.logAccess(request, authorized: ok)
            if !ok {
                let body = Array(#"{"error":"auth_required"}"#.utf8)
                return .raw(401, "Unauthorized",
                            ["Content-Type": "application/json", "WWW-Authenticate": "PIN"],
                            { try? $0.write(body) })
            }
            return handler(request)
        }
    }

    /// 削除系（完全削除・アルバム削除・サーバー停止）専用の保護ラッパー。
    /// 通常の認証に加え、「認証オフでも削除にはPINを要求」設定が有効なら
    /// 認証オフの状態でもPINの一致を要求する（閲覧は自由・削除は保護、という運用のため）。
    func protectedDestructive(_ handler: @escaping (HttpRequest) -> HttpResponse) -> (HttpRequest) -> HttpResponse {
        return { [weak self] request in
            guard let self = self else { return .internalServerError }
            let ok: Bool
            if self.authEnabledCache {
                ok = self.isAuthorized(request)
            } else if self.requirePINForDeletionCache && !self.authPINCache.isEmpty {
                ok = self.checkPIN(request)
            } else {
                ok = true
            }
            self.logAccess(request, authorized: ok)
            if !ok {
                let body = Array(#"{"error":"auth_required"}"#.utf8)
                return .raw(401, "Unauthorized",
                            ["Content-Type": "application/json", "WWW-Authenticate": "PIN"],
                            { try? $0.write(body) })
            }
            return handler(request)
        }
    }

    // MARK: - Server Control
    func startServer() {
        guard !server.operating else { return }
        guard dataManager?.isReadyForOperations == true else {
            statusMessage = "❌ ライブラリ保存先を利用できないため，サーバーを開始できません．"
            return
        }

        let portToUse = in_port_t(targetPort)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // priority のデフォルトは .background。これだと接続処理スレッドが
                // 強くスロットリングされ、サムネイル生成などでワーカースレッドが埋まると
                // 動画ストリーミングのリクエストにスレッドが割り当てられず固まってしまう
                // （アルバムを開いた直後に同時再生が始まらない原因）。
                // .userInitiated に上げてワーカースレッドを十分確保する。
                try self.server.start(portToUse, forceIPv4: true, priority: .userInitiated)
                let actualPort = try self.server.port()
                DispatchQueue.main.async {
                    self.targetPort = Int(actualPort)
                    guard let computerName = Host.current().localizedName else {
                        self.statusMessage = "❌ [FATAL] Could not get computer name."; self.server.stop(); return
                    }
                    let userName = NSUserName()
                    let customName = self.serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let uniqueServiceName = customName.isEmpty ? "\(computerName) (\(userName))" : customName
                    self.netService = NetService(domain: "local.", type: "_myvideoserver._tcp.", name: uniqueServiceName, port: Int32(actualPort))
                    self.netService?.delegate = self
                    self.netService?.publish()

                    self.serverStartTime = Date()
                    self.startUptimeTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "❌ 起動失敗: ポート \(portToUse) は既に使用されている可能性があります．"
                }
            }
        }
    }

    private func startUptimeTimer() {
        self.timerCancellable?.cancel()
        self.timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self, let start = self.serverStartTime else { return }
            let diff = Int(Date().timeIntervalSince(start))

            if self.autoStopEnabled {
                let limitSeconds = self.autoStopIntervalMinutes * 60
                if diff >= limitSeconds {
                    self.stopServerInternal()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            if self.scheduleEnabled {
                let now = Date()
                let cal = Calendar.current
                let stop = cal.dateComponents([.hour, .minute], from: self.scheduleStopTime)
                let cur = cal.dateComponents([.hour, .minute], from: now)
                if cur.hour == stop.hour && cur.minute == stop.minute {
                    self.stopServerInternal()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            let h = diff / 3600
            let m = (diff % 3600) / 60
            let s = diff % 60
            self.uptimeString = String(format: "%02d:%02d:%02d", h, m, s)
        }
    }

    @objc func stopServer() { stopServerInternal() }

    func stopServerInternal() {
        netService?.stop(); netService = nil
        server.stop()

        DispatchQueue.main.async {
            self.serverStartTime = nil
            self.timerCancellable?.cancel()
            self.uptimeString = "00:00:00"
            self.serverURL = nil
            self.statusMessage = "🛑 サーバー停止"
        }
    }

    @objc private func handleSessionOrAppTermination() { stopServerInternal() }

    // MARK: - スケジュール起動/停止
    /// 現在時刻が起動時刻〜停止時刻の時間帯に入っているか（日をまたぐ設定にも対応）
    func isWithinScheduleWindow(_ now: Date) -> Bool {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        let e = cal.dateComponents([.hour, .minute], from: scheduleStopTime)
        let n = cal.dateComponents([.hour, .minute], from: now)
        let startMin = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        let stopMin  = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        let nowMin   = (n.hour ?? 0) * 60 + (n.minute ?? 0)
        if startMin == stopMin { return false }
        if startMin < stopMin { return nowMin >= startMin && nowMin < stopMin }
        return nowMin >= startMin || nowMin < stopMin // 日をまたぐ場合
    }

    private var launchAgentLabel: String {
        (Bundle.main.bundleIdentifier ?? "com.allserverformac.app") + ".autostart"
    }
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// 設定画面の「適用」ボタンから呼ぶ。LaunchAgent登録 + スリープ起床(pmset)を設定する
    func applySchedule() {
        installLaunchAgent()
        scheduleWake()
    }

    /// スケジュール解除（LaunchAgent削除 + pmset起床解除）
    func removeSchedule() {
        removeLaunchAgent()
        cancelWake()
        DispatchQueue.main.async { self.scheduleStatusMessage = "スケジュールを解除しました．" }
    }

    private func installLaunchAgent() {
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        let hour = comp.hour ?? 9
        let minute = comp.minute ?? 0
        let appPath = Bundle.main.bundlePath

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "RunAtLoad": false
        ]

        do {
            let dir = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL)
            reloadLaunchAgent()
            let timeStr = String(format: "%02d:%02d", hour, minute)
            DispatchQueue.main.async {
                self.scheduleStatusMessage = "✅ 毎日 \(timeStr) に自動起動するよう登録しました．"
            }
        } catch {
            DispatchQueue.main.async {
                self.scheduleStatusMessage = "❌ 自動起動の登録に失敗: \(error.localizedDescription)"
            }
        }
    }

    private func reloadLaunchAgent() {
        let path = launchAgentURL.path
        _ = runProcess("/bin/launchctl", ["unload", path])   // 既存があれば解除（失敗は無視）
        _ = runProcess("/bin/launchctl", ["load", "-w", path])
    }

    private func removeLaunchAgent() {
        let path = launchAgentURL.path
        _ = runProcess("/bin/launchctl", ["unload", path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    /// スリープ中でも起動時刻にMacを起こす（pmset / 管理者権限が必要）。起動2分前に起床させる
    private func scheduleWake() {
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        var total = (comp.hour ?? 9) * 60 + (comp.minute ?? 0) - 2
        if total < 0 { total += 24 * 60 }
        let timeStr = String(format: "%02d:%02d:00", total / 60, total % 60)
        runAdminShell("/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(timeStr)") { ok in
            DispatchQueue.main.async {
                if !ok {
                    self.scheduleStatusMessage = "⚠️ 自動起動は登録しましたが，スリープ起床(pmset)の設定がキャンセル/失敗しました．"
                }
            }
        }
    }

    private func cancelWake() {
        runAdminShell("/usr/bin/pmset repeat cancel") { _ in }
    }

    /// 管理者権限でシェルコマンドを実行（GUIでパスワード入力を求める）
    private func runAdminShell(_ command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with administrator privileges"
            var errorDict: NSDictionary?
            if let script = NSAppleScript(source: source) {
                script.executeAndReturnError(&errorDict)
                completion(errorDict == nil)
            } else {
                completion(false)
            }
        }
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        let ipAddress = getIPAddress() ?? "N/A"
        self.serverURL = "http://\(ipAddress):\(sender.port)"
        // 同名サービスが既にLAN上にあると Bonjour は自動リネームして公開する。
        // 黙ってリネームされると iOS 側で「設定した名前が見つからない」ように見えるため、
        // 実際に公開された名前をステータスに出して気づけるようにする。
        let requestedName = serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedName.isEmpty && sender.name != requestedName {
            self.statusMessage = "✅ 実行中: http://\(ipAddress):\(sender.port)（名前重複のため「\(sender.name)」として公開中）"
        } else {
            self.statusMessage = "✅ 実行中: http://\(ipAddress):\(sender.port)"
        }
    }

    /// Bonjour の公開自体に失敗したとき（名前衝突で自動リネームも効かない場合など）。
    /// これを実装しないと、サーバーは動いているのに iOS から一切発見できない状態が
    /// 何のエラー表示もなく続いてしまう。
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        self.statusMessage = "⚠️ サーバーは起動していますが，ネットワーク公開（Bonjour）に失敗しました．iOSから自動発見できません．"
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        self.statusMessage = "❌ Bonjour publish failed."
        self.server.stop()
    }
}
