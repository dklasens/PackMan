import Foundation

enum HistoryOutcome: String, Codable, CaseIterable, Sendable {
    case queued = "Queued", running = "Running", updated = "Updated", verified = "Verified"
    case failed = "Failed", unverified = "Unverified", cancelled = "Cancelled"
    case notStarted = "Not started", interrupted = "Interrupted", external = "Awaiting external update"
}

struct UpdateHistoryEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    var runID: UUID
    var startedAt = Date.now
    var finishedAt: Date?
    var sourceID: SourceID
    var packageID: String
    var registryID: String?
    var name: String
    var beforeVersion: String
    var targetVersion: String
    var installedVersion: String?
    var outcome: HistoryOutcome = .queued
    var toolPath: String
    var evidence = ""
    var output = ""
    var verificationOnly = false

    var versionText: String { "\(beforeVersion) → \(installedVersion ?? "not confirmed") (requested \(targetVersion))" }
}

protocol UpdateHistoryStoring: Sendable {
    var loadIssue: String? { get }
    func read() -> [UpdateHistoryEntry]
    func save(_ entries: [UpdateHistoryEntry]) throws
}

final class UpdateHistoryStore: UpdateHistoryStoring, @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PackMan/update-history.json")
    static let outputLimit = 64 * 1024
    private let url: URL?
    private let lock = NSLock()
    private var entries: [UpdateHistoryEntry] = []
    private(set) var loadIssue: String?

    init(url: URL? = defaultURL) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            entries = try JSONDecoder().decode([UpdateHistoryEntry].self, from: Data(contentsOf: url))
            entries = Array(entries.prefix(500)).map { original in
                var entry = original
                if entry.outcome == .running || entry.outcome == .queued {
                    entry.outcome = entry.outcome == .running ? .interrupted : .notStarted
                    entry.evidence = "PackMan closed before this attempt completed. Verify before retrying."
                    entry.finishedAt = .now
                }
                entry.output = Self.bounded(entry.output)
                return entry
            }
        } catch {
            loadIssue = "History could not be read: \(error.localizedDescription). The original file has been retained."
        }
    }

    func read() -> [UpdateHistoryEntry] { lock.withLock { entries } }

    func save(_ updates: [UpdateHistoryEntry]) throws {
        try lock.withLock {
            var next = entries
            for var entry in updates {
                entry.output = Self.bounded(entry.output)
                if let index = next.firstIndex(where: { $0.id == entry.id }) { next[index] = entry }
                else { next.insert(entry, at: 0) }
            }
            next.sort { $0.startedAt > $1.startedAt }
            next = Array(next.prefix(500))
            if let url {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                // Preserve unreadable history before replacing it with a fresh store.
                if loadIssue != nil, FileManager.default.fileExists(atPath: url.path) {
                    let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: url, to: backup)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
                let encoded = try JSONEncoder().encode(next)
                try encoded.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            entries = next
            loadIssue = nil
        }
    }

    static func bounded(_ text: String) -> String {
        guard text.utf8.count > outputLimit else { return text }
        return "[Earlier output truncated]\n" + String(decoding: text.utf8.suffix(outputLimit), as: UTF8.self)
    }
}

enum DiagnosticRedactor {
    static func redact(_ value: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var text = value.replacingOccurrences(of: home, with: "~")
        // Scrub both assignments/headers and quoted JSON values, URL credentials,
        // common token forms, and private key blocks. Arbitrary output still merits review.
        let patterns: [(String, String)] = [
            (#"(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
            (#"(?i)(https?://)[^\s/@]+:[^\s/@]+@"#, "$1[REDACTED]@"),
            (#"(?i)(authorization\s*[:=]\s*)(?:bearer|basic)\s+[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)((?:[\"']?)(?:_authToken|_auth|password|passwd|secret|token|api[-_]?key|access[-_]?key|client[-_]?secret)(?:[\"']?)\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s&;,]+)"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:[^=&\s]*(?:token|secret|signature|credential|key|sig)[^=&\s]*)=)[^&\s]+"#, "$1[REDACTED]"),
            (#"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|npm_[A-Za-z0-9]+|sk-[A-Za-z0-9_-]{12,})\b"#, "[REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    static func export(history: [UpdateHistoryEntry], log: [LogEntry]) throws -> String {
        // Redact fields before encoding so newlines and escaped JSON cannot bypass matching.
        let records = history.map { original in
            var entry = original
            entry.packageID = redact(entry.packageID); entry.registryID = entry.registryID.map { redact($0) }
            entry.name = redact(entry.name); entry.beforeVersion = redact(entry.beforeVersion)
            entry.targetVersion = redact(entry.targetVersion); entry.installedVersion = entry.installedVersion.map { redact($0) }
            entry.toolPath = redact(entry.toolPath); entry.evidence = redact(entry.evidence); entry.output = redact(entry.output)
            return entry
        }
        struct Export: Encodable { let version: String; let history: [UpdateHistoryEntry]; let log: [String] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Export(version: AppViewModel.appVersion, history: records,
            log: log.map { redact("\($0.timestamp) [\($0.scope ?? "PackMan")] \($0.message)") }))
        return String(decoding: data, as: UTF8.self)
    }
}
