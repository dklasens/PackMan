import Foundation

struct PackageLink: Identifiable, Sendable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

struct PackageMetadataService: Sendable {
    var runner: any ProcessRunning = ProcessRunner.shared

    static func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func packageLink(source: SourceID, id: String) -> PackageLink? {
        guard PackageIdValidator.isValid(id) else { return nil }
        let base: String
        switch source {
        case .npm: base = "https://www.npmjs.com/package/"
        case .pip, .pipx: base = "https://pypi.org/project/"
        case .dotnet: base = "https://www.nuget.org/packages/"
        case .appStore: base = "https://apps.apple.com/app/id"
        case .homebrew: base = "https://formulae.brew.sh/formula/"
        case .homebrewCasks: base = "https://formulae.brew.sh/cask/"
        }
        if (source == .homebrew || source == .homebrewCasks) && id.contains("/") { return nil }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = safeURL(base + encoded) else { return nil }
        return PackageLink(title: "Package page", url: url)
    }

    func links(source: SourceID, id: String, context: ToolContext) async throws -> [PackageLink] {
        guard PackageIdValidator.isValid(id) else { throw SourceError.invalidPackageId(id) }
        var links = Self.packageLink(source: source, id: id).map { [$0] } ?? []
        let arguments: [String]
        switch source {
        case .npm: arguments = ["view", id, "--json"]
        case .homebrew, .homebrewCasks: arguments = ["info", "--json=v2", source == .homebrew ? "--formula" : "--cask", id]
        default: return links
        }
        let result = try await runner.run(context.executablePath, arguments, timeout: 30,
            environment: SourceSupport.environment(pathEntries: context.pathEntries, additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
        guard result.succeeded else { throw SourceSupport.commandFailure("Package metadata", result: result) }
        guard let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return links }
        let record = source == .npm ? object : ((object[source == .homebrew ? "formulae" : "casks"] as? [[String: Any]])?.first ?? [:])
        if let url = Self.safeURL(record["homepage"] as? String) { links.append(PackageLink(title: "Homepage", url: url)) }
        if let repository = record["repository"] as? [String: Any], let raw = repository["url"] as? String,
           let url = Self.safeURL(raw.replacingOccurrences(of: "git+https://", with: "https://")) {
            links.append(PackageLink(title: "Source repository", url: url))
        }
        if let url = Self.safeURL(record["release_notes"] as? String) { links.append(PackageLink(title: "Release notes", url: url)) }
        return links
    }
}
