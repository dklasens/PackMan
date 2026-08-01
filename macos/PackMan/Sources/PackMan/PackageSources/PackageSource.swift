import Foundation

enum SourceError: LocalizedError {
    case toolNotFound(String)
    case invalidPackageId(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .toolNotFound(tool):
            return "\(tool) was not found on PATH."
        case let .invalidPackageId(id):
            return "Refusing to update package with invalid id '\(id)'."
        case let .commandFailed(message):
            return message
        }
    }
}

protocol PackageSource: Sendable {
    var name: String { get }

    func isAvailable() async -> Bool

    func scan() async throws -> [PackageInfo]

    func update(packageID: String, sourceDetail: String, onOutput: @escaping @Sendable (String) -> Void) async throws
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
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
