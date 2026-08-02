import Foundation

protocol SettingsStoring: Sendable {
    var loadIssue: String? { get }

    func isSourceEnabled(_ id: SourceID) -> Bool
    func setSource(_ id: SourceID, enabled: Bool) throws
    func executableOverride(for toolID: ToolID) -> String?
    func setExecutableOverride(_ path: String?, for toolID: ToolID) throws
}

final class SettingsStore: SettingsStoring, @unchecked Sendable {
    static let shared = SettingsStore()

    private struct SettingsData: Codable {
        var version: Int
        var disabledSources: [String]
        var executableOverrides: [String: String]
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
        data = SettingsData(version: 2, disabledSources: [], executableOverrides: [:])
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

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        do {
            let raw = try Data(contentsOf: settingsURL)
            let decoder = JSONDecoder()
            if let current = try? decoder.decode(SettingsData.self, from: raw), current.version == 2 {
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
        loadIssue = nil
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
