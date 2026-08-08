import Foundation

protocol SettingsStoring: Sendable {
    var loadIssue: String? { get }

    func isSourceEnabled(_ id: SourceID) -> Bool
    func setSource(_ id: SourceID, enabled: Bool) throws
    func executableOverride(for toolID: ToolID) -> String?
    func setExecutableOverride(_ path: String?, for toolID: ToolID) throws
    func cachedContext(for sourceID: SourceID) -> ToolContext?
    func setCachedContext(_ context: ToolContext?, for sourceID: SourceID) throws
    func ignoredUpdateKeys() -> Set<String>
    func setUpdateIgnored(_ key: String, ignored: Bool) throws
}

final class SettingsStore: SettingsStoring, @unchecked Sendable {
    static let shared = SettingsStore()

    private struct SettingsData: Codable {
        var version: Int
        var disabledSources: [String]
        var executableOverrides: [String: String]
        var cachedContexts: [String: CachedToolContext]?
        var ignoredUpdates: [String]?
    }

    private struct CachedToolContext: Codable {
        let executablePath: String
        let version: String
        let pathEntries: [String]
        let origin: ToolResolutionOrigin

        init(_ context: ToolContext) {
            executablePath = context.executablePath
            version = context.version
            pathEntries = context.pathEntries
            origin = context.origin
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
            version: 3,
            disabledSources: [],
            executableOverrides: [:],
            cachedContexts: [:],
            ignoredUpdates: [])
        loadFromDisk()
    }

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
                  FileManager.default.isExecutableFile(atPath: cached.executablePath) else {
                return nil
            }
            return cached.context
        }
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

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        Self.restrictPermissions(at: settingsURL)
        do {
            let raw = try Data(contentsOf: settingsURL)
            let decoder = JSONDecoder()
            if var current = try? decoder.decode(SettingsData.self, from: raw), current.version >= 2 {
                current.version = 3
                current.cachedContexts = current.cachedContexts ?? [:]
                current.ignoredUpdates = current.ignoredUpdates ?? []
                data = current
                return
            }
            if let legacy = try? decoder.decode(LegacySettingsData.self, from: raw) {
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
