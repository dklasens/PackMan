import Foundation

struct NpmSource: PackageSource {
    let name = "NPM"

    private static let knownPaths = [
        "/opt/homebrew/bin/npm",
        "/usr/local/bin/npm",
    ]

    func isAvailable() async -> Bool {
        await resolveNpm() != nil
    }

    func scan() async throws -> [PackageInfo] {
        let npm = try await requireNpm()
        let result = try await ProcessRunner.run(
            npm,
            ["outdated", "-g", "--json"],
            timeout: 180)

        // npm outdated exits 1 when updates are available; that is not an error.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw SourceError.commandFailed("npm outdated failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }
        guard let data = result.stdout.data(using: .utf8), !result.stdout.trimmed.isEmpty else {
            return []
        }

        let entries = try JSONDecoder().decode([String: NpmOutdatedEntry].self, from: data)

        return entries
            .filter { PackageIdValidator.isValid($0.key) }
            .map { key, value in
                PackageInfo(
                    id: key,
                    name: key,
                    currentVersion: value.current ?? "",
                    availableVersion: value.wanted ?? value.latest ?? "")
            }
            .sorted { $0.name < $1.name }
    }

    func update(packageID: String, sourceDetail: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard PackageIdValidator.isValid(packageID) else {
            throw SourceError.invalidPackageId(packageID)
        }

        let npm = try await requireNpm()
        let result = try await ProcessRunner.run(
            npm,
            ["install", "-g", "\(packageID)@latest"],
            timeout: 600,
            onOutput: onOutput)

        guard result.succeeded else {
            throw SourceError.commandFailed("npm install failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }
    }

    private func requireNpm() async throws -> String {
        guard let path = await resolveNpm() else {
            throw SourceError.toolNotFound("npm")
        }
        return path
    }

    private func resolveNpm() async -> String? {
        await ProcessRunner.resolve("npm", knownPaths: Self.knownPaths)
    }
}

private struct NpmOutdatedEntry: Decodable {
    let current: String?
    let wanted: String?
    let latest: String?
}
