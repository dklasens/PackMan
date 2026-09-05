import Foundation
import XCTest
@testable import PackMan

func makeSignedTestApp(at url: URL, version: String) throws -> URL {
    let contents = url.appendingPathComponent("Contents")
    let binary = contents.appendingPathComponent("MacOS/PackMan")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": "com.packman.PackMan", "CFBundleExecutable": "PackMan",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    // Use the just-built app executable; it has exactly the test host architecture.
    let candidates = [Bundle(for: ReleaseBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("PackMan"),
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PackMan"),
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PackMan.app/Contents/MacOS/PackMan"),
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("PackMan")]
    if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        try FileManager.default.copyItem(at: executable, to: binary)
    } else {
        // Xcode-hosted tests can locate the application via its loaded bundle.
        let app = Bundle.allBundles.first { $0.bundleIdentifier == "com.packman.PackMan" }
        let executable = try XCTUnwrap(app?.executableURL)
        try FileManager.default.copyItem(at: executable, to: binary)
    }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--deep", "--sign", "-", url.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "TestSigning", code: Int(process.terminationStatus)) }
    return url
}

@MainActor
func waitForOperation(_ model: AppViewModel, timeout: TimeInterval = 5) async throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while model.completedOperations < model.startedOperations || model.isBusy {
        if Date.now > deadline { throw NSError(domain: "TestTimeout", code: 1) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private final class ReleaseBundleToken {}
