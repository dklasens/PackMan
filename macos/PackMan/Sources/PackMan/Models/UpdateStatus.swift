import Foundation

enum UpdateStatus: String, Sendable {
    case pending = "Pending"
    case updating = "Updating"
    case succeeded = "OK"
    case failed = "Failed"
}
