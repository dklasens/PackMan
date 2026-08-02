import Foundation

protocol ToolResolving: Sendable {
    func resolve(_ descriptor: SourceDescriptor) async -> ToolResolution
}

final class ToolResolver: ToolResolving, @unchecked Sendable {
    static let shared = ToolResolver(settings: SettingsStore.shared)

    private let settings: any SettingsStoring
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        settings: any SettingsStoring,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func resolve(_ descriptor: SourceDescriptor) async -> ToolResolution {
        if let override = settings.executableOverride(for: descriptor.toolID) {
            guard fileManager.isExecutableFile(atPath: override) else {
                return .invalidOverride(override)
            }
            return .resolved(executable(path: override, origin: .explicit))
        }

        if let path = executableOnInheritedPath(named: descriptor.executableName) {
            return .resolved(executable(path: path, origin: .inheritedPath))
        }

        if let path = descriptor.knownPaths.first(where: fileManager.isExecutableFile(atPath:)) {
            return .resolved(executable(path: path, origin: .knownPath))
        }

        for directory in userSearchDirectories {
            let path = directory.appendingPathComponent(descriptor.executableName).path
            if fileManager.isExecutableFile(atPath: path) {
                return .resolved(executable(path: path, origin: .userPath))
            }
        }

        if descriptor.toolID == .npm, let npm = resolveNVMNpm() {
            return .resolved(executable(path: npm, origin: .nvm))
        }

        return .notFound
    }

    private func executable(path: String, origin: ToolResolutionOrigin) -> ResolvedExecutable {
        ResolvedExecutable(
            path: path,
            pathEntries: [URL(fileURLWithPath: path).deletingLastPathComponent().path],
            origin: origin)
    }

    private func executableOnInheritedPath(named name: String) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private var userSearchDirectories: [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".asdf/shims", isDirectory: true),
            homeDirectory.appendingPathComponent(".mise/shims", isDirectory: true),
            homeDirectory.appendingPathComponent(".pyenv/shims", isDirectory: true),
        ]
    }

    private func resolveNVMNpm() -> String? {
        let nvmRoot = homeDirectory.appendingPathComponent(".nvm", isDirectory: true)
        let versionsRoot = nvmRoot.appendingPathComponent("versions/node", isDirectory: true)
        let defaultAlias = nvmRoot.appendingPathComponent("alias/default")

        if let alias = try? String(contentsOf: defaultAlias, encoding: .utf8).trimmed,
           !alias.isEmpty {
            let normalized = alias.hasPrefix("v") ? alias : "v\(alias)"
            let exact = versionsRoot.appendingPathComponent(normalized).appendingPathComponent("bin/npm").path
            if fileManager.isExecutableFile(atPath: exact) { return exact }
        }

        guard let versions = try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return nil
        }
        return versions
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/npm").path }
            .first(where: fileManager.isExecutableFile(atPath:))
    }
}
