import Foundation

struct PackageInfo: Sendable {
    let id: String
    let name: String
    let currentVersion: String
    let availableVersion: String
    var sourceDetail: String = ""
    var statusMessage: String?
}

@Observable
final class PackageUpdate: Identifiable {
    let sourceRef: any PackageSource
    let packageID: String
    var name: String
    let source: String
    var currentVersion: String
    let availableVersion: String
    var sourceDetail: String
    var isSelected: Bool
    var status: UpdateStatus
    var statusMessage: String?

    var id: String { "\(source)|\(packageID)" }

    init(info: PackageInfo, source: any PackageSource) {
        self.sourceRef = source
        self.packageID = info.id
        self.name = info.name
        self.source = source.name
        self.currentVersion = info.currentVersion
        self.availableVersion = info.availableVersion
        self.sourceDetail = info.sourceDetail
        self.isSelected = true
        self.status = .pending
        self.statusMessage = info.statusMessage
    }
}
