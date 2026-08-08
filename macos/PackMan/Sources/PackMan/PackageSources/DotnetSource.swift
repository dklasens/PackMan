import Foundation

struct DotnetSource: PackageSource {
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
        id: .dotnet,
        name: ".NET Tools",
        toolID: .dotnet,
        executableName: "dotnet",
        knownPaths: [
            "/opt/homebrew/bin/dotnet",
            "/usr/local/bin/dotnet",
            "/usr/local/share/dotnet/dotnet",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dotnet/dotnet").path,
        ],
        installationURL: URL(string: "https://dotnet.microsoft.com/download"))

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
            ["tool", "list", "--global"],
            timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceSupport.commandFailure("dotnet tool list", result: result) }

        let parsed = DotnetToolListParser.parse(result.stdout)
        let lookups = await withTaskGroup(of: DotnetLookup.self, returning: [DotnetLookup].self) { group in
            var iterator = parsed.tools.makeIterator()
            var results: [DotnetLookup] = []

            func enqueue() {
                guard let tool = iterator.next() else { return }
                group.addTask {
                    await lookupNuGet(id: tool.id, currentVersion: tool.version)
                }
            }

            for _ in 0..<min(8, parsed.tools.count) { enqueue() }
            while let lookup = await group.next() {
                results.append(lookup)
                enqueue()
            }
            return results
        }

        var updates: [PackageInfo] = []
        var issues = parsed.issues
        for lookup in lookups {
            switch lookup {
            case .current:
                break
            case .outdated(let update):
                updates.append(update)
            case .failed(let id, let message):
                issues.append(SourceIssue(
                    kind: .network,
                    message: "\(id): \(message)",
                    recovery: "Check the network and retry."))
            }
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
        let result = try await runner.run(
            context.executablePath,
            ["tool", "update", "--global", request.packageID, "--version", request.targetVersion],
            timeout: 900,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("dotnet tool update", result: result) }
    }

    private func lookupNuGet(id: String, currentVersion: String) async -> DotnetLookup {
        let encoded = id.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id.lowercased()
        guard let url = URL(string: "https://api.nuget.org/v3-flatcontainer/\(encoded)/index.json") else {
            return .failed(id: id, message: "The package URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        do {
            let response = try await httpClient.data(for: request)
            if response.statusCode == 404 {
                return .failed(id: id, message: "The package was not found on nuget.org.")
            }
            guard response.statusCode == 200 else {
                return .failed(id: id, message: "nuget.org returned HTTP \(response.statusCode).")
            }
            let versions = try JSONDecoder().decode(NuGetVersionIndex.self, from: response.data).versions
            let stable = versions.filter { !$0.contains("-") }
            guard let latest = (stable.isEmpty ? versions : stable).max(by: { lhs, rhs in
                VersionComparator.compare(lhs, rhs) == .orderedAscending
            }), PackageIdValidator.isValidVersion(latest) else {
                return .failed(id: id, message: "nuget.org returned no valid versions.")
            }
            guard VersionComparator.compare(currentVersion, latest) == .orderedAscending else {
                return .current(id: id)
            }
            return .outdated(PackageInfo(
                id: id,
                name: id,
                currentVersion: currentVersion,
                availableVersion: latest))
        } catch is CancellationError {
            return .failed(id: id, message: "Lookup was cancelled.")
        } catch {
            return .failed(id: id, message: error.decodingDescription)
        }
    }
}

enum DotnetLookup: Sendable {
    case current(id: String)
    case outdated(PackageInfo)
    case failed(id: String, message: String)
}

struct NuGetVersionIndex: Decodable {
    let versions: [String]
}

enum DotnetToolListParser {
    struct Result: Equatable {
        let tools: [Tool]
        let issues: [SourceIssue]
    }

    struct Tool: Equatable {
        let id: String
        let version: String
    }

    static func parse(_ output: String) -> Result {
        var tools: [Tool] = []
        var issues: [SourceIssue] = []
        var inTable = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).terminalSanitized.trimmed
            guard !line.isEmpty else { continue }
            if line.localizedCaseInsensitiveContains("package id")
                && line.localizedCaseInsensitiveContains("version") {
                inTable = true
                continue
            }
            if line.allSatisfy({ $0 == "-" || $0.isWhitespace }) { continue }
            guard inTable else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2,
                  PackageIdValidator.isValid(fields[0]),
                  PackageIdValidator.isValidVersion(fields[1]) else {
                issues.append(SourceIssue(
                    kind: .parsing,
                    message: "dotnet tool list returned a record that could not be parsed."))
                continue
            }
            tools.append(Tool(id: fields[0], version: fields[1]))
        }
        return Result(tools: tools, issues: issues)
    }
}
