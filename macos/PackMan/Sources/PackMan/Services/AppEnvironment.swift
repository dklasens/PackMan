import AppKit
import Foundation

enum AppEnvironment {
    @MainActor
    static func makeViewModel() -> AppViewModel {
        #if DEBUG
        guard let scenario = uiTestScenario else { return AppViewModel() }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-AppleInterfaceStyle"), arguments.indices.contains(index + 1) {
            NSApplication.shared.appearance = NSAppearance(named: arguments[index + 1] == "Dark" ? .darkAqua : .aqua)
        }
        let source = UITestPackageSource(scenario: scenario)
        return AppViewModel(sources: [source], settings: UITestSettings(), updater: NoOpAppUpdateService(), cacheInspector: UITestCacheInspector())
        #else
        return AppViewModel()
        #endif
    }

    private static var uiTestScenario: UITestScenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-test-scenario"),
              arguments.indices.contains(index + 1) else { return nil }
        return UITestScenario(rawValue: arguments[index + 1])
    }
}

private enum UITestScenario: String, Sendable {
    case initial
    case updates
    case partial
    case slowScan
    case failedUpdate
    case manual
    case quitScan
}

private struct UITestPackageSource: PackageSource {
    let scenario: UITestScenario

    var descriptor: SourceDescriptor { SourceDescriptor(
        id: scenario == .manual ? .appStore : .npm,
        name: scenario == .manual ? "App Store" : "npm",
        toolID: scenario == .manual ? .mas : .npm,
        executableName: "npm",
        knownPaths: [],
        installationURL: nil) }

    func probe() async -> SourceProbe {
        .available(ToolContext(
            executablePath: "/ui-test/npm",
            version: "npm 12.0.0",
            pathEntries: ["/ui-test"],
            origin: .explicit))
    }

    func scan(
        context: ToolContext,
        progress: @escaping @Sendable (SourcePhase) async -> Void
    ) async throws -> SourceScanReport {
        await progress(.scanning)
        if scenario == .quitScan { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if scenario == .slowScan {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } else {
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let updates = [
            PackageInfo(id: "alpha", name: "Alpha Tool", currentVersion: "1.0.0", availableVersion: "2.0.0"),
            PackageInfo(id: "beta", name: "Beta Tool", currentVersion: "3.9.0", availableVersion: "3.10.0"),
        ]
        if scenario == .manual { return SourceScanReport(updates: [PackageInfo(id: "123456", name: "Manual App", currentVersion: "1", availableVersion: "2")]) }
        if scenario == .initial { return SourceScanReport() }
        if scenario == .partial {
            return SourceScanReport(
                updates: [updates[0]],
                issues: [SourceIssue(kind: .network, message: "Registry lookup failed for one package.")])
        }
        return SourceScanReport(updates: updates)
    }

    func update(
        request: UpdateRequest,
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws {
        await onOutput(ProcessOutputEvent(stream: .stdout, line: "Updating \(request.name)"))
        try await Task.sleep(nanoseconds: 60_000_000)
        if scenario == .failedUpdate && request.packageID == "beta" {
            throw SourceError.commandFailed("Synthetic update failure.")
        }
    }

    func verify(
        requests: [UpdateRequest],
        context: ToolContext
    ) async throws -> [String: UpdateVerification] {
        Dictionary(uniqueKeysWithValues: requests.map {
            ($0.packageID, .satisfied(installedVersion: $0.targetVersion))
        })
    }
}

private final class UITestSettings: SettingsStoring, @unchecked Sendable {
    let loadIssue: String? = nil
    private let lock = NSLock()
    private var enabled = true
    private var overridePath: String?

    func isSourceEnabled(_ id: SourceID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setSource(_ id: SourceID, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
    }

    func executableOverride(for toolID: ToolID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return overridePath
    }

    func setExecutableOverride(_ path: String?, for toolID: ToolID) throws {
        lock.lock(); defer { lock.unlock() }
        overridePath = path
    }

    func cachedContext(for sourceID: SourceID) -> ToolContext? { nil }
    func setCachedContext(_ context: ToolContext?, for sourceID: SourceID) throws {}
    func ignoredUpdateKeys() -> Set<String> { [] }
    func setUpdateIgnored(_ key: String, ignored: Bool) throws {}
    func lastAppUpdateCheck() -> Date? { nil }
    func setLastAppUpdateCheck(_ date: Date?) throws {}
    func skippedAppUpdateVersion() -> String? { nil }
    func setSkippedAppUpdateVersion(_ version: String?) throws {}
    func availableAppUpdate() -> AppUpdateInfo? { nil }
    func setAvailableAppUpdate(_ update: AppUpdateInfo?) throws {}
}

private struct NoOpAppUpdateService: AppUpdateChecking {
    func check(force: Bool) async throws -> AppUpdateInfo? { nil }
    func apply(_ update: AppUpdateInfo, progress: (@Sendable (String) -> Void)?) async throws {}
}


private struct UITestCacheInspector: CacheInspecting {
    func preview(source: any PackageSource, context: ToolContext, includeGlobalPackages: Bool) async throws -> CachePreview {
        CachePreview(sourceID: source.id, sourceName: source.name, context: context, paths: ["/ui-test/cache"], bytes: 12_000_000, scope: "Synthetic test cache; no real files are removed.")
    }
    func clear(_ preview: CachePreview, includeGlobalPackages: Bool, onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void) async throws {
        await onOutput(.init(stream: .stdout, line: "Synthetic cleanup completed"))
    }
}
