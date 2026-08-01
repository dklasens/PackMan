import Foundation

@MainActor
final class Settings {
    static let shared = Settings()

    private let settingsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("PackMan", isDirectory: true)
            .appendingPathComponent("settings.json")
    }()

    private(set) var disabledSources: Set<String> = []

    private init() {}

    func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: data),
              let disabled = decoded.disabledSources else {
            return
        }
        disabledSources = Set(disabled.map { $0.lowercased() })
    }

    func isDisabled(_ sourceName: String) -> Bool {
        disabledSources.contains(sourceName.lowercased())
    }

    func setSource(_ name: String, enabled: Bool) {
        let key = name.lowercased()
        if enabled {
            disabledSources.remove(key)
        } else {
            disabledSources.insert(key)
        }
        save()
    }

    private func save() {
        let directory = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = SettingsData(disabledSources: disabledSources.sorted())
        if let encoded = try? JSONEncoder.withPrettyPrint.encode(data) {
            try? encoded.write(to: settingsURL, options: .atomic)
        }
    }

    private struct SettingsData: Codable {
        var disabledSources: [String]?
    }
}

private extension JSONEncoder {
    static var withPrettyPrint: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
