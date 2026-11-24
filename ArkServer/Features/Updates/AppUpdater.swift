import SwiftUI
import AppKit
import Combine
import Foundation

/// SemVer precedence; shortened versions such as 1.2 are padded with zeroes.
struct UpdateVersion: Comparable {
    let core: [Int]
    let prerelease: [String]
    let build: Int?

    init?(_ text: String) {
        let raw = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let metadata = raw.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ Self.validNumber(String($0)) }) else { return nil }
        core = numbers.map { Int($0)! } + Array(repeating: 0, count: 3 - numbers.count)
        let pre = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard pre.allSatisfy({ Self.validIdentifier($0) && (!Self.isNumeric($0) || Self.validNumber($0)) }) else { return nil }
        prerelease = pre
        if metadata.count == 2 {
            let identifiers = metadata[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard identifiers.allSatisfy(Self.validIdentifier) else { return nil }
            build = Int(metadata[1])
        } else {
            build = nil
        }
    }

    private static func isNumeric(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (48...57).contains($0) } }
    private static func validNumber(_ s: String) -> Bool {
        isNumeric(s) && (s.count == 1 || s.first != "0") && Int(s) != nil
    }
    private static func validIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.core == rhs.core && lhs.prerelease == rhs.prerelease }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if Self.isNumeric(a), Self.isNumeric(b) {
                return a.count == b.count ? a < b : a.count < b.count
            }
            if Self.isNumeric(a) != Self.isNumeric(b) { return Self.isNumeric(a) }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    func isNewer(than current: Self, currentBuild: Int) -> Bool {
        self > current || (self == current && build.map { $0 > currentBuild } == true)
    }
}

struct AppRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var downloadURL: URL? {
        assets.first { $0.name == "ArkServer.dmg" && Self.trustedURL($0.browser_download_url, download: true) }?.browser_download_url
    }
    static func trustedURL(_ url: URL, download: Bool = false) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.path.hasPrefix("/HR0101/ArkServer/releases/" + (download ? "download/" : ""))
    }
}

enum AppUpdateError: LocalizedError {
    case response, rateLimited, http(Int), invalidRelease
    var errorDescription: String? {
        switch self {
        case .response: return "更新サーバーから有効な応答を取得できませんでした。"
        case .rateLimited: return "GitHubのアクセス制限に達しました。しばらく待ってから再試行してください。"
        case .http(let code): return "更新サーバーでエラーが発生しました（HTTP \(code)）。"
        case .invalidRelease: return "リリース情報の形式が正しくありません。"
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    static let automaticKey = "updates.checkAtLaunch"
    static let skippedKey = "updates.skippedVersion"
    static let lastCheckKey = "updates.lastCheck"
    static let latestURL = URL(string: "https://api.github.com/repos/HR0101/ArkServer/releases/latest")!
    /// 進捗をこの幅（1%）以上進んだときだけ画面に反映し，再描画の回数を抑える
    static let progressReportStep = 0.01

    enum State: Equatable {
        case idle, checking, available(AppRelease), upToDate, noRelease
        case downloading(AppRelease), downloaded(URL), failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var lastCheck: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Self.automaticKey) }
    }
    let currentVersion: String
    let currentBuild: String
    private let defaults: UserDefaults
    private let session: URLSession
    private var operation: Task<Void, Never>?
    private var downloadID: UUID?
    private var window: NSWindow?
    private var manualRequested = false
    private let presentsWindows: Bool
    private let downloadsDirectory: URL?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         version: String? = nil, build: String? = nil, presentsWindows: Bool = true,
         downloadsDirectory: URL? = nil) {
        self.defaults = defaults
        self.session = session
        self.presentsWindows = presentsWindows
        self.downloadsDirectory = downloadsDirectory
        currentVersion = version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentBuild = build ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        automaticallyChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var isBusy: Bool {
        switch state { case .checking, .downloading: return true; default: return false }
    }

    func check(manual: Bool) {
        if manual {
            manualRequested = true
            showWindow()
        }
        guard !isBusy else { return }
        manualRequested = manual
        state = .checking
        operation = Task {
            do {
                var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("ArkServer", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw AppUpdateError.response }
                if http.statusCode == 404 {
                    recordCheck()
                    state = .noRelease
                    return
                }
                try Self.validateHTTP(http)
                let release: AppRelease
                do { release = try JSONDecoder().decode(AppRelease.self, from: data) }
                catch { throw AppUpdateError.invalidRelease }
                guard !release.draft, !release.prerelease,
                      AppRelease.trustedURL(release.html_url),
                      let remote = UpdateVersion(release.tag_name),
                      let current = UpdateVersion(currentVersion) else { throw AppUpdateError.invalidRelease }
                recordCheck()
                if remote.isNewer(than: current, currentBuild: Int(currentBuild) ?? 0) {
                    if !manualRequested && defaults.string(forKey: Self.skippedKey) == release.tag_name {
                        state = .idle
                    } else {
                        state = .available(release)
                        // Background checks only expose the in-app update button.
                        // Details are presented when the user requests them.
                    }
                } else {
                    state = .upToDate
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = manualRequested ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    private func recordCheck() {
        lastCheck = Date()
        defaults.set(lastCheck, forKey: Self.lastCheckKey)
    }

    static func validateHTTP(_ http: HTTPURLResponse) throws {
        if http.statusCode == 403 || http.statusCode == 429 { throw AppUpdateError.rateLimited }
        guard (200...299).contains(http.statusCode) else { throw AppUpdateError.http(http.statusCode) }
    }

    func skip(_ release: AppRelease) {
        defaults.set(release.tag_name, forKey: Self.skippedKey)
        state = .idle
        window?.close()
    }

    /// Download only: unsigned/ad-hoc releases must never replace the running bundle.
    /// This also works from read-only DMGs and leaves server/library jobs untouched.
    func download(_ release: AppRelease) {
        guard !isBusy, let url = release.downloadURL else { return }
        let id = UUID()
        downloadID = id
        state = .downloading(release)
        progress = nil
        operation = Task {
            do {
                let delegate = UpdateDownloadProgress { [weak self] value in
                    Task { @MainActor in
                        guard self?.downloadID == id, case .downloading = self?.state else { return }
                        self?.applyProgress(value)
                    }
                }
                defer { delegate.invalidate() }
                let (temporary, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 300), delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw AppUpdateError.response }
                try Self.validateHTTP(http)
                let directory = try downloadsDirectory ?? FileManager.default.url(
                    for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("ArkServer-\(UUID().uuidString).dmg")
                try FileManager.default.moveItem(at: temporary, to: destination)
                downloadID = nil
                state = .downloaded(destination)
                if presentsWindows {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                guard !Task.isCancelled else { return }
                downloadID = nil
                state = .failed("ダウンロードできませんでした。\(error.localizedDescription) リリースページから手動でダウンロードできます。")
            }
        }
    }

    /// 通知の順序は保証されないため，進捗は増える方向にだけ更新する
    private func applyProgress(_ value: Double?) {
        // nil（サイズ不明）は開始時に設定済みなので，ここでは確定値だけを扱う．
        // 確定値の後に nil へ戻すとバーがスピナーに戻ってしまうため無視する
        guard let value else { return }
        if let current = progress {
            guard value > current else { return }
            guard value >= 1 || value - current >= Self.progressReportStep else { return }
        }
        progress = value
    }

    func cancelDownload() {
        guard case .downloading(let release) = state else { return }
        operation?.cancel()
        downloadID = nil
        state = .available(release)
        progress = nil
    }

    func remindLater() { window?.close() }

    func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/HR0101/ArkServer/releases/latest")!)
    }

    func showWindow() {
        guard presentsWindows else { return }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AppUpdateView(updater: self)))
            window.title = "Ark Server アップデート"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Observes download progress from the created `URLSessionTask`.
///
/// Async `URLSession.download(for:delegate:)` only forwards `URLSessionTaskDelegate`
/// callbacks and skips `URLSessionDownloadDelegate.didWriteData`, so we observe `task.progress`.
private nonisolated final class UpdateDownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private let report: @Sendable (Double?) -> Void

    init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    deinit {
        invalidate()
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = self.report
        let next = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak task] progress, _ in
            // 旧実装の totalBytesExpectedToWrite > 0 と同じく，応答の予定サイズで「サイズ不明」を判定する
            let expectedBytes = task?.countOfBytesExpectedToReceive ?? 0
            let fraction: Double? = expectedBytes > 0
                ? min(1, max(0, progress.fractionCompleted))
                : nil
            report(fraction)
        }
        let previous = lock.withLock { () -> NSKeyValueObservation? in
            defer { observation = next }
            return observation
        }
        previous?.invalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        invalidate()
    }

    func invalidate() {
        let current = lock.withLock { () -> NSKeyValueObservation? in
            defer { observation = nil }
            return observation
        }
        current?.invalidate()
    }
}
