import XCTest
@testable import PackMan

final class Lifecycle19Tests: XCTestCase {
    func testTimeoutBoundsPipesAfterParentExitsAndChildIgnoresTermination() async throws {
        let started = Date.now
        do {
            _ = try await ProcessRunner.shared.run("/bin/sh", ["-c", "(trap '' TERM; sleep 20) & exit 0"], timeout: 0.1)
            XCTFail("Expected timeout while inherited pipe remains open")
        } catch let error as ProcessError {
            guard case .timedOut = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 3)
    }

    func testCancellationBeforeLaunchDoesNotExecuteCommand() async throws {
        let task = Task {
            try Task.checkCancellation()
            return try await ProcessRunner.shared.run("/bin/sleep", ["10"], timeout: 15)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? ProcessError)?.isCancellation == true) }
    }

    func testOutputCaptureLimitStopsUnboundedCommand() async throws {
        do {
            _ = try await ProcessRunner.shared.run("/usr/bin/yes", ["test"], timeout: 10)
            XCTFail("Expected output limit")
        } catch let error as ProcessError {
            guard case .outputLimit = error else { return XCTFail("Expected output limit, got \(error)") }
        }
    }

    func testActualHelperSwapsRenamedBundleWithSpacesFromBothPriorVersions() async throws {
        for previous in ["1.8.2", "1.9.0"] {
            let fixture = try fixture(previous: previous)
            let result = try await runHelper(fixture)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            XCTAssertEqual(UpdateApplier.shortVersion(of: fixture.target)?.displayString, "1.9.1")
            XCTAssertTrue(try String(contentsOf: fixture.log).contains("completed successfully"))
        }
    }

    func testActualHelperAbortsWhenParentRemainsAlive() async throws {
        let fixture = try fixture(previous: "1.8.2")
        let result = try await runHelper(fixture, parent: String(ProcessInfo.processInfo.processIdentifier), wait: "0")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(UpdateApplier.shortVersion(of: fixture.target)?.displayString, "1.8.2")
        XCTAssertTrue(try String(contentsOf: fixture.log).contains("replacement aborted"))
    }

    func testActualHelperPreservesOldBundleIfStagedSignatureIsInvalid() async throws {
        let fixture = try fixture(previous: "1.8.2")
        try Data("invalid".utf8).write(to: fixture.staged.appendingPathComponent("Contents/MacOS/PackMan"))
        let result = try await runHelper(fixture)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(UpdateApplier.shortVersion(of: fixture.target)?.displayString, "1.8.2")
    }

    func testActualHelperRollsBackFailedSwap() async throws {
        let fixture = try fixture(previous: "1.9.0")
        // Inject only the failing filesystem primitive. The production transaction,
        // trap, backup, and recovery commands are executed unchanged.
        let move = fixture.root.appendingPathComponent("move")
        try "#!/bin/bash\ncase \"$1\" in *.new-*) exit 1 ;; esac\nexec /bin/mv \"$@\"\n".write(to: move, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: move.path)
        let result = try await runHelper(fixture, move: move.path)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(UpdateApplier.shortVersion(of: fixture.target)?.displayString, "1.9.0")
        XCTAssertTrue(try String(contentsOf: fixture.log).contains("Previous PackMan restored"))
    }

    func testActualHelperRetainsManualRestartNoticeIfOpenFails() async throws {
        let fixture = try fixture(previous: "1.8.2")
        let result = try await runHelper(fixture, relaunch: "1", opener: "/usr/bin/false")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(UpdateApplier.shortVersion(of: fixture.target)?.displayString, "1.9.1")
        XCTAssertTrue(try String(contentsOf: fixture.log).contains("Reopen PackMan manually"))
    }

    func testBundleValidationRejectsWrongIdentity() async throws {
        let fixture = try fixture(previous: "1.9.0")
        let path = fixture.staged.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as! [String: String]
        info["CFBundleIdentifier"] = "other.app"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path)
        do { try await UpdateApplier.validateBundle(fixture.staged); XCTFail("Expected wrong identity rejection") }
        catch { XCTAssertEqual(error as? AppUpdateError, .missingApplication) }
    }

    private struct Fixture {
        let root: URL; let staging: URL; let staged: URL; let target: URL; let script: URL; let log: URL
    }
    private func fixture(previous: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackMan helper test \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let staged = try makeSignedTestApp(at: staging.appendingPathComponent("PackMan.app"), version: "1.9.1")
        let target = try makeSignedTestApp(at: root.appendingPathComponent("My Renamed App.app"), version: previous)
        let script = root.appendingPathComponent("apply.sh")
        try UpdateApplier.helperScript.write(to: script, atomically: true, encoding: .utf8)
        return Fixture(root: root, staging: staging, staged: staged, target: target, script: script, log: root.appendingPathComponent("result.log"))
    }
    private func runHelper(_ fixture: Fixture, parent: String = "2147483647", wait: String = "2", relaunch: String = "0",
                           move: String = "/bin/mv", opener: String = "/usr/bin/open") async throws -> ProcessResult {
        try await ProcessRunner.shared.run("/bin/bash", [fixture.script.path, parent, fixture.staged.path, fixture.target.path,
            fixture.staging.path, fixture.log.path, wait, relaunch, move, opener], timeout: 15)
    }
}
