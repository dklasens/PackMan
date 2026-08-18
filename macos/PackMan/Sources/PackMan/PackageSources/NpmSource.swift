import Foundation

struct NpmSource: PackageSource {
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
        id: .npm,
        name: "npm",
        toolID: .npm,
        executableName: "npm",
        knownPaths: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"],
        installationURL: URL(string: "https://docs.npmjs.com/downloading-and-installing-node-js-and-npm"))

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
        await progress(.scanning)
        let result = try await runner.run(
            context.executablePath,
            ["outdated", "-g", "--json"],
            timeout: 180,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw SourceSupport.commandFailure("npm outdated", result: result)
        }
        guard !result.stdout.trimmed.isEmpty else { return SourceScanReport() }
        guard let data = result.stdout.data(using: .utf8) else {
            throw SourceError.commandFailed("npm outdated returned non-UTF-8 output.")
        }

        let entries: [String: NpmOutdatedEntry]
        do {
            entries = try JSONDecoder().decode([String: NpmOutdatedEntry].self, from: data)
        } catch {
            throw SourceError.commandFailed("npm outdated JSON parse failed: \(error.decodingDescription)")
        }

        var issues: [SourceIssue] = []
        var updates: [PackageInfo] = []
        for (name, entry) in entries.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            guard PackageIdValidator.isValid(name) else {
                issues.append(SourceIssue(kind: .parsing, message: "npm returned an invalid package identifier."))
                continue
            }
            guard let latest = entry.latest?.trimmed, PackageIdValidator.isValidVersion(latest) else {
                issues.append(SourceIssue(
                    kind: .parsing,
                    message: "npm did not provide a valid latest version for \(name).",
                    recovery: "Run npm outdated -g --json in Terminal and inspect the record."))
                continue
            }
            let current = entry.current?.trimmed ?? ""
            guard current != latest else { continue }
            updates.append(PackageInfo(
                id: name,
                name: name,
                currentVersion: current,
                availableVersion: latest))
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
        guard PackageIdValidator.isValidVersion(request.targetVersion) else {
            throw SourceError.invalidTargetVersion(request.targetVersion)
        }
        let result = try await runner.run(
            context.executablePath,
            ["install", "-g", "\(request.packageID)@\(request.targetVersion)"],
            timeout: 600,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("npm install", result: result) }
    }

    func verify(
        requests: [UpdateRequest],
        context: ToolContext
    ) async throws -> [String: UpdateVerification] {
        try Task.checkCancellation()
        let result = try await runner.run(
            context.executablePath,
            ["list", "-g", "--depth=0", "--json"],
            timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded || result.exitCode == 1,
              let data = result.stdout.data(using: .utf8),
              let list = try? JSONDecoder().decode(NpmListResult.self, from: data) else {
            throw SourceError.verificationFailed("npm could not confirm the installed versions.")
        }

        var verification: [String: UpdateVerification] = [:]
        for request in requests {
            guard let installed = list.dependencies?[request.packageID]?.version else {
                throw SourceError.verificationFailed("npm could not confirm the installed version of \(request.name).")
            }
            if installed == request.targetVersion {
                verification[request.packageID] = .satisfied(installedVersion: installed)
            } else {
                verification[request.packageID] = .stillOutdated(PackageInfo(
                    id: request.packageID,
                    name: request.name,
                    currentVersion: installed,
                    availableVersion: request.targetVersion))
            }
        }
        return verification
    }

    func clearCache(
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws -> Int64 {
        let npmCacheURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm")
        let sizeBefore = SourceSupport.directorySize(at: npmCacheURL)

        let result = try await runner.run(
            context.executablePath,
            ["cache", "clean", "--force"],
            timeout: 180,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("npm cache clean", result: result) }

        let sizeAfter = SourceSupport.directorySize(at: npmCacheURL)
        return max(0, sizeBefore - sizeAfter)
    }
}

struct NpmOutdatedEntry: Decodable {
    let current: String?
    let wanted: String?
    let latest: String?
}

private struct NpmListResult: Decodable {
    let dependencies: [String: Dependency]?

    struct Dependency: Decodable {
        let version: String?
    }
}
