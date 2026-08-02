import Foundation

struct PackageInfo: Sendable, Equatable {
    let id: String
    let name: String
    let currentVersion: String
    let availableVersion: String
    var statusMessage: String?
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
    let toolContext: ToolContext
    var isSelected: Bool
    var status: UpdateStatus

    var id: String { "\(sourceID.rawValue)|\(packageID)" }
    var statusMessage: String? { status.message }
    var isActionable: Bool { status.isActionable }

    init(info: PackageInfo, source: any PackageSource, context: ToolContext) {
        sourceRef = source
        sourceID = source.id
        packageID = info.id
        name = info.name
        self.source = source.name
        currentVersion = info.currentVersion
        availableVersion = info.availableVersion
        toolContext = context
        isSelected = true
        status = info.statusMessage.map { .failed(.verification, $0) } ?? .pending
    }

    var updateRequest: UpdateRequest {
        UpdateRequest(packageID: packageID, name: name, targetVersion: availableVersion)
    }
}
