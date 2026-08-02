import Foundation

enum SourceSupport {
    static func probe(
        descriptor: SourceDescriptor,
        versionArguments: [String],
        resolver: any ToolResolving,
        runner: any ProcessRunning
    ) async -> SourceProbe {
        let resolution = await resolver.resolve(descriptor)
        let executable: ResolvedExecutable
        switch resolution {
        case .resolved(let result):
            executable = result
        case .notFound:
            return .unavailable(SourceIssue(
                kind: .unavailable,
                message: "\(descriptor.executableName) was not found.",
                recovery: "Install \(descriptor.name), or choose its executable in Sources."))
        case .invalidOverride(let path):
            return .unavailable(SourceIssue(
                kind: .configuration,
                message: "The selected executable is missing or cannot be run: \(path)",
                recovery: "Choose another executable or switch to automatic discovery."))
        case let .missingDependency(executablePath, dependency):
            return .unavailable(SourceIssue(
                kind: .configuration,
                message: "\(descriptor.executableName) was found at \(executablePath), but its required \(dependency) runtime was not found.",
                recovery: "Install or activate \(dependency) for this \(descriptor.executableName) executable, choose \(descriptor.executableName) from a complete installation in Sources, then retry."))
        }

        let contextEnvironment = environment(pathEntries: executable.pathEntries)
        do {
            let result = try await runner.run(
                executable.path,
                versionArguments,
                timeout: 15,
                environment: contextEnvironment)
            guard result.succeeded else {
                let detail = [result.stderr.trimmed, result.stdout.trimmed].first { !$0.isEmpty } ?? "exit \(result.exitCode)"
                return .unavailable(SourceIssue(
                    kind: .unavailable,
                    message: "\(descriptor.name) could not be used: \(detail)",
                    recovery: "Check the executable in Sources."))
            }
            let version = (result.stdout + "\n" + result.stderr)
                .split(separator: "\n")
                .map { String($0).trimmed }
                .first { !$0.isEmpty } ?? "Available"
            return .available(ToolContext(
                executablePath: executable.path,
                version: version,
                pathEntries: executable.pathEntries,
                origin: executable.origin))
        } catch is CancellationError {
            return .unavailable(SourceIssue(kind: .command, message: "Availability check was cancelled."))
        } catch let error as ProcessError where error.isCancellation {
            return .unavailable(SourceIssue(kind: .command, message: "Availability check was cancelled."))
        } catch {
            return .unavailable(SourceIssue(
                kind: .unavailable,
                message: "\(descriptor.name) could not be checked: \(error.userMessage)",
                recovery: "Check the executable in Sources."))
        }
    }

    static func environment(pathEntries: [String], additions: [String: String] = [:]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let paths = unique(pathEntries + ProcessRunner.standardSearchPaths)
        var environment = additions
        environment["PATH"] = paths.joined(separator: ":") + ":" + inherited
        return environment
    }

    static func commandFailure(_ command: String, result: ProcessResult) -> SourceError {
        let detail = [result.stderr.trimmed, result.stdout.trimmed].first { !$0.isEmpty } ?? "No diagnostic output."
        return .commandFailed("\(command) failed (exit \(result.exitCode)): \(detail)")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

extension ProcessError {
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> HTTPDataResponse
}

struct HTTPDataResponse: Sendable {
    let data: Data
    let statusCode: Int
}

struct URLSessionHTTPClient: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPDataResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        return HTTPDataResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
