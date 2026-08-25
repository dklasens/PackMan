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
            // npm reports the "latest" dist-tag even when it trails what is installed, which is
            // routine for a package tracking a prerelease channel. Installing that version would
            // be a downgrade, so only offer versions that provably move forward.
            guard VersionComparator.isUpgrade(from: current, to: latest) else { continue }
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
        var arguments = ["install", "-g"]
        if NpmSource.supportsScriptAllowlist(context.version) {
            arguments.append("--allow-scripts=\(request.packageID)")
        }
        arguments.append("\(request.packageID)@\(request.targetVersion)")
        let result = try await runner.run(
            context.executablePath,
            arguments,
            timeout: 600,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("npm install", result: result) }

        let blocked = NpmSource.blockedScriptPackages(in: result.stdout + "\n" + result.stderr)
        guard !blocked.contains(where: { $0.caseInsensitiveCompare(request.packageID) == .orderedSame }) else {
            throw SourceError.verificationFailed(
                "npm installed \(request.packageID) \(request.targetVersion) but blocked its install scripts, "
                + "so the package may be left with a placeholder launcher that cannot run. "
                + "Run `npm config set allow-scripts=\(request.packageID) --location=user` and update again.")
        }
    }

    // npm 12 stopped running package install scripts unless the package is allowlisted. CLIs that
    // ship a placeholder launcher for their postinstall to replace with a real binary are left
    // unrunnable when that is skipped, and npm still exits 0. Allow scripts only for the single
    // package the user chose to update; everything else stays blocked.
    static let scriptAllowlistNpmMajor = 12

    static func supportsScriptAllowlist(_ version: String) -> Bool {
        let token = version.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let core = token.hasPrefix("v") ? String(token.dropFirst()) : token
        guard let major = core.split(separator: ".").first.map(String.init), let value = Int(major) else {
            return false
        }
        return value >= scriptAllowlistNpmMajor
    }

    // npm reports each skipped package as `npm warn install-scripts <name>@<version> (...)`.
    // The surrounding prose lines carry no name@version token and fall out here.
    static func blockedScriptPackages(in output: String) -> [String] {
        var names: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmed
            guard line.hasPrefix("npm warn ") || line.hasPrefix("npm error "),
                  let marker = line.range(of: "install-scripts") else { continue }
            let remainder = String(line[marker.upperBound...]).trimmed
            guard let token = remainder.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  let separator = token.lastIndex(of: "@"), separator != token.startIndex else { continue }
            let name = String(token[token.startIndex..<separator])
            guard !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
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
