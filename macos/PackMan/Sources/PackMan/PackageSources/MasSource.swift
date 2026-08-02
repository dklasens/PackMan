import Foundation

struct MasSource: PackageSource {
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
        id: .appStore,
        name: "App Store",
        toolID: .mas,
        executableName: "mas",
        knownPaths: ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"],
        installationURL: URL(string: "https://github.com/mas-cli/mas"))

    func probe() async -> SourceProbe {
        await SourceSupport.probe(
            descriptor: descriptor,
            versionArguments: ["version"],
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
            ["outdated"],
            timeout: 120,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceSupport.commandFailure("mas outdated", result: result) }

        var updates: [PackageInfo] = []
        var rejected = 0
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if let update = MasOutdatedParser.parse(String(line)) {
                updates.append(update)
            } else {
                rejected += 1
            }
        }
        let issues = rejected == 0 ? [] : [SourceIssue(
            kind: .parsing,
            message: "Could not parse \(rejected) App Store update record(s).",
            recovery: "Run mas outdated in Terminal and inspect its output.")]
        return SourceScanReport(updates: updates, issues: issues)
    }

    func update(
        request: UpdateRequest,
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws {
        guard PackageIdValidator.isAllDigits(request.packageID) else {
            throw SourceError.invalidPackageId(request.packageID)
        }
        let result = try await runner.run(
            context.executablePath,
            ["upgrade", request.packageID],
            timeout: 900,
            environment: SourceSupport.environment(pathEntries: context.pathEntries),
            onOutput: onOutput)
        guard result.succeeded else { throw SourceSupport.commandFailure("mas upgrade", result: result) }
    }
}

enum MasOutdatedParser {
    // 497799835 Xcode (16.4 -> 16.5)
    private static let pattern = try! NSRegularExpression(pattern: "^(\\d+)\\s+(.+?)\\s+\\((.+?)\\s*->\\s*(.+?)\\)\\s*$")

    static func parse(_ text: String) -> PackageInfo? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              match.numberOfRanges == 5,
              let idRange = Range(match.range(at: 1), in: text),
              let nameRange = Range(match.range(at: 2), in: text),
              let currentRange = Range(match.range(at: 3), in: text),
              let availableRange = Range(match.range(at: 4), in: text) else {
            return nil
        }
        let id = String(text[idRange])
        guard PackageIdValidator.isAllDigits(id) else { return nil }
        return PackageInfo(
            id: id,
            name: String(text[nameRange]),
            currentVersion: String(text[currentRange]),
            availableVersion: String(text[availableRange]))
    }
}
