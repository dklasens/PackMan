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
    case outputLimit(executable: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(executable, timeout):
            return "'\(URL(fileURLWithPath: executable).lastPathComponent)' timed out after \(Int(timeout))s."
        case let .outputLimit(executable):
            return "Output from \(executable) exceeded the 16 MB capture limit; the command was stopped."
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
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let environment: [String: String]
    private let collector: ProcessOutputCollector
    private let lock = NSLock()
    private var cancelled = false

    init(executable: String, arguments: [String], timeout: TimeInterval, environment: [String: String],
         onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
        self.environment = environment; collector = ProcessOutputCollector(onOutput: onOutput)
    }

    func cancel() { lock.withLock { cancelled = true } }

    func start() async throws -> ProcessResult {
        // POSIX_SPAWN_SETPGROUP creates the group before exec, avoiding the race
        // inherent in calling setpgid after Foundation.Process.run().
        let outcome = await Task.detached { self.execute() }.value
        let output = await collector.finish()
        switch outcome {
        case .success(let code): return ProcessResult(exitCode: code, stdout: output.stdout, stderr: output.stderr)
        case .failure(let error): throw error
        }
    }

    private func execute() -> Result<Int32, Error> {
        if lock.withLock({ cancelled }) { return .failure(ProcessError.cancelled(executable: executable)) }
        var outFD: [Int32] = [0, 0], errFD: [Int32] = [0, 0]
        guard pipe(&outFD) == 0 else { return .failure(POSIXError(.EMFILE)) }
        guard pipe(&errFD) == 0 else { close(outFD[0]); close(outFD[1]); return .failure(POSIXError(.EMFILE)) }
        for fd in outFD + errFD { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        for fd in outFD + errFD { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var merged = ProcessInfo.processInfo.environment
        merged["PATH"] = ProcessRunner.standardSearchPaths.joined(separator: ":") + ":" + (merged["PATH"] ?? "")
        merged.merge(environment, uniquingKeysWith: { _, new in new })
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let launchCode = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        close(outFD[1]); close(errFD[1])
        guard launchCode == 0 else {
            close(outFD[0]); close(errFD[0])
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(launchCode)))
        }
        _ = fcntl(outFD[0], F_SETFL, O_NONBLOCK); _ = fcntl(errFD[0], F_SETFL, O_NONBLOCK)
        defer { close(outFD[0]); close(errFD[0]) }
        var outOpen = true, errOpen = true, parentExited = false
        var status: Int32 = 0
        var stopError: Error?
        var stopAt: TimeInterval?
        var sentKill = false
        let began = ProcessInfo.processInfo.systemUptime
        var bytesRead = 0
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if stopError == nil {
                if lock.withLock({ cancelled }) { stopError = ProcessError.cancelled(executable: executable) }
                else if now - began >= timeout { stopError = ProcessError.timedOut(executable: executable, timeout: timeout) }
                else if bytesRead > 16 * 1024 * 1024 { stopError = ProcessError.outputLimit(executable: executable) }
                if stopError != nil { stopAt = now; _ = kill(-pid, SIGTERM) }
            }
            if let stopAt, now - stopAt >= 1, !sentKill {
                _ = kill(-pid, SIGKILL)
                sentKill = true
            }
            for (fd, stream) in [(outFD[0], ProcessOutputStream.stdout), (errFD[0], .stderr)] {
                if (stream == .stdout && !outOpen) || (stream == .stderr && !errOpen) { continue }
                // Limit each drain turn so a busy writer cannot starve cancellation.
                for _ in 0..<16 {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        bytesRead += count
                        if bytesRead <= 16 * 1024 * 1024 { collector.append(Data(buffer.prefix(count)), stream: stream) }
                    } else {
                        if count == 0 || (errno != EAGAIN && errno != EINTR) {
                            if stream == .stdout { outOpen = false } else { errOpen = false }
                        }
                        break
                    }
                }
            }
            if !parentExited {
                let waited = waitpid(pid, &status, WNOHANG)
                parentExited = waited == pid || (waited < 0 && errno == ECHILD)
            }
            if parentExited && !outOpen && !errOpen { break }
            // Escaped descendants must not keep inherited pipes alive forever.
            if let stopAt, now - stopAt >= 2, parentExited { break }
            usleep(10_000)
        }
        if let stopError { return .failure(stopError) }
        let signal = status & 0x7f
        return .success(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
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
    private var droppedEvents = 0

    init(onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?) {
        var streamContinuation: AsyncStream<ProcessOutputEvent>.Continuation!
        let stream = AsyncStream<ProcessOutputEvent>(bufferingPolicy: .bufferingNewest(1024)) { streamContinuation = $0 }
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
            if droppedEvents > 0 {
                continuation.yield(ProcessOutputEvent(stream: .stderr,
                    line: "[Live output omitted at least \(droppedEvents) lines because the display could not keep up.]"))
            }
            didFinish = true
            continuation.finish()
        }
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (stdout, stderr)
    }

    private func emitCompleteLines(from remainder: inout Data, stream: ProcessOutputStream) {
        if remainder.count > 64 * 1024 && !remainder.contains(0x0A) {
            emitRemainder(remainder, stream: stream)
            remainder.removeAll(keepingCapacity: true)
        }
        while let newline = remainder.firstIndex(of: 0x0A) {
            let lineData = remainder.subdata(in: remainder.startIndex..<newline)
            remainder.removeSubrange(remainder.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                emit(ProcessOutputEvent(stream: stream, line: line))
            }
        }
    }

    private func emit(_ event: ProcessOutputEvent) {
        if case .dropped = continuation.yield(event) { droppedEvents += 1 }
    }

    private func emitRemainder(_ remainder: Data, stream: ProcessOutputStream) {
        guard !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8) else { return }
        emit(ProcessOutputEvent(stream: stream, line: line))
    }
}
