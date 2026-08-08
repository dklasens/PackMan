import Foundation

enum SourceID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case homebrew
    case homebrewCasks
    case appStore
    case npm
    case pip
    case pipx
    case dotnet

    var id: String { rawValue }
}

enum ToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case brew
    case mas
    case npm
    case python
    case pipx
    case dotnet
}

struct SourceDescriptor: Identifiable, Hashable, Sendable {
    let id: SourceID
    let name: String
    let toolID: ToolID
    let executableName: String
    let knownPaths: [String]
    let installationURL: URL?
}

enum ToolResolutionOrigin: String, Codable, Sendable {
    case explicit = "Custom"
    case inheritedPath = "PATH"
    case knownPath = "Known location"
    case userPath = "User location"
    case nvm = "nvm"
    case fnm = "fnm"
    case volta = "Volta"
}

struct ResolvedExecutable: Equatable, Sendable {
    let path: String
    let pathEntries: [String]
    let origin: ToolResolutionOrigin
}

enum ToolResolution: Equatable, Sendable {
    case resolved(ResolvedExecutable)
    case notFound
    case invalidOverride(String)
    case missingDependency(executablePath: String, dependency: String)
}

struct ToolContext: Equatable, Sendable {
    let executablePath: String
    let version: String
    let pathEntries: [String]
    let origin: ToolResolutionOrigin

    var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let entries = pathEntries + ProcessRunner.standardSearchPaths
        return ["PATH": Array(NSOrderedSet(array: entries)).compactMap { $0 as? String }.joined(separator: ":") + ":" + inherited]
    }
}

enum SourceIssueKind: String, Sendable {
    case unavailable
    case command
    case parsing
    case network
    case configuration
    case verification
}

struct SourceIssue: Identifiable, Equatable, Sendable {
    let id: String
    let kind: SourceIssueKind
    let message: String
    let recovery: String?

    init(kind: SourceIssueKind, message: String, recovery: String? = nil, id: String? = nil) {
        self.kind = kind
        self.message = message
        self.recovery = recovery
        self.id = id ?? "\(kind.rawValue)|\(message)"
    }
}

enum SourceProbe: Sendable {
    case available(ToolContext)
    case unavailable(SourceIssue)
}

enum SourcePhase: String, Sendable {
    case probing = "Checking availability"
    case refreshing = "Refreshing metadata"
    case scanning = "Checking packages"
    case verifying = "Verifying updates"
}

struct SourceScanReport: Sendable {
    var updates: [PackageInfo]
    var issues: [SourceIssue]

    init(updates: [PackageInfo] = [], issues: [SourceIssue] = []) {
        self.updates = updates
        self.issues = issues
    }
}

struct UpdateRequest: Sendable {
    let packageID: String
    let name: String
    let targetVersion: String
}

enum UpdateVerification: Sendable {
    case satisfied(installedVersion: String?)
    case stillOutdated(PackageInfo)
}

enum SourceError: LocalizedError, Equatable {
    case toolNotFound(String)
    case invalidPackageId(String)
    case invalidTargetVersion(String)
    case commandFailed(String)
    case verificationFailed(String)
    case requiresTerminalUpdate(String)

    var errorDescription: String? {
        switch self {
        case let .toolNotFound(tool):
            return "\(tool) was not found."
        case .invalidPackageId(let id):
            return "Refusing to update package with invalid id '\(id)'."
        case .invalidTargetVersion(let version):
            return "Refusing to use invalid target version '\(version)'."
        case .commandFailed(let message), .verificationFailed(let message):
            return message
        case .requiresTerminalUpdate(let command):
            return "App Store updates cannot be installed from within PackMan because macOS ties App Store commerce to your logged-in session. Run `\(command)` in Terminal, or choose Open in App Store, then scan again."
        }
    }
}

protocol PackageSource: Sendable {
    var descriptor: SourceDescriptor { get }

    func probe() async -> SourceProbe

    func scan(
        context: ToolContext,
        progress: @escaping @Sendable (SourcePhase) async -> Void
    ) async throws -> SourceScanReport

    func update(
        request: UpdateRequest,
        context: ToolContext,
        onOutput: @escaping @Sendable (ProcessOutputEvent) async -> Void
    ) async throws

    func verify(
        requests: [UpdateRequest],
        context: ToolContext
    ) async throws -> [String: UpdateVerification]
}

extension PackageSource {
    var name: String { descriptor.name }
    var id: SourceID { descriptor.id }

    var requirementHint: String? {
        switch id {
        case .appStore:
            return "Updates require mas 4 or newer and an Apple Account signed in to the App Store."
        default:
            return nil
        }
    }

    func verify(
        requests: [UpdateRequest],
        context: ToolContext
    ) async throws -> [String: UpdateVerification] {
        let report = try await scan(context: context) { _ in }
        guard report.issues.isEmpty else {
            throw SourceError.verificationFailed(report.issues.map(\.message).joined(separator: "; "))
        }

        let updates = Dictionary(uniqueKeysWithValues: report.updates.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: requests.map { request in
            if let update = updates[request.packageID] {
                return (request.packageID, .stillOutdated(update))
            }
            return (request.packageID, .satisfied(installedVersion: request.targetVersion))
        })
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes terminal formatting and other control characters before command
    /// output is presented in the SwiftUI log or an error message.
    var terminalSanitized: String {
        let scalars = unicodeScalars
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let value = scalar.value

            // Accept both a real ESC and the control-picture glyph sometimes
            // produced when an ESC passes through a text rendering layer.
            if value == 0x1B || value == 0x241B {
                let next = scalars.index(after: index)
                guard next < scalars.endIndex else { break }
                let introducer = scalars[next].value

                if introducer == 0x5B { // CSI: ESC [ ... final byte
                    index = scalars.index(after: next)
                    while index < scalars.endIndex {
                        let byte = scalars[index].value
                        index = scalars.index(after: index)
                        if (0x40...0x7E).contains(byte) { break }
                    }
                    continue
                }

                if introducer == 0x5D { // OSC: ESC ] ... BEL or ESC \
                    index = scalars.index(after: next)
                    while index < scalars.endIndex {
                        let byte = scalars[index].value
                        if byte == 0x07 {
                            index = scalars.index(after: index)
                            break
                        }
                        if byte == 0x1B || byte == 0x241B {
                            let terminator = scalars.index(after: index)
                            if terminator < scalars.endIndex, scalars[terminator].value == 0x5C {
                                index = scalars.index(after: terminator)
                                break
                            }
                        }
                        index = scalars.index(after: index)
                    }
                    continue
                }

                // Other two-byte escape sequences.
                index = scalars.index(after: next)
                continue
            }

            // Preserve tabs and printable text. Carriage returns, backspaces,
            // and other C0 controls otherwise render as visible glyphs.
            if value == 0x09 || value >= 0x20 {
                result.append(scalar)
            }
            index = scalars.index(after: index)
        }
        return String(result)
    }
}

extension Error {
    /// DecodingError's localizedDescription is generic ("The data couldn't be read...");
    /// surface the actual key path and reason instead.
    var decodingDescription: String {
        guard let error = self as? DecodingError else { return localizedDescription }

        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }

        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "unexpected value at '\(path(context))' (\(context.debugDescription))"
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at '\(path(context))'"
        case .dataCorrupted(let context):
            return "corrupted data (\(context.debugDescription))"
        @unknown default:
            return localizedDescription
        }
    }
}
