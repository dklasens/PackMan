import Foundation

struct PipxSource: PackageSource {
    let runner: any ProcessRunning
    let resolver: any ToolResolving
    let httpClient: any HTTPDataLoading

    init(
        runner: any ProcessRunning = ProcessRunner.shared,
        resolver: any ToolResolving = ToolResolver.shared,
        httpClient: any HTTPDataLoading = URLSessionHTTPClient()
    ) {
        self.runner = runner
        self.resolver = resolver
        self.httpClient = httpClient
    }

    let descriptor = SourceDescriptor(
        id: .pipx,
        name: "pipx",
        toolID: .pipx,
        executableName: "pipx",
        knownPaths: ["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx"],
        installationURL: URL(string: "https://pipx.pypa.io/stable/installation/"))

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
        if try await supportsNativeOutdated(context: context) {
            return try await scanNative(context: context)
        }
        return try await scanLegacy(context: context)
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
            ["upgrade", request.packageID],
            timeout: 600,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("pipx upgrade", result: result) }
    }

    private func supportsNativeOutdated(context: ToolContext) async throws -> Bool {
        let result = try await runner.run(
            context.executablePath,
            ["list", "--help"],
            timeout: 15,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { return false }
        return result.stdout.contains("--outdated") && result.stdout.contains("--output")
    }

    private func scanNative(context: ToolContext) async throws -> SourceScanReport {
        let result = try await runner.run(
            context.executablePath,
            ["list", "--outdated", "--output", "json"],
            timeout: 180,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard let data = result.stdout.data(using: .utf8), !result.stdout.trimmed.isEmpty else {
            if result.succeeded { return SourceScanReport() }
            throw SourceSupport.commandFailure("pipx list --outdated", result: result)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope: PipxOutdatedEnvelope
        do {
            envelope = try decoder.decode(PipxOutdatedEnvelope.self, from: data)
        } catch {
            throw SourceError.commandFailed("pipx outdated JSON parse failed: \(error.decodingDescription)")
        }

        let updates = envelope.data.packages
            .filter { !$0.injected && PackageIdValidator.isValid($0.package) }
            .map {
                PackageInfo(
                    id: $0.package,
                    name: $0.package,
                    currentVersion: $0.version,
                    availableVersion: $0.latestVersion)
            }
        var issues = envelope.errors.map { error in
            let scope = error.environment ?? error.package
            return SourceIssue(
                kind: .network,
                message: scope.map { "\($0): \(error.message)" } ?? error.message,
                recovery: "Check the package index configuration and retry.")
        }
        if !result.succeeded && issues.isEmpty {
            issues.append(SourceIssue(
                kind: .command,
                message: "pipx reported an unsuccessful outdated check.",
                recovery: result.stderr.trimmed.isEmpty ? "Retry the scan." : result.stderr.trimmed))
        }
        return SourceScanReport(updates: updates, issues: issues)
    }

    private func scanLegacy(context: ToolContext) async throws -> SourceScanReport {
        let result = try await runner.run(
            context.executablePath,
            ["list", "--short"],
            timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceSupport.commandFailure("pipx list", result: result) }

        var installed: [(name: String, version: String)] = []
        var issues: [SourceIssue] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, PackageIdValidator.isValid(String(parts[0])) else {
                issues.append(SourceIssue(kind: .parsing, message: "Could not parse a pipx package record."))
                continue
            }
            installed.append((String(parts[0]), String(parts[1])))
        }

        let lookups = await withTaskGroup(of: PipxLookup.self, returning: [PipxLookup].self) { group in
            var iterator = installed.makeIterator()
            var results: [PipxLookup] = []

            func enqueue() {
                guard let package = iterator.next() else { return }
                group.addTask {
                    await lookupPyPI(name: package.name, currentVersion: package.version)
                }
            }

            for _ in 0..<min(8, installed.count) { enqueue() }
            while let lookup = await group.next() {
                results.append(lookup)
                enqueue()
            }
            return results
        }

        var updates: [PackageInfo] = []
        for lookup in lookups {
            switch lookup {
            case .current:
                break
            case .outdated(let info):
                updates.append(info)
            case .failed(let name, let message):
                issues.append(SourceIssue(
                    kind: .network,
                    message: "\(name): \(message)",
                    recovery: "Check your network or package index and retry."))
            }
        }
        updates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return SourceScanReport(updates: updates, issues: issues)
    }

    private func lookupPyPI(name: String, currentVersion: String) async -> PipxLookup {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://pypi.org/pypi/\(encoded)/json") else {
            return .failed(name: name, message: "The package URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let response = try await httpClient.data(for: request)
            guard response.statusCode == 200 else {
                return .failed(name: name, message: "PyPI returned HTTP \(response.statusCode).")
            }
            let latest = try JSONDecoder().decode(PyPIResponse.self, from: response.data).info.version
            if latest == currentVersion { return .current(name: name) }
            return .outdated(PackageInfo(
                id: name,
                name: name,
                currentVersion: currentVersion,
                availableVersion: latest))
        } catch is CancellationError {
            return .failed(name: name, message: "Lookup was cancelled.")
        } catch {
            return .failed(name: name, message: error.decodingDescription)
        }
    }
}

enum PipxLookup: Sendable {
    case current(name: String)
    case outdated(PackageInfo)
    case failed(name: String, message: String)
}

struct PipxOutdatedEnvelope: Decodable {
    let status: String
    let exitCode: Int
    let data: OutdatedData
    let errors: [EnvelopeError]

    struct OutdatedData: Decodable {
        let packagesChecked: Int
        let packages: [Package]
        let skipped: [Skipped]
    }

    struct Package: Decodable {
        let environment: String
        let package: String
        let version: String
        let latestVersion: String
        let injected: Bool
        let pinned: Bool
    }

    struct Skipped: Decodable {
        let environment: String
        let package: String
        let reason: String
    }

    struct EnvelopeError: Decodable {
        let code: String
        let message: String
        let environment: String?
        let package: String?
    }
}

struct PyPIResponse: Decodable {
    let info: Info

    struct Info: Decodable {
        let version: String
    }
}
