import Foundation

enum BrewKind: Sendable {
    case formula
    case cask
}

struct BrewSource: PackageSource {
    let kind: BrewKind
    let runner: any ProcessRunning
    let resolver: any ToolResolving
    let refresh: BrewRefreshing
    let inventory: BrewInventory?
    let settings: any SettingsStoring

    init(
        kind: BrewKind,
        runner: any ProcessRunning = ProcessRunner.shared,
        resolver: any ToolResolving = ToolResolver.shared,
        refresh: BrewRefreshing = BrewRefresh.shared,
        inventory: BrewInventory? = nil,
        settings: any SettingsStoring = SettingsStore.shared
    ) {
        self.kind = kind
        self.runner = runner
        self.resolver = resolver
        self.refresh = refresh
        self.inventory = inventory
        self.settings = settings
    }

    var descriptor: SourceDescriptor {
        SourceDescriptor(
            id: kind == .formula ? .homebrew : .homebrewCasks,
            name: kind == .formula ? "Homebrew" : "Homebrew Casks",
            toolID: .brew,
            executableName: "brew",
            knownPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
            installationURL: URL(string: "https://brew.sh"))
    }

    func probe() async -> SourceProbe {
        await SourceSupport.probe(
            descriptor: descriptor,
            versionArguments: ["--version"],
            resolver: resolver,
            runner: runner)
    }

    func scan(
        context: ToolContext,
        progress: @escaping @Sendable (SourcePhase) async -> Void
    ) async throws -> SourceScanReport {
        try Task.checkCancellation()
        await progress(.refreshing)
        var issues: [SourceIssue] = []
        do {
            try await refresh.refreshIfNeeded(context: context, runner: runner)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessError where error.isCancellation {
            throw CancellationError()
        } catch {
            issues.append(SourceIssue(
                kind: .network,
                message: "Homebrew metadata could not be refreshed: \(error.userMessage)",
                recovery: "Check your network connection and retry."))
        }

        try Task.checkCancellation()
        await progress(.scanning)
        let greedy = settings.includesSelfUpdatingCasks()
        let result: ProcessResult
        if let inventory {
            result = try await inventory.outdated(context: context, runner: runner, greedy: greedy)
        } else {
            result = try await runner.run(context.executablePath,
                ["outdated", "--json=v2"] + (greedy ? ["--greedy-auto-updates"] : []), timeout: 300,
                environment: SourceSupport.environment(pathEntries: context.pathEntries, additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
        }
        guard result.succeeded else { throw SourceSupport.commandFailure("brew outdated", result: result) }
        guard let data = result.stdout.data(using: .utf8) else {
            throw SourceError.commandFailed("brew outdated returned non-UTF-8 output.")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let outdated: BrewOutdated
        do {
            outdated = try decoder.decode(BrewOutdated.self, from: data)
        } catch {
            throw SourceError.commandFailed("brew outdated JSON parse failed: \(error.decodingDescription)")
        }

        let entries = kind == .formula ? outdated.formulae : outdated.casks
        let rejected = entries.filter { !PackageIdValidator.isValid($0.name) }
        if !rejected.isEmpty {
            issues.append(SourceIssue(
                kind: .parsing,
                message: "Ignored \(rejected.count) Homebrew record(s) with invalid package identifiers.",
                recovery: "Run brew outdated --json=v2 in Terminal and inspect its output."))
        }

        let updates = entries
            .filter { !($0.pinned ?? false) && PackageIdValidator.isValid($0.name) }
            .map {
                PackageInfo(
                    id: $0.fullToken ?? $0.fullName ?? $0.name,
                    name: $0.name,
                    currentVersion: $0.installedVersions.last ?? "",
                    availableVersion: $0.currentVersion)
            }
        return SourceScanReport(updates: updates, issues: issues, skippedCount: entries.filter { $0.pinned == true }.count)
    }

    func update(
        request: UpdateRequest,
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws {
        guard PackageIdValidator.isValid(request.packageID) else {
            throw SourceError.invalidPackageId(request.packageID)
        }
        var arguments = ["upgrade"]
        arguments.append(kind == .cask ? "--cask" : "--formula")
        if kind == .cask && settings.includesSelfUpdatingCasks() { arguments.append("--greedy-auto-updates") }
        arguments.append(request.packageID)

        let result = try await runner.run(
            context.executablePath,
            arguments,
            timeout: 900,
            environment: SourceSupport.environment(
                pathEntries: context.pathEntries,
                additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("brew upgrade", result: result) }
    }

    func clearCache(
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws -> Int64 {
        let homebrewCacheURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Homebrew")
        let sizeBefore = SourceSupport.directorySize(at: homebrewCacheURL)

        let result = try await runner.run(
            context.executablePath,
            ["cleanup"],
            timeout: 300,
            environment: SourceSupport.environment(
                pathEntries: context.pathEntries,
                additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("brew cleanup", result: result) }

        let sizeAfter = SourceSupport.directorySize(at: homebrewCacheURL)
        let delta = max(0, sizeBefore - sizeAfter)
        if delta > 0 { return delta }
        return parseFreedBytes(from: result.stdout.components(separatedBy: .newlines))
    }

    private func parseFreedBytes(from lines: [String]) -> Int64 {
        for line in lines {
            if line.contains("freed approximately"), let bytes = parseSpaceString(line) {
                return bytes
            }
        }
        return 0
    }

    private func parseSpaceString(_ line: String) -> Int64? {
        let pattern = try? NSRegularExpression(pattern: "freed approximately\\s+([0-9.]+)\\s*(GB|MB|KB|B)", options: .caseInsensitive)
        let nsLine = line as NSString
        guard let match = pattern?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
              match.numberOfRanges == 3 else { return nil }
        let numStr = nsLine.substring(with: match.range(at: 1))
        let unit = nsLine.substring(with: match.range(at: 2)).uppercased()
        guard let value = Double(numStr) else { return nil }
        switch unit {
        case "GB": return Int64(value * 1_073_741_824)
        case "MB": return Int64(value * 1_048_576)
        case "KB": return Int64(value * 1_024)
        default: return Int64(value)
        }
    }
}

protocol BrewRefreshing: Sendable {
    func refreshIfNeeded(context: ToolContext, runner: any ProcessRunning) async throws
}

actor BrewRefresh: BrewRefreshing {
    static let shared = BrewRefresh()

    private var lastSuccessfulRefresh: [String: Date] = [:]
    private var inFlight: [String: Task<Void, Error>] = [:]
    private let interval: TimeInterval = 3600

    func invalidate() { lastSuccessfulRefresh.removeAll() }

    func refreshIfNeeded(context: ToolContext, runner: any ProcessRunning) async throws {
        let key = context.installationKey
        if let date = lastSuccessfulRefresh[key], Date().timeIntervalSince(date) < interval { return }
        if let task = inFlight[key] { return try await task.value }

        let task = Task {
            let result = try await runner.run(
                context.executablePath,
                ["update"],
                timeout: 300,
                environment: SourceSupport.environment(
                    pathEntries: context.pathEntries,
                    additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
            guard result.succeeded else { throw SourceSupport.commandFailure("brew update", result: result) }
        }
        inFlight[key] = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            lastSuccessfulRefresh[key] = .now
            inFlight[key] = nil
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

struct BrewOutdated: Decodable {
    let formulae: [Entry]
    let casks: [Entry]

    struct Entry: Decodable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String
        let pinned: Bool?
        let fullName: String?
        let fullToken: String?
    }
}


extension ToolContext {
    var installationKey: String {
        URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path + "|" + version + "|" + pathEntries.joined(separator: ":")
    }
}

actor BrewInventory {
    private var tasks: [String: Task<ProcessResult, Error>] = [:]
    func beginScan() { tasks.removeAll() }
    func outdated(context: ToolContext, runner: any ProcessRunning, greedy: Bool) async throws -> ProcessResult {
        let key = context.installationKey + "|\(greedy)"
        let task: Task<ProcessResult, Error>
        if let existing = tasks[key] { task = existing }
        else {
            task = Task {
                if greedy {
                    let help = try await runner.run(context.executablePath, ["outdated", "--help"], timeout: 15,
                        environment: SourceSupport.environment(pathEntries: context.pathEntries))
                    guard help.succeeded && help.stdout.contains("--greedy-auto-updates") else {
                        throw SourceError.commandFailed("This Homebrew does not support checking self-updating casks. Upgrade Homebrew or turn off that setting.")
                    }
                }
                return try await runner.run(context.executablePath,
                    ["outdated", "--json=v2"] + (greedy ? ["--greedy-auto-updates"] : []), timeout: 300,
                    environment: SourceSupport.environment(pathEntries: context.pathEntries, additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
            }
            tasks[key] = task
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
