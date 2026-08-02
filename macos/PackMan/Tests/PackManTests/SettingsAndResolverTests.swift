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

    func testResolverUsesInheritedPath() async throws {
        let root = try temporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("npm")
        try makeExecutable(tool)
        let resolver = ToolResolver(
            settings: MemorySettings(),
            environment: ["PATH": bin.path],
            homeDirectory: root)
        let result = await resolver.resolve(npmDescriptor)
        guard case .resolved(let executable) = result else { return XCTFail("Expected resolution") }
        XCTAssertEqual(executable.path, tool.path)
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
        let resolver = ToolResolver(settings: MemorySettings(), environment: ["PATH": ""], homeDirectory: root)
        let result = await resolver.resolve(npmDescriptor)
        guard case .resolved(let executable) = result else { return XCTFail("Expected resolution") }
        XCTAssertEqual(executable.origin, .userPath)
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
}
