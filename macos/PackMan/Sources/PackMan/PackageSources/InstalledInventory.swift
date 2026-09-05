import Foundation

/// A missing record is never evidence that the requested target was installed.
/// Multiple matches are ambiguous; retain that uncertainty instead of choosing one.
enum InstalledInventory {
    struct Entry: Sendable {
        let id: String
        let version: String
    }

    static func verify(_ requests: [UpdateRequest], entries: [Entry], normalize: (String) -> String = { $0 }) -> [String: UpdateVerification] {
        let grouped = Dictionary(grouping: entries, by: { normalize($0.id) })
        return Dictionary(requests.map { request in
            let matches = grouped[normalize(request.packageID)] ?? []
            let outcome: UpdateVerification
            if matches.isEmpty {
                outcome = .missing("The package is absent from this manager's installed inventory. Verify its identity and environment before retrying.")
            } else if matches.count != 1 {
                outcome = .inconclusive(installedVersion: nil, evidence: "Multiple installed records match this identity.")
            } else {
                let installed = matches[0].version.trimmed
                let target = request.targetVersion.trimmed
                if installed.isEmpty || target.isEmpty || installed == "latest" || target == "latest" {
                    outcome = .inconclusive(installedVersion: installed.isEmpty ? nil : installed, evidence: "The manager did not supply comparable installed and target versions.")
                } else if installed == target {
                    outcome = .satisfied(installedVersion: installed)
                } else if let comparison = VersionComparator.strictCompare(installed, target) {
                    outcome = comparison == .orderedAscending
                        ? .stillOutdated(PackageInfo(id: request.packageID, name: request.name, currentVersion: installed, availableVersion: target))
                        : .satisfied(installedVersion: installed)
                } else {
                    outcome = .inconclusive(installedVersion: installed, evidence: "Observed \(installed), requested \(target). These versions cannot be compared reliably; scan this source again.")
                }
            }
            return (request.packageID, outcome)
        }, uniquingKeysWith: { first, _ in first })
    }

    static func pythonName(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }
}

extension PipSource {
    func verify(requests: [UpdateRequest], context: ToolContext) async throws -> [String: UpdateVerification] {
        let result = try await runner.run(context.executablePath,
            ["-m", "pip", "list", "--format", "json", "--disable-pip-version-check"], timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceSupport.commandFailure("pip list", result: result) }
        struct Record: Decodable { let name: String; let version: String }
        let records = try JSONDecoder().decode([Record].self, from: Data(result.stdout.utf8))
        return InstalledInventory.verify(requests, entries: records.map { .init(id: $0.name, version: $0.version) }, normalize: InstalledInventory.pythonName)
    }
}

extension DotnetSource {
    func verify(requests: [UpdateRequest], context: ToolContext) async throws -> [String: UpdateVerification] {
        let result = try await runner.run(context.executablePath, ["tool", "list", "--global"], timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries, additions: ["DOTNET_CLI_UI_LANGUAGE": "en-US"]))
        guard result.succeeded else { throw SourceSupport.commandFailure("dotnet tool list", result: result) }
        let parsed = DotnetToolListParser.parse(result.stdout)
        guard parsed.issues.isEmpty else { throw SourceError.verificationFailed(parsed.issues.map(\.message).joined(separator: "; ")) }
        return InstalledInventory.verify(requests, entries: parsed.tools.map { .init(id: $0.id, version: $0.version) }, normalize: { $0.lowercased() })
    }
}

extension BrewSource {
    func verify(requests: [UpdateRequest], context: ToolContext) async throws -> [String: UpdateVerification] {
        let result = try await runner.run(context.executablePath, ["info", "--json=v2", "--installed", kind == .cask ? "--cask" : "--formula"], timeout: 120,
            environment: SourceSupport.environment(pathEntries: context.pathEntries, additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
        guard result.succeeded else { throw SourceSupport.commandFailure("brew info", result: result) }
        let root = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        guard let object = root as? [String: Any], let records = object[kind == .cask ? "casks" : "formulae"] as? [[String: Any]] else {
            throw SourceError.verificationFailed("Homebrew returned an unrecognised installed inventory.")
        }
        var entries: [InstalledInventory.Entry] = []
        for record in records {
            guard let name = (record["full_token"] ?? record["full_name"] ?? record["token"] ?? record["name"]) as? String else {
                throw SourceError.verificationFailed("Homebrew inventory contains an unnamed package.")
            }
            let versions: [String]
            if kind == .cask {
                if let installed = record["installed"] as? String { versions = [installed] }
                else { versions = record["installed"] as? [String] ?? [] }
            } else {
                guard let installed = record["installed"] as? [[String: Any]] else {
                    throw SourceError.verificationFailed("Homebrew inventory has no installed version field.")
                }
                versions = installed.compactMap { $0["version"] as? String }
            }
            // Homebrew may retain old kegs. Select the newest provably comparable
            // version, or leave multiple incomparable records ambiguous.
            let unique = Array(Set(versions))
            if unique.allSatisfy({ VersionComparator.strictCompare($0, unique.first ?? "") != nil }),
               let newest = unique.max(by: { VersionComparator.compare($0, $1) == .orderedAscending }) {
                entries.append(.init(id: name, version: newest))
            } else {
                entries += unique.map { .init(id: name, version: $0) }
            }
        }
        return InstalledInventory.verify(requests, entries: entries)
    }
}

extension PipxSource {
    func verify(requests: [UpdateRequest], context: ToolContext) async throws -> [String: UpdateVerification] {
        let result = try await runner.run(context.executablePath, ["list", "--json"], timeout: 60,
            environment: SourceSupport.environment(pathEntries: context.pathEntries))
        guard result.succeeded else { throw SourceSupport.commandFailure("pipx list", result: result) }
        return InstalledInventory.verify(requests, entries: try Self.installedEntries(result.stdout))
    }

    static func installedEntries(_ output: String) throws -> [InstalledInventory.Entry] {
        struct Snapshot: Decodable {
            let venvs: [String: Venv]
            struct Venv: Decodable { let metadata: Metadata }
            struct Metadata: Decodable { let main_package: Package }
            struct Package: Decodable { let package_version: String }
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(output.utf8))
        return snapshot.venvs.map { .init(id: $0.key, version: $0.value.metadata.main_package.package_version) }
    }
}
