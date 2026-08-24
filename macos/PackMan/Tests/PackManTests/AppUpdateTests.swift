import CryptoKit
import Foundation
import XCTest
@testable import PackMan

final class AppUpdateTests: XCTestCase {
    private let newerVersion = "99.0.0"
    private let downloadURL = URL(string: "https://github.com/dklasens/PackMan/releases/download/v99.0.0/PackMan-macOS.zip")!
    private let checksumURL = URL(string: "https://github.com/dklasens/PackMan/releases/download/v99.0.0/PackMan-macOS.zip.sha256")!
    private let releaseURL = URL(string: "https://github.com/dklasens/PackMan/releases/tag/v99.0.0")!

    func testNewerReleaseIsDetectedWithMacAssets() async throws {
        let settings = MemorySettings()
        let service = AppUpdateService(
            settings: settings,
            transport: StubAppUpdateTransport.json(releaseJSON(tag: newerVersion)),
            currentVersion: AppVersion("1.8.0")!)

        let update = try await service.check(force: true)

        XCTAssertEqual(update?.version, newerVersion)
        XCTAssertEqual(update?.downloadURL, downloadURL)
        XCTAssertEqual(update?.checksumURL, checksumURL)
        XCTAssertEqual(update?.releaseURL, releaseURL)
        XCTAssertNotNil(settings.lastAppUpdateCheck())
        XCTAssertEqual(settings.availableAppUpdate(), update)
    }

    func testOlderReleaseReturnsNilAndClearsPersistedUpdate() async throws {
        let settings = MemorySettings()
        settings.storedAvailableAppUpdate = sampleUpdate
        let service = AppUpdateService(
            settings: settings,
            transport: StubAppUpdateTransport.json(releaseJSON(tag: "0.0.1")),
            currentVersion: AppVersion("1.8.0")!)

        let update = try await service.check(force: true)
        XCTAssertNil(update)
        XCTAssertNil(settings.availableAppUpdate())
    }

    func testPrereleasesAndDraftsAreIgnored() async throws {
        let prerelease = AppUpdateService(
            settings: MemorySettings(),
            transport: StubAppUpdateTransport.json(releaseJSON(tag: newerVersion, prerelease: true)),
            currentVersion: AppVersion("1.8.0")!)
        let draft = AppUpdateService(
            settings: MemorySettings(),
            transport: StubAppUpdateTransport.json(releaseJSON(tag: newerVersion, draft: true)),
            currentVersion: AppVersion("1.8.0")!)

        let prereleaseUpdate = try await prerelease.check(force: true)
        let draftUpdate = try await draft.check(force: true)
        XCTAssertNil(prereleaseUpdate)
        XCTAssertNil(draftUpdate)
    }

    func testMissingMacAssetReturnsNil() async throws {
        let service = AppUpdateService(
            settings: MemorySettings(),
            transport: StubAppUpdateTransport.json(releaseJSON(tag: newerVersion, includeMacAssets: false)),
            currentVersion: AppVersion("1.8.0")!)
        let update = try await service.check(force: true)
        XCTAssertNil(update)
    }

    func testNoReleasesAtAllReturnsNil() async throws {
        let transport = StubAppUpdateTransport { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let service = AppUpdateService(
            settings: MemorySettings(),
            transport: transport,
            currentVersion: AppVersion("1.8.0")!)
        let update = try await service.check(force: true)
        XCTAssertNil(update)
    }

    func testThrottledCheckUsesPersistedUpdateWithoutNetwork() async throws {
        let settings = MemorySettings()
        settings.lastAppUpdateCheckAt = Date()
        settings.storedAvailableAppUpdate = sampleUpdate
        let transport = StubAppUpdateTransport { _ in
            XCTFail("No network call is expected while throttled.")
            throw AppUpdateError.invalidResponse
        }
        let service = AppUpdateService(
            settings: settings,
            transport: transport,
            currentVersion: AppVersion("1.8.0")!)

        let update = try await service.check(force: false)
        XCTAssertEqual(update?.version, newerVersion)
    }

    func testSkippedVersionIsHiddenUntilForced() async throws {
        let settings = MemorySettings()
        settings.lastAppUpdateCheckAt = Date()
        settings.storedAvailableAppUpdate = sampleUpdate
        settings.skippedAppVersion = newerVersion
        let service = AppUpdateService(
            settings: settings,
            transport: StubAppUpdateTransport.json(releaseJSON(tag: newerVersion)),
            currentVersion: AppVersion("1.8.0")!)

        let throttled = try await service.check(force: false)
        let forced = try await service.check(force: true)
        XCTAssertNil(throttled)
        XCTAssertEqual(forced?.version, newerVersion)
    }

    func testApplyStagesVerifiedAppAndLaunchesHelper() async throws {
        let (zipData, appRoot) = try makeAppZip(version: newerVersion)
        addTeardownBlock { try? FileManager.default.removeItem(at: appRoot) }
        let hash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let transport = StubAppUpdateTransport { request in
            if request.url?.lastPathComponent == "PackMan-macOS.zip" {
                return (zipData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (
                Data("\(hash)  PackMan-macOS.zip".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let target = appRoot.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let targetApp = target.appendingPathComponent("PackMan.app")
        try FileManager.default.createDirectory(at: targetApp, withIntermediateDirectories: true)

        var launched: UpdateApplyRequest?
        let service = AppUpdateService(
            settings: MemorySettings(),
            transport: transport,
            currentVersion: AppVersion("1.8.0")!,
            targetBundleURL: targetApp,
            launchApplyHelper: { request in
                launched = request
                return true
            }
        )

        try await service.apply(sampleUpdate, progress: nil)

        XCTAssertNotNil(launched)
        XCTAssertEqual(launched?.targetApp.standardizedFileURL, targetApp.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: launched!.stagedApp.path))
        XCTAssertEqual(UpdateApplier.shortVersion(of: launched!.stagedApp)?.displayString, newerVersion)
    }

    func testChecksumMismatchRejectsUpdate() async throws {
        let (zipData, appRoot) = try makeAppZip(version: newerVersion)
        addTeardownBlock { try? FileManager.default.removeItem(at: appRoot) }
        let transport = StubAppUpdateTransport { request in
            if request.url?.lastPathComponent == "PackMan-macOS.zip" {
                return (zipData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (
                Data("\(String(repeating: "0", count: 64))  PackMan-macOS.zip".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let target = appRoot.appendingPathComponent("PackMan.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = AppUpdateService(
            settings: MemorySettings(),
            transport: transport,
            currentVersion: AppVersion("1.8.0")!,
            targetBundleURL: target,
            launchApplyHelper: { _ in true }
        )

        do {
            try await service.apply(sampleUpdate, progress: nil)
            XCTFail("Expected checksum failure")
        } catch AppUpdateError.checksumMismatch {
            // expected
        }
    }

    func testApplyRefusesDisallowedHosts() async throws {
        let service = AppUpdateService(
            settings: MemorySettings(),
            currentVersion: AppVersion("1.8.0")!)
        let update = AppUpdateInfo(
            version: newerVersion,
            downloadURL: URL(string: "https://evil.example/PackMan-macOS.zip")!,
            checksumURL: checksumURL,
            releaseURL: releaseURL)
        do {
            try await service.apply(update, progress: nil)
            XCTFail("Expected host rejection")
        } catch AppUpdateError.disallowedHost("evil.example") {
            // expected
        }
    }

    func testHelperLaunchFailureThrows() async throws {
        let (zipData, appRoot) = try makeAppZip(version: newerVersion)
        addTeardownBlock { try? FileManager.default.removeItem(at: appRoot) }
        let hash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let transport = StubAppUpdateTransport { request in
            if request.url?.lastPathComponent == "PackMan-macOS.zip" {
                return (zipData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (
                Data("\(hash)  PackMan-macOS.zip".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let target = appRoot.appendingPathComponent("PackMan.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = AppUpdateService(
            settings: MemorySettings(),
            transport: transport,
            currentVersion: AppVersion("1.8.0")!,
            targetBundleURL: target,
            launchApplyHelper: { _ in false }
        )

        do {
            try await service.apply(sampleUpdate, progress: nil)
            XCTFail("Expected helper failure")
        } catch AppUpdateError.helperFailed {
            // expected
        }
    }

    func testReplaceBundleSwapsApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let staged = try makeFakeApp(at: root.appendingPathComponent("staged/PackMan.app"), version: "99.0.0", marker: "new-bits")
        let target = try makeFakeApp(at: root.appendingPathComponent("installed/PackMan.app"), version: "1.8.0", marker: "old-bits")

        try UpdateApplier.replaceBundle(stagedApp: staged, targetApp: target)

        let marker = try String(contentsOf: target.appendingPathComponent("Contents/MacOS/PackMan"), encoding: .utf8)
        XCTAssertEqual(marker, "new-bits")
        XCTAssertEqual(UpdateApplier.shortVersion(of: target)?.displayString, "99.0.0")
    }

    func testIsTrustedRejectsTargetsOtherThanItself() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackMan", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("PackMan.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("other.app")

        XCTAssertFalse(UpdateApplier.isTrusted(
            stagedApp: staged,
            targetApp: target,
            stagingRoot: root,
            ownBundle: root.appendingPathComponent("elsewhere.app")))
    }

    func testIsTrustedRejectsStagedFilesOutsideStagingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackMan", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("stray-\(UUID().uuidString).app")
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("PackMan.app")

        XCTAssertFalse(UpdateApplier.isTrusted(
            stagedApp: outside,
            targetApp: target,
            stagingRoot: root,
            ownBundle: target))
    }

    func testVersionComparison() {
        XCTAssertEqual(AppVersion("v1.8"), AppVersion("1.8.0"))
        XCTAssertTrue(AppVersion("1.8.1")! > AppVersion("1.8.0")!)
        XCTAssertTrue(AppVersion("2.0")! > AppVersion("1.9.9")!)
        XCTAssertNil(AppVersion("nope"))
    }

    private var sampleUpdate: AppUpdateInfo {
        AppUpdateInfo(
            version: newerVersion,
            downloadURL: downloadURL,
            checksumURL: checksumURL,
            releaseURL: releaseURL)
    }

    private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false, includeMacAssets: Bool = true) -> String {
        let assets = includeMacAssets
            ? """
              { "name": "PackMan-macOS.zip", "browser_download_url": "\(downloadURL.absoluteString)" },
              { "name": "PackMan-macOS.zip.sha256", "browser_download_url": "\(checksumURL.absoluteString)" },
            """
            : ""
        return """
            {
              "tag_name": "v\(tag)",
              "html_url": "\(releaseURL.absoluteString)",
              "draft": \(draft),
              "prerelease": \(prerelease),
              "assets": [
                \(assets){ "name": "PackMan-Windows-x64.zip", "browser_download_url": "https://github.com/dklasens/PackMan/releases/download/v\(tag)/PackMan-Windows-x64.zip" }
              ]
            }
            """
    }

    private func makeAppZip(version: String) throws -> (Data, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = try makeFakeApp(at: root.appendingPathComponent("PackMan.app"), version: version, marker: "payload-\(UUID().uuidString)")
        let zip = root.appendingPathComponent("PackMan-macOS.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (try Data(contentsOf: zip), root)
    }

    private func makeFakeApp(at url: URL, version: String, marker: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleShortVersionString</key><string>\(version)</string>
              <key>CFBundleExecutable</key><string>PackMan</string>
            </dict></plist>
            """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try Data(marker.utf8).write(to: macos.appendingPathComponent("PackMan"))
        return url
    }
}

private struct StubAppUpdateTransport: AppUpdateTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static func json(_ body: String) -> StubAppUpdateTransport {
        StubAppUpdateTransport { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}
