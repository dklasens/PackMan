import XCTest
@testable import PackMan

final class SourceParsingTests: XCTestCase {
    func testBrewFixtureDecodesFormulaeAndCasks() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(BrewOutdated.self, from: fixtureData("brew-outdated"))
        XCTAssertEqual(result.formulae.count, 2)
        XCTAssertEqual(result.formulae[0].installedVersions, ["14.1.0"])
        XCTAssertEqual(result.casks.first?.currentVersion, "1.100.0")
    }

    func testMasParserAcceptsValidLineAndRejectsMalformedLine() {
        let parsed = MasOutdatedParser.parse("497799835 Xcode (16.4 -> 16.5)")
        XCTAssertEqual(parsed?.id, "497799835")
        XCTAssertEqual(parsed?.name, "Xcode")
        XCTAssertEqual(parsed?.availableVersion, "16.5")
        XCTAssertNil(MasOutdatedParser.parse("not a mas record"))
    }

    func testMasParserAcceptsColumnAlignedTabularLine() {
        let parsed = MasOutdatedParser.parseLine("6445813049  Spark Desktop  (3.30.4 -> 3.30.5)")
        XCTAssertEqual(parsed?.id, "6445813049")
        XCTAssertEqual(parsed?.name, "Spark Desktop")
        XCTAssertEqual(parsed?.currentVersion, "3.30.4")
        XCTAssertEqual(parsed?.availableVersion, "3.30.5")
    }

    func testMasParserAcceptsJsonLineFromRawMasBinary() {
        let line = #"{"adamID":6445813049,"bundleID":"com.readdle.SparkDesktop.appstore","fileSystemSize":877424036,"name":"Spark Desktop","newVersion":"3.30.5","path":"/Applications/Spark Desktop.app","version":"3.30.4"}"#
        let parsed = MasOutdatedParser.parseLine(line)
        XCTAssertEqual(parsed?.id, "6445813049")
        XCTAssertEqual(parsed?.name, "Spark Desktop")
        XCTAssertEqual(parsed?.currentVersion, "3.30.4")
        XCTAssertEqual(parsed?.availableVersion, "3.30.5")
    }

    func testMasParserRejectsJsonLineWithInvalidNewVersion() {
        let line = #"{"adamID":123,"name":"App","newVersion":"","version":"1.0"}"#
        XCTAssertNil(MasOutdatedParser.parseLine(line))
    }

    func testMasVersionGateRejectsLegacyMas() {
        XCTAssertNotNil(MasVersionGate.issueIfUnsupported("1.8.7"))
        XCTAssertNil(MasVersionGate.issueIfUnsupported("4.1.2"))
        XCTAssertNil(MasVersionGate.issueIfUnsupported("7.0.0"))
        XCTAssertNil(MasVersionGate.issueIfUnsupported("built from source"))
    }

    func testMasProbeRejectsLegacyVersion() async {
        let runner = StubProcessRunner()
        await runner.enqueueAny(
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "1.8.7\n", stderr: "")))
        let source = MasSource(
            runner: runner,
            resolver: StubResolver(resolution: .resolved(ResolvedExecutable(
                path: "/test/mas",
                pathEntries: ["/test"],
                origin: .knownPath))))
        let probe = await source.probe()
        guard case .unavailable(let issue) = probe else {
            return XCTFail("Expected legacy mas to be unavailable")
        }
        XCTAssertTrue(issue.message.contains("too old"))
        XCTAssertEqual(issue.recovery, "Run `brew upgrade mas` in Terminal, then retry.")
    }

    func testMasScanRejectsLegacyVersionFromCachedContext() async {
        let source = MasSource(runner: StubProcessRunner(), resolver: StubResolver(resolution: .notFound))
        let context = masToolContext(executablePath: "/test/mas", version: "1.8.7")
        do {
            _ = try await source.scan(context: context) { _ in }
            XCTFail("Expected scan to refuse legacy mas")
        } catch let error as SourceError {
            XCTAssertTrue(error.errorDescription?.contains("too old") == true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMasScanSurfacesSpotlightIndexingWarnings() async throws {
        let runner = StubProcessRunner()
        let stderr = """
        Warning: Found a likely App Store app that is not indexed in Spotlight in /Applications/Speedtest.app

                 Indexing now; will likely complete sometime after mas exits

                 Disable auto-indexing via: export MAS_NO_AUTO_INDEX=1
        Warning: Found a likely App Store app that is not indexed in Spotlight in /Applications/Bitwarden.app
        """
        await runner.enqueue(
            arguments: ["outdated"],
            stub: .init(result: ProcessResult(
                exitCode: 0,
                stdout: "6445813049  Spark Desktop  (3.30.4 -> 3.30.5)\n",
                stderr: stderr)))
        let source = MasSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        let report = try await source.scan(context: masToolContext(executablePath: "/test/mas")) { _ in }
        XCTAssertEqual(report.updates.count, 1)
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertTrue(issue.message.contains("2 App Store app(s)"))
        XCTAssertTrue(issue.message.contains("Speedtest.app"))
        XCTAssertTrue(issue.message.contains("Bitwarden.app"))
        XCTAssertTrue(issue.recovery?.contains("mdutil") == true)
    }

    func testMasVerifyToleratesIndexingIssuesAfterUpdate() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["outdated"],
            stub: .init(result: ProcessResult(
                exitCode: 0,
                stdout: "",
                stderr: "Warning: Found a likely App Store app that is not indexed in Spotlight in /Applications/Speedtest.app")))
        let source = MasSource(
            runner: runner,
            resolver: StubResolver(resolution: .notFound),
            verificationDelay: .zero)
        let verification = try await source.verify(
            requests: [UpdateRequest(packageID: "6445813049", name: "Spark Desktop", targetVersion: "3.30.5")],
            context: masToolContext(executablePath: "/test/mas"))
        guard case .satisfied(let installed) = verification["6445813049"] else {
            return XCTFail("Expected satisfied verification")
        }
        XCTAssertEqual(installed, "3.30.5")
    }

    func testMasVerifyReportsStillOutdatedWhenAppRemainsListed() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["outdated"],
            stub: .init(result: ProcessResult(
                exitCode: 0,
                stdout: "6445813049  Spark Desktop  (3.30.4 -> 3.30.5)\n",
                stderr: "")))
        let source = MasSource(
            runner: runner,
            resolver: StubResolver(resolution: .notFound),
            verificationDelay: .zero)
        let verification = try await source.verify(
            requests: [UpdateRequest(packageID: "6445813049", name: "Spark Desktop", targetVersion: "3.30.5")],
            context: masToolContext(executablePath: "/test/mas"))
        guard case .stillOutdated(let info) = verification["6445813049"] else {
            return XCTFail("Expected still-outdated verification")
        }
        XCTAssertEqual(info.currentVersion, "3.30.4")
    }

    func testLiveMasScanAgainstRealMasIfEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PACKMAN_LIVE_MAS_TESTS"] == "1",
            "Set PACKMAN_LIVE_MAS_TESTS=1 to run live mas integration tests.")
        let source = MasSource(verificationDelay: .zero)
        let probe = await source.probe()
        guard case .available(let context) = probe else {
            return XCTFail("mas is not available on this machine: \(probe)")
        }
        print("LIVE mas probe: \(context.executablePath) (\(context.version), \(context.origin.rawValue))")
        let report = try await source.scan(context: context) { _ in }
        print("LIVE mas scan: \(report.updates.count) update(s), \(report.issues.count) issue(s)")
        for update in report.updates {
            print("  update: \(update.id) \(update.name) \(update.currentVersion) -> \(update.availableVersion)")
        }
        for issue in report.issues {
            print("  issue: \(issue.message)")
        }
        XCTAssertTrue(report.updates.allSatisfy { PackageIdValidator.isAllDigits($0.id) })
    }

    func testMasUpdateHandsOffToTerminalElevation() async throws {
        let runner = StubProcessRunner()
        let source = MasSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        let recorder = OutputRecorder()

        do {
            try await source.update(
                request: UpdateRequest(packageID: "6445813049", name: "Spark Desktop", targetVersion: "3.30.5"),
                context: masToolContext(executablePath: "/opt/homebrew/bin/mas")) { event in
                    await recorder.append(event.line)
                }
            XCTFail("Expected requiresTerminalUpdate")
        } catch let error as SourceError {
            guard case .requiresTerminalUpdate(let command) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(command, "sudo mas update --force 6445813049")
            XCTAssertTrue(error.errorDescription?.contains("sudo mas update --force 6445813049") == true)
            XCTAssertTrue(error.errorDescription?.contains("logged-in session") == true)
        }

        let streamed = await recorder.lines
        XCTAssertEqual(streamed, ["sudo mas update --force 6445813049"])
        let invocations = await runner.invocations
        XCTAssertTrue(invocations.isEmpty, "No process may be launched for the handoff")
    }

    func testMasUpdateRejectsInvalidPackageIdBeforeHandoff() async throws {
        let source = MasSource(runner: StubProcessRunner(), resolver: StubResolver(resolution: .notFound))
        do {
            try await source.update(
                request: UpdateRequest(packageID: "not-an-id", name: "Bad", targetVersion: "1.0"),
                context: masToolContext(executablePath: "/opt/homebrew/bin/mas")) { _ in }
            XCTFail("Expected invalidPackageId")
        } catch let error as SourceError {
            guard case .invalidPackageId = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testNpmUsesLatestRatherThanWanted() async throws {
        let runner = StubProcessRunner()
        let json = String(data: try fixtureData("npm-outdated"), encoding: .utf8)!
        await runner.enqueue(
            arguments: ["outdated", "-g", "--json"],
            stub: .init(result: ProcessResult(exitCode: 1, stdout: json, stderr: "")))
        let source = NpmSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        let report = try await source.scan(context: testToolContext) { _ in }
        XCTAssertEqual(report.updates.first(where: { $0.id == "typescript" })?.currentVersion, "5.4.0")
        XCTAssertEqual(report.updates.first(where: { $0.id == "typescript" })?.availableVersion, "6.0.1")
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testNpmVerifyConfirmsAllRequestsInOneCall() async throws {
        let runner = StubProcessRunner()
        let json = #"{"dependencies":{"a":{"version":"2.0.0"},"b":{"version":"1.0.0"}}}"#
        await runner.enqueue(
            arguments: ["list", "-g", "--depth=0", "--json"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: json, stderr: "")))
        let source = NpmSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        let verification = try await source.verify(
            requests: [
                UpdateRequest(packageID: "a", name: "a", targetVersion: "2.0.0"),
                UpdateRequest(packageID: "b", name: "b", targetVersion: "2.0.0"),
            ],
            context: testToolContext)
        guard case .satisfied(let installed) = verification["a"] else {
            return XCTFail("Expected a to be satisfied")
        }
        XCTAssertEqual(installed, "2.0.0")
        guard case .stillOutdated(let info) = verification["b"] else {
            return XCTFail("Expected b to be still outdated")
        }
        XCTAssertEqual(info.currentVersion, "1.0.0")
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 1, "Verification must batch all packages into one npm call")
    }

    func testNpmInstallsExactDisplayedTarget() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["install", "-g", "typescript@6.0.1"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "updated", stderr: "")))
        let source = NpmSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        try await source.update(
            request: UpdateRequest(packageID: "typescript", name: "typescript", targetVersion: "6.0.1"),
            context: testToolContext) { _ in }
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.last?.arguments, ["install", "-g", "typescript@6.0.1"])
    }

    func testPipFixtureParses() async throws {
        let runner = StubProcessRunner()
        let json = String(data: try fixtureData("pip-outdated"), encoding: .utf8)!
        await runner.enqueue(
            arguments: ["-m", "pip", "list", "--outdated", "--format", "json", "--disable-pip-version-check"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: json, stderr: "")))
        let source = PipSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        let report = try await source.scan(context: testToolContext) { _ in }
        XCTAssertEqual(report.updates.map(\.name), ["httpx", "ruff"])
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testPipPinsTargetAndInstalledDependentsInOneTransaction() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["-c", PipSource.findDependentsScript, "urllib3"],
            stub: .init(result: ProcessResult(
                exitCode: 0,
                stdout: #"[{"name":"requests","version":"2.32.4"}]"#,
                stderr: "")))
        await runner.enqueue(
            arguments: ["-m", "pip", "install", "--upgrade", "urllib3==2.6.0", "requests==2.32.4"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "updated", stderr: "")))
        let source = PipSource(runner: runner, resolver: StubResolver(resolution: .notFound))

        try await source.update(
            request: UpdateRequest(packageID: "urllib3", name: "urllib3", targetVersion: "2.6.0"),
            context: testToolContext) { _ in }

        let invocations = await runner.invocations
        XCTAssertEqual(
            invocations.last?.arguments,
            ["-m", "pip", "install", "--upgrade", "urllib3==2.6.0", "requests==2.32.4"])
    }

    func testDotnetParserAndNuGetLookupFindUpdate() async throws {
        let output = """
        Package Id      Version      Commands
        -------------------------------------
        dotnet-ef       8.0.0        dotnet-ef
        """
        let parsed = DotnetToolListParser.parse(output)
        XCTAssertEqual(parsed.tools, [.init(id: "dotnet-ef", version: "8.0.0")])
        XCTAssertTrue(parsed.issues.isEmpty)

        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["tool", "list", "--global"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: output, stderr: "")))
        let client = StaticHTTPClient(
            statusCode: 200,
            body: #"{"versions":["8.0.0","9.0.2","10.0.0-preview.1"]}"#)
        let source = DotnetSource(
            runner: runner,
            resolver: StubResolver(resolution: .notFound),
            httpClient: client)

        let report = try await source.scan(context: testToolContext) { _ in }
        XCTAssertEqual(report.updates, [PackageInfo(
            id: "dotnet-ef",
            name: "dotnet-ef",
            currentVersion: "8.0.0",
            availableVersion: "9.0.2")])
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testPipxNativePartialOutputKeepsUpdatesAndIssues() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["list", "--help"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "--outdated --output", stderr: "")))
        let json = String(data: try fixtureData("pipx-outdated"), encoding: .utf8)!
        await runner.enqueue(
            arguments: ["list", "--outdated", "--output", "json"],
            stub: .init(result: ProcessResult(exitCode: 1, stdout: json, stderr: "")))
        let source = PipxSource(
            runner: runner,
            resolver: StubResolver(resolution: .notFound),
            httpClient: StubHTTPClient())
        let report = try await source.scan(context: testToolContext) { _ in }
        XCTAssertEqual(report.updates.first?.id, "ruff")
        XCTAssertEqual(report.updates.first?.availableVersion, "0.11.0")
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues[0].message.contains("black"))
    }

    func testBrewClearCacheRunsCleanup() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["cleanup"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "Cleaned up", stderr: "")))
        let source = BrewSource(kind: .formula, runner: runner, resolver: StubResolver(resolution: .notFound))
        try await source.clearCache(context: testToolContext) { _ in }
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.last?.arguments, ["cleanup"])
    }

    func testNpmClearCacheRunsCacheCleanForce() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["cache", "clean", "--force"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "", stderr: "")))
        let source = NpmSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        try await source.clearCache(context: testToolContext) { _ in }
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.last?.arguments, ["cache", "clean", "--force"])
    }

    func testPipClearCacheRunsCachePurge() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["-m", "pip", "cache", "purge"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "Files removed", stderr: "")))
        let source = PipSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        try await source.clearCache(context: testToolContext) { _ in }
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.last?.arguments, ["-m", "pip", "cache", "purge"])
    }

    func testPipxClearCacheRunsCachePurge() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["cache", "purge"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "", stderr: "")))
        let source = PipxSource(runner: runner, resolver: StubResolver(resolution: .notFound), httpClient: StubHTTPClient())
        try await source.clearCache(context: testToolContext) { _ in }
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.last?.arguments, ["cache", "purge"])
    }

    func testDotnetClearCacheRunsNugetLocalsAllClear() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["nuget", "locals", "all", "--clear"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "Clearing NuGet cache", stderr: "")))
        let source = DotnetSource(runner: runner, resolver: StubResolver(resolution: .notFound), httpClient: StubHTTPClient())
        try await source.clearCache(context: testToolContext) { _ in }
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.last?.arguments, ["nuget", "locals", "all", "--clear"])
    }

    func testMasClearCacheLogsAutomaticManagement() async throws {
        let runner = StubProcessRunner()
        let source = MasSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        var outputLines: [String] = []
        let freed = try await source.clearCache(context: masToolContext(executablePath: "/opt/homebrew/bin/mas")) { event in
            outputLines.append(event.line)
        }
        XCTAssertEqual(freed, 0)
        XCTAssertTrue(outputLines.contains { $0.contains("automatically by macOS") })
        let invocations = await runner.invocations
        XCTAssertTrue(invocations.isEmpty, "Mas clearCache must not run mas reset or terminate system processes")
    }

    func testMasScanSurfacesNetworkTimeoutAsIssue() async throws {
        let runner = StubProcessRunner()
        let stderr = """
        Error: Error Domain=NSURLErrorDomain Code=-1001 "The request timed out." UserInfo={NSErrorFailingURLKey=https://itunes.apple.com/lookup?media=software&entity=desktopSoftware&country=AU&bundleId=com.apple.pixelmator}
        """
        await runner.enqueue(
            arguments: ["outdated"],
            stub: .init(result: ProcessResult(exitCode: 1, stdout: "", stderr: stderr)))
        let source = MasSource(runner: runner, resolver: StubResolver(resolution: .notFound))
        let report = try await source.scan(context: masToolContext(executablePath: "/opt/homebrew/bin/mas")) { _ in }
        XCTAssertTrue(report.updates.isEmpty)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(report.issues.first?.kind, .network)
        XCTAssertTrue(report.issues.first?.message.contains("com.apple.pixelmator") == true)
    }
}

private func masToolContext(executablePath: String, version: String = "7.0.0") -> ToolContext {
    ToolContext(
        executablePath: executablePath,
        version: version,
        pathEntries: ["/test"],
        origin: .knownPath)
}

private struct StubHTTPClient: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPDataResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct StaticHTTPClient: HTTPDataLoading {
    let statusCode: Int
    let body: String

    func data(for request: URLRequest) async throws -> HTTPDataResponse {
        HTTPDataResponse(data: Data(body.utf8), statusCode: statusCode)
    }
}

private actor OutputRecorder {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
