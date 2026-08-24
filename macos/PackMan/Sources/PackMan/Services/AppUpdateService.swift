import CryptoKit
import Foundation

final class AppUpdateService: AppUpdateChecking, @unchecked Sendable {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/dklasens/PackMan/releases/latest")!
    static let zipAssetName = "PackMan-macOS.zip"
    static let checksumAssetName = zipAssetName + ".sha256"
    static let checkThrottle: TimeInterval = 24 * 60 * 60
    static let downloadTimeout: TimeInterval = 10 * 60
    static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
    ]

    private let transport: any AppUpdateTransport
    private let settings: any SettingsStoring
    private let fileManager: FileManager
    var currentVersion: AppVersion
    var targetBundleURL: URL
    var now: () -> Date
    var launchApplyHelper: (UpdateApplyRequest) -> Bool

    init(
        settings: any SettingsStoring,
        transport: any AppUpdateTransport = URLSessionAppUpdateTransport(),
        currentVersion: AppVersion = .current,
        targetBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        launchApplyHelper: ((UpdateApplyRequest) -> Bool)? = nil
    ) {
        self.settings = settings
        self.transport = transport
        self.currentVersion = currentVersion
        self.targetBundleURL = targetBundleURL
        self.fileManager = fileManager
        self.now = now
        self.launchApplyHelper = launchApplyHelper ?? UpdateApplier.launchHelper
    }

    func check(force: Bool) async throws -> AppUpdateInfo? {
        if !force,
           let lastCheck = settings.lastAppUpdateCheck(),
           now().timeIntervalSince(lastCheck) < Self.checkThrottle {
            return validate(settings.availableAppUpdate(), skipped: settings.skippedAppUpdateVersion(), force: force)
        }

        let release = try await fetchLatestRelease()
        try settings.setLastAppUpdateCheck(now())
        let newer = isNewer(release) ? release : nil
        try settings.setAvailableAppUpdate(newer)
        return validate(newer, skipped: settings.skippedAppUpdateVersion(), force: force)
    }

    func apply(_ update: AppUpdateInfo, progress: (@Sendable (String) -> Void)?) async throws {
        try Self.validateDownloadURL(update.downloadURL)
        try Self.validateDownloadURL(update.checksumURL)

        let targetDirectory = targetBundleURL.deletingLastPathComponent()
        guard Self.canWrite(to: targetDirectory, fileManager: fileManager) else {
            throw AppUpdateError.notWritable
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PackMan", isDirectory: true)
            .appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        let zipURL = stagingRoot.appendingPathComponent(Self.zipAssetName)
        progress?("Downloading PackMan \(update.version)…")
        try await downloadFile(from: update.downloadURL, to: zipURL)

        progress?("Verifying the download against the release checksum…")
        try await verifyChecksum(from: update.checksumURL, fileURL: zipURL)

        progress?("Extracting the update…")
        let stagedDirectory = stagingRoot.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try UpdateApplier.extractZip(zipURL, to: stagedDirectory)
        guard let stagedApp = UpdateApplier.findPackManApp(in: stagedDirectory) else {
            throw AppUpdateError.missingApplication
        }
        guard let stagedVersion = UpdateApplier.shortVersion(of: stagedApp),
              stagedVersion > currentVersion else {
            throw AppUpdateError.missingApplication
        }

        progress?("Closing PackMan to finish the update…")
        let request = UpdateApplyRequest(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            stagedApp: stagedApp,
            targetApp: targetBundleURL,
            stagingRoot: stagingRoot)
        guard launchApplyHelper(request) else {
            throw AppUpdateError.helperFailed
        }
    }

    private func isNewer(_ candidate: AppUpdateInfo?) -> Bool {
        guard let candidate, let version = AppVersion(candidate.version) else { return false }
        return version > currentVersion
    }

    private func validate(_ candidate: AppUpdateInfo?, skipped: String?, force: Bool) -> AppUpdateInfo? {
        guard isNewer(candidate) else { return nil }
        if !force, let skipped, skipped.compare(candidate!.version, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return candidate
    }

    private func fetchLatestRelease() async throws -> AppUpdateInfo? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PackMan", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw AppUpdateError.httpStatus(response.statusCode) }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        if release.draft || release.prerelease { return nil }
        guard let tag = release.tagName.flatMap(AppVersion.init) else { return nil }
        let assets = release.assets ?? []
        guard let download = assets.first(where: { $0.name?.compare(Self.zipAssetName, options: .caseInsensitive) == .orderedSame })?.browserDownloadURL,
              let checksum = assets.first(where: { $0.name?.compare(Self.checksumAssetName, options: .caseInsensitive) == .orderedSame })?.browserDownloadURL,
              let html = release.htmlURL,
              let downloadURL = URL(string: download),
              let checksumURL = URL(string: checksum),
              let releaseURL = URL(string: html) else {
            return nil
        }
        try Self.validateDownloadURL(downloadURL)
        try Self.validateDownloadURL(checksumURL)
        return AppUpdateInfo(
            version: tag.displayString,
            downloadURL: downloadURL,
            checksumURL: checksumURL,
            releaseURL: releaseURL)
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("PackMan", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.downloadTimeout
        do {
            let (data, response) = try await transport.data(for: request)
            guard (200...299).contains(response.statusCode) else {
                throw AppUpdateError.httpStatus(response.statusCode)
            }
            try data.write(to: destination, options: .atomic)
        } catch is CancellationError {
            throw AppUpdateError.downloadTimedOut
        } catch let error as URLError where error.code == .timedOut {
            throw AppUpdateError.downloadTimedOut
        }
    }

    private func verifyChecksum(from checksumURL: URL, fileURL: URL) async throws {
        var request = URLRequest(url: checksumURL)
        request.setValue("PackMan", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.malformedChecksum
        }
        let expected = text.split { $0.isWhitespace }.first.map(String.init)
        guard let expected, expected.count == 64, expected.unicodeScalars.allSatisfy(CharacterSet.hexadecimal.contains) else {
            throw AppUpdateError.malformedChecksum
        }
        let fileData = try Data(contentsOf: fileURL)
        let actual = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw AppUpdateError.checksumMismatch
        }
    }

    static func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            throw AppUpdateError.disallowedHost(url.host ?? url.absoluteString)
        }
        guard allowedHosts.contains(host) else {
            throw AppUpdateError.disallowedHost(host)
        }
    }

    static func canWrite(to directory: URL, fileManager: FileManager = .default) -> Bool {
        let probe = directory.appendingPathComponent(".packman-write-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private struct GitHubRelease: Decodable {
        var tagName: String?
        var htmlURL: String?
        var draft: Bool
        var prerelease: Bool
        var assets: [GitHubAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        var name: String?
        var browserDownloadURL: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

private extension CharacterSet {
    static let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
}

enum UpdateApplier {
    static func extractZip(_ zipURL: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.missingApplication
        }
    }

    static func findPackManApp(in directory: URL) -> URL? {
        let root = directory.appendingPathComponent("PackMan.app")
        if FileManager.default.fileExists(atPath: root.path) { return root }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "PackMan.app" {
            return url
        }
        return nil
    }

    static func shortVersion(of appURL: URL) -> AppVersion? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(version)
    }

    static func isTrusted(stagedApp: URL, targetApp: URL, stagingRoot: URL, ownBundle: URL) -> Bool {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PackMan", isDirectory: true)
            .standardizedFileURL.path
        let root = stagingRoot.standardizedFileURL.path
        let staged = stagedApp.standardizedFileURL.path
        let target = targetApp.standardizedFileURL.path
        let own = ownBundle.standardizedFileURL.path
        return target == own
            && (root == tempRoot || root.hasPrefix(tempRoot + "/"))
            && staged.hasPrefix(root + "/")
            && fileManager.fileExists(atPath: staged)
    }

    static func replaceBundle(stagedApp: URL, targetApp: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetApp.path) {
            _ = try fileManager.replaceItemAt(targetApp, withItemAt: stagedApp)
        } else {
            try fileManager.copyItem(at: stagedApp, to: targetApp)
        }
        clearQuarantine(at: targetApp)
    }

    static func clearQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func launchHelper(_ request: UpdateApplyRequest) -> Bool {
        guard isTrusted(
            stagedApp: request.stagedApp,
            targetApp: request.targetApp,
            stagingRoot: request.stagingRoot,
            ownBundle: request.targetApp
        ) else { return false }

        let scriptURL = request.stagingRoot.appendingPathComponent("apply.sh")
        let script = """
        #!/bin/bash
        set -eu
        parent="$1"
        staged="$2"
        target="$3"
        staging="$4"
        i=0
        while kill -0 "$parent" 2>/dev/null; do
          i=$((i + 1))
          if [ "$i" -gt 240 ]; then
            break
          fi
          sleep 0.5
        done
        sleep 0.25
        /bin/rm -rf "$target"
        /usr/bin/ditto "$staged" "$target"
        /usr/bin/xattr -dr com.apple.quarantine "$target" || true
        /usr/bin/open "$target"
        /bin/rm -rf "$staging"
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            let process = Process()
            process.executableURL = scriptURL
            process.arguments = [
                String(request.parentPID),
                request.stagedApp.path,
                request.targetApp.path,
                request.stagingRoot.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
