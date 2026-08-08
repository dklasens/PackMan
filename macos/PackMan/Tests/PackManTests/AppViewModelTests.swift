import XCTest
@testable import PackMan

@MainActor
final class AppViewModelTests: XCTestCase {
    func testSuccessfulEmptyScanIsUpToDate() async throws {
        let source = availableSource(id: .npm, name: "npm", report: SourceScanReport())
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        guard case .upToDate = viewModel.scanSummary else {
            return XCTFail("Expected up-to-date state, got \(viewModel.scanSummary)")
        }
    }

    func testPartialEmptyScanNeverReportsUpToDate() async throws {
        let report = SourceScanReport(issues: [SourceIssue(kind: .network, message: "offline")])
        let source = availableSource(id: .pipx, name: "pipx", report: report)
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        guard case .completedWithIssues(let updates, let issues, _) = viewModel.scanSummary else {
            return XCTFail("Expected issue state, got \(viewModel.scanSummary)")
        }
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(issues, 1)
        XCTAssertFalse(viewModel.statusText.lowercased().contains("up to date"))
    }

    func testPartialScanKeepsUpdatesVisible() async throws {
        let update = PackageInfo(id: "ruff", name: "ruff", currentVersion: "1", availableVersion: "2")
        let report = SourceScanReport(
            updates: [update],
            issues: [SourceIssue(kind: .network, message: "one lookup failed")])
        let source = availableSource(id: .pipx, name: "pipx", report: report)
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        XCTAssertEqual(viewModel.packages.map(\.packageID), ["ruff"])
        guard case .completedWithIssues(let count, _, _) = viewModel.scanSummary else {
            return XCTFail("Expected partial summary")
        }
        XCTAssertEqual(count, 1)
    }

    func testAllUnavailableHasDedicatedState() async throws {
        let issue = SourceIssue(kind: .unavailable, message: "missing")
        let source = StubSource(
            id: .npm,
            name: "npm",
            probe: { .unavailable(issue) },
            scan: { SourceScanReport() })
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        guard case .allUnavailable = viewModel.scanSummary else {
            return XCTFail("Expected all-unavailable state")
        }
    }

    func testFastSourcePublishesBeforeSlowSourceCompletes() async throws {
        let slowGate = TestGate()
        let fast = StubSource(
            id: .npm,
            name: "npm",
            probe: { .available(testToolContext) },
            scan: {
                return SourceScanReport(updates: [PackageInfo(id: "fast", name: "fast", currentVersion: "1", availableVersion: "2")])
            })
        let slow = StubSource(
            id: .pip,
            name: "pip",
            probe: { .available(testToolContext) },
            scan: {
                await slowGate.wait()
                return SourceScanReport()
            })
        let viewModel = AppViewModel(sources: [fast, slow], settings: MemorySettings())
        viewModel.startScan()

        let deadline = Date.now.addingTimeInterval(2)
        while viewModel.packages.first?.packageID != "fast" {
            if Date.now > deadline { throw WaitError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(viewModel.isBusy)
        XCTAssertEqual(viewModel.packages.first?.packageID, "fast")
        await slowGate.open()
        try await waitUntilIdle(viewModel)
    }

    func testCancellationPreservesCancelledSummary() async throws {
        let source = StubSource(
            id: .pip,
            name: "pip",
            probe: { .available(testToolContext) },
            scan: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return SourceScanReport()
            })
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await Task.sleep(nanoseconds: 50_000_000)
        viewModel.cancelOperation()
        try await waitUntilIdle(viewModel)

        guard case .cancelled = viewModel.scanSummary else {
            return XCTFail("Expected cancelled summary")
        }
    }

    func testSecondScanUsesCachedProbeContext() async throws {
        let probes = Counter()
        let source = StubSource(
            id: .npm,
            name: "npm",
            probe: {
                await probes.increment()
                return .available(testToolContext)
            },
            scan: { SourceScanReport() })
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())

        viewModel.startScan()
        try await waitUntilIdle(viewModel)
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        let probeCount = await probes.value
        XCTAssertEqual(probeCount, 1)
    }

    func testIgnoredUpdateStaysHiddenUntilRuleIsRestored() async throws {
        let update = PackageInfo(id: "tool", name: "Tool", currentVersion: "1", availableVersion: "2")
        let settings = MemorySettings()
        let source = availableSource(id: .npm, name: "npm", report: SourceScanReport(updates: [update]))
        let viewModel = AppViewModel(sources: [source], settings: settings)
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        viewModel.ignore(try XCTUnwrap(viewModel.packages.first), versionOnly: true)
        XCTAssertTrue(viewModel.packages.isEmpty)
        XCTAssertEqual(settings.ignoredUpdateKeys(), ["npm:tool@2"])

        viewModel.startScan()
        try await waitUntilIdle(viewModel)
        XCTAssertTrue(viewModel.packages.isEmpty)

        viewModel.removeIgnored("npm:tool@2")
        viewModel.startScan()
        try await waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.packages.map(\.packageID), ["tool"])
    }

    func testVerificationRunsAcrossSourcesConcurrently() async throws {
        let barrier = AsyncBarrier(participantCount: 2)
        let first = StubSource(
            id: .npm,
            name: "npm",
            probe: { .available(testToolContext) },
            scan: { SourceScanReport(updates: [PackageInfo(id: "one", name: "one", currentVersion: "1", availableVersion: "2")]) },
            verify: { requests in
                try await barrier.arriveAndWait()
                return Dictionary(uniqueKeysWithValues: requests.map { ($0.packageID, .satisfied(installedVersion: $0.targetVersion)) })
            })
        let second = StubSource(
            id: .pip,
            name: "pip",
            probe: { .available(testToolContext) },
            scan: { SourceScanReport(updates: [PackageInfo(id: "two", name: "two", currentVersion: "1", availableVersion: "2")]) },
            verify: { requests in
                try await barrier.arriveAndWait()
                return Dictionary(uniqueKeysWithValues: requests.map { ($0.packageID, .satisfied(installedVersion: $0.targetVersion)) })
            })
        let viewModel = AppViewModel(sources: [first, second], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        viewModel.startUpdateSelected()
        try await waitUntilIdle(viewModel)

        XCTAssertTrue(viewModel.packages.isEmpty)
        XCTAssertEqual(viewModel.updateSummary?.updated, 2)
    }

    func testVerifiedUpdateIsRemovedAndSummarized() async throws {
        let update = PackageInfo(id: "tool", name: "tool", currentVersion: "1", availableVersion: "2")
        let source = availableSource(id: .npm, name: "npm", report: SourceScanReport(updates: [update]))
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)
        viewModel.startUpdateSelected()
        try await waitUntilIdle(viewModel)

        XCTAssertTrue(viewModel.packages.isEmpty)
        XCTAssertEqual(viewModel.updateSummary?.updated, 1)
        guard case .updatesCompleted = viewModel.scanSummary else {
            return XCTFail("Expected completed-updates empty state")
        }
    }

    func testFailedUpdateRemainsSelectedAndRetryable() async throws {
        let update = PackageInfo(id: "tool", name: "tool", currentVersion: "1", availableVersion: "2")
        let source = StubSource(
            id: .npm,
            name: "npm",
            probe: { .available(testToolContext) },
            scan: { SourceScanReport(updates: [update]) },
            update: { _ in throw SourceError.commandFailed("boom") })
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)
        viewModel.startUpdateSelected()
        try await waitUntilIdle(viewModel)

        XCTAssertEqual(viewModel.packages.count, 1)
        XCTAssertTrue(viewModel.packages[0].isSelected)
        XCTAssertTrue(viewModel.packages[0].isActionable)
        guard case .failed(.update, let message) = viewModel.packages[0].status else {
            return XCTFail("Expected update failure")
        }
        XCTAssertEqual(message, "boom")
    }

    func testCancellationStopsVerificationAndKeepsPackageRetryable() async throws {
        let update = PackageInfo(id: "tool", name: "tool", currentVersion: "1", availableVersion: "2")
        let verifier = SlowVerifier()
        let source = StubSource(
            id: .npm,
            name: "npm",
            probe: { .available(testToolContext) },
            scan: { SourceScanReport(updates: [update]) },
            verify: { requests in try await verifier.verify(requests) })
        let viewModel = AppViewModel(sources: [source], settings: MemorySettings())
        viewModel.startScan()
        try await waitUntilIdle(viewModel)

        viewModel.startUpdateSelected()
        let deadline = Date.now.addingTimeInterval(1)
        while !(await verifier.hasStarted) {
            if Date.now > deadline { throw WaitError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        viewModel.cancelOperation()
        try await waitUntilIdle(viewModel)

        XCTAssertEqual(viewModel.packages.count, 1)
        XCTAssertTrue(viewModel.packages[0].isSelected)
        XCTAssertTrue(viewModel.packages[0].isActionable)
        XCTAssertEqual(viewModel.updateSummary?.verificationFailed, 1)
        guard case .failed(.verification, let message) = viewModel.packages[0].status else {
            return XCTFail("Expected a retryable verification failure")
        }
        XCTAssertTrue(message.contains("cancelled"))
    }

    private func availableSource(id: SourceID, name: String, report: SourceScanReport) -> StubSource {
        StubSource(
            id: id,
            name: name,
            probe: { .available(testToolContext) },
            scan: { report })
    }

    private func waitUntilIdle(_ viewModel: AppViewModel, timeout: TimeInterval = 2) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        // Deterministic completion tracking: start calls bump startedOperations
        // synchronously, the operation task bumps completedOperations when done,
        // so instant operations cannot race the wait.
        let target = viewModel.startedOperations
        while viewModel.completedOperations < target || viewModel.isBusy {
            if Date.now > deadline { throw WaitError.timedOut }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // The task clears its ownership immediately after returning to idle.
        try await Task.sleep(nanoseconds: 5_000_000)
    }

    private enum WaitError: Error { case timedOut }
}

private actor SlowVerifier {
    private(set) var hasStarted = false

    func verify(_ requests: [UpdateRequest]) async throws -> [String: UpdateVerification] {
        hasStarted = true
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return Dictionary(uniqueKeysWithValues: requests.map {
            ($0.packageID, .satisfied(installedVersion: $0.targetVersion))
        })
    }
}

private actor TestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor AsyncBarrier {
    private let participantCount: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async throws {
        try Task.checkCancellation()
        arrivals += 1
        if arrivals == participantCount {
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuations.append($0) }
        try Task.checkCancellation()
    }
}
