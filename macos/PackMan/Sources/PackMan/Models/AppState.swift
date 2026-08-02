import Foundation

enum SourceScanState: Sendable, Equatable {
    case disabled
    case notScanned
    case waiting
    case probing(startedAt: Date)
    case scanning(phase: SourcePhase, startedAt: Date)
    case succeeded(updateCount: Int, completedAt: Date)
    case partial(updateCount: Int, issues: [SourceIssue], completedAt: Date)
    case unavailable(SourceIssue, completedAt: Date)
    case failed(SourceIssue, completedAt: Date)
    case cancelled(completedAt: Date)

    var hasIssue: Bool {
        switch self {
        case .partial, .unavailable, .failed, .cancelled: return true
        default: return false
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var issues: [SourceIssue] {
        switch self {
        case .partial(_, let issues, _): return issues
        case .unavailable(let issue, _), .failed(let issue, _): return [issue]
        default: return []
        }
    }
}

enum AppOperation: Sendable, Equatable {
    case idle
    case scanning(completed: Int, total: Int)
    case updating(current: String?, completed: Int, total: Int)
    case cancelling

    var isBusy: Bool { self != .idle }
}

enum ScanSummary: Sendable, Equatable {
    case notStarted
    case running
    case updatesAvailable(Int)
    case updatesCompleted(Date)
    case upToDate(Date)
    case completedWithIssues(updateCount: Int, issueCount: Int, completedAt: Date)
    case allUnavailable(Date)
    case noSources
    case cancelled(Date)
}

struct UpdateRunSummary: Sendable, Equatable {
    var updated = 0
    var failed = 0
    var cancelled = 0
    var verificationFailed = 0

    var total: Int { updated + failed + cancelled + verificationFailed }
}

struct LogEntry: Identifiable, Sendable, Equatable {
    enum Level: Sendable {
        case info
        case output
        case warning
        case error
        case success
    }

    let id: Int
    let timestamp: Date
    let level: Level
    let scope: String?
    let stream: ProcessOutputStream?
    let message: String
}
