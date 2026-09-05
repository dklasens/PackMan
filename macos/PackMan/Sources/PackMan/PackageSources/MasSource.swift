import Foundation

struct MasSource: PackageSource {
    let runner: any ProcessRunning
    let resolver: any ToolResolving
    let verificationDelay: Duration

    init(
        runner: any ProcessRunning = ProcessRunner.shared,
        resolver: any ToolResolving = ToolResolver.shared,
        verificationDelay: Duration = .seconds(8)
    ) {
        self.runner = runner
        self.resolver = resolver
        self.verificationDelay = verificationDelay
    }

    let descriptor = SourceDescriptor(
        id: .appStore,
        name: "App Store",
        toolID: .mas,
        executableName: "mas",
        knownPaths: ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"],
        installationURL: URL(string: "https://github.com/mas-cli/mas"))

    func probe() async -> SourceProbe {
        let probe = await SourceSupport.probe(
            descriptor: descriptor,
            versionArguments: ["version"],
            resolver: resolver,
            runner: runner)
        guard case .available(let context) = probe else { return probe }
        if let issue = MasVersionGate.issueIfUnsupported(context.version) {
            return .unavailable(issue)
        }
        return .available(context)
    }

    func scan(
        context: ToolContext,
        progress: @escaping @Sendable (SourcePhase) async -> Void
    ) async throws -> SourceScanReport {
        if let issue = MasVersionGate.issueIfUnsupported(context.version) {
            throw SourceError.commandFailed(issue.message)
        }
        await progress(.scanning)
        let result = try await runner.run(
            context.executablePath,
            ["outdated"],
            timeout: 180,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))

        var updates: [PackageInfo] = []
        var rejected = 0
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if let update = MasOutdatedParser.parseLine(String(line)) {
                updates.append(update)
            } else {
                rejected += 1
            }
        }
        var issues: [SourceIssue] = []
        if rejected > 0 {
            issues.append(SourceIssue(
                kind: .parsing,
                message: "Could not parse \(rejected) App Store update record(s).",
                recovery: "Run mas outdated in Terminal and inspect its output."))
        }
        if let indexingIssue = MasIndexingWarningParser.issue(fromStderr: result.stderr) {
            issues.append(indexingIssue)
        }
        if let networkIssue = MasNetworkErrorParser.issue(fromStderr: result.stderr) {
            issues.append(networkIssue)
        }

        if !result.succeeded && issues.isEmpty && updates.isEmpty {
            throw SourceSupport.commandFailure("mas outdated", result: result)
        }

        if !result.succeeded && issues.isEmpty {
            issues.append(SourceIssue(kind: .command, message: "mas returned exit \(result.exitCode); results may be incomplete.", recovery: result.stderr.terminalSanitized))
        }
        return SourceScanReport(updates: updates, issues: issues)
    }

    static func terminalUpdateCommand(forADAMID id: String) -> String {
        "sudo mas update --force \(id)"
    }

    func update(
        request: UpdateRequest,
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws {
        guard PackageIdValidator.isAllDigits(request.packageID) else {
            throw SourceError.invalidPackageId(request.packageID)
        }
        if let issue = MasVersionGate.issueIfUnsupported(context.version) {
            throw SourceError.commandFailed(issue.message)
        }
        // App Store commerce (CommerceKit) only answers inside the user's
        // logged-in GUI session: processes elevated through authorization
        // services hang at the purchase step (mas-cli/mas#128), and unprivileged
        // mas re-executes itself via sudo, which a GUI app cannot answer.
        // Hand the install to the one elevation path that reliably works.
        let command = Self.terminalUpdateCommand(forADAMID: request.packageID)
        await onOutput(ProcessOutputEvent(stream: .stdout, line: command))
        throw SourceError.requiresTerminalUpdate(command)
    }

    func verify(
        requests: [UpdateRequest],
        context: ToolContext
    ) async throws -> [String: UpdateVerification] {
        if verificationDelay > .zero {
            try await Task.sleep(for: verificationDelay)
        }
        try Task.checkCancellation()
        let result = try await runner.run(context.executablePath, ["list"], timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceSupport.commandFailure("mas list", result: result) }
        if let issue = MasIndexingWarningParser.issue(fromStderr: result.stderr) ?? MasNetworkErrorParser.issue(fromStderr: result.stderr) {
            throw SourceError.verificationFailed(issue.message)
        }
        let entries = try result.stdout.split(whereSeparator: \.isNewline).map { try Self.installedEntry(String($0)) }
        return InstalledInventory.verify(requests, entries: entries)
    }

    static func installedEntry(_ line: String) throws -> InstalledInventory.Entry {
        if line.trimmed.hasPrefix("{") {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            if let rawID = object?["adamID"], let version = object?["version"] as? String {
                let id = String(describing: rawID)
                if PackageIdValidator.isAllDigits(id) { return .init(id: id, version: version) }
            }
        } else {
            let pattern = try NSRegularExpression(pattern: #"^(\d+)\s+.+\s+\(([^()]+)\)\s*$"#)
            if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let id = Range(match.range(at: 1), in: line), let version = Range(match.range(at: 2), in: line) {
                return .init(id: String(line[id]), version: String(line[version]))
            }
        }
        throw SourceError.verificationFailed("App Store installed inventory contains an unrecognised record.")
    }

    func clearCache(
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws -> Int64 {
        await onOutput(ProcessOutputEvent(stream: .stdout, line: "App Store cache is managed automatically by macOS."))
        return 0
    }

    static func appStorePageURL(forADAMID id: String) -> URL? {
        URL(string: "macappstore://apps.apple.com/app/id\(id)")
    }
}

enum MasVersionGate {
    static let minimumMajorVersion = 4

    static func issueIfUnsupported(_ version: String) -> SourceIssue? {
        guard let major = majorVersion(of: version), major < minimumMajorVersion else { return nil }
        return SourceIssue(
            kind: .configuration,
            message: "mas \(version.trimmed) is too old; App Store support requires mas \(minimumMajorVersion).0 or newer.",
            recovery: "Run `brew upgrade mas` in Terminal, then retry.")
    }

    static func majorVersion(of version: String) -> Int? {
        let trimmed = version.trimmed
        let token = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        let component = token.split(separator: ".").first.map(String.init) ?? token
        return Int(component)
    }
}

enum MasIndexingWarningParser {
    private static let marker = "not indexed in Spotlight in "

    static func issue(fromStderr stderr: String) -> SourceIssue? {
        var paths: [String] = []
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = line.range(of: marker) else { continue }
            let path = String(line[range.upperBound...]).trimmed
            guard !path.isEmpty, !paths.contains(path) else { continue }
            paths.append(path)
        }
        guard !paths.isEmpty else { return nil }
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let listed = names.prefix(5).joined(separator: ", ")
        let suffix = names.count > 5 ? ", and \(names.count - 5) more" : ""
        return SourceIssue(
            kind: .configuration,
            message: "\(names.count) App Store app(s) are not indexed in Spotlight and were skipped: \(listed)\(suffix). mas started indexing them.",
            recovery: "Scan again shortly. If apps remain missing, run `sudo mdutil -Eai on` in Terminal to rebuild the Spotlight index.")
    }
}

enum MasNetworkErrorParser {
    static func issue(fromStderr stderr: String) -> SourceIssue? {
        guard stderr.contains("NSURLErrorDomain")
                || stderr.contains("The request timed out.")
                || stderr.contains("itunes.apple.com") else { return nil }

        let detail: String
        if let bundleRange = stderr.range(of: "bundleId=") {
            let suffix = stderr[bundleRange.upperBound...]
            let bundleId = suffix.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "}" }).first.map(String.init) ?? ""
            detail = bundleId.isEmpty ? "Network request to iTunes Store timed out." : "iTunes Store request timed out for \(bundleId)."
        } else {
            detail = "Network request to iTunes Store timed out."
        }

        return SourceIssue(
            kind: .network,
            message: "App Store scan encountered a network issue: \(detail)",
            recovery: "Apple iTunes lookup timed out. Check network connection and retry the scan.")
    }
}

enum MasOutdatedParser {
    // 497799835 Xcode (16.4 -> 16.5)
    private static let pattern = try! NSRegularExpression(pattern: "^(\\d+)\\s+(.+?)\\s+\\((.+?)\\s*->\\s*(.+?)\\)\\s*$")

    /// Accepts both the tabular rows produced by mas's shell wrapper and the
    /// JSON-lines emitted by the raw mas binary (mas 7+).
    static func parseLine(_ text: String) -> PackageInfo? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"), let record = parseJSON(trimmed) { return record }
        return parse(trimmed)
    }

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

    static func parseJSON(_ text: String) -> PackageInfo? {
        guard let data = text.data(using: .utf8),
              let record = try? JSONDecoder().decode(MasOutdatedRecord.self, from: data) else {
            return nil
        }
        return record.packageInfo
    }
}

struct MasOutdatedRecord: Decodable {
    let adamID: String
    let name: String
    let version: String
    let newVersion: String

    private enum CodingKeys: String, CodingKey {
        case adamID, name, version, newVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numeric = try? container.decode(Int.self, forKey: .adamID) {
            adamID = String(numeric)
        } else {
            adamID = try container.decode(String.self, forKey: .adamID)
        }
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        newVersion = try container.decode(String.self, forKey: .newVersion)
    }

    var packageInfo: PackageInfo? {
        guard PackageIdValidator.isAllDigits(adamID),
              !name.trimmed.isEmpty,
              PackageIdValidator.isValidVersion(newVersion) else { return nil }
        return PackageInfo(
            id: adamID,
            name: name,
            currentVersion: version,
            availableVersion: newVersion)
    }
}
