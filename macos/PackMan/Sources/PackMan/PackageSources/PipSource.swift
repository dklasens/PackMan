import Foundation

struct PipSource: PackageSource {
    static let findDependentsScript = #"""
import importlib.metadata as metadata
import json
import re
import sys

normalize = lambda value: re.sub(r"[-_.]+", "-", value).lower()
target = normalize(sys.argv[1])
dependents = {}
for distribution in metadata.distributions():
    name = distribution.metadata.get("Name")
    version = distribution.version
    if not name or not version or normalize(name) == target:
        continue
    for requirement in distribution.requires or ():
        match = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", requirement)
        if match and normalize(match.group(1)) == target:
            dependents.setdefault(normalize(name), {"name": name, "version": version})
            break
print(json.dumps(list(dependents.values()), ensure_ascii=True))
"""#

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
        guard !result.stdout.trimmed.isEmpty else { throw SourceError.commandFailed("pip returned empty output instead of JSON.") }
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
        guard PackageIdValidator.isValidVersion(request.targetVersion) else {
            throw SourceError.invalidTargetVersion(request.targetVersion)
        }
        let dependents = try await findInstalledDependents(
            of: request.packageID,
            context: context)
        let requirements = ["\(request.packageID)==\(request.targetVersion)"]
            + dependents.map { "\($0.name)==\($0.version)" }
        let result = try await runner.run(
            context.executablePath,
            ["-m", "pip", "install", "--upgrade"] + requirements,
            timeout: 600,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        if !result.succeeded,
           result.stderr.localizedCaseInsensitiveContains("ResolutionImpossible"),
           !dependents.isEmpty {
            let names = dependents.map { "\($0.name) \($0.version)" }.joined(separator: ", ")
            throw SourceError.commandFailed(
                "pip blocked \(request.packageID) \(request.targetVersion) because it conflicts with installed dependent package(s): \(names). No packages were changed; review the command log for the constraints.")
        }
        guard result.succeeded else { throw SourceError.commandFailed(Self.friendlyFailure("pip install", result)) }
    }

    private func findInstalledDependents(
        of packageID: String,
        context: ToolContext
    ) async throws -> [PipDependent] {
        let result = try await runner.run(
            context.executablePath,
            ["-c", Self.findDependentsScript, packageID],
            timeout: 30,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else {
            throw SourceError.commandFailed(
                "Could not inspect installed pip dependencies, so the update was not attempted: \(Self.friendlyFailure("python", result))")
        }
        do {
            let dependents = result.stdout.trimmed.isEmpty
                ? []
                : try JSONDecoder().decode([PipDependent].self, from: Data(result.stdout.utf8))
            guard dependents.allSatisfy({
                PackageIdValidator.isValid($0.name) && PackageIdValidator.isValidVersion($0.version)
            }) else {
                throw SourceError.commandFailed(
                    "Installed pip dependency metadata contained an invalid name or version, so the update was not attempted.")
            }
            return dependents
        } catch let error as SourceError {
            throw error
        } catch {
            throw SourceError.commandFailed(
                "Could not read installed pip dependencies, so the update was not attempted: \(error.decodingDescription)")
        }
    }

    private static func friendlyFailure(_ command: String, _ result: ProcessResult) -> String {
        if result.stderr.contains("externally-managed-environment") {
            return "\(command) refused: this Python is externally managed (PEP 668). Install the tool with pipx instead."
        }
        let detail = [result.stderr.terminalSanitized.trimmed, result.stdout.terminalSanitized.trimmed]
            .first { !$0.isEmpty } ?? "No diagnostic output."
        return "\(command) failed (exit \(result.exitCode)): \(detail)"
    }

    func clearCache(
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pipCacheURLs = [
            home.appendingPathComponent("Library/Caches/pip"),
            home.appendingPathComponent(".cache/pip")
        ]
        let sizeBefore = SourceSupport.directorySize(at: pipCacheURLs)

        let result = try await runner.run(
            context.executablePath,
            ["-m", "pip", "cache", "purge"],
            timeout: 180,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("pip cache purge", result: result) }

        let sizeAfter = SourceSupport.directorySize(at: pipCacheURLs)
        return max(0, sizeBefore - sizeAfter)
    }
}

struct PipOutdatedEntry: Decodable {
    let name: String
    let version: String?
    let latestVersion: String?
}

private struct PipDependent: Decodable {
    let name: String
    let version: String
}
