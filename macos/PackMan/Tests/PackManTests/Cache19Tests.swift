import XCTest
@testable import PackMan

@MainActor
final class Cache19Tests: XCTestCase {
    func testClearRefreshesPreviewAndRequiresConfirmation() async throws {
        let inspector = StubCacheInspector()
        let model = AppViewModel(sources: [source(.npm)], settings: MemorySettings(), cacheInspector: inspector)
        model.startClearAllCaches()
        model.startCachePreview(); try await waitForOperation(model)
        var previewCalls = await inspector.previews
        XCTAssertEqual(previewCalls, 1)
        model.confirmCacheCleanup = { previews in
            XCTAssertEqual(previews.first?.bytes, 20)
            return false
        }
        model.startCachePreview(clearAfterConfirmation: true); try await waitForOperation(model)
        previewCalls = await inspector.previews
        var clears = await inspector.clears
        XCTAssertEqual(previewCalls, 2); XCTAssertEqual(clears, 0)
        model.confirmCacheCleanup = { _ in true }
        model.startCachePreview(clearAfterConfirmation: true); try await waitForOperation(model)
        previewCalls = await inspector.previews; clears = await inspector.clears
        XCTAssertEqual(previewCalls, 3); XCTAssertEqual(clears, 1)
    }

    func testSharedBrewCacheIsPreviewedAndClearedOnce() async throws {
        let inspector = StubCacheInspector()
        let model = AppViewModel(sources: [source(.homebrew), source(.homebrewCasks)], settings: MemorySettings(), cacheInspector: inspector)
        model.confirmCacheCleanup = { _ in true }
        model.startClearAllCaches(); model.startCachePreview(clearAfterConfirmation: true)
        try await waitForOperation(model)
        let previews = await inspector.previews, clears = await inspector.clears
        XCTAssertEqual(previews, 1); XCTAssertEqual(clears, 1)
        XCTAssertEqual(model.cacheResults.count, 2)
        XCTAssertTrue(model.cacheResults[.homebrewCasks]?.contains("Shared cleanup") == true)
    }

    func testSharedCleanupFailureRemainsFailureForBothSources() async throws {
        let inspector = StubCacheInspector(fail: true)
        let model = AppViewModel(sources: [source(.homebrew), source(.homebrewCasks)], settings: MemorySettings(), cacheInspector: inspector)
        model.confirmCacheCleanup = { _ in true }
        model.startClearAllCaches(); model.startCachePreview(clearAfterConfirmation: true)
        try await waitForOperation(model)
        XCTAssertTrue(model.cacheResults.values.allSatisfy { $0.contains("Failed") })
    }

    func testConfiguredNpmCachePathIsMeasuredInsteadOfDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 321).write(to: root.appendingPathComponent("cached"))
        let runner = StubProcessRunner()
        await runner.enqueue(arguments: ["config", "get", "cache"], stub: .init(result: ProcessResult(exitCode: 0, stdout: root.path + "\n", stderr: "")))
        let preview = try await CacheInspector(runner: runner).preview(source: NpmSource(), context: testToolContext, includeGlobalPackages: false)
        XCTAssertEqual(preview.paths, [root.path]); XCTAssertEqual(preview.bytes, 321)
    }

    func testAppStoreHasNoCleanupCapability() async throws {
        let preview = try await CacheInspector(runner: StubProcessRunner()).preview(source: MasSource(), context: testToolContext, includeGlobalPackages: false)
        XCTAssertFalse(preview.supported); XCTAssertNil(preview.bytes)
    }

    func testUnsupportedPipxDoesNotAttemptFallbackCleanup() async throws {
        let runner = StubProcessRunner()
        await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 2, stdout: "", stderr: "unsupported")))
        let preview = try await CacheInspector(runner: runner).preview(source: PipxSource(), context: testToolContext, includeGlobalPackages: false)
        XCTAssertFalse(preview.supported)
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 1)
    }

    func testNugetPreviewExcludesGlobalPackagesUntilOptedIn() async throws {
        let runner = StubProcessRunner()
        for _ in 0..<2 {
            await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 0,
                stdout: "http-cache: /tmp/absent-http\ntemp: /tmp/absent-nuget-temp\nglobal-packages: /tmp/absent-global\nplugins-cache: /tmp/absent-plugin\n", stderr: "")))
        }
        let inspector = CacheInspector(runner: runner)
        let defaultPreview = try await inspector.preview(source: DotnetSource(), context: testToolContext, includeGlobalPackages: false)
        let explicit = try await inspector.preview(source: DotnetSource(), context: testToolContext, includeGlobalPackages: true)
        XCTAssertEqual(defaultPreview.paths.count, 3); XCTAssertEqual(explicit.paths.count, 4)
        XCTAssertFalse(defaultPreview.paths.contains("/tmp/absent-global"))
    }

    private func source(_ id: SourceID) -> StubSource {
        StubSource(id: id, name: id.rawValue, probe: { .available(testToolContext) }, scan: { SourceScanReport() })
    }

    func testCleanupUsesThePreviewedManagerAndStreamsOutputForEverySource() async throws {
        let cases: [(SourceID, [[String]])] = [
            (.homebrew, [["cleanup"]]), (.homebrewCasks, [["cleanup"]]),
            (.npm, [["cache", "clean", "--force"]]), (.pip, [["-m", "pip", "cache", "purge"]]),
            (.pipx, [["cache", "purge"]]),
            (.dotnet, ["http-cache", "temp", "plugins-cache"].map { ["nuget", "locals", $0, "--clear"] })
        ]
        for (id, commands) in cases {
            let runner = StubProcessRunner()
            let output = CacheOutputRecorder()
            for command in commands {
                await runner.enqueue(arguments: command, stub: .init(result: ProcessResult(exitCode: 0, stdout: "Cleared", stderr: ""),
                    output: [.init(stream: .stdout, line: "Cleared")]))
            }
            let preview = CachePreview(sourceID: id, sourceName: id.rawValue, context: testToolContext, scope: "Test cache")
            try await CacheInspector(runner: runner).clear(preview, includeGlobalPackages: false) { await output.append($0) }
            let calls = await runner.invocations
            let events = await output.events
            XCTAssertEqual(calls.map(\.arguments), commands)
            XCTAssertTrue(calls.allSatisfy { $0.executable == testToolContext.executablePath })
            XCTAssertEqual(events.count, commands.count)
        }
    }

    func testNugetGlobalPackagesAreOnlyClearedWithExplicitOptIn() async throws {
        let runner = StubProcessRunner()
        for _ in 0..<4 { await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))) }
        let preview = CachePreview(sourceID: .dotnet, sourceName: ".NET", context: testToolContext, scope: "Test cache")
        try await CacheInspector(runner: runner).clear(preview, includeGlobalPackages: true) { _ in }
        let calls = await runner.invocations
        XCTAssertEqual(calls.last?.arguments, ["nuget", "locals", "global-packages", "--clear"])
        XCTAssertFalse(calls.contains { $0.arguments.contains("all") })
    }

    func testUnsupportedOrFailedPreviewsCannotStartCleanup() async throws {
        let runner = StubProcessRunner()
        for preview in [
            CachePreview(sourceID: .appStore, sourceName: "App Store", context: testToolContext, scope: "Managed", supported: false),
            CachePreview(sourceID: .pipx, sourceName: "pipx", context: testToolContext, scope: "Cache", issue: "Unsupported"),
            CachePreview(sourceID: .npm, sourceName: "npm", scope: "No manager")
        ] {
            do {
                try await CacheInspector(runner: runner).clear(preview, includeGlobalPackages: false) { _ in }
                XCTFail("An unavailable preview must not execute cleanup")
            } catch { }
        }
        let calls = await runner.invocations
        XCTAssertTrue(calls.isEmpty)
    }

    func testCleanupFailureStopsFurtherNugetCommands() async throws {
        let runner = StubProcessRunner()
        await runner.enqueueAny(stub: .init(result: ProcessResult(exitCode: 1, stdout: "", stderr: "Locked cache")))
        let preview = CachePreview(sourceID: .dotnet, sourceName: ".NET", context: testToolContext, scope: "Test cache")
        do {
            try await CacheInspector(runner: runner).clear(preview, includeGlobalPackages: true) { _ in }
            XCTFail("Cleanup failure must be reported")
        } catch { XCTAssertTrue(error.userMessage.contains("Locked cache")) }
        let calls = await runner.invocations
        XCTAssertEqual(calls.count, 1)
    }
}

private actor CacheOutputRecorder {
    var events: [ProcessOutputEvent] = []
    func append(_ event: ProcessOutputEvent) { events.append(event) }
}

private actor StubCacheInspector: CacheInspecting {
    let fail: Bool
    var previews = 0
    var clears = 0
    init(fail: Bool = false) { self.fail = fail }
    func preview(source: any PackageSource, context: ToolContext, includeGlobalPackages: Bool) async throws -> CachePreview {
        previews += 1
        return CachePreview(sourceID: source.id, sourceName: source.name, context: context, bytes: Int64(previews * 10), scope: "Test cache")
    }
    func clear(_ preview: CachePreview, includeGlobalPackages: Bool, onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void) async throws {
        clears += 1
        if fail { throw SourceError.commandFailed("Synthetic cleanup failure") }
        await onOutput(.init(stream: .stdout, line: "Cleared test cache"))
    }
}
