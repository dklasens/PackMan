import Foundation

enum PackageIdValidator {
    private static let validId: NSRegularExpression = {
        // Brew tokens use '+' (e.g. gtk+3); npm scopes use '@' and '/'.
        try! NSRegularExpression(pattern: "^[A-Za-z0-9@._/+\\-]+$")
    }()

    static func isValid(_ id: String?) -> Bool {
        guard let id, !id.isEmpty, id.count <= 256, !id.hasPrefix("-") else {
            return false
        }
        let range = NSRange(id.startIndex..., in: id)
        return validId.firstMatch(in: id, range: range) != nil
    }

    static func isAllDigits(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy(\.isNumber)
    }

    static func isValidVersion(_ version: String?) -> Bool {
        guard let version,
              !version.isEmpty,
              version.count <= 128,
              !version.hasPrefix("-"),
              !version.contains(where: { $0.isWhitespace || $0.isNewline || $0.isASCII && $0.asciiValue! < 0x20 }) else {
            return false
        }
        return true
    }
}
