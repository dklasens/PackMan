import Foundation

protocol SettingsStoring: Sendable {
    var loadIssue: String? { get }
    func hasCompletedSourceSetup() -> Bool
    func setSourceSetupCompleted() throws
    func includesSelfUpdatingCasks() -> Bool
    func setIncludesSelfUpdatingCasks(_ value: Bool) throws

    func isSourceEnabled(_ id: SourceID) -> Bool
    func setSource(_ id: SourceID, enabled: Bool) throws
    func executableOverride(for toolID: ToolID) -> String?
    func setExecutableOverride(_ path: String?, for toolID: ToolID) throws
    func cachedContext(for sourceID: SourceID) -> ToolContext?
    func setCachedContext(_ context: ToolContext?, for sourceID: SourceID) throws
    func ignoredUpdateKeys() -> Set<String>
    func setUpdateIgnored(_ key: String, ignored: Bool) throws
    func lastAppUpdateCheck() -> Date?
    func setLastAppUpdateCheck(_ date: Date?) throws
    func skippedAppUpdateVersion() -> String?
    func setSkippedAppUpdateVersion(_ version: String?) throws
    func availableAppUpdate() -> AppUpdateInfo?
    func setAvailableAppUpdate(_ update: AppUpdateInfo?) throws
}

final class SettingsStore: SettingsStoring, @unchecked Sendable {
    static let shared = SettingsStore()

    private struct SettingsData: Codable {
        var version: Int
        var disabledSources: [String]
        var executableOverrides: [String: String]
        var cachedContexts: [String: CachedToolContext]?
        var ignoredUpdates: [String]?
        var lastAppUpdateCheck: Date?
        var skippedAppUpdateVersion: String?
        var availableAppUpdate: StoredAppUpdate?
        var sourceSetupCompleted: Bool?
        var includeSelfUpdatingCasks: Bool?
    }

    private struct StoredAppUpdate: Codable {
        var version: String
        var downloadUrl: String
        var checksumUrl: String
        var releaseUrl: String

        init(_ info: AppUpdateInfo) {
            version = info.version
            downloadUrl = info.downloadURL.absoluteString
            checksumUrl = info.checksumURL.absoluteString
            releaseUrl = info.releaseURL.absoluteString
        }

        var info: AppUpdateInfo? {
            guard let downloadURL = URL(string: downloadUrl),
                  let checksumURL = URL(string: checksumUrl),
                  let releaseURL = URL(string: releaseUrl),
                  !version.trimmed.isEmpty else { return nil }
            return AppUpdateInfo(
                version: version,
                downloadURL: downloadURL,
                checksumURL: checksumURL,
                releaseURL: releaseURL)
        }
    }

    private struct CachedToolContext: Codable {
        let executablePath: String
        let version: String
        let pathEntries: [String]
        let origin: ToolResolutionOrigin
        var checkedAt: Date?
        var fingerprint: String?

        init(_ context: ToolContext) {
            executablePath = context.executablePath
            version = context.version
            pathEntries = context.pathEntries
            origin = context.origin
            checkedAt = .now
            fingerprint = SettingsStore.fingerprint(context)
        }

        var context: ToolContext {
            ToolContext(
                executablePath: executablePath,
                version: version,
                pathEntries: pathEntries,
                origin: origin)
        }
    }

    private struct LegacySettingsData: Decodable {
        var disabledSources: [String]?
    }

    private let lock = NSLock()
    private let settingsURL: URL
    private var data: SettingsData
    private(set) var loadIssue: String?

    init(settingsURL: URL? = nil) {
        self.settingsURL = settingsURL ?? Self.defaultURL
        data = SettingsData(
            version: 4,
            disabledSources: [],
            executableOverrides: [:],
            cachedContexts: [:],
            ignoredUpdates: [])
        loadFromDisk()
    }

    func hasCompletedSourceSetup() -> Bool { lock.withLock { data.sourceSetupCompleted ?? false } }
    func setSourceSetupCompleted() throws { try lock.withLock { data.sourceSetupCompleted = true; try saveLocked() } }
    func includesSelfUpdatingCasks() -> Bool { lock.withLock { data.includeSelfUpdatingCasks ?? false } }
    func setIncludesSelfUpdatingCasks(_ value: Bool) throws { try lock.withLock { data.includeSelfUpdatingCasks = value; try saveLocked() } }

    func isSourceEnabled(_ id: SourceID) -> Bool {
        lock.withLock { !data.disabledSources.contains(id.rawValue) }
    }

    func setSource(_ id: SourceID, enabled: Bool) throws {
        try lock.withLock {
            if enabled {
                data.disabledSources.removeAll { $0 == id.rawValue }
            } else if !data.disabledSources.contains(id.rawValue) {
                data.disabledSources.append(id.rawValue)
            }
            data.disabledSources.sort()
            try saveLocked()
        }
    }

    func executableOverride(for toolID: ToolID) -> String? {
        lock.withLock { data.executableOverrides[toolID.rawValue] }
    }

    func setExecutableOverride(_ path: String?, for toolID: ToolID) throws {
        try lock.withLock {
            if let path, !path.trimmed.isEmpty {
                data.executableOverrides[toolID.rawValue] = path
            } else {
                data.executableOverrides.removeValue(forKey: toolID.rawValue)
            }
            try saveLocked()
        }
    }

    func cachedContext(for sourceID: SourceID) -> ToolContext? {
        lock.withLock {
            guard let cached = data.cachedContexts?[sourceID.rawValue],
                  FileManager.default.isExecutableFile(atPath: cached.executablePath),
                  let checkedAt = cached.checkedAt, Date.now.timeIntervalSince(checkedAt) < 300,
                  cached.fingerprint == Self.fingerprint(cached.context) else {
                return nil
            }
            return cached.context
        }
    }

    private static func fingerprint(_ context: ToolContext) -> String {
        ([context.executablePath] + context.pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("node").path }).map { path in
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            return "\(url.path)|\(attrs[.modificationDate] ?? "")|\(attrs[.size] ?? "")|\(attrs[.systemFileNumber] ?? "")"
        }.joined(separator: "\n")
    }

    func setCachedContext(_ context: ToolContext?, for sourceID: SourceID) throws {
        try lock.withLock {
            var contexts = data.cachedContexts ?? [:]
            if let context {
                contexts[sourceID.rawValue] = CachedToolContext(context)
            } else {
                contexts.removeValue(forKey: sourceID.rawValue)
            }
            data.cachedContexts = contexts
            try saveLocked()
        }
    }

    func ignoredUpdateKeys() -> Set<String> {
        lock.withLock { Set(data.ignoredUpdates ?? []) }
    }

    func setUpdateIgnored(_ key: String, ignored: Bool) throws {
        try lock.withLock {
            var keys = Set(data.ignoredUpdates ?? [])
            if ignored { keys.insert(key) } else { keys.remove(key) }
            data.ignoredUpdates = keys.sorted()
            try saveLocked()
        }
    }

    func lastAppUpdateCheck() -> Date? {
        lock.withLock { data.lastAppUpdateCheck }
    }

    func setLastAppUpdateCheck(_ date: Date?) throws {
        try lock.withLock {
            data.lastAppUpdateCheck = date
            try saveLocked()
        }
    }

    func skippedAppUpdateVersion() -> String? {
        lock.withLock { data.skippedAppUpdateVersion }
    }

    func setSkippedAppUpdateVersion(_ version: String?) throws {
        try lock.withLock {
            data.skippedAppUpdateVersion = version?.trimmed.isEmpty == false ? version : nil
            try saveLocked()
        }
    }

    func availableAppUpdate() -> AppUpdateInfo? {
        lock.withLock { data.availableAppUpdate?.info }
    }

    func setAvailableAppUpdate(_ update: AppUpdateInfo?) throws {
        try lock.withLock {
            data.availableAppUpdate = update.map(StoredAppUpdate.init)
            try saveLocked()
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        Self.restrictPermissions(at: settingsURL)
        do {
            let raw = try Data(contentsOf: settingsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if var current = try? decoder.decode(SettingsData.self, from: raw), current.version >= 2 {
                current.sourceSetupCompleted = current.sourceSetupCompleted ?? true
                current.version = 4
                current.cachedContexts = current.cachedContexts ?? [:]
                current.ignoredUpdates = current.ignoredUpdates ?? []
                data = current
                return
            }
            if let legacy = try? decoder.decode(LegacySettingsData.self, from: raw) {
                data.sourceSetupCompleted = true
                data.disabledSources = (legacy.disabledSources ?? []).compactMap(Self.legacySourceID).map(\.rawValue)
                return
            }
            throw CocoaError(.coderReadCorrupt)
        } catch {
            loadIssue = "Settings could not be read; defaults are being used. \(error.localizedDescription)"
        }
    }

    private func saveLocked() throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(data).write(to: settingsURL, options: .atomic)
        Self.restrictPermissions(at: settingsURL)
        loadIssue = nil
    }

    /// Settings can contain executable overrides that PackMan runs with
    /// administrator privileges, so keep them private to the current user.
    private static func restrictPermissions(at url: URL) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 != 0 else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("PackMan", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private static func legacySourceID(_ name: String) -> SourceID? {
        switch name.lowercased() {
        case "homebrew": return .homebrew
        case "homebrew casks": return .homebrewCasks
        case "app store": return .appStore
        case "npm": return .npm
        case "pip": return .pip
        case "pipx": return .pipx
        case ".net tools", "dotnet": return .dotnet
        default: return nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}


extension SettingsStoring {
    func hasCompletedSourceSetup() -> Bool { true }
    func setSourceSetupCompleted() throws {}
    func includesSelfUpdatingCasks() -> Bool { false }
    func setIncludesSelfUpdatingCasks(_ value: Bool) throws {}
}
