import SwiftUI
import AppKit
import Combine
import Darwin
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
    static func trustedRepositoryWebURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.path.hasPrefix("/HR0101/ArkServer/")
    }
}

struct FormattedReleaseNotes: Equatable {
    enum Category: Int, Comparable, Equatable {
        case feature = 0
        case fix = 1
        case improvement = 2
        case general = 3
        case docs = 4
        case internalChange = 5

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String? {
            switch self {
            case .feature: return "新機能"
            case .fix: return "修正"
            case .improvement: return "改善"
            case .general: return nil
            case .docs: return "案内"
            case .internalChange: return "基盤"
            }
        }
    }

    struct Item: Equatable, Identifiable {
        enum Kind: Equatable {
            case change(Category)
            case paragraph
        }
        let id: Int
        let kind: Kind
        let text: String
        let pullNumber: Int?
        let pullURL: URL?
    }

    struct Section: Equatable, Identifiable {
        let id: Int
        let title: String?
        let items: [Item]
    }

    let sections: [Section]
    let compareURL: URL?

    var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }

    var changeCount: Int {
        sections.reduce(0) { total, section in
            total + section.items.filter {
                if case .change = $0.kind { return true }
                return false
            }.count
        }
    }

    static func parse(_ rawBody: String?) -> FormattedReleaseNotes {
        guard let rawBody else { return FormattedReleaseNotes(sections: [], compareURL: nil) }
        let normalized = rawBody.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var sections: [(title: String?, items: [Item])] = []
        var currentTitle: String? = nil
        var currentItems: [Item] = []
        var compareURL: URL? = nil
        var nextID = 0
        var skippingIgnoredSection = false

        func flushSection() {
            guard !currentItems.isEmpty else { return }
            let sortedItems = Self.sortChangeItemsIfAppropriate(currentItems)
            sections.append((title: currentTitle, items: sortedItems))
            currentItems = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Full Changelog フッターの抽出
            if let extractedCompare = Self.extractFullChangelogURL(from: line) {
                compareURL = extractedCompare
                continue
            }

            // Markdown 見出し (# / ## / ###)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let lower = heading.lowercased()
                if lower == "new contributors" {
                    flushSection()
                    skippingIgnoredSection = true
                    currentTitle = nil
                    continue
                }
                skippingIgnoredSection = false
                if lower == "what's changed" || lower == "whats changed" || lower == "changes" {
                    flushSection()
                    currentTitle = nil
                    continue
                }
                flushSection()
                currentTitle = heading.isEmpty ? nil : heading
                continue
            }

            if skippingIgnoredSection { continue }

            // 箇条書き (* / - / +)
            if let bulletBody = Self.stripBulletPrefix(line) {
                if bulletBody.contains("made their first contribution in ") {
                    continue
                }
                let (cleanedWithoutPR, prNumber, prURL) = Self.extractTrailingPRReference(from: bulletBody)
                let (category, cleanedSummary) = Self.extractConventionalPrefix(from: cleanedWithoutPR)
                guard !cleanedSummary.isEmpty else { continue }
                currentItems.append(
                    Item(
                        id: nextID,
                        kind: .change(category),
                        text: cleanedSummary,
                        pullNumber: prNumber,
                        pullURL: prURL
                    )
                )
                nextID += 1
            } else {
                currentItems.append(
                    Item(
                        id: nextID,
                        kind: .paragraph,
                        text: line,
                        pullNumber: nil,
                        pullURL: nil
                    )
                )
                nextID += 1
            }
        }

        flushSection()

        let builtSections = sections.enumerated().map { index, entry in
            Section(id: index, title: entry.title, items: entry.items)
        }
        return FormattedReleaseNotes(sections: builtSections, compareURL: compareURL)
    }

    private static func sortChangeItemsIfAppropriate(_ items: [Item]) -> [Item] {
        // 段落混じりの手動リリースノートは記述順を維持し、箇条書きのみのセクションは種別順（新機能→修正→改善→基盤）に整列する。
        let hasParagraph = items.contains {
            if case .paragraph = $0.kind { return true }
            return false
        }
        guard !hasParagraph else { return items }
        return items.enumerated().sorted { lhs, rhs in
            guard case .change(let leftCat) = lhs.element.kind,
                  case .change(let rightCat) = rhs.element.kind else {
                return lhs.offset < rhs.offset
            }
            if leftCat != rightCat { return leftCat < rightCat }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func stripBulletPrefix(_ line: String) -> String? {
        for prefix in ["* ", "- ", "+ ", "・"] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func extractFullChangelogURL(from line: String) -> URL? {
        let stripped = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        guard stripped.lowercased().hasPrefix("full changelog:") else { return nil }
        let urlPart = stripped.dropFirst("full changelog:".count).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlPart), AppRelease.trustedRepositoryWebURL(url) else { return nil }
        return url
    }

    private static func extractTrailingPRReference(from text: String) -> (String, Int?, URL?) {
        // 例: "... by @HR0101 in https://github.com/HR0101/ArkServer/pull/60"
        // または "... in https://github.com/HR0101/ArkServer/pull/60"
        if let range = text.range(
            of: #"(?:\s+by\s+@[\w\-]+)?\s+in\s+(https://github\.com/HR0101/ArkServer/pull/(\d+))\s*$"#,
            options: .regularExpression
        ) {
            let suffix = String(text[range])
            let cleaned = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let urlRange = suffix.range(of: #"https://github\.com/HR0101/ArkServer/pull/\d+"#, options: .regularExpression) {
                let urlString = String(suffix[urlRange])
                let numberString = urlString.components(separatedBy: "/").last ?? ""
                let url = URL(string: urlString).flatMap { AppRelease.trustedRepositoryWebURL($0) ? $0 : nil }
                return (cleaned, Int(numberString), url)
            }
            return (cleaned, nil, nil)
        }
        return (text, nil, nil)
    }

    private static func extractConventionalPrefix(from text: String) -> (Category, String) {
        // 例: "feat(ui/musicvideo): 説明" / "fix: 説明"
        guard let matchRange = text.range(
            of: #"^([A-Za-z]+)(?:\([^)]*\))?!?\s*[:：]\s*"#,
            options: .regularExpression
        ) else {
            return (.general, text)
        }
        let prefixHeader = String(text[matchRange])
        let remainder = String(text[matchRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return (.general, text) }

        let typeToken = prefixHeader
            .prefix(while: { $0.isLetter })
            .lowercased()

        let category: Category? = switch typeToken {
        case "feat", "add": .feature
        case "fix", "bugfix", "hotfix": .fix
        case "refactor", "perf", "style", "ui", "improve": .improvement
        case "docs", "doc": .docs
        case "test", "tests", "ci", "build", "chore", "merge", "revert": .internalChange
        default: nil
        }

        guard let category else {
            return (.general, text)
        }
        return (category, remainder)
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case response
    case rateLimited
    case http(Int)
    case invalidRelease
    case nonWritableLocation(String)
    case mountFailed(String)
    case appNotFoundInDMG
    case copyFailed(String)
    case invalidAppBundle
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case signatureVerificationFailed(String)
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .response:
            return "更新サーバーから有効な応答を取得できませんでした。"
        case .rateLimited:
            return "GitHubのアクセス制限に達しました。しばらく待ってから再試行してください。"
        case .http(let code):
            return "更新サーバーでエラーが発生しました（HTTP \(code)）。"
        case .invalidRelease:
            return "リリース情報の形式が正しくありません。"
        case .nonWritableLocation(let path):
            return "現在の場所（\(path)）にあるアプリは書き換えできないため、自動アップデートできません。アプリを「アプリケーション」フォルダへ移動してから再試行してください。"
        case .mountFailed(let detail):
            return "アップデート用ディスクイメージを開けませんでした（\(detail)）。"
        case .appNotFoundInDMG:
            return "ディスクイメージ内にアプリケーションが見つかりませんでした。"
        case .copyFailed(let detail):
            return "新しいアプリケーションの配置に失敗しました（\(detail)）。"
        case .invalidAppBundle:
            return "ダウンロードしたアプリケーションの形式が正しくありません。"
        case .bundleIdentifierMismatch(let expected, let actual):
            return "アプリケーションの識別子が一致しません（期待値: \(expected), 実際: \(actual ?? "不明")）。"
        case .signatureVerificationFailed(let detail):
            return "ダウンロードしたアプリケーションの署名検証に失敗しました（\(detail)）。"
        case .relaunchFailed(let detail):
            return "更新後の再起動処理を開始できませんでした（\(detail)）。"
        }
    }
}

enum AppUpdateInstaller {
    struct CommandOutput: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated static func runCommand(_ executablePath: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    nonisolated static func canWrite(to targetBundleURL: URL) -> Bool {
        let fm = FileManager.default
        guard targetBundleURL.pathExtension == "app",
              !targetBundleURL.path.contains("/AppTranslocation/") else {
            return false
        }
        let parentURL = targetBundleURL.deletingLastPathComponent()
        var statInfo = statfs()
        if statfs(parentURL.path, &statInfo) == 0 {
            if (statInfo.f_flags & UInt32(MNT_RDONLY)) != 0 {
                return false
            }
        }
        return fm.isWritableFile(atPath: parentURL.path) && fm.isWritableFile(atPath: targetBundleURL.path)
    }

    nonisolated static func validateWritableTarget(_ targetBundleURL: URL) throws {
        guard canWrite(to: targetBundleURL) else {
            throw AppUpdateError.nonWritableLocation(targetBundleURL.path)
        }
    }

    /// DMGをマウントして中の `.app` を検証し、対象アプリと同じ親ディレクトリ内に一時配置して返す。
    nonisolated static func stageUpdate(
        fromDMG dmgURL: URL,
        targetBundleURL: URL,
        expectedBundleIdentifier: String?,
        verifySignature: Bool = true
    ) throws -> URL {
        try validateWritableTarget(targetBundleURL)
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ArkServerUpdateStage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let mountPoint = workDir.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = try runCommand(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path, dmgURL.path]
        )
        guard attach.status == 0 else {
            let detail = attach.stderr.isEmpty ? attach.stdout : attach.stderr
            throw AppUpdateError.mountFailed(detail.isEmpty ? "exit \(attach.status)" : detail)
        }
        defer {
            _ = try? runCommand("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }

        guard let appInDMG = try findAppBundle(in: mountPoint, preferredName: targetBundleURL.lastPathComponent) else {
            throw AppUpdateError.appNotFoundInDMG
        }

        let extractedAppURL = workDir.appendingPathComponent(targetBundleURL.lastPathComponent, isDirectory: true)
        let copyFromDMG = try runCommand("/usr/bin/ditto", [appInDMG.path, extractedAppURL.path])
        guard copyFromDMG.status == 0 else {
            let detail = copyFromDMG.stderr.isEmpty ? "exit \(copyFromDMG.status)" : copyFromDMG.stderr
            throw AppUpdateError.copyFailed(detail)
        }

        _ = try? runCommand("/usr/bin/xattr", ["-dr", "com.apple.quarantine", extractedAppURL.path])

        let infoPlistURL = extractedAppURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let executableName = plist["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            throw AppUpdateError.invalidAppBundle
        }
        let executableURL = extractedAppURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            throw AppUpdateError.invalidAppBundle
        }

        let actualBundleID = plist["CFBundleIdentifier"] as? String
        if let expected = expectedBundleIdentifier, actualBundleID != expected {
            throw AppUpdateError.bundleIdentifierMismatch(expected: expected, actual: actualBundleID)
        }

        if verifySignature {
            let verify = try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", extractedAppURL.path])
            guard verify.status == 0 else {
                let detail = verify.stderr.isEmpty ? verify.stdout : verify.stderr
                throw AppUpdateError.signatureVerificationFailed(detail.isEmpty ? "exit \(verify.status)" : detail)
            }
        }

        let parentDir = targetBundleURL.deletingLastPathComponent()
        let baseName = targetBundleURL.deletingPathExtension().lastPathComponent
        let stagedInParentURL = parentDir.appendingPathComponent(".\(baseName)-update-\(UUID().uuidString).app", isDirectory: true)
        let stageCopy = try runCommand("/usr/bin/ditto", [extractedAppURL.path, stagedInParentURL.path])
        guard stageCopy.status == 0 else {
            try? fm.removeItem(at: stagedInParentURL)
            let detail = stageCopy.stderr.isEmpty ? "exit \(stageCopy.status)" : stageCopy.stderr
            throw AppUpdateError.copyFailed(detail)
        }

        return stagedInParentURL
    }

    /// ステージ済み `.app` で対象 `.app` をアトミックに置き換える（失敗時は元のアプリへロールバック）。
    nonisolated static func replaceAppBundle(targetBundleURL: URL, withStagedBundleURL stagedBundleURL: URL) throws {
        let fm = FileManager.default
        let parentDir = targetBundleURL.deletingLastPathComponent()
        let baseName = targetBundleURL.deletingPathExtension().lastPathComponent
        let backupURL = parentDir.appendingPathComponent(".\(baseName)-backup-\(UUID().uuidString).app", isDirectory: true)
        try? fm.removeItem(at: backupURL)
        do {
            try fm.moveItem(at: targetBundleURL, to: backupURL)
            do {
                try fm.moveItem(at: stagedBundleURL, to: targetBundleURL)
                try? fm.removeItem(at: backupURL)
            } catch {
                try? fm.moveItem(at: backupURL, to: targetBundleURL)
                try? fm.removeItem(at: stagedBundleURL)
                throw AppUpdateError.copyFailed(error.localizedDescription)
            }
        } catch let error as AppUpdateError {
            throw error
        } catch {
            try? fm.removeItem(at: stagedBundleURL)
            throw AppUpdateError.copyFailed(error.localizedDescription)
        }
    }

    /// 現在のプロセス終了を待ってからアプリバンドルを差し替え、新しいアプリを起動する独立プロセスを開始する。
    nonisolated static func launchReplacementScriptAndRelaunch(
        targetBundleURL: URL,
        stagedBundleURL: URL,
        waitingForPID pid: Int32,
        reopen: Bool = true
    ) throws {
        let parentDir = targetBundleURL.deletingLastPathComponent()
        let baseName = targetBundleURL.deletingPathExtension().lastPathComponent
        let backupURL = parentDir.appendingPathComponent(".\(baseName)-backup-\(UUID().uuidString).app", isDirectory: true)

        let script = """
        trap '' HUP INT TERM PIPE
        PID="$1"
        TARGET="$2"
        STAGED="$3"
        BACKUP="$4"
        REOPEN="$5"

        i=0
        while kill -0 "$PID" 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -ge 300 ]; then
                rm -rf "$STAGED"
                exit 1
            fi
            sleep 0.1
        done

        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP" && mv "$STAGED" "$TARGET"; then
            rm -rf "$BACKUP"
            if [ "$REOPEN" = "1" ]; then
                /usr/bin/open "$TARGET"
            fi
            exit 0
        else
            if [ ! -e "$TARGET" ] && [ -e "$BACKUP" ]; then
                mv "$BACKUP" "$TARGET"
            fi
            rm -rf "$STAGED"
            if [ "$REOPEN" = "1" ]; then
                /usr/bin/open "$TARGET"
            fi
            exit 1
        fi
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "arkserver-updater",
            "\(pid)",
            targetBundleURL.path,
            stagedBundleURL.path,
            backupURL.path,
            reopen ? "1" : "0"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: stagedBundleURL)
            throw AppUpdateError.relaunchFailed(error.localizedDescription)
        }
    }

    private nonisolated static func findAppBundle(in mountPoint: URL, preferredName: String) throws -> URL? {
        let fm = FileManager.default
        for candidateName in [preferredName, "ArkServer.app"] {
            let candidate = mountPoint.appendingPathComponent(candidateName, isDirectory: true)
            if isRealAppDirectory(candidate) {
                return candidate
            }
        }
        let items = try fm.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return items.first { isRealAppDirectory($0) }
    }

    private nonisolated static func isRealAppDirectory(_ url: URL) -> Bool {
        guard url.pathExtension == "app",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }
        return true
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    static let automaticKey = "updates.checkAtLaunch"
    static let skippedKey = "updates.skippedVersion"
    static let lastCheckKey = "updates.lastCheck"
    static let latestURL = URL(string: "https://api.github.com/repos/HR0101/ArkServer/releases/latest")!

    typealias RelaunchHandler = @MainActor (_ targetBundleURL: URL, _ stagedBundleURL: URL) throws -> Void

    enum State: Equatable {
        case idle, checking, available(AppRelease), upToDate, noRelease
        case downloading(AppRelease), installing(AppRelease), downloaded(URL), failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var availableRelease: AppRelease?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Self.automaticKey) }
    }
    let currentVersion: String
    let currentBuild: String
    let targetBundleURL: URL
    let expectedBundleIdentifier: String?
    private let defaults: UserDefaults
    private let session: URLSession
    private var operation: Task<Void, Never>?
    private var downloadID: UUID?
    private var window: NSWindow?
    private var manualRequested = false
    private let presentsWindows: Bool
    private let relaunchHandler: RelaunchHandler?

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        version: String? = nil,
        build: String? = nil,
        presentsWindows: Bool = true,
        targetBundleURL: URL = Bundle.main.bundleURL,
        expectedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        relaunchHandler: RelaunchHandler? = nil
    ) {
        self.defaults = defaults
        self.session = session
        self.presentsWindows = presentsWindows
        self.targetBundleURL = targetBundleURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.relaunchHandler = relaunchHandler
        currentVersion = version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentBuild = build ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        automaticallyChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var isBusy: Bool {
        switch state { case .checking, .downloading, .installing: return true; default: return false }
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
                    availableRelease = nil
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
                        availableRelease = nil
                        state = .idle
                    } else {
                        availableRelease = release
                        state = .available(release)
                    }
                } else {
                    availableRelease = nil
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
        availableRelease = nil
        state = .idle
        window?.close()
    }

    /// DMGの自動ダウンロード・マウント・署名/識別子検証・アプリバンドルの自動置換・再起動を一括で行う。
    func install(_ release: AppRelease) {
        guard !isBusy, let url = release.downloadURL else { return }
        do {
            try AppUpdateInstaller.validateWritableTarget(targetBundleURL)
        } catch {
            availableRelease = release
            state = .failed(error.localizedDescription)
            return
        }
        let id = UUID()
        downloadID = id
        availableRelease = release
        state = .downloading(release)
        progress = nil
        operation = Task {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArkServerDownload-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workDir) }
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let delegate = UpdateDownloadProgress { [weak self] value in
                    Task { @MainActor in
                        guard self?.downloadID == id, case .downloading = self?.state else { return }
                        self?.progress = value
                    }
                }
                let (temporary, response) = try await session.download(
                    for: URLRequest(url: url, timeoutInterval: 300),
                    delegate: delegate
                )
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw AppUpdateError.response }
                try Self.validateHTTP(http)

                let dmgURL = workDir.appendingPathComponent("ArkServer.dmg")
                try FileManager.default.moveItem(at: temporary, to: dmgURL)
                try Task.checkCancellation()

                downloadID = nil
                progress = nil
                state = .installing(release)

                try await performInstallation(fromDMG: dmgURL)
            } catch {
                guard !Task.isCancelled else { return }
                downloadID = nil
                progress = nil
                state = .failed("アップデートできませんでした。\(error.localizedDescription)")
            }
        }
    }

    /// ダウンロード済みのDMGから直接アップデートを適用して再起動する。
    func install(dmgURL: URL) {
        guard !isBusy else { return }
        do {
            try AppUpdateInstaller.validateWritableTarget(targetBundleURL)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let release = availableRelease ?? AppRelease(
            tag_name: "最新版",
            html_url: URL(string: "https://github.com/HR0101/ArkServer/releases/latest")!,
            body: nil,
            draft: false,
            prerelease: false,
            assets: []
        )
        state = .installing(release)
        progress = nil
        operation = Task {
            do {
                try await performInstallation(fromDMG: dmgURL)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed("アップデートできませんでした。\(error.localizedDescription)")
            }
        }
    }

    private func performInstallation(fromDMG dmgURL: URL) async throws {
        let targetURL = targetBundleURL
        let expectedBundleID = expectedBundleIdentifier
        let stagedBundleURL = try await Task.detached(priority: .userInitiated) {
            try AppUpdateInstaller.stageUpdate(
                fromDMG: dmgURL,
                targetBundleURL: targetURL,
                expectedBundleIdentifier: expectedBundleID
            )
        }.value

        if let relaunchHandler {
            try relaunchHandler(targetURL, stagedBundleURL)
        } else {
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            try AppUpdateInstaller.launchReplacementScriptAndRelaunch(
                targetBundleURL: targetURL,
                stagedBundleURL: stagedBundleURL,
                waitingForPID: ProcessInfo.processInfo.processIdentifier,
                reopen: true
            )
            NSApplication.shared.terminate(nil)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                exit(0)
            }
        }
    }

    /// DMGをダウンロードフォルダへ保存する（手動適用または読み取り専用環境向けのフォールバック）。
    func download(_ release: AppRelease) {
        guard !isBusy, let url = release.downloadURL else { return }
        let id = UUID()
        downloadID = id
        availableRelease = release
        state = .downloading(release)
        progress = nil
        operation = Task {
            do {
                let delegate = UpdateDownloadProgress { [weak self] value in
                    Task { @MainActor in
                        guard self?.downloadID == id, case .downloading = self?.state else { return }
                        self?.progress = value
                    }
                }
                let (temporary, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 300), delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw AppUpdateError.response }
                try Self.validateHTTP(http)
                let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let destination = directory.appendingPathComponent("ArkServer-\(UUID().uuidString).dmg")
                try FileManager.default.moveItem(at: temporary, to: destination)
                downloadID = nil
                state = .downloaded(destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                guard !Task.isCancelled else { return }
                downloadID = nil
                state = .failed("ダウンロードできませんでした。\(error.localizedDescription) リリースページから手動でダウンロードできます。")
            }
        }
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
            let hosting = NSHostingController(rootView: AppUpdateView(updater: self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Ark Server アップデート"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 420)
            window.setContentSize(NSSize(width: 680, height: 560))
            window.center()
            self.window = window
        }
        window?.appearance = NSAppearance(named: NeomorphicTheme.isDarkBase ? .darkAqua : .aqua)
        window?.backgroundColor = NSColor(NeomorphicTheme.canvas)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated let report: @Sendable (Double?) -> Void
    nonisolated init(report: @escaping @Sendable (Double?) -> Void) { self.report = report }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
}
