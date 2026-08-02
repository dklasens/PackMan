import XCTest
@testable import PackMan

final class SortingAndRefreshTests: XCTestCase {
    func testSemanticAndNaturalVersionOrdering() {
        XCTAssertEqual(VersionComparator.compare("1.9.0", "1.10.0"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("2.0.0-beta.2", "2.0.0-beta.10"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("2.0.0-rc.1", "2.0.0"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("release-9", "release-10"), .orderedAscending)
    }

    func testHomebrewConcurrentRefreshRunsOnlyOnce() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["update"],
            stub: .init(
                result: ProcessResult(exitCode: 0, stdout: "Already up-to-date", stderr: ""),
                delayNanoseconds: 50_000_000))
        let refresh = BrewRefresh()
        async let first: Void = refresh.refreshIfNeeded(context: testToolContext, runner: runner)
        async let second: Void = refresh.refreshIfNeeded(context: testToolContext, runner: runner)
        _ = try await (first, second)

        let invocations = await runner.invocations.filter { $0.arguments == ["update"] }
        XCTAssertEqual(invocations.count, 1)
    }
}
