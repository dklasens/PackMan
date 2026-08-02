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

    init(
        kind: BrewKind,
        runner: any ProcessRunning = ProcessRunner.shared,
        resolver: any ToolResolving = ToolResolver.shared,
        refresh: BrewRefreshing = BrewRefresh.shared
    ) {
        self.kind = kind
        self.runner = runner
        self.resolver = resolver
        self.refresh = refresh
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
        let result = try await runner.run(
            context.executablePath,
            ["outdated", "--json=v2"],
            timeout: 300,
            environment: SourceSupport.environment(
                pathEntries: context.pathEntries,
                additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
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
                    id: $0.name,
                    name: $0.name,
                    currentVersion: $0.installedVersions.last ?? "",
                    availableVersion: $0.currentVersion)
            }
        return SourceScanReport(updates: updates, issues: issues)
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
        if kind == .cask { arguments.append("--cask") }
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
}

protocol BrewRefreshing: Sendable {
    func refreshIfNeeded(context: ToolContext, runner: any ProcessRunning) async throws
}

actor BrewRefresh: BrewRefreshing {
    static let shared = BrewRefresh()

    private var lastSuccessfulRefresh: Date?
    private var inFlight: Task<Void, Error>?
    private let interval: TimeInterval = 3600

    func refreshIfNeeded(context: ToolContext, runner: any ProcessRunning) async throws {
        if let lastSuccessfulRefresh, Date().timeIntervalSince(lastSuccessfulRefresh) < interval { return }
        if let inFlight {
            return try await inFlight.value
        }

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
        inFlight = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            lastSuccessfulRefresh = .now
            inFlight = nil
        } catch {
            inFlight = nil
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
    }
}
