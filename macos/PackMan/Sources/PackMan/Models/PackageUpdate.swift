import Foundation

struct PackageInfo: Sendable, Equatable {
    let id: String
    let name: String
    let currentVersion: String
    let availableVersion: String
    var statusMessage: String?
    var registryID: String? = nil
    var isIdentityAmbiguous = false
}

@Observable
final class PackageUpdate: Identifiable {
    let sourceRef: any PackageSource
    let sourceID: SourceID
    let packageID: String
    var name: String
    let source: String
    var currentVersion: String
    var availableVersion: String
    var toolContext: ToolContext
    var isSelected: Bool
    var status: UpdateStatus
    var identityIsAmbiguous = false
    var warning: String?
    var registryID: String?
    var verificationEvidence: String?
    var attemptID: UUID?
    var output = ""

    var id: String { "\(sourceID.rawValue)|\(packageID)" }
    var statusMessage: String? { status.message }
    var isActionable: Bool { sourceID != .appStore && !identityIsAmbiguous && status.isActionable }
    var isManual: Bool { sourceID == .appStore }

    init(info: PackageInfo, source: any PackageSource, context: ToolContext) {
        sourceRef = source
        sourceID = source.id
        packageID = info.id
        name = info.name
        self.source = source.name
        currentVersion = info.currentVersion
        availableVersion = info.availableVersion
        toolContext = context
        isSelected = source.id != .appStore
        warning = info.statusMessage
        registryID = info.registryID
        identityIsAmbiguous = info.isIdentityAmbiguous
        status = source.id == .appStore ? .manual : .pending
    }

    var updateRequest: UpdateRequest {
        UpdateRequest(packageID: packageID, name: name, targetVersion: availableVersion)
    }
}


enum PackageStatusFilter: String, CaseIterable, Identifiable {
    case all = "All statuses", pending = "Pending", failed = "Failed / unverified", manual = "Manual", selected = "Selected"
    var id: String { rawValue }
    func matches(_ package: PackageUpdate) -> Bool {
        switch self {
        case .all: return true
        case .pending: return package.status == .pending
        case .failed: if case .failed = package.status { return true }; return package.status == .cancelled
        case .manual: return package.isManual
        case .selected: return package.isSelected
        }
    }
}
