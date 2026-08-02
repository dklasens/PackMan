import Foundation

enum PackageSortField: Hashable, Sendable {
    case name
    case source
    case currentVersion
    case availableVersion
    case status
}

struct PackageSortComparator: SortComparator, Hashable, Sendable {
    typealias Compared = PackageUpdate

    let field: PackageSortField
    var order: SortOrder = .forward

    func compare(_ lhs: PackageUpdate, _ rhs: PackageUpdate) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .source:
            result = lhs.source.localizedStandardCompare(rhs.source)
        case .currentVersion:
            result = VersionComparator.compare(lhs.currentVersion, rhs.currentVersion)
        case .availableVersion:
            result = VersionComparator.compare(lhs.availableVersion, rhs.availableVersion)
        case .status:
            result = Self.compare(Self.statusRank(lhs.status), Self.statusRank(rhs.status))
        }
        return order == .forward ? result : result.reversed
    }

    private static func statusRank(_ status: UpdateStatus) -> Int {
        switch status {
        case .pending: return 0
        case .updating: return 1
        case .verifying: return 2
        case .failed: return 3
        case .cancelled: return 4
        }
    }

    private static func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

enum VersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) {
            return left.compare(to: right)
        }
        return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }
}

private struct SemanticVersion {
    let core: [Int]
    let prerelease: [String]

    init?(_ value: String) {
        let withoutBuild = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numbers.isEmpty,
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        core = numbers.compactMap { Int($0) }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    func compare(to other: SemanticVersion) -> ComparisonResult {
        let count = max(core.count, other.core.count)
        for index in 0..<count {
            let lhs = index < core.count ? core[index] : 0
            let rhs = index < other.core.count ? other.core[index] : 0
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        if prerelease.isEmpty && other.prerelease.isEmpty { return .orderedSame }
        if prerelease.isEmpty { return .orderedDescending }
        if other.prerelease.isEmpty { return .orderedAscending }
        for index in 0..<max(prerelease.count, other.prerelease.count) {
            guard index < prerelease.count else { return .orderedAscending }
            guard index < other.prerelease.count else { return .orderedDescending }
            let lhs = prerelease[index]
            let rhs = other.prerelease[index]
            if let leftNumber = Int(lhs), let rightNumber = Int(rhs) {
                if leftNumber < rightNumber { return .orderedAscending }
                if leftNumber > rightNumber { return .orderedDescending }
            } else if Int(lhs) != nil {
                return .orderedAscending
            } else if Int(rhs) != nil {
                return .orderedDescending
            } else {
                let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
                if comparison != .orderedSame { return comparison }
            }
        }
        return .orderedSame
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
