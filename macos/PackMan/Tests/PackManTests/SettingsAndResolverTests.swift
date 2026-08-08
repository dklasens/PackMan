import Foundation
import XCTest
@testable import PackMan

final class SettingsAndResolverTests: XCTestCase {
    func testLegacyDisabledSourceMigrates() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        try Data(#"{"disabledSources":["NPM","Homebrew Casks"]}"#.utf8).write(to: url)
        let settings = SettingsStore(settingsURL: url)
        XCTAssertFalse(settings.isSourceEnabled(.npm))
        XCTAssertFalse(settings.isSourceEnabled(.homebrewCasks))
        XCTAssertTrue(settings.isSourceEnabled(.pip))
    }

    func testVersionTwoSettingsMigrateWithoutLosingSelectionsOrOverrides() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        try Data(#"{"version":2,"disabledSources":["pipx"],"executableOverrides":{"npm":"/custom/npm"}}"#.utf8)
            .write(to: url)

        let settings = SettingsStore(settingsURL: url)
        XCTAssertFalse(settings.isSourceEnabled(.pipx))
        XCTAssertEqual(settings.executableOverride(for: .npm), "/custom/npm")
        XCTAssertTrue(settings.ignoredUpdateKeys().isEmpty)
    }

    func testCorruptSettingsUseDefaultsAndExposeIssue() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: url)
        let settings = SettingsStore(settingsURL: url)
        XCTAssertTrue(settings.isSourceEnabled(.npm))
        XCTAssertNotNil(settings.loadIssue)
    }

    func testSettingsPersistOverridesAtomically() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        var settings: SettingsStore? = SettingsStore(settingsURL: url)
        try settings?.setSource(.pipx, enabled: false)
        try settings?.setExecutableOverride("/custom/pipx", for: .pipx)
        settings = nil

        let reloaded = SettingsStore(settingsURL: url)
        XCTAssertFalse(reloaded.isSourceEnabled(.pipx))
        XCTAssertEqual(reloaded.executableOverride(for: .pipx), "/custom/pipx")
    }

    func testSettingsPersistCachedContextsAndIgnoreRules() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        let executable = root.appendingPathComponent("dotnet")
        try makeExecutable(executable)
        let context = ToolContext(
            executablePath: executable.path,
            version: "10.0.100",
            pathEntries: [root.path],
            origin: .knownPath)

        var settings: SettingsStore? = SettingsStore(settingsURL: url)
        try settings?.setCachedContext(context, for: .dotnet)
        try settings?.setUpdateIgnored("dotnet:dotnet-ef@10.0.1", ignored: true)
        settings = nil

        let reloaded = SettingsStore(settingsURL: url)
        XCTAssertEqual(reloaded.cachedContext(for: .dotnet), context)
        XCTAssertEqual(reloaded.ignoredUpdateKeys(), ["dotnet:dotnet-ef@10.0.1"])

        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(reloaded.cachedContext(for: .dotnet), "Missing executables must invalidate cached probes")
    }

    func testResolverUsesInheritedPath() async throws {
        let root = try temporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("npm")
        try makeExecutable(tool)
        try makeExecutable(bin.appendingPathComponent("node"))
        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": bin.path],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)
        guard case .resolved(let executable) = result else { return XCTFail("Expected resolution") }
        XCTAssertEqual(executable.path, tool.path)
        XCTAssertEqual(executable.pathEntries, [bin.path])
        XCTAssertEqual(executable.origin, .inheritedPath)
    }

    func testInvalidOverrideDoesNotSilentlyFallBack() async throws {
        let settings = MemorySettings(overrides: [.npm: "/missing/npm"])
        let resolver = ToolResolver(settings: settings, environment: ["PATH": "/usr/bin"])
        let result = await resolver.resolve(npmDescriptor)
        XCTAssertEqual(result, .invalidOverride("/missing/npm"))
    }

    func testResolverFindsUserLocalBin() async throws {
        let root = try temporaryDirectory()
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("npm")
        try makeExecutable(tool)
        try makeExecutable(bin.appendingPathComponent("node"))
        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": ""],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)
        guard case .resolved(let executable) = result else { return XCTFail("Expected resolution") }
        XCTAssertEqual(executable.origin, .userPath)
    }

    func testResolverFallsBackFromIncompleteNpmToNVM() async throws {
        let root = try temporaryDirectory()
        let brokenBin = root.appendingPathComponent("broken/bin", isDirectory: true)
        let nvmBin = root.appendingPathComponent(".nvm/versions/node/v22.12.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
        try makeExecutable(brokenBin.appendingPathComponent("npm"))
        try makeExecutable(nvmBin.appendingPathComponent("npm"))
        try makeExecutable(nvmBin.appendingPathComponent("node"))

        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": brokenBin.path],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)

        guard case .resolved(let executable) = result else { return XCTFail("Expected nvm resolution") }
        XCTAssertEqual(resolvedPath(executable.path), resolvedPath(nvmBin.appendingPathComponent("npm").path))
        XCTAssertEqual(executable.pathEntries.map(resolvedPath), [resolvedPath(nvmBin.path)])
        XCTAssertEqual(executable.origin, .nvm)
    }

    func testResolverPreservesSeparateNpmAndNodeDirectories() async throws {
        let root = try temporaryDirectory()
        let npmBin = root.appendingPathComponent("npm-bin", isDirectory: true)
        let nodeBin = root.appendingPathComponent("node-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: npmBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeBin, withIntermediateDirectories: true)
        try makeExecutable(npmBin.appendingPathComponent("npm"))
        try makeExecutable(nodeBin.appendingPathComponent("node"))

        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": "\(npmBin.path):\(nodeBin.path)"],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)

        guard case .resolved(let executable) = result else { return XCTFail("Expected resolution") }
        XCTAssertEqual(executable.pathEntries, [npmBin.path, nodeBin.path])
        XCTAssertEqual(executable.origin, .inheritedPath)
    }

    func testExplicitNpmOverridePreservesSeparateNodeDirectory() async throws {
        let root = try temporaryDirectory()
        let npmBin = root.appendingPathComponent("npm-bin", isDirectory: true)
        let nodeBin = root.appendingPathComponent("node-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: npmBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeBin, withIntermediateDirectories: true)
        let npm = npmBin.appendingPathComponent("npm")
        try makeExecutable(npm)
        try makeExecutable(nodeBin.appendingPathComponent("node"))

        let resolver = ToolResolver(
            settings: MemorySettings(overrides: [.npm: npm.path]),
            environment: ["PATH": nodeBin.path],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)

        guard case .resolved(let executable) = result else { return XCTFail("Expected resolution") }
        XCTAssertEqual(executable.path, npm.path)
        XCTAssertEqual(executable.pathEntries, [npmBin.path, nodeBin.path])
        XCTAssertEqual(executable.origin, .explicit)
    }

    func testResolverReportsNpmPathWhenNodeIsMissing() async throws {
        let root = try temporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let npm = bin.appendingPathComponent("npm")
        try makeExecutable(npm)

        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": bin.path],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)

        XCTAssertEqual(result, .missingDependency(executablePath: npm.path, dependency: "Node"))
    }

    func testResolverFindsFNMInstallation() async throws {
        let root = try temporaryDirectory()
        let fnmBin = root.appendingPathComponent(
            "Library/Application Support/fnm/node-versions/v22.11.0/installation/bin",
            isDirectory: true)
        try FileManager.default.createDirectory(at: fnmBin, withIntermediateDirectories: true)
        try makeExecutable(fnmBin.appendingPathComponent("npm"))
        try makeExecutable(fnmBin.appendingPathComponent("node"))

        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": ""],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)

        guard case .resolved(let executable) = result else { return XCTFail("Expected fnm resolution") }
        XCTAssertEqual(resolvedPath(executable.path), resolvedPath(fnmBin.appendingPathComponent("npm").path))
        XCTAssertEqual(executable.origin, .fnm)
    }

    func testResolverFindsVoltaInstallation() async throws {
        let root = try temporaryDirectory()
        let voltaBin = root.appendingPathComponent(".volta/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: voltaBin, withIntermediateDirectories: true)
        try makeExecutable(voltaBin.appendingPathComponent("npm"))
        try makeExecutable(voltaBin.appendingPathComponent("node"))

        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": ""],
            homeDirectory: root,
            standardSearchPaths: [])
        let result = await resolver.resolve(npmDescriptor)

        guard case .resolved(let executable) = result else { return XCTFail("Expected Volta resolution") }
        XCTAssertEqual(executable.path, voltaBin.appendingPathComponent("npm").path)
        XCTAssertEqual(executable.origin, .volta)
    }

    func testNpmProbeExplainsMissingNodeRuntime() async {
        let npmPath = "/custom/npm"
        let resolver = StubResolver(resolution: .missingDependency(
            executablePath: npmPath,
            dependency: "Node"))
        let probe = await SourceSupport.probe(
            descriptor: npmDescriptor,
            versionArguments: ["--version"],
            resolver: resolver,
            runner: StubProcessRunner())

        guard case .unavailable(let issue) = probe else { return XCTFail("Expected unavailable probe") }
        XCTAssertEqual(issue.kind, .configuration)
        XCTAssertTrue(issue.message.contains(npmPath))
        XCTAssertTrue(issue.message.contains("Node runtime was not found"))
        XCTAssertTrue(issue.recovery?.contains("complete installation") == true)
    }

    func testPipProbeChecksPipModuleNotOnlyPython() async throws {
        let runner = StubProcessRunner()
        await runner.enqueue(
            arguments: ["-m", "pip", "--version"],
            stub: .init(result: ProcessResult(exitCode: 0, stdout: "pip 26.0", stderr: "")))
        let resolver = StubResolver(resolution: .resolved(ResolvedExecutable(
            path: "/python3",
            pathEntries: ["/"],
            origin: .explicit)))
        let probe = await PipSource(runner: runner, resolver: resolver).probe()
        guard case .available(let context) = probe else { return XCTFail("Expected pip to be available") }
        XCTAssertEqual(context.version, "pip 26.0")
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.first?.arguments, ["-m", "pip", "--version"])
    }

    func testSettingsWritesAreRestrictedToOwner() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        let settings = SettingsStore(settingsURL: url)
        try settings.setSource(.npm, enabled: false)
        let permissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o077, 0, "Settings must not be readable or writable by group or others")
    }

    func testSettingsLoadRepairsLoosePermissions() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("settings.json")
        try Data(#"{"version":3,"disabledSources":[],"executableOverrides":{}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        _ = SettingsStore(settingsURL: url)

        let permissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o077, 0)
    }

    private var npmDescriptor: SourceDescriptor {
        SourceDescriptor(
            id: .npm,
            name: "npm",
            toolID: .npm,
            executableName: "npm",
            knownPaths: [],
            installationURL: nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeExecutable(_ url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
