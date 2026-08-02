import Foundation

enum UpdateFailureKind: Sendable, Equatable {
    case update
    case verification
}

enum UpdateStatus: Sendable, Equatable {
    case pending
    case updating
    case verifying
    case failed(UpdateFailureKind, String)
    case cancelled

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .updating: return "Updating"
        case .verifying: return "Verifying"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var message: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    var isActionable: Bool {
        switch self {
        case .pending, .failed, .cancelled: return true
        case .updating, .verifying: return false
        }
    }

    var needsVerificationOnly: Bool {
        if case .failed(.verification, _) = self { return true }
        return false
    }
}
