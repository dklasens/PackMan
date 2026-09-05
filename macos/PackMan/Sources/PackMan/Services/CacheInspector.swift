import Foundation

struct CachePreview: Identifiable, Sendable {
    var sourceID: SourceID
    var sourceName: String
    var context: ToolContext?
    var paths: [String] = []
    var bytes: Int64?
    var measurementComplete = true
    var scope: String
    var removalPreview = ""
    var issue: String?
    var supported = true
    var id: SourceID { sourceID }
    var sizeText: String {
        guard let bytes else { return "Size unavailable" }
        return (measurementComplete ? "About " : "At least ") + SourceSupport.formatBytes(bytes)
    }
}

protocol CacheInspecting: Sendable {
    func preview(source: any PackageSource, context: ToolContext, includeGlobalPackages: Bool) async throws -> CachePreview
    func clear(_ preview: CachePreview, includeGlobalPackages: Bool,
               onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void) async throws
}

struct CacheInspector: CacheInspecting {
    var runner: any ProcessRunning = ProcessRunner.shared

    func preview(source: any PackageSource, context: ToolContext, includeGlobalPackages: Bool) async throws -> CachePreview {
        let id = source.id
        var preview = CachePreview(sourceID: id, sourceName: source.name, context: context, scope: Self.scope(id, includeGlobalPackages: includeGlobalPackages))
        if id == .appStore { preview.supported = false; preview.bytes = nil; return preview }
        let arguments: [String]
        switch id {
        case .homebrew, .homebrewCasks: arguments = ["--cache"]
        case .npm: arguments = ["config", "get", "cache"]
        case .pip: arguments = ["-m", "pip", "cache", "dir"]
        case .pipx:
            let help = try await command(context, ["cache", "--help"])
            guard help.succeeded && help.stdout.contains("purge") && help.stdout.contains("dir") else {
                preview.supported = false; preview.issue = "This pipx does not support cache preview/purge. Upgrade pipx to manage its run cache."; return preview
            }
            arguments = ["cache", "dir"]
        case .dotnet: arguments = ["nuget", "locals", "all", "--list"]
        case .appStore: return preview
        }
        let result = try await command(context, arguments)
        guard result.succeeded else { throw SourceSupport.commandFailure("Cache location", result: result) }
        if id == .dotnet {
            let allowed = includeGlobalPackages ? ["http-cache", "temp", "plugins-cache", "global-packages"] : ["http-cache", "temp", "plugins-cache"]
            for line in result.stdout.components(separatedBy: .newlines) {
                guard let colon = line.firstIndex(of: ":"), allowed.contains(String(line[..<colon]).trimmed) else { continue }
                preview.paths.append(String(line[line.index(after: colon)...]).trimmed)
            }
        } else {
            preview.paths = result.stdout.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
        }
        guard !preview.paths.isEmpty, preview.paths.allSatisfy({ $0.hasPrefix("/") && $0 != "/" }) else {
            throw SourceError.commandFailed("The manager did not return recognised absolute cache paths.")
        }
        let measurement = try await Self.measure(preview.paths)
        preview.bytes = measurement.bytes; preview.measurementComplete = measurement.complete
        if id == .homebrew || id == .homebrewCasks {
            let dryRun = try await command(context, ["cleanup", "--dry-run"])
            guard dryRun.succeeded else { throw SourceSupport.commandFailure("brew cleanup preview", result: dryRun) }
            preview.removalPreview = UpdateHistoryStore.bounded(dryRun.stdout + "\n" + dryRun.stderr)
            // Homebrew's cache footprint differs from cleanup's reclaimable scope.
            // Report the footprint explicitly and leave reclaimed space unspecified.
            preview.scope += " Cache footprint: \(preview.sizeText). Reclaimable space depends on the removals below."
            preview.bytes = nil
        }
        return preview
    }

    func clear(_ preview: CachePreview, includeGlobalPackages: Bool,
               onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void) async throws {
        guard preview.supported, preview.issue == nil, let context = preview.context else {
            throw SourceError.commandFailed(preview.issue ?? "This cache is managed by macOS.")
        }
        let commands: [[String]]
        switch preview.sourceID {
        case .homebrew, .homebrewCasks: commands = [["cleanup"]]
        case .npm: commands = [["cache", "clean", "--force"]]
        case .pip: commands = [["-m", "pip", "cache", "purge"]]
        case .pipx: commands = [["cache", "purge"]]
        case .dotnet:
            commands = (includeGlobalPackages ? ["http-cache", "temp", "plugins-cache", "global-packages"] : ["http-cache", "temp", "plugins-cache"])
                .map { ["nuget", "locals", $0, "--clear"] }
        case .appStore: throw SourceError.commandFailed("App Store cache is managed by macOS.")
        }
        for arguments in commands {
            try Task.checkCancellation()
            let result = try await runner.run(context.executablePath, arguments, timeout: 300,
                environment: Self.environment(context), onOutput: onOutput)
            guard result.succeeded else { throw SourceSupport.commandFailure("Cache cleanup", result: result) }
        }
    }

    private func command(_ context: ToolContext, _ args: [String]) async throws -> ProcessResult {
        try await runner.run(context.executablePath, args, timeout: 60, environment: Self.environment(context))
    }
    private static func environment(_ context: ToolContext) -> [String: String] {
        SourceSupport.environment(pathEntries: context.pathEntries, additions: ["HOMEBREW_NO_AUTO_UPDATE": "1", "DOTNET_CLI_UI_LANGUAGE": "en-US"])
    }
    static func scope(_ id: SourceID, includeGlobalPackages: Bool) -> String {
        switch id {
        case .homebrew, .homebrewCasks: return "Homebrew formulae and casks share cleanup. Removes old downloads and old installed formula versions."
        case .npm: return "npm's configured download cache; packages remain installed."
        case .pip: return "This Python's pip download and wheel cache."
        case .pipx: return "Cached pipx run environments; installed tools remain installed."
        case .dotnet: return includeGlobalPackages ? "NuGet HTTP/temp/plugin caches and global packages. Other projects will need to restore packages again." : "NuGet HTTP/temp/plugin caches. Global packages are retained."
        case .appStore: return "Managed automatically by macOS. No cleanup action is available."
        }
    }

    static func measure(_ paths: [String]) async throws -> (bytes: Int64, complete: Bool) {
        let task = Task.detached { try measureSynchronously(paths) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func measureSynchronously(_ paths: [String]) throws -> (bytes: Int64, complete: Bool) {
            let manager = FileManager.default
            var total: Int64 = 0, complete = true
            var seen = Set<String>()
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            for path in paths {
                try Task.checkCancellation()
                let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                do { _ = try manager.attributesOfItem(atPath: root.path) }
                catch let error as NSError {
                    if !(error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) { complete = false }
                    continue
                }
                guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                    errorHandler: { _, _ in complete = false; return true }) else { complete = false; continue }
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    do {
                        let values = try url.resourceValues(forKeys: keys)
                        if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                        if values.isRegularFile == true, seen.insert(url.standardizedFileURL.path).inserted {
                            if let size = values.fileSize { total += Int64(size) } else { complete = false }
                        }
                    } catch { complete = false }
                }
            }
            return (total, complete)
    }
}
