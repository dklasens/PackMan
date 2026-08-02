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
}

private struct StubHTTPClient: HTTPDataLoading {
    func data(for request: URLRequest) async throws -> HTTPDataResponse {
        throw URLError(.notConnectedToInternet)
    }
}
