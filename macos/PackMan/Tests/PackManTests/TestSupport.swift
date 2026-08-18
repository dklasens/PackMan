import Foundation
import XCTest
@testable import PackMan

actor StubProcessRunner: ProcessRunning {
    struct Stub: Sendable {
        let result: ProcessResult?
        let output: [ProcessOutputEvent]
        let delayNanoseconds: UInt64

        init(
            result: ProcessResult,
            output: [ProcessOutputEvent] = [],
            delayNanoseconds: UInt64 = 0
        ) {
            self.result = result
            self.output = output
            self.delayNanoseconds = delayNanoseconds
        }
    }

    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private var stubs: [String: [Stub]] = [:]
    private var anyStubs: [Stub] = []
    private(set) var invocations: [Invocation] = []

    func enqueue(arguments: [String], stub: Stub) {
        stubs[arguments.joined(separator: "\u{0}"), default: []].append(stub)
    }

    func enqueueAny(stub: Stub) {
        anyStubs.append(stub)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String],
        onOutput: (@Sendable (ProcessOutputEvent) async -> Void)?
    ) async throws -> ProcessResult {
        invocations.append(Invocation(executable: executable, arguments: arguments, environment: environment))
        let key = arguments.joined(separator: "\u{0}")
        let stub: Stub
        if var queued = stubs[key], !queued.isEmpty {
            stub = queued.removeFirst()
            stubs[key] = queued
        } else if !anyStubs.isEmpty {
            stub = anyStubs.removeFirst()
        } else {
            fatalError("No stub for \(arguments)")
        }
        if stub.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: stub.delayNanoseconds)
        }
        try Task.checkCancellation()
        for event in stub.output { await onOutput?(event) }
        return stub.result!
    }
}

struct StubResolver: ToolResolving {
    let resolution: ToolResolution

    func resolve(_ descriptor: SourceDescriptor) async -> ToolResolution { resolution }
}

final class MemorySettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: [SourceID: Bool]
    private var overrides: [ToolID: String]
    private var cachedContexts: [SourceID: ToolContext]
    private var ignored: Set<String>
    let loadIssue: String?

    init(
        enabled: [SourceID: Bool] = [:],
        overrides: [ToolID: String] = [:],
        cachedContexts: [SourceID: ToolContext] = [:],
        ignored: Set<String> = [],
        loadIssue: String? = nil
    ) {
        self.enabled = enabled
        self.overrides = overrides
        self.cachedContexts = cachedContexts
        self.ignored = ignored
        self.loadIssue = loadIssue
    }

    func isSourceEnabled(_ id: SourceID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled[id] ?? true
    }

    func setSource(_ id: SourceID, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        self.enabled[id] = enabled
    }

    func executableOverride(for toolID: ToolID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return overrides[toolID]
    }

    func setExecutableOverride(_ path: String?, for toolID: ToolID) throws {
        lock.lock(); defer { lock.unlock() }
        overrides[toolID] = path
    }

    func cachedContext(for sourceID: SourceID) -> ToolContext? {
        lock.lock(); defer { lock.unlock() }
        return cachedContexts[sourceID]
    }

    func setCachedContext(_ context: ToolContext?, for sourceID: SourceID) throws {
        lock.lock(); defer { lock.unlock() }
        cachedContexts[sourceID] = context
    }

    func ignoredUpdateKeys() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return ignored
    }

    func setUpdateIgnored(_ key: String, ignored: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if ignored { self.ignored.insert(key) } else { self.ignored.remove(key) }
    }
}

struct StubSource: PackageSource {
    let descriptor: SourceDescriptor
    let probeHandler: @Sendable () async -> SourceProbe
    let scanHandler: @Sendable () async throws -> SourceScanReport
    let updateHandler: @Sendable (UpdateRequest) async throws -> Void
    let verifyHandler: @Sendable ([UpdateRequest]) async throws -> [String: UpdateVerification]
    let clearCacheHandler: @Sendable () async throws -> Int64

    init(
        id: SourceID,
        name: String,
        probe: @escaping @Sendable () async -> SourceProbe,
        scan: @escaping @Sendable () async throws -> SourceScanReport,
        update: @escaping @Sendable (UpdateRequest) async throws -> Void = { _ in },
        verify: @escaping @Sendable ([UpdateRequest]) async throws -> [String: UpdateVerification] = { requests in
            Dictionary(uniqueKeysWithValues: requests.map { ($0.packageID, .satisfied(installedVersion: $0.targetVersion)) })
        },
        clearCache: @escaping @Sendable () async throws -> Int64 = { 0 }
    ) {
        descriptor = SourceDescriptor(
            id: id,
            name: name,
            toolID: id == .npm ? .npm : (id == .homebrew || id == .homebrewCasks ? .brew : (id == .pip ? .python : (id == .pipx ? .pipx : (id == .appStore ? .mas : .dotnet)))),
            executableName: name.lowercased(),
            knownPaths: [],
            installationURL: nil)
        probeHandler = probe
        scanHandler = scan
        updateHandler = update
        verifyHandler = verify
        clearCacheHandler = clearCache
    }

    func probe() async -> SourceProbe { await probeHandler() }

    func scan(
        context: ToolContext,
        progress: @escaping @Sendable (SourcePhase) async -> Void
    ) async throws -> SourceScanReport {
        await progress(.scanning)
        return try await scanHandler()
    }

    func update(
        request: UpdateRequest,
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws {
        try await updateHandler(request)
    }

    func verify(
        requests: [UpdateRequest],
        context: ToolContext
    ) async throws -> [String: UpdateVerification] {
        try await verifyHandler(requests)
    }

    func clearCache(
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws -> Int64 {
        try await clearCacheHandler()
    }
}

let testToolContext = ToolContext(
    executablePath: "/test/tool",
    version: "1.0.0",
    pathEntries: ["/test"],
    origin: .knownPath)

func fixtureData(_ name: String, extension fileExtension: String = "json") throws -> Data {
#if SWIFT_PACKAGE
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: fileExtension))
#else
    let url = try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: name, withExtension: fileExtension))
#endif
    return try Data(contentsOf: url)
}

private final class BundleToken {}
