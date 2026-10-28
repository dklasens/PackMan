import XCTest
@testable import PackMan

@MainActor
final class Reliability110Tests: XCTestCase {
    func testHistoryRetryHonoursAmbiguousIdentity() async throws {
        let recorder = ReviewRecorder()
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) },
            scan: { SourceScanReport(updates: [
                PackageInfo(id: "example", name: "Example", currentVersion: "1", availableVersion: "2"),
                PackageInfo(id: "example", name: "Example", currentVersion: "1", availableVersion: "2")]) },
            update: { request in await recorder.record(request.targetVersion) })
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        model.startScan(); try await waitForOperation(model)
        XCTAssertFalse(try XCTUnwrap(model.packages.first).isActionable)
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: .npm, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", outcome: .failed, toolPath: testToolContext.executablePath)
        model.recoverHistory(entry, verifyOnly: false); try await waitForOperation(model)
        let recorded = await recorder.values
        XCTAssertTrue(recorded.isEmpty, "History retry must honour the same identity guard as the main update action. Actual targets: \(recorded)")
    }

    func testHistoryRetryDoesNotSwitchPythonEnvironment() async throws {
        let source = ReviewContextSource()
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: .pip, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", outcome: .failed, toolPath: "/old-environment/bin/python3")
        model.recoverHistory(entry, verifyOnly: false); try await waitForOperation(model)
        let paths = await source.paths
        XCTAssertFalse(paths.contains("/different-environment/bin/python3"),
            "Recovery must not silently execute in another Python environment. Actual paths: \(paths)")
    }

    func testNpmVersionRefreshesAfterNpmUpdatesWithinBatch() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(arguments: ["--version"], stub: .init(result: ProcessResult(exitCode: 0, stdout: "11.0.0", stderr: "")))
        await runner.enqueue(arguments: ["--version"], stub: .init(result: ProcessResult(exitCode: 0, stdout: "11.0.0", stderr: "")))
        await runner.enqueue(arguments: ["--version"], stub: .init(result: ProcessResult(exitCode: 0, stdout: "12.0.0", stderr: "")))
        await runner.enqueue(arguments: ["--version"], stub: .init(result: ProcessResult(exitCode: 0, stdout: "12.0.0", stderr: "")))
        await runner.enqueue(arguments: ["outdated", "-g", "--json"], stub: .init(result: ProcessResult(exitCode: 0,
            stdout: #"{"npm":{"current":"11.0.0","latest":"12.0.0"},"wrangler":{"current":"1.0.0","latest":"2.0.0"}}"#, stderr: "")))
        for args in [["install", "-g", "npm@12.0.0"], ["install", "-g", "wrangler@2.0.0"],
                     ["install", "-g", "--allow-scripts=wrangler", "wrangler@2.0.0"]] {
            await runner.enqueue(arguments: args, stub: .init(result: ProcessResult(exitCode: 0, stdout: "installed", stderr: "")))
        }
        await runner.enqueue(arguments: ["list", "-g", "--depth=0", "--json"], stub: .init(result: ProcessResult(exitCode: 0,
            stdout: #"{"dependencies":{"npm":{"version":"12.0.0"},"wrangler":{"version":"2.0.0"}}}"#, stderr: "")))
        let source = NpmSource(runner: runner, resolver: StubResolver(resolution: .resolved(
            ResolvedExecutable(path: "/test/npm", pathEntries: ["/test"], origin: .knownPath))))
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        model.startScan(); try await waitForOperation(model)
        model.startUpdateSelected(); try await waitForOperation(model)
        let calls = await runner.invocations
        let install = try XCTUnwrap(calls.first { $0.arguments.contains("wrangler@2.0.0") })
        XCTAssertTrue(install.arguments.contains("--allow-scripts=wrangler"),
            "The second installation now runs under npm 12. Actual arguments: \(install.arguments)")
    }

    func testIgnoredOnlyScanExplainsHiddenUpdate() async throws {
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) },
            scan: { SourceScanReport(updates: [PackageInfo(id: "example", name: "Example", currentVersion: "1", availableVersion: "2")]) })
        let model = AppViewModel(sources: [source], settings: MemorySettings(ignored: ["npm:example"]))
        model.startScan(); try await waitForOperation(model)
        XCTAssertEqual(model.ignoredCount, 1)
        XCTAssertTrue(model.statusText.contains("ignored"), "Actual status: \(model.statusText)")
    }

    func testHistoryRecoveryAlsoBlocksVerificationInDifferentEnvironment() async throws {
        let source = ReviewContextSource()
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: .pip, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", outcome: .failed, toolPath: "/old-environment/bin/python3")
        model.recoverHistory(entry, verifyOnly: true); try await waitForOperation(model)
        let paths = await source.paths
        let verified = await source.verifiedPaths
        XCTAssertTrue(paths.isEmpty); XCTAssertTrue(verified.isEmpty)
        XCTAssertTrue(model.history.first?.evidence.contains("environment changed") == true)
        XCTAssertEqual(model.history.first?.toolPath, entry.toolPath)
    }

    func testExistingScanRowCannotReplaceHistoryEnvironment() async throws {
        let source = ReviewContextSource()
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        model.startScan(); try await waitForOperation(model)
        let row = try XCTUnwrap(model.packages.first)
        let originalContext = row.toolContext
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: .pip, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", outcome: .failed, toolPath: "/old-environment/bin/python3")
        model.recoverHistory(entry, verifyOnly: false); try await waitForOperation(model)
        XCTAssertEqual(row.toolContext, originalContext)
        let paths = await source.paths
        XCTAssertTrue(paths.isEmpty)
        XCTAssertTrue(model.logEntries.contains { $0.message.contains("different manager environment") })
    }

    func testLegacyHistoryWithMatchingExecutableStillRecovers() async throws {
        let source = ReviewContextSource()
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        let original = UpdateHistoryEntry(runID: UUID(), sourceID: .pip, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", outcome: .failed, toolPath: "/different-environment/bin/python3")
        let encoded = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("toolContext"))
        let entry = try JSONDecoder().decode(UpdateHistoryEntry.self, from: encoded)
        model.recoverHistory(entry, verifyOnly: false); try await waitForOperation(model)
        let paths = await source.paths
        XCTAssertEqual(paths, [entry.toolPath])
        XCTAssertEqual(model.history.first?.outcome, .updated)
        XCTAssertEqual(model.history.first?.toolContext?.executablePath, entry.toolPath)
    }

    func testEnvironmentIdentityIgnoresVersionButRetainsRuntimePaths() {
        let original = ToolContext(executablePath: "/venv/bin/python3", version: "1", pathEntries: ["/venv/bin"], origin: .explicit)
        XCTAssertTrue(original.matchesEnvironment(ToolContext(executablePath: "/venv/bin/./python3", version: "2", pathEntries: ["/venv/bin"], origin: .knownPath)))
        XCTAssertFalse(original.matchesEnvironment(ToolContext(executablePath: original.executablePath, version: "2", pathEntries: ["/other/bin"], origin: .explicit)))
        XCTAssertFalse(original.matchesEnvironment(ToolContext(executablePath: "/other/bin/python3", version: "1", pathEntries: original.pathEntries, origin: .explicit)))
    }

    func testRuntimePathChangeStopsHistoryRetry() async throws {
        let source = ReviewContextSource()
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        let context = ToolContext(executablePath: "/different-environment/bin/python3", version: "old", pathEntries: ["/original-runtime"], origin: .explicit)
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: .pip, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", outcome: .failed, toolPath: context.executablePath, toolContext: context)
        model.recoverHistory(entry, verifyOnly: false); try await waitForOperation(model)
        let paths = await source.paths
        XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(model.history.first?.outcome, .failed)
    }

    func testNewHistoryContextIsRedactedInDiagnosticExport() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let context = ToolContext(executablePath: home + "/bin/npm", version: "12", pathEntries: [home + "/bin"], origin: .explicit)
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: .npm, packageID: "example", name: "Example",
            beforeVersion: "1", targetVersion: "2", toolPath: context.executablePath, toolContext: context)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(UpdateHistoryEntry.self, from: data).toolContext, context)
        let exported = try DiagnosticRedactor.export(history: [entry], log: [])
        XCTAssertFalse(exported.contains(home))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        let records = try XCTUnwrap(object["history"] as? [[String: Any]])
        let savedContext = try XCTUnwrap(records.first?["toolContext"] as? [String: Any])
        XCTAssertEqual(savedContext["pathEntries"] as? [String], ["~/bin"])
    }

    func testManualAndSkippedOnlyScansExplainCoverage() async throws {
        let manual = StubSource(id: .appStore, name: "App Store", probe: { .available(testToolContext) }, scan: {
            SourceScanReport(updates: [PackageInfo(id: "123", name: "Manual", currentVersion: "1", availableVersion: "2")])
        })
        let skipped = StubSource(id: .homebrew, name: "Homebrew", probe: { .available(testToolContext) }, scan: { SourceScanReport(skippedCount: 3) })
        for sources in [[manual], [skipped], [manual, skipped]] {
            let model = AppViewModel(sources: sources, settings: MemorySettings())
            model.startScan(); try await waitForOperation(model)
            guard case .noAutomaticUpdates = model.scanSummary else { return XCTFail("Coverage must not become all-clear") }
            XCTAssertFalse(model.statusText.contains("0 Updates Available"))
            if model.manualCount > 0 { XCTAssertTrue(model.statusText.contains("manual")) }
            if model.skippedCount > 0 { XCTAssertTrue(model.statusText.contains("skipped")) }
        }
    }

    func testScanIssuesTakePrecedenceOverIgnoredOnlySummary() async throws {
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) }, scan: {
            SourceScanReport(updates: [PackageInfo(id: "example", name: "Example", currentVersion: "1", availableVersion: "2")],
                issues: [SourceIssue(kind: .network, message: "Incomplete lookup")])
        })
        let model = AppViewModel(sources: [source], settings: MemorySettings(ignored: ["npm:example"]))
        model.startScan(); try await waitForOperation(model)
        guard case .completedWithIssues = model.scanSummary else { return XCTFail("Do not hide scan issues") }
    }

}

private actor ReviewRecorder {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private actor ReviewContextSource: PackageSource {
    nonisolated let descriptor = SourceDescriptor(id: .pip, name: "pip", toolID: .python,
        executableName: "python3", knownPaths: [], installationURL: nil)
    var paths: [String] = []
    var verifiedPaths: [String] = []
    func probe() async -> SourceProbe {
        .available(ToolContext(executablePath: "/different-environment/bin/python3", version: "1.0", pathEntries: ["/different-environment/bin"], origin: .knownPath))
    }
    func scan(context: ToolContext, progress: @escaping @Sendable (SourcePhase) async -> Void) async throws -> SourceScanReport { SourceScanReport(updates: [PackageInfo(id: "example", name: "Example", currentVersion: "1", availableVersion: "2")]) }
    func update(request: UpdateRequest, context: ToolContext, onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void) async throws {
        paths.append(context.executablePath)
    }
    func verify(requests: [UpdateRequest], context: ToolContext) async throws -> [String: UpdateVerification] {
        verifiedPaths.append(context.executablePath)
        return Dictionary(uniqueKeysWithValues: requests.map { ($0.packageID, .satisfied(installedVersion: $0.targetVersion)) })
    }
}
