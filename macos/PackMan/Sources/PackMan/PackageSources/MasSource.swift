import Foundation

struct MasSource: PackageSource {
    let name = "App Store"

    private static let knownPaths = [
        "/opt/homebrew/bin/mas",
        "/usr/local/bin/mas",
    ]

    // 497799835 Xcode (16.4 -> 16.5)
    private static let outdatedLine: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^(\\d+)\\s+(.+?)\\s+\\((.+?)\\s*->\\s*(.+?)\\)\\s*$")
    }()

    func isAvailable() async -> Bool {
        await resolveMas() != nil
    }

    func scan() async throws -> [PackageInfo] {
        let mas = try await requireMas()
        let result = try await ProcessRunner.run(mas, ["outdated"], timeout: 120)

        guard result.succeeded else {
            throw SourceError.commandFailed("mas outdated failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }

        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> PackageInfo? in
                let text = String(line)
                let range = NSRange(text.startIndex..., in: text)
                guard let match = Self.outdatedLine.firstMatch(in: text, range: range),
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

    func update(packageID: String, sourceDetail: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard PackageIdValidator.isAllDigits(packageID) else {
            throw SourceError.invalidPackageId(packageID)
        }

        let mas = try await requireMas()
        let result = try await ProcessRunner.run(
            mas,
            ["upgrade", packageID],
            timeout: 900,
            onOutput: onOutput)

        guard result.succeeded else {
            throw SourceError.commandFailed("mas upgrade failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }
    }

    private func requireMas() async throws -> String {
        guard let path = await resolveMas() else {
            throw SourceError.toolNotFound("mas")
        }
        return path
    }

    private func resolveMas() async -> String? {
        await ProcessRunner.resolve("mas", knownPaths: Self.knownPaths)
    }
}
