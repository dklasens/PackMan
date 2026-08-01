import Foundation

struct PipSource: PackageSource {
    let name = "pip"

    private static let knownPaths = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]

    func isAvailable() async -> Bool {
        await resolvePython() != nil
    }

    func scan() async throws -> [PackageInfo] {
        let python = try await requirePython()
        let result = try await ProcessRunner.run(
            python,
            ["-m", "pip", "list", "--outdated", "--format", "json", "--disable-pip-version-check"],
            timeout: 180)

        guard result.succeeded else {
            throw SourceError.commandFailed(Self.friendlyFailure("pip list", result))
        }
        guard let data = result.stdout.data(using: .utf8), !result.stdout.trimmed.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode([PipOutdatedEntry].self, from: data)

        return entries
            .filter { PackageIdValidator.isValid($0.name) }
            .map {
                PackageInfo(
                    id: $0.name,
                    name: $0.name,
                    currentVersion: $0.version ?? "",
                    availableVersion: $0.latestVersion ?? "")
            }
            .sorted { $0.name < $1.name }
    }

    func update(packageID: String, sourceDetail: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard PackageIdValidator.isValid(packageID) else {
            throw SourceError.invalidPackageId(packageID)
        }

        let python = try await requirePython()
        let result = try await ProcessRunner.run(
            python,
            ["-m", "pip", "install", "--upgrade", packageID],
            timeout: 600,
            onOutput: onOutput)

        guard result.succeeded else {
            throw SourceError.commandFailed(Self.friendlyFailure("pip install", result))
        }
    }

    private static func friendlyFailure(_ command: String, _ result: ProcessResult) -> String {
        if result.stderr.contains("externally-managed-environment") {
            return "\(command) refused: this Python is externally managed (PEP 668). Install the tool with pipx instead."
        }
        return "\(command) failed (exit \(result.exitCode)): \(result.stderr.trimmed)"
    }

    private func requirePython() async throws -> String {
        guard let path = await resolvePython() else {
            throw SourceError.toolNotFound("python3")
        }
        return path
    }

    private func resolvePython() async -> String? {
        await ProcessRunner.resolve("python3", knownPaths: Self.knownPaths)
    }
}

private struct PipOutdatedEntry: Decodable {
    let name: String
    let version: String?
    let latestVersion: String?
}
