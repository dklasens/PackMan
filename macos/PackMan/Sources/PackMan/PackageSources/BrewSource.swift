import Foundation

enum BrewKind: Sendable {
    case formula
    case cask
}

struct BrewSource: PackageSource {
    let kind: BrewKind

    var name: String {
        switch kind {
        case .formula: return "Homebrew"
        case .cask: return "Homebrew Casks"
        }
    }

    private static let knownPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private static let noAutoUpdate: [String: String] = ["HOMEBREW_NO_AUTO_UPDATE": "1"]

    func isAvailable() async -> Bool {
        await resolveBrew() != nil
    }

    func scan() async throws -> [PackageInfo] {
        let brew = try await requireBrew()
        await BrewRefresh.shared.refreshIfNeeded(brew: brew)

        let result = try await ProcessRunner.run(
            brew,
            ["outdated", "--json=v2"],
            timeout: 300,
            extraEnvironment: Self.noAutoUpdate)

        guard result.succeeded else {
            throw SourceError.commandFailed("brew outdated failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }
        guard let data = result.stdout.data(using: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let outdated: BrewOutdated
        do {
            outdated = try decoder.decode(BrewOutdated.self, from: data)
        } catch {
            throw SourceError.commandFailed("brew outdated JSON parse failed: \(error.decodingDescription)")
        }

        let entries: [BrewOutdated.Entry]
        switch kind {
        case .formula: entries = outdated.formulae
        case .cask: entries = outdated.casks
        }

        return entries
            .filter { !($0.pinned ?? false) && PackageIdValidator.isValid($0.name) }
            .map {
                PackageInfo(
                    id: $0.name,
                    name: $0.name,
                    currentVersion: $0.installedVersions.last ?? "",
                    availableVersion: $0.currentVersion)
            }
    }

    func update(packageID: String, sourceDetail: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard PackageIdValidator.isValid(packageID) else {
            throw SourceError.invalidPackageId(packageID)
        }

        let brew = try await requireBrew()
        var arguments = ["upgrade"]
        if kind == .cask {
            arguments.append("--cask")
        }
        arguments.append(packageID)

        let result = try await ProcessRunner.run(
            brew,
            arguments,
            timeout: 900,
            extraEnvironment: Self.noAutoUpdate,
            onOutput: onOutput)

        guard result.succeeded else {
            throw SourceError.commandFailed("brew upgrade failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }
    }

    private func requireBrew() async throws -> String {
        guard let path = await resolveBrew() else {
            throw SourceError.toolNotFound("brew")
        }
        return path
    }

    private func resolveBrew() async -> String? {
        await ProcessRunner.resolve("brew", knownPaths: Self.knownPaths)
    }
}

/// Runs `brew update` at most once per interval so scans see fresh tap metadata
/// without paying the cost for both the formula and cask sources.
private actor BrewRefresh {
    static let shared = BrewRefresh()

    private var lastRefresh: Date?
    private let interval: TimeInterval = 3600

    func refreshIfNeeded(brew: String) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < interval {
            return
        }
        lastRefresh = Date()
        _ = try? await ProcessRunner.run(
            brew,
            ["update"],
            timeout: 300,
            extraEnvironment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
    }
}

private struct BrewOutdated: Decodable {
    let formulae: [Entry]
    let casks: [Entry]

    struct Entry: Decodable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String
        let pinned: Bool?
    }
}
