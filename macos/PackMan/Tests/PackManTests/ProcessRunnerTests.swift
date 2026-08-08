import Darwin
import XCTest
@testable import PackMan

final class ProcessRunnerTests: XCTestCase {
    func testTerminalSanitizerRemovesAnsiAndControlPictures() {
        let raw = "\u{001B}[34m==>\u{001B}[0m \u{001B}[1mInstalling\u{001B}[0m\r\u{0008} now"
        XCTAssertEqual(raw.terminalSanitized, "==> Installing now")
        XCTAssertEqual("␛[34mBlue␛[0m".terminalSanitized, "Blue")
    }

    func testCapturesBothStreamsAndFlushesPartialLinesBeforeCompletion() async throws {
        let recorder = EventRecorder()
        let result = try await ProcessRunner.shared.run(
            "/bin/sh",
            ["-c", "printf 'out-one\\nout-tail'; printf 'err-one\\nerr-tail' >&2"],
            timeout: 5,
            environment: [:]
        ) { event in
            await recorder.append(event)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "out-one\nout-tail")
        XCTAssertEqual(result.stderr, "err-one\nerr-tail")
        let events = await recorder.events
        XCTAssertTrue(events.contains(ProcessOutputEvent(stream: .stdout, line: "out-one")))
        XCTAssertTrue(events.contains(ProcessOutputEvent(stream: .stdout, line: "out-tail")))
        XCTAssertTrue(events.contains(ProcessOutputEvent(stream: .stderr, line: "err-one")))
        XCTAssertTrue(events.contains(ProcessOutputEvent(stream: .stderr, line: "err-tail")))
    }

    func testReturnsNonzeroExitCodeWithoutThrowing() async throws {
        let result = try await ProcessRunner.shared.run(
            "/bin/sh",
            ["-c", "printf problem >&2; exit 7"],
            timeout: 5,
            environment: [:])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stderr, "problem")
    }

    func testTimeoutThrowsTimedOut() async {
        do {
            _ = try await ProcessRunner.shared.run(
                "/bin/sleep",
                ["5"],
                timeout: 0.05,
                environment: [:])
            XCTFail("Expected timeout")
        } catch let error as ProcessError {
            guard case .timedOut = error else { return XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testCancellationStopsParentAndChildProcess() async throws {
        let recorder = EventRecorder()
        let task = Task {
            try await ProcessRunner.shared.run(
                "/bin/sh",
                ["-c", "sleep 30 & child=$!; printf \"$child\\n\"; wait"],
                timeout: 60,
                environment: [:]
            ) { event in
                await recorder.append(event)
            }
        }

        let childPID = try await waitForPID(recorder)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as ProcessError {
            guard case .cancelled = error else { return XCTFail("Wrong error: \(error)") }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1, "Child process should no longer exist")
    }

    private func waitForPID(_ recorder: EventRecorder) async throws -> pid_t {
        let deadline = Date.now.addingTimeInterval(2)
        while Date.now < deadline {
            if let line = await recorder.events.first(where: { $0.stream == .stdout })?.line,
               let pid = pid_t(line.trimmed) {
                return pid
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}

private actor EventRecorder {
    private(set) var events: [ProcessOutputEvent] = []
    func append(_ event: ProcessOutputEvent) { events.append(event) }
}
