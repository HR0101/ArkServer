import Foundation
import Testing
@testable import ArkServer

@Suite(.serialized)
@MainActor
struct AppUpdaterTests {
    @Test func semanticVersions() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2", "1.10"]
        let versions = try ordered.map { try #require(UpdateVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b) }
        #expect(UpdateVersion("v1.2.0") == UpdateVersion("1.2"))
        #expect(UpdateVersion("1.0.0+build.2") == UpdateVersion("1.0.0+build.1"))
        for invalid in ["", "1..2", "1.2.3.4", "1.0.0-", "01.2.3", "1.0.0-01", "1.0.0+", "garbage"] {
            #expect(UpdateVersion(invalid) == nil)
        }
        let current = try #require(UpdateVersion("1.0.0"))
        #expect(try #require(UpdateVersion("1.0.0+2")).isNewer(than: current, currentBuild: 1))
        #expect(!current.isNewer(than: current, currentBuild: 1))
        #expect(!(try #require(UpdateVersion("0.9.0+99"))).isNewer(than: current, currentBuild: 1))
    }

    @Test func checksAndSkipPersistence() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        UpdateMockProtocol.response = (200, releaseJSON(), nil)
        // Automatic detection stops at availability; installation requires user action.
        updater.check(manual: false)
        #expect(updater.state == .checking)
        await finish(updater)
        guard case .available(let release) = updater.state else { Issue.record("Expected update"); return }
        #expect(release.downloadURL != nil)
        #expect(updater.lastCheck != nil)
        updater.skip(release)
        #expect(updater.state == .idle)
        updater.check(manual: false)
        await finish(updater)
        #expect(updater.state == .idle)
        updater.check(manual: true)
        await finish(updater)
        #expect(updater.state == .available(release))
        updater.automaticallyChecks = false
        let restored = AppUpdater(defaults: defaults, session: session, version: "1.0", build: "1", presentsWindows: false)
        #expect(!restored.automaticallyChecks)
        #expect(restored.lastCheck != nil)
        UpdateMockProtocol.response = (200, releaseJSON(tag: "v3.0.0"), nil)
        updater.check(manual: false)
        await finish(updater)
        guard case .available(let newer) = updater.state else { Issue.record("New version should not be skipped"); return }
        #expect(newer.tag_name == "v3.0.0")
    }

    @Test func sameAndOlderAreUpToDate() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        for tag in ["v1.0.0", "v0.9.0"] {
            UpdateMockProtocol.response = (200, releaseJSON(tag: tag), nil)
            updater.check(manual: true)
            await finish(updater)
            #expect(updater.state == .upToDate)
        }
        UpdateMockProtocol.response = (404, Data(), nil)
        updater.check(manual: true)
        await finish(updater)
        #expect(updater.state == .noRelease)
    }

    @Test func malformedAndNetworkErrors() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        for response: (Int, Data, Error?) in [
            (200, Data("not JSON".utf8), nil),
            (200, releaseJSON(tag: "nonsense"), nil),
            (403, Data(), nil), (429, Data(), nil), (500, Data(), nil),
            (200, Data(), URLError(.notConnectedToInternet)),
            (200, Data(), URLError(.timedOut))
        ] {
            UpdateMockProtocol.response = response
            updater.check(manual: true)
            await finish(updater)
            guard case .failed = updater.state else { Issue.record("Expected visible manual error"); continue }
            #expect(updater.lastCheck == nil)
            updater.check(manual: false)
            await finish(updater)
            #expect(updater.state == .idle)
        }
    }

    @Test func downloadCancellationRestoresOffer() async throws {
        let (updater, defaults, session, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        let release = try JSONDecoder().decode(AppRelease.self, from: releaseJSON())
        updater.download(release)
        #expect(updater.state == .downloading(release))
        updater.check(manual: true)
        #expect(updater.state == .downloading(release))
        updater.cancelDownload()
        #expect(updater.state == .available(release))
        try await Task.sleep(for: .milliseconds(50))
        #expect(updater.state == .available(release))
        #expect(updater.progress == nil)
    }

    @Test func onlyRepositoryAssetsAreTrusted() throws {
        #expect(!AppRelease.trustedURL(URL(string: "http://github.com/HR0101/ArkServer/releases/tag/v2")!))
        #expect(!AppRelease.trustedURL(URL(string: "https://evil.example/HR0101/ArkServer/releases/tag/v2")!))
        #expect(!AppRelease.trustedURL(URL(string: "https://github.com/HR0101/Other/releases/tag/v2")!))
        #expect(AppRelease.trustedURL(URL(string: "https://github.com/HR0101/ArkServer/releases/download/v2/ArkServer.dmg")!, download: true))
    }

    @Test func formatsGitHubAndCustomReleaseNotesCleanly() throws {
        let githubGenerated = """
        ## What's Changed
        * ci(release): Developer ID署名とApple公証に対応 by @HR0101 in https://github.com/HR0101/ArkServer/pull/70
        * fix(security): 認証オフ時の削除PINにも総当たり制限を適用する by @HR0101 in https://github.com/HR0101/ArkServer/pull/58
        * feat(musicvideo): 曲の拍に合わせて自動編集する機能を追加 by @HR0101 in https://github.com/HR0101/ArkServer/pull/60
        * refactor(musicvideo): プレビューと3つの操作パネルに画面を整理 by @HR0101 in https://github.com/HR0101/ArkServer/pull/67

        ## New Contributors
        * @HR0101 made their first contribution in https://github.com/HR0101/ArkServer/pull/58

        **Full Changelog**: https://github.com/HR0101/ArkServer/compare/v1.0.0...v1.0.1
        """

        let parsed = FormattedReleaseNotes.parse(githubGenerated)
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].title == nil)
        #expect(parsed.changeCount == 4)
        #expect(parsed.compareURL?.absoluteString == "https://github.com/HR0101/ArkServer/compare/v1.0.0...v1.0.1")

        let items = parsed.sections[0].items
        #expect(items.map(\.text) == [
            "曲の拍に合わせて自動編集する機能を追加",
            "認証オフ時の削除PINにも総当たり制限を適用する",
            "プレビューと3つの操作パネルに画面を整理",
            "Developer ID署名とApple公証に対応"
        ])
        #expect(items.map(\.pullNumber) == [60, 58, 67, 70])
        #expect(items[0].kind == .change(.feature))
        #expect(items[1].kind == .change(.fix))
        #expect(items[2].kind == .change(.improvement))
        #expect(items[3].kind == .change(.internalChange))

        let customMarkdown = """
        ## 主な変更点
        - **自動アップデート**に対応しました
        細かな安定性も改善しています。
        """
        let customParsed = FormattedReleaseNotes.parse(customMarkdown)
        #expect(customParsed.sections.count == 1)
        #expect(customParsed.sections[0].title == "主な変更点")
        #expect(customParsed.sections[0].items.count == 2)
    }

    @Test func installAutomaticallyMountsDMGVerifiesAndReplacesAppBundle() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("UpdaterInstallTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let installDir = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        let targetAppURL = installDir.appendingPathComponent("ArkServer.app", isDirectory: true)
        try makeSignedDummyApp(at: targetAppURL, bundleID: "hr.AllServerForMac", version: "1.0.0", build: "1")

        let dmgURL = tempRoot.appendingPathComponent("ArkServer.dmg")
        try makeDummyReleaseDMG(at: dmgURL, bundleID: "hr.AllServerForMac", version: "2.0.0", build: "2")
        let dmgData = try Data(contentsOf: dmgURL)

        var relaunchedTarget: URL?
        let (updater, defaults, session, suite) = try fixture(
            targetBundleURL: targetAppURL,
            expectedBundleIdentifier: "hr.AllServerForMac"
        ) { target, staged in
            try AppUpdateInstaller.replaceAppBundle(targetBundleURL: target, withStagedBundleURL: staged)
            relaunchedTarget = target
        }
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }

        let release = try JSONDecoder().decode(AppRelease.self, from: releaseJSON(tag: "v2.0.0"))
        UpdateMockProtocol.response = (200, dmgData, nil)

        updater.install(release)
        for _ in 0..<500 {
            if relaunchedTarget != nil { break }
            if case .failed = updater.state { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(relaunchedTarget == targetAppURL)
        let updatedPlist = try readInfoPlist(of: targetAppURL)
        #expect(updatedPlist["CFBundleShortVersionString"] as? String == "2.0.0")
        #expect(updatedPlist["CFBundleVersion"] as? String == "2")
        let remainingItems = try fm.contentsOfDirectory(atPath: installDir.path)
        #expect(remainingItems == ["ArkServer.app"])
    }

    @Test func installRejectsBundleIdentifierMismatchAndPreservesExistingApp() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("UpdaterMismatchTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let installDir = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        let targetAppURL = installDir.appendingPathComponent("ArkServer.app", isDirectory: true)
        try makeSignedDummyApp(at: targetAppURL, bundleID: "hr.AllServerForMac", version: "1.0.0", build: "1")

        let dmgURL = tempRoot.appendingPathComponent("ArkServer.dmg")
        try makeDummyReleaseDMG(at: dmgURL, bundleID: "com.example.UnexpectedApp", version: "2.0.0", build: "2")
        let dmgData = try Data(contentsOf: dmgURL)

        var relaunchCalled = false
        let (updater, defaults, session, suite) = try fixture(
            targetBundleURL: targetAppURL,
            expectedBundleIdentifier: "hr.AllServerForMac"
        ) { _, _ in
            relaunchCalled = true
        }
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }

        let release = try JSONDecoder().decode(AppRelease.self, from: releaseJSON(tag: "v2.0.0"))
        UpdateMockProtocol.response = (200, dmgData, nil)

        updater.install(release)
        await finish(updater)

        #expect(!relaunchCalled)
        guard case .failed(let message) = updater.state else {
            Issue.record("Expected installation failure on bundle ID mismatch")
            return
        }
        #expect(message.contains("識別子"))
        let currentPlist = try readInfoPlist(of: targetAppURL)
        #expect(currentPlist["CFBundleShortVersionString"] as? String == "1.0.0")
    }

    @Test func installRejectsTranslocatedOrNonWritableLocation() async throws {
        let translocatedURL = URL(fileURLWithPath: "/private/var/folders/xx/yy/T/AppTranslocation/ABC/d/ArkServer.app")
        let (updater, defaults, session, suite) = try fixture(
            targetBundleURL: translocatedURL,
            expectedBundleIdentifier: "hr.AllServerForMac"
        )
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }

        let release = try JSONDecoder().decode(AppRelease.self, from: releaseJSON(tag: "v2.0.0"))
        updater.install(release)
        guard case .failed(let message) = updater.state else {
            Issue.record("Expected non-writable location failure")
            return
        }
        #expect(message.contains("アプリケーション"))
        #expect(updater.availableRelease == release)
    }

    @Test func launchReplacementScriptWaitsForProcessExitAndSwapsBundle() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("UpdaterScriptTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let targetAppURL = tempRoot.appendingPathComponent("ArkServer.app", isDirectory: true)
        let stagedAppURL = tempRoot.appendingPathComponent(".ArkServer-update-test.app", isDirectory: true)
        try makeSignedDummyApp(at: targetAppURL, bundleID: "hr.AllServerForMac", version: "1.0.0", build: "1")
        try makeSignedDummyApp(at: stagedAppURL, bundleID: "hr.AllServerForMac", version: "2.1.0", build: "3")

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.2"]
        try sleeper.run()

        try AppUpdateInstaller.launchReplacementScriptAndRelaunch(
            targetBundleURL: targetAppURL,
            stagedBundleURL: stagedAppURL,
            waitingForPID: sleeper.processIdentifier,
            reopen: false
        )

        var updatedVersion: String?
        for _ in 0..<100 {
            if !fm.fileExists(atPath: stagedAppURL.path),
               let plist = try? readInfoPlist(of: targetAppURL),
               let version = plist["CFBundleShortVersionString"] as? String,
               version == "2.1.0" {
                updatedVersion = version
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(updatedVersion == "2.1.0")
    }

    private func fixture(
        targetBundleURL: URL = Bundle.main.bundleURL,
        expectedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        relaunchHandler: AppUpdater.RelaunchHandler? = nil
    ) throws -> (AppUpdater, UserDefaults, URLSession, String) {
        let suite = "UpdaterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let updater = AppUpdater(
            defaults: defaults,
            session: session,
            version: "1.0",
            build: "1",
            presentsWindows: false,
            targetBundleURL: targetBundleURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            relaunchHandler: relaunchHandler
        )
        return (updater, defaults, session, suite)
    }

    private func finish(_ updater: AppUpdater) async {
        for _ in 0..<500 {
            if !updater.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Update check timed out")
    }

    private func finishInstall(_ updater: AppUpdater) async {
        for _ in 0..<1000 {
            switch updater.state {
            case .downloading:
                try? await Task.sleep(for: .milliseconds(20))
            case .installing:
                // Wait until either failed or operation finishes
                try? await Task.sleep(for: .milliseconds(20))
            default:
                return
            }
        }
    }

    private func makeSignedDummyApp(at appURL: URL, bundleID: String, version: String, build: String) throws {
        let fm = FileManager.default
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent("ArkServer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Ark Server",
            "CFBundleExecutable": "ArkServer",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let sign = try AppUpdateInstaller.runCommand("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path])
        try #require(sign.status == 0, "codesign failed: \(sign.stderr)")
    }

    private func makeDummyReleaseDMG(at dmgURL: URL, bundleID: String, version: String, build: String) throws {
        let fm = FileManager.default
        let stagingDir = dmgURL.deletingLastPathComponent().appendingPathComponent("DMGStaging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let appURL = stagingDir.appendingPathComponent("ArkServer.app", isDirectory: true)
        try makeSignedDummyApp(at: appURL, bundleID: bundleID, version: version, build: build)
        try fm.createSymbolicLink(atPath: stagingDir.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")

        let create = try AppUpdateInstaller.runCommand(
            "/usr/bin/hdiutil",
            ["create", "-volname", "Ark Server", "-srcfolder", stagingDir.path, "-ov", "-format", "UDZO", dmgURL.path]
        )
        try #require(create.status == 0, "hdiutil create failed: \(create.stderr)")
    }

    private func readInfoPlist(of appURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(plist as? [String: Any])
    }

    private func releaseJSON(tag: String = "v2.0.0") -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/HR0101/ArkServer/releases/tag/\(tag)",
         "body":"Release notes","draft":false,"prerelease":false,
         "assets":[{"name":"ArkServer.dmg","browser_download_url":"https://github.com/HR0101/ArkServer/releases/download/\(tag)/ArkServer.dmg"}]}
        """.utf8)
    }
}

private final class UpdateMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data, Error?) = (200, Data(), nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, error) = Self.response
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
