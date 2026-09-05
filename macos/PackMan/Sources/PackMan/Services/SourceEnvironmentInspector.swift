import Foundation

enum SourceEnvironmentInspector {
    static func scope(_ id: SourceID, context: ToolContext) -> String {
        switch id {
        case .pip: return "Manages only packages belonging to this Python interpreter. Project environments are not scanned."
        case .npm: return "Manages global packages for this npm/Node installation. Runtime search paths: \(context.pathEntries.joined(separator: ", "))."
        case .homebrew, .homebrewCasks: return "Manages this Homebrew installation; other Homebrew prefixes are not scanned."
        case .pipx: return "Manages isolated environments belonging to this pipx installation. Environment identity is retained in package details."
        case .dotnet: return "Manages this user's global .NET tools; project-local tools are not scanned."
        case .appStore: return "Checks Spotlight-indexed App Store applications. Updates are completed in the App Store or Terminal."
        }
    }

    static func describe(_ id: SourceID, context: ToolContext, runner: any ProcessRunning = ProcessRunner.shared) async -> String {
        let arguments: [String]
        switch id {
        case .npm: arguments = ["prefix", "-g"]
        case .pip: arguments = ["-c", "import sys; print('Interpreter: ' + sys.executable); print('Environment: ' + sys.prefix)"]
        case .homebrew, .homebrewCasks: arguments = ["--prefix"]
        default: return scope(id, context: context)
        }
        do {
            let result = try await runner.run(context.executablePath, arguments, timeout: 15,
                environment: SourceSupport.environment(pathEntries: context.pathEntries, additions: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
            guard result.succeeded else { return scope(id, context: context) + " Environment details unavailable." }
            return scope(id, context: context) + "\n" + (id == .pip ? "" : "Prefix: ") + result.stdout.terminalSanitized.trimmed
        } catch { return scope(id, context: context) + " Environment details unavailable: \(error.localizedDescription)" }
    }
}
