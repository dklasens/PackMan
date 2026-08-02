import Foundation

struct PipSource: PackageSource {
    let runner: any ProcessRunning
    let resolver: any ToolResolving

    init(
        runner: any ProcessRunning = ProcessRunner.shared,
        resolver: any ToolResolving = ToolResolver.shared
    ) {
        self.runner = runner
        self.resolver = resolver
    }

    let descriptor = SourceDescriptor(
        id: .pip,
        name: "pip",
        toolID: .python,
        executableName: "python3",
        knownPaths: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"],
        installationURL: URL(string: "https://pip.pypa.io/en/stable/installation/"))

    func probe() async -> SourceProbe {
        await SourceSupport.probe(
            descriptor: descriptor,
            versionArguments: ["-m", "pip", "--version"],
            resolver: resolver,
            runner: runner)
    }

    func scan(
        context: ToolContext,
        progress: @escaping @Sendable (SourcePhase) async -> Void
    ) async throws -> SourceScanReport {
        await progress(.scanning)
        let result = try await runner.run(
            context.executablePath,
            ["-m", "pip", "list", "--outdated", "--format", "json", "--disable-pip-version-check"],
            timeout: 180,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceError.commandFailed(Self.friendlyFailure("pip list", result)) }
        guard !result.stdout.trimmed.isEmpty else { return SourceScanReport() }
        guard let data = result.stdout.data(using: .utf8) else {
            throw SourceError.commandFailed("pip list returned non-UTF-8 output.")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries: [PipOutdatedEntry]
        do {
            entries = try decoder.decode([PipOutdatedEntry].self, from: data)
        } catch {
            throw SourceError.commandFailed("pip list JSON parse failed: \(error.decodingDescription)")
        }

        var updates: [PackageInfo] = []
        var issues: [SourceIssue] = []
        for entry in entries {
            guard PackageIdValidator.isValid(entry.name),
                  let current = entry.version,
                  let latest = entry.latestVersion,
                  PackageIdValidator.isValidVersion(latest) else {
                issues.append(SourceIssue(kind: .parsing, message: "pip returned an incomplete or invalid package record."))
                continue
            }
            updates.append(PackageInfo(
                id: entry.name,
                name: entry.name,
                currentVersion: current,
                availableVersion: latest))
        }
        updates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        let result = try await runner.run(
            context.executablePath,
            ["-m", "pip", "install", "--upgrade", request.packageID],
            timeout: 600,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceError.commandFailed(Self.friendlyFailure("pip install", result)) }
    }

    private static func friendlyFailure(_ command: String, _ result: ProcessResult) -> String {
        if result.stderr.contains("externally-managed-environment") {
            return "\(command) refused: this Python is externally managed (PEP 668). Install the tool with pipx instead."
        }
        let detail = [result.stderr.trimmed, result.stdout.trimmed].first { !$0.isEmpty } ?? "No diagnostic output."
        return "\(command) failed (exit \(result.exitCode)): \(detail)"
    }
}

struct PipOutdatedEntry: Decodable {
    let name: String
    let version: String?
    let latestVersion: String?
}
