import Darwin
import Foundation

struct ProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessOutputStream: String, Sendable {
    case stdout
    case stderr
}

struct ProcessOutputEvent: Sendable, Equatable {
    let stream: ProcessOutputStream
    let line: String
}

enum ProcessError: LocalizedError, Equatable {
    case timedOut(executable: String, timeout: TimeInterval)
    case cancelled(executable: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(executable, timeout):
            return "'\(URL(fileURLWithPath: executable).lastPathComponent)' timed out after \(Int(timeout))s."
        case let .cancelled(executable):
            return "'\(URL(fileURLWithPath: executable).lastPathComponent)' was cancelled."
        }
    }
}

protocol ProcessRunning: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String],
        onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?
    ) async throws -> ProcessResult
}

extension ProcessRunning {
    func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = ProcessRunner.defaultTimeout,
        environment: [String: String] = [:],
        onOutput: (@Sendable (ProcessOutputEvent) async -> Void)? = nil
    ) async throws -> ProcessResult {
        try await run(
            executable,
            arguments,
            timeout: timeout,
            environment: environment,
            onOutput: onOutput)
    }
}

struct ProcessRunner: ProcessRunning {
    static let shared = ProcessRunner()
    static let defaultTimeout: TimeInterval = 180
    static let standardSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String],
        onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?
    ) async throws -> ProcessResult {
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environment: environment,
            onOutput: onOutput)

        return try await withTaskCancellationHandler {
            try await execution.start()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private enum StopReason {
        case cancelled
        case timedOut
    }

    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let environment: [String: String]
    private let collector: ProcessOutputCollector
    private let lock = NSLock()

    private var process: Process?
    private var ownsProcessGroup = false
    private var stopReason: StopReason?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var didResume = false

    init(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String],
        onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.environment = environment
        collector = ProcessOutputCollector(onOutput: onOutput)
    }

    func start() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            launch()
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var mergedEnvironment = ProcessInfo.processInfo.environment
        let inheritedPATH = mergedEnvironment["PATH"] ?? "/usr/bin:/bin"
        mergedEnvironment["PATH"] = ProcessRunner.standardSearchPaths.joined(separator: ":") + ":" + inheritedPATH
        for (key, value) in environment { mergedEnvironment[key] = value }
        process.environment = mergedEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReadQueue = DispatchQueue(label: "com.packman.process.stdout.\(UUID().uuidString)")
        let stderrReadQueue = DispatchQueue(label: "com.packman.process.stderr.\(UUID().uuidString)")
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [collector] handle in
            stdoutReadQueue.async {
                collector.append(handle.availableData, stream: .stdout)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [collector] handle in
            stderrReadQueue.async {
                collector.append(handle.availableData, stream: .stderr)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutReadQueue.sync {
                self.collector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), stream: .stdout)
            }
            stderrReadQueue.sync {
                self.collector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), stream: .stderr)
            }
            self.complete(exitCode: terminated.terminationStatus)
        }

        lock.lock()
        self.process = process
        let shouldStop = stopReason != nil
        lock.unlock()

        do {
            try process.run()
            let pid = process.processIdentifier
            let groupWasCreated = setpgid(pid, pid) == 0 || getpgid(pid) == pid
            lock.lock()
            ownsProcessGroup = groupWasCreated
            lock.unlock()

            scheduleTimeout()
            if shouldStop { terminateProcess() }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { [collector] in
                _ = await collector.finish()
                self.resume(throwing: error)
            }
        }
    }

    private func scheduleTimeout() {
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            requestStop(.timedOut)
        }
    }

    private func requestStop(_ reason: StopReason) {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        let process = process
        lock.unlock()

        guard process != nil else { return }
        terminateProcess()
    }

    private func terminateProcess() {
        lock.lock()
        guard let process else {
            lock.unlock()
            return
        }
        let pid = process.processIdentifier
        let processGroup = ownsProcessGroup
        lock.unlock()

        if processGroup { _ = Darwin.kill(-pid, SIGTERM) }
        if process.isRunning { process.terminate() }

        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.forceKillIfRunning()
        }
    }

    private func forceKillIfRunning() {
        lock.lock()
        guard let process, process.isRunning else {
            lock.unlock()
            return
        }
        let pid = process.processIdentifier
        let processGroup = ownsProcessGroup
        lock.unlock()

        if processGroup { _ = Darwin.kill(-pid, SIGKILL) }
        _ = Darwin.kill(pid, SIGKILL)
    }

    private func complete(exitCode: Int32) {
        timeoutTask?.cancel()
        Task { [collector] in
            let output = await collector.finish()
            let reason = self.currentStopReason()

            switch reason {
            case .cancelled:
                self.resume(throwing: ProcessError.cancelled(executable: self.executable))
            case .timedOut:
                self.resume(throwing: ProcessError.timedOut(executable: self.executable, timeout: self.timeout))
            case nil:
                self.resume(returning: ProcessResult(exitCode: exitCode, stdout: output.stdout, stderr: output.stderr))
            }
        }
    }

    private func resume(returning result: ProcessResult) {
        takeContinuation()?.resume(returning: result)
    }

    private func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<ProcessResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return nil }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        return continuation
    }

    private func currentStopReason() -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private let continuation: AsyncStream<ProcessOutputEvent>.Continuation
    private let deliveryTask: Task<Void, Never>
    private var didFinish = false

    init(onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?) {
        var streamContinuation: AsyncStream<ProcessOutputEvent>.Continuation!
        let stream = AsyncStream<ProcessOutputEvent> { streamContinuation = $0 }
        continuation = streamContinuation
        deliveryTask = Task {
            for await event in stream {
                await onOutput?(event)
            }
        }
    }

    func append(_ data: Data, stream: ProcessOutputStream) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        switch stream {
        case .stdout:
            stdoutData.append(data)
            stdoutRemainder.append(data)
            emitCompleteLines(from: &stdoutRemainder, stream: .stdout)
        case .stderr:
            stderrData.append(data)
            stderrRemainder.append(data)
            emitCompleteLines(from: &stderrRemainder, stream: .stderr)
        }
        lock.unlock()
    }

    func finish() async -> (stdout: String, stderr: String) {
        let output = finishSnapshot()
        await deliveryTask.value
        return output
    }

    private func finishSnapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        if !didFinish {
            emitRemainder(stdoutRemainder, stream: .stdout)
            emitRemainder(stderrRemainder, stream: .stderr)
            didFinish = true
            continuation.finish()
        }
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (stdout, stderr)
    }

    private func emitCompleteLines(from remainder: inout Data, stream: ProcessOutputStream) {
        while let newline = remainder.firstIndex(of: 0x0A) {
            let lineData = remainder.subdata(in: remainder.startIndex..<newline)
            remainder.removeSubrange(remainder.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                continuation.yield(ProcessOutputEvent(stream: stream, line: line))
            }
        }
    }

    private func emitRemainder(_ remainder: Data, stream: ProcessOutputStream) {
        guard !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8) else { return }
        continuation.yield(ProcessOutputEvent(stream: stream, line: line))
    }
}
