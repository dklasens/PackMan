import Foundation

struct PipxSource: PackageSource {
    let name = "pipx"

    private static let knownPaths = [
        "/opt/homebrew/bin/pipx",
        "/usr/local/bin/pipx",
    ]

    func isAvailable() async -> Bool {
        await resolvePipx() != nil
    }

    func scan() async throws -> [PackageInfo] {
        let pipx = try await requirePipx()
        let result = try await ProcessRunner.run(pipx, ["list", "--short"], timeout: 60)

        guard result.succeeded else {
            throw SourceError.commandFailed("pipx list failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }

        let installed: [(name: String, version: String)] = result.stdout
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                let name = String(parts[0])
                return PackageIdValidator.isValid(name) ? (name, String(parts[1])) : nil
            }

        // pipx has no "outdated" command; check PyPI for the latest version of each package.
        return await withTaskGroup(of: PackageInfo?.self) { group in
            var pending = installed.makeIterator()
            var updates: [PackageInfo] = []
            var inFlight = 0

            func enqueueNext() {
                guard let package = pending.next() else { return }
                inFlight += 1
                group.addTask {
                    await Self.checkForUpdate(name: package.name, currentVersion: package.version)
                }
            }

            for _ in 0..<4 { enqueueNext() }
            while let update = await group.next() {
                inFlight -= 1
                if let update { updates.append(update) }
                enqueueNext()
            }

            return updates.sorted { $0.name < $1.name }
        }
    }

    func update(packageID: String, sourceDetail: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard PackageIdValidator.isValid(packageID) else {
            throw SourceError.invalidPackageId(packageID)
        }

        let pipx = try await requirePipx()
        let result = try await ProcessRunner.run(
            pipx,
            ["upgrade", packageID],
            timeout: 600,
            onOutput: onOutput)

        guard result.succeeded else {
            throw SourceError.commandFailed("pipx upgrade failed (exit \(result.exitCode)): \(result.stderr.trimmed)")
        }
    }

    private static func checkForUpdate(name: String, currentVersion: String) async -> PackageInfo? {
        guard let latest = await latestPyPIVersion(for: name), latest != currentVersion else {
            return nil
        }
        return PackageInfo(id: name, name: name, currentVersion: currentVersion, availableVersion: latest)
    }

    private static func latestPyPIVersion(for package: String) async -> String? {
        guard let encoded = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://pypi.org/pypi/\(encoded)/json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(PyPIResponse.self, from: data) else {
            return nil
        }
        return info.info.version
    }

    private func requirePipx() async throws -> String {
        guard let path = await resolvePipx() else {
            throw SourceError.toolNotFound("pipx")
        }
        return path
    }

    private func resolvePipx() async -> String? {
        await ProcessRunner.resolve("pipx", knownPaths: Self.knownPaths)
    }
}

private struct PyPIResponse: Decodable {
    let info: Info

    struct Info: Decodable {
        let version: String
    }
}
