import Darwin
import XCTest
@testable import PackMan

@MainActor
final class Release19Tests: XCTestCase {
    func testSearchDoesNotChangeScanTruth() async throws {
        let model = model()
        model.searchText = "nothing matches"
        model.startScan(); try await waitForOperation(model)
        XCTAssertEqual(model.updateCount, 1)
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertEqual(model.totalSelectedCount, 1)
        if case .upToDate = model.scanSummary { XCTFail("Search must not change scan truth") }
    }

    func testIgnoringLastUpdatePreservesDetectedCountAndScanDate() async throws {
        let model = model()
        model.startScan(); try await waitForOperation(model)
        let date = model.lastScanDate
        model.ignore(try XCTUnwrap(model.packages.first), versionOnly: true)
        XCTAssertEqual(model.ignoredCount, 1); XCTAssertEqual(model.detectedCount, 1)
        XCTAssertEqual(model.lastScanDate, date)
        if case .upToDate = model.scanSummary { XCTFail("Ignored update must not become all-clear") }
    }

    func testAppStoreRowsAreManualAndNotSelected() {
        let row = PackageUpdate(info: PackageInfo(id: "123", name: "App", currentVersion: "1", availableVersion: "2"), source: MasSource(), context: testToolContext)
        XCTAssertFalse(row.isActionable); XCTAssertFalse(row.isSelected); XCTAssertEqual(row.status, .manual)
    }

    func testScanWarningDoesNotSkipInstallation() async throws {
        let counter = ReleaseCounter()
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) }, scan: {
            SourceScanReport(updates: [PackageInfo(id: "tool", name: "Tool", currentVersion: "1", availableVersion: "2", statusMessage: "Warning")])
        }, update: { _ in await counter.increment() })
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        model.startScan(); try await waitForOperation(model)
        model.startUpdateSelected(); try await waitForOperation(model)
        let count = await counter.value
        XCTAssertEqual(count, 1); XCTAssertEqual(model.history.first?.outcome, .updated)
    }

    func testExplicitVerifyDoesNotInstallAndRecordsObservedNewerVersion() async throws {
        let counter = ReleaseCounter()
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) }, scan: { Self.report },
            update: { _ in await counter.increment() }, verify: { _ in ["tool": .satisfied(installedVersion: "3")] })
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        model.startScan(); try await waitForOperation(model)
        model.startVerify(try XCTUnwrap(model.packages.first)); try await waitForOperation(model)
        let count = await counter.value
        XCTAssertEqual(count, 0); XCTAssertEqual(model.updateSummary?.updated, 0)
        XCTAssertEqual(model.updateSummary?.verified, 1); XCTAssertEqual(model.history.first?.outcome, .verified)
        XCTAssertEqual(model.history.first?.installedVersion, "3")
    }

    func testFailureToPersistQueuePreventsInstallation() async throws {
        let counter = ReleaseCounter()
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) }, scan: { Self.report }, update: { _ in await counter.increment() })
        let model = AppViewModel(sources: [source], settings: MemorySettings(), historyStore: RejectingHistory())
        model.startScan(); try await waitForOperation(model)
        model.startUpdateSelected(); try await waitForOperation(model)
        let count = await counter.value
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.logEntries.contains { $0.message.contains("Could not save update history") })
    }

    func testCancellationAccountsForPackagesNotStartedAndWaits() async throws {
        let counter = ReleaseCounter()
        let source = StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) }, scan: {
            SourceScanReport(updates: [PackageInfo(id: "one", name: "One", currentVersion: "1", availableVersion: "2"),
                PackageInfo(id: "two", name: "Two", currentVersion: "1", availableVersion: "2")])
        }, update: { _ in await counter.increment(); try await Task.sleep(for: .seconds(10)) })
        let model = AppViewModel(sources: [source], settings: MemorySettings())
        model.startScan(); try await waitForOperation(model)
        model.startUpdateSelected()
        while await counter.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await model.cancelAndWait()
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.updateSummary?.cancelled, 1); XCTAssertEqual(model.updateSummary?.notStarted, 1)
        XCTAssertEqual(Set(model.history.map(\.outcome)), [.cancelled, .notStarted])
    }

    func testUnknownDotnetOutputIsAnIssue() {
        XCTAssertFalse(DotnetToolListParser.parse("Unrecognised inventory format").issues.isEmpty)
        XCTAssertTrue(DotnetToolListParser.parse("Package Id Version Commands\n---------------------------\n").issues.isEmpty)
    }

    func testPipVerificationUsesInstalledInventoryAndNormalizesNames() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(arguments: ["-m", "pip", "list", "--format", "json", "--disable-pip-version-check"], stub: .init(result:
            ProcessResult(exitCode: 0, stdout: #"[{"name":"Some_Tool","version":"2.1"}]"#, stderr: "")))
        let result = try await PipSource(runner: runner).verify(requests: [request("some-tool"), request("missing")], context: testToolContext)
        XCTAssertEqual(result["some-tool"]?.installedVersion, "2.1")
        guard case .missing = result["missing"] else { return XCTFail("Missing inventory must remain missing") }
    }

    func testNpmMissingRecordDoesNotDiscardOtherVerification() async throws {
        let runner = StubProcessRunner()
        await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 1, stdout: #"{"dependencies":{"tool":{"version":"2"}}}"#, stderr: "missing dependency")))
        let result = try await NpmSource(runner: runner).verify(requests: [request("tool"), request("missing")], context: testToolContext)
        guard case .satisfied = result["tool"], case .missing = result["missing"] else { return XCTFail("Expected independent results") }
    }

    func testBrewVerificationRetainsTapAndNewestInstalledKeg() async throws {
        let runner = StubProcessRunner()
        await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 0,
            stdout: #"{"formulae":[{"name":"tool","full_name":"owner/tap/tool","installed":[{"version":"1"},{"version":"3"}]}]}"#, stderr: "")))
        let result = try await BrewSource(kind: .formula, runner: runner).verify(requests: [request("owner/tap/tool"), request("tool")], context: testToolContext)
        XCTAssertEqual(result["owner/tap/tool"]?.installedVersion, "3")
        guard case .missing = result["tool"] else { return XCTFail("Do not drop tap identity") }
    }

    func testPipxInventoryPreservesDistinctEnvironments() throws {
        let entries = try PipxSource.installedEntries(#"{"venvs":{"tool":{"metadata":{"main_package":{"package_version":"1"}}},"tool-next":{"metadata":{"main_package":{"package_version":"3"}}}}}"#)
        let result = InstalledInventory.verify([request("tool"), request("tool-next")], entries: entries)
        XCTAssertEqual(result["tool"]?.installedVersion, "1"); XCTAssertEqual(result["tool-next"]?.installedVersion, "3")
    }

    func testAmbiguousAndUnknownVersionsRemainInconclusive() {
        let duplicate = InstalledInventory.verify([request("tool")], entries: [.init(id: "tool", version: "1"), .init(id: "tool", version: "3")])
        let unknown = InstalledInventory.verify([request("tool")], entries: [.init(id: "tool", version: "latest")])
        guard case .inconclusive = duplicate["tool"], case .inconclusive = unknown["tool"] else { return XCTFail("Expected uncertainty") }
    }

    func testHistorySurvivesRestartAndMarksInterruptedQueue() throws {
        let directory = try tempDirectory()
        let url = directory.appendingPathComponent("history.json")
        let store = UpdateHistoryStore(url: url)
        var running = entry(); running.outcome = .running
        var queued = entry(); queued.outcome = .queued
        try store.save([running, queued])
        let restored = UpdateHistoryStore(url: url).read()
        XCTAssertEqual(Set(restored.map(\.outcome)), [.interrupted, .notStarted])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHistoryRetentionOutputLimitAndCorruptBackup() throws {
        let directory = try tempDirectory(), url = directory.appendingPathComponent("history.json")
        try Data("corrupted".utf8).write(to: url)
        let store = UpdateHistoryStore(url: url)
        XCTAssertNotNil(store.loadIssue)
        var entries = (0..<505).map { _ in entry() }
        entries[0].output = String(repeating: "x", count: 100_000)
        try store.save(entries)
        XCTAssertEqual(store.read().count, 500)
        XCTAssertTrue(store.read().allSatisfy { $0.output.utf8.count < 66_000 })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("unreadable") })
    }

    func testDiagnosticRedactionCoversFieldsAndMultilineSecrets() throws {
        var attempt = entry()
        attempt.name = "token=abc123"
        attempt.toolPath = FileManager.default.homeDirectoryForCurrentUser.path + "/private/tool"
        attempt.evidence = "Authorization: Bearer credential\nhttps://user:pass@example.com/?access_token=secret"
        attempt.output = "password=hidden\n-----BEGIN PRIVATE KEY-----\nkeydata\n-----END PRIVATE KEY-----"
        let text = try DiagnosticRedactor.export(history: [attempt], log: [])
        for secret in ["abc123", "credential", "user:pass", "=secret", "hidden", "keydata", FileManager.default.homeDirectoryForCurrentUser.path] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testMetadataRejectsExecutableAndCredentialLinks() {
        XCTAssertNil(PackageMetadataService.safeURL("javascript:alert(1)"))
        XCTAssertNil(PackageMetadataService.safeURL("file:///tmp/tool"))
        XCTAssertNil(PackageMetadataService.safeURL("https://user:secret@example.com"))
        XCTAssertNotNil(PackageMetadataService.safeURL("https://example.com/releases"))
    }

    func testToolReplacementInvalidatesCachedVersion() throws {
        let directory = try tempDirectory(), path = directory.appendingPathComponent("npm")
        try Data("#!/bin/sh\necho 11".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let settings = SettingsStore(settingsURL: directory.appendingPathComponent("settings.json"))
        let context = ToolContext(executablePath: path.path, version: "11", pathEntries: [], origin: .explicit)
        try settings.setCachedContext(context, for: .npm)
        XCTAssertNotNil(settings.cachedContext(for: .npm))
        try Data("#!/bin/sh\necho 12.0.0".utf8).write(to: path)
        XCTAssertNil(settings.cachedContext(for: .npm))
    }

    func testSetupMigrationPreservesExistingChoices() throws {
        let directory = try tempDirectory(), url = directory.appendingPathComponent("settings.json")
        let fresh = SettingsStore(settingsURL: url)
        XCTAssertFalse(fresh.hasCompletedSourceSetup())
        try Data(#"{"version":4,"disabledSources":["pip"],"executableOverrides":{}}"#.utf8).write(to: url)
        let existing = SettingsStore(settingsURL: url)
        XCTAssertTrue(existing.hasCompletedSourceSetup()); XCTAssertFalse(existing.isSourceEnabled(.pip))
        try existing.setIncludesSelfUpdatingCasks(true)
        XCTAssertTrue(SettingsStore(settingsURL: url).includesSelfUpdatingCasks())
    }

    func testSharedHomebrewSnapshotExecutesOncePerScan() async throws {
        let runner = StubProcessRunner(), inventory = BrewInventory()
        await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 0, stdout: "{}", stderr: ""), delayNanoseconds: 20_000_000))
        async let one = inventory.outdated(context: testToolContext, runner: runner, greedy: false)
        async let two = inventory.outdated(context: testToolContext, runner: runner, greedy: false)
        _ = try await (one, two)
        var count = await runner.invocations.count
        XCTAssertEqual(count, 1)
        await inventory.beginScan()
        await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 0, stdout: "{}", stderr: "")))
        _ = try await inventory.outdated(context: testToolContext, runner: runner, greedy: false)
        count = await runner.invocations.count
        XCTAssertEqual(count, 2)
    }

    func testPipxCapabilitiesAreReusedUntilToolVersionChanges() async throws {
        let runner = StubProcessRunner()
        let source = PipxSource(runner: runner)
        for _ in 0..<2 {
            await runner.enqueue(arguments: ["list", "--help"], stub: .init(result: ProcessResult(exitCode: 0, stdout: "--outdated --output", stderr: "")))
        }
        for _ in 0..<3 {
            await runner.enqueue(arguments: ["list", "--outdated", "--output", "json"], stub: .init(result: ProcessResult(exitCode: 0, stdout: #"{"status":"success","exit_code":0,"data":{"packages_checked":0,"packages":[],"skipped":[]},"errors":[]}"#, stderr: "")))
        }
        _ = try await source.scan(context: testToolContext) { _ in }
        _ = try await source.scan(context: testToolContext) { _ in }
        let changed = ToolContext(executablePath: testToolContext.executablePath, version: "new", pathEntries: testToolContext.pathEntries, origin: .explicit)
        _ = try await source.scan(context: changed) { _ in }
        let calls = await runner.invocations
        XCTAssertEqual(calls.filter { $0.arguments == ["list", "--help"] }.count, 2)
    }

    func testInaccessibleCacheIsPartialRatherThanEmpty() async throws {
        let root = try tempDirectory(), hidden = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        let result = try await CacheInspector.measure([hidden.appendingPathComponent("cache").path])
        XCTAssertFalse(result.complete)
    }

    func testCacheMeasurementDeduplicatesNestedPathsAndSkipsSymlinks() async throws {
        let directory = try tempDirectory(), nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 123).write(to: nested.appendingPathComponent("cache"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: nested)
        let measured = try await CacheInspector.measure([directory.path, nested.path])
        XCTAssertEqual(measured.bytes, 123); XCTAssertTrue(measured.complete)
    }

    func testNugetGlobalPackageRemovalRequiresExplicitOption() async throws {
        let runner = StubProcessRunner(), inspector = CacheInspector(runner: StubProcessRunner())
        _ = inspector
        let preview = CachePreview(sourceID: .dotnet, sourceName: ".NET", context: testToolContext, scope: "")
        for _ in 0..<3 { await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))) }
        try await CacheInspector(runner: runner).clear(preview, includeGlobalPackages: false) { _ in }
        let calls = await runner.invocations
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls.contains { $0.arguments.contains("all") || $0.arguments.contains("global-packages") })
    }

    private nonisolated static var report: SourceScanReport {
        SourceScanReport(updates: [PackageInfo(id: "tool", name: "Tool", currentVersion: "1", availableVersion: "2")])
    }
    private func model() -> AppViewModel {
        AppViewModel(sources: [StubSource(id: .npm, name: "npm", probe: { .available(testToolContext) }, scan: { Self.report })], settings: MemorySettings())
    }
    private func request(_ id: String) -> UpdateRequest { UpdateRequest(packageID: id, name: id, targetVersion: "2") }
    private func entry() -> UpdateHistoryEntry {
        UpdateHistoryEntry(runID: UUID(), sourceID: .npm, packageID: "tool", name: "Tool", beforeVersion: "1", targetVersion: "2", toolPath: "/test/npm")
    }
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PackMan-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor ReleaseCounter {
    var value = 0
    func increment() { value += 1 }
}
private struct RejectingHistory: UpdateHistoryStoring {
    var loadIssue: String? { nil }
    func read() -> [UpdateHistoryEntry] { [] }
    func save(_ entries: [UpdateHistoryEntry]) throws { throw CocoaError(.fileWriteNoPermission) }
}
