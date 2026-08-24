import Foundation

struct AppUpdateInfo: Equatable, Sendable {
    var version: String
    var downloadURL: URL
    var checksumURL: URL
    var releaseURL: URL
}

struct AppVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count),
              let major = Int(parts[0]), major >= 0 else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, minor >= 0, let patch, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var displayString: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static var current: AppVersion {
        AppVersion(AppViewModel.appVersion) ?? AppVersion("0.0.0")!
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case malformedChecksum
    case checksumMismatch
    case downloadTimedOut
    case missingApplication
    case notWritable
    case disallowedHost(String)
    case helperFailed

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code) while checking for updates."
        case .invalidResponse:
            return "The update service returned an invalid response."
        case .malformedChecksum:
            return "The release checksum file is malformed."
        case .checksumMismatch:
            return "The downloaded file does not match the release checksum; the update was aborted."
        case .downloadTimedOut:
            return "The update download timed out."
        case .missingApplication:
            return "The release archive does not contain PackMan.app."
        case .notWritable:
            return "PackMan cannot replace the app at this location. Download the latest release from GitHub instead."
        case .disallowedHost(let host):
            return "Refused to download an update from \(host)."
        case .helperFailed:
            return "Could not start the update helper."
        }
    }
}

protocol AppUpdateTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAppUpdateTransport: AppUpdateTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        return (data, http)
    }
}

protocol AppUpdateChecking: Sendable {
    func check(force: Bool) async throws -> AppUpdateInfo?
    func apply(_ update: AppUpdateInfo, progress: (@Sendable (String) -> Void)?) async throws
}

struct UpdateApplyRequest: Equatable, Sendable {
    let parentPID: Int32
    let stagedApp: URL
    let targetApp: URL
    let stagingRoot: URL
}
