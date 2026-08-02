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
    private let standardSearchPaths: [String]

    init(
        settings: any SettingsStoring,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        standardSearchPaths: [String] = ProcessRunner.standardSearchPaths
    ) {
        self.settings = settings
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.standardSearchPaths = standardSearchPaths
    }

    func resolve(_ descriptor: SourceDescriptor) async -> ToolResolution {
        if let override = settings.executableOverride(for: descriptor.toolID) {
            guard fileManager.isExecutableFile(atPath: override) else {
                return .invalidOverride(override)
            }

            if descriptor.toolID == .npm {
                return resolveNpm(candidates: [Candidate(path: override, origin: .explicit)])
            }
            return .resolved(executable(path: override, origin: .explicit))
        }

        if descriptor.toolID == .npm {
            return resolveNpmAutomatically(descriptor)
        }

        if let candidate = standardCandidates(for: descriptor).first {
            return .resolved(executable(path: candidate.path, origin: candidate.origin))
        }

        return .notFound
    }

    private func resolveNpmAutomatically(_ descriptor: SourceDescriptor) -> ToolResolution {
        let candidates = standardCandidates(for: descriptor)
            + nvmNpmCandidates()
            + fnmNpmCandidates()
            + voltaNpmCandidates()
        return resolveNpm(candidates: unique(candidates))
    }

    private func resolveNpm(candidates: [Candidate]) -> ToolResolution {
        var firstIncompletePath: String?

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            guard let nodePath = nodePath(forNpmAt: candidate.path) else {
                firstIncompletePath = firstIncompletePath ?? candidate.path
                continue
            }

            let npmDirectory = URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
            let nodeDirectory = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
            return .resolved(ResolvedExecutable(
                path: candidate.path,
                pathEntries: unique([npmDirectory, nodeDirectory]),
                origin: candidate.origin))
        }

        if let firstIncompletePath {
            return .missingDependency(executablePath: firstIncompletePath, dependency: "Node")
        }
        return .notFound
    }

    private func executable(path: String, origin: ToolResolutionOrigin) -> ResolvedExecutable {
        ResolvedExecutable(
            path: path,
            pathEntries: [URL(fileURLWithPath: path).deletingLastPathComponent().path],
            origin: origin)
    }

    private func standardCandidates(for descriptor: SourceDescriptor) -> [Candidate] {
        let inherited = executablePaths(
            named: descriptor.executableName,
            directories: inheritedPathDirectories)
            .map { Candidate(path: $0, origin: .inheritedPath) }
        let known = descriptor.knownPaths
            .filter(fileManager.isExecutableFile(atPath:))
            .map { Candidate(path: $0, origin: .knownPath) }
        let user = executablePaths(
            named: descriptor.executableName,
            directories: userSearchDirectories)
            .map { Candidate(path: $0, origin: .userPath) }
        return unique(inherited + known + user)
    }

    private func nodePath(forNpmAt npmPath: String) -> String? {
        let npmDirectory = URL(fileURLWithPath: npmPath).deletingLastPathComponent()
        let directories = [npmDirectory]
            + inheritedPathDirectories
            + standardSearchPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return executablePaths(named: "node", directories: unique(directories)).first
    }

    private func executablePaths(named name: String, directories: [URL]) -> [String] {
        directories.compactMap { directory in
            let path = directory.appendingPathComponent(name).path
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
    }

    private var inheritedPathDirectories: [URL] {
        (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    private var userSearchDirectories: [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".asdf/shims", isDirectory: true),
            homeDirectory.appendingPathComponent(".mise/shims", isDirectory: true),
            homeDirectory.appendingPathComponent(".pyenv/shims", isDirectory: true),
        ]
    }

    private func nvmNpmCandidates() -> [Candidate] {
        var roots = environmentDirectory(named: "NVM_DIR").map { [$0] } ?? []
        roots.append(homeDirectory.appendingPathComponent(".nvm", isDirectory: true))
        return unique(roots).flatMap { nvmRoot in
            let versionsRoot = nvmRoot.appendingPathComponent("versions/node", isDirectory: true)
            let defaultAlias = nvmRoot.appendingPathComponent("alias/default")
            var paths: [String] = []

            if let alias = try? String(contentsOf: defaultAlias, encoding: .utf8).trimmed,
               !alias.isEmpty {
                let normalized = alias.hasPrefix("v") ? alias : "v\(alias)"
                paths.append(versionsRoot
                    .appendingPathComponent(normalized)
                    .appendingPathComponent("bin/npm").path)
            }

            paths.append(contentsOf: versionDirectories(in: versionsRoot).map {
                $0.appendingPathComponent("bin/npm").path
            })
            return unique(paths)
                .filter(fileManager.isExecutableFile(atPath:))
                .map { Candidate(path: $0, origin: .nvm) }
        }
    }

    private func fnmNpmCandidates() -> [Candidate] {
        var paths: [String] = []
        if let multishell = environmentDirectory(named: "FNM_MULTISHELL_PATH") {
            paths.append(multishell.appendingPathComponent("bin/npm").path)
        }

        var roots = environmentDirectory(named: "FNM_DIR").map { [$0] } ?? []
        roots.append(contentsOf: [
            homeDirectory.appendingPathComponent("Library/Application Support/fnm", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/share/fnm", isDirectory: true),
            homeDirectory.appendingPathComponent(".fnm", isDirectory: true),
        ])
        for root in unique(roots) {
            let versionsRoot = root.appendingPathComponent("node-versions", isDirectory: true)
            paths.append(contentsOf: versionDirectories(in: versionsRoot).map {
                $0.appendingPathComponent("installation/bin/npm").path
            })
        }

        return unique(paths)
            .filter(fileManager.isExecutableFile(atPath:))
            .map { Candidate(path: $0, origin: .fnm) }
    }

    private func voltaNpmCandidates() -> [Candidate] {
        var roots = environmentDirectory(named: "VOLTA_HOME").map { [$0] } ?? []
        roots.append(homeDirectory.appendingPathComponent(".volta", isDirectory: true))
        return unique(roots)
            .map { $0.appendingPathComponent("bin/npm").path }
            .filter(fileManager.isExecutableFile(atPath:))
            .map { Candidate(path: $0, origin: .volta) }
    }

    private func versionDirectories(in root: URL) -> [URL] {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return versions.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
    }

    private func environmentDirectory(named name: String) -> URL? {
        guard let value = environment[name]?.trimmed, !value.isEmpty else { return nil }
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func unique<T>(_ values: [T], by key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return values.filter { seen.insert(key($0)).inserted }
    }

    private func unique(_ values: [String]) -> [String] {
        unique(values, by: { $0 })
    }

    private func unique(_ values: [URL]) -> [URL] {
        unique(values, by: { $0.standardizedFileURL.path })
    }

    private func unique(_ values: [Candidate]) -> [Candidate] {
        unique(values, by: { $0.path })
    }

    private struct Candidate {
        let path: String
        let origin: ToolResolutionOrigin
    }
}
