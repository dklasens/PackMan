import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessError: LocalizedError {
    case timedOut(executable: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(executable, timeout):
            return "'\(executable)' timed out after \(Int(timeout))s."
        }
    }
}

enum ProcessRunner {
    static let defaultTimeout: TimeInterval = 180

    static let searchPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        extraEnvironment: [String: String] = [:],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Self.searchPATH + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            for (key, value) in extraEnvironment {
                environment[key] = value
            }
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let box = OutputBox(onOutput: onOutput)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { box.append(data, isStdErr: false) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { box.append(data, isStdErr: true) }
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                box.markTimedOut()
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            process.terminationHandler = { proc in
                timeoutTask.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                box.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), isStdErr: false)
                box.append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), isStdErr: true)

                if box.isTimedOut {
                    continuation.resume(throwing: ProcessError.timedOut(executable: executable, timeout: timeout))
                } else {
                    continuation.resume(returning: box.result(exitCode: proc.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    static func resolve(_ name: String, knownPaths: [String] = []) async -> String? {
        await ToolPathCache.shared.resolve(name, knownPaths: knownPaths)
    }

    fileprivate static func uncachedResolve(_ name: String, knownPaths: [String]) async -> String? {
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        guard let result = try? await run("/usr/bin/which", [name], timeout: 10),
              result.succeeded else {
            return nil
        }

        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Tool locations never change during an app run; avoid re-spawning `which`
/// for every scan and update. (Newly installed tools are picked up on relaunch.)
private actor ToolPathCache {
    static let shared = ToolPathCache()

    private var cache: [String: String?] = [:]

    func resolve(_ name: String, knownPaths: [String]) async -> String? {
        let key = name + "\u{0}" + knownPaths.joined(separator: "\u{0}")
        if let cached = cache[key] {
            return cached
        }
        let found = await ProcessRunner.uncachedResolve(name, knownPaths: knownPaths)
        cache[key] = found
        return found
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var pendingLine = Data()
    private var timedOut = false
    private let onOutput: (@Sendable (String) -> Void)?

    init(onOutput: (@Sendable (String) -> Void)?) {
        self.onOutput = onOutput
    }

    func append(_ data: Data, isStdErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isStdErr {
            stderrData.append(data)
            lock.unlock()
            return
        }
        stdoutData.append(data)
        pendingLine.append(data)
        var lines: [String] = []
        while let newlineIndex = pendingLine.firstIndex(of: 0x0A) {
            let lineData = pendingLine.subdata(in: pendingLine.startIndex..<newlineIndex)
            pendingLine.removeSubrange(pendingLine.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        let callback = onOutput
        lock.unlock()

        if let callback {
            for line in lines { callback(line) }
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func result(exitCode: Int32) -> ProcessResult {
        lock.lock()
        let out = String(data: stdoutData, encoding: .utf8) ?? ""
        let err = String(data: stderrData, encoding: .utf8) ?? ""
        let remainder = pendingLine
        let callback = onOutput
        lock.unlock()

        if let callback, !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8) {
            callback(line)
        }

        return ProcessResult(exitCode: exitCode, stdout: out, stderr: err)
    }
}
