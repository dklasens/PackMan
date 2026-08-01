import Foundation
import SwiftUI

@Observable
@MainActor
final class SourceOption: Identifiable {
    let source: any PackageSource
    var isEnabled: Bool {
        didSet { Settings.shared.setSource(source.name, enabled: isEnabled) }
    }

    nonisolated var id: String { source.name }
    var name: String { source.name }

    init(source: any PackageSource) {
        self.source = source
        self.isEnabled = !Settings.shared.isDisabled(source.name)
    }
}

private struct ScanOutcome: Sendable {
    enum State: Sendable {
        case unavailable
        case success([PackageInfo])
        case failed(String)
    }

    let index: Int
    let name: String
    let state: State
}

@Observable
@MainActor
final class AppViewModel {
    var packages: [PackageUpdate] = []
    var logLines: [String] = []
    var isBusy = false
    var hasScanned = false
    var statusText = "Ready. Click Scan to check for updates."
    var sortOrder: [KeyPathComparator<PackageUpdate>] = [
        .init(\.source, order: .forward),
        .init(\.name, order: .forward),
    ]

    let sourceOptions: [SourceOption]

    private static let maxLogLines = 1000
    private var lastOutputLine = ""

    init() {
        Settings.shared.load()
        let sources: [any PackageSource] = [
            BrewSource(kind: .formula),
            BrewSource(kind: .cask),
            MasSource(),
            NpmSource(),
            PipSource(),
            PipxSource(),
        ]
        sourceOptions = sources.map { SourceOption(source: $0) }
    }

    func scan() async {
        guard !isBusy else { return }
        let sources = sourceOptions.filter(\.isEnabled).map(\.source)
        guard !sources.isEmpty else {
            statusText = "No sources selected."
            return
        }

        isBusy = true
        statusText = "Scanning..."
        packages = []
        log("Scan started (\(sources.map(\.name).joined(separator: ", "))).")

        let outcomes = await withTaskGroup(of: ScanOutcome.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    guard await source.isAvailable() else {
                        return ScanOutcome(index: index, name: source.name, state: .unavailable)
                    }
                    do {
                        let found = try await source.scan()
                        return ScanOutcome(index: index, name: source.name, state: .success(found))
                    } catch {
                        return ScanOutcome(index: index, name: source.name, state: .failed(error.userMessage))
                    }
                }
            }

            var collected: [ScanOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.index < $1.index }
        }

        var found: [PackageUpdate] = []
        for outcome in outcomes {
            switch outcome.state {
            case .unavailable:
                log("\(outcome.name): not found, skipped.")
            case .failed(let message):
                log("\(outcome.name): scan failed - \(message)")
            case .success(let infos):
                log("\(outcome.name): \(infos.count) update(s).")
                let source = sources[outcome.index]
                found.append(contentsOf: infos.map { PackageUpdate(info: $0, source: source) })
            }
        }

        packages = found
        applySort()
        hasScanned = true
        log("Scan complete. \(packages.count) update(s) found.")
        statusText = packages.isEmpty
            ? "System is up to date."
            : "\(packages.count) update(s) available."
        isBusy = false
    }

    func updateSelected() async {
        guard !isBusy else { return }
        let selected = packages.filter(\.isSelected)
        guard !selected.isEmpty else {
            statusText = "Nothing selected."
            return
        }

        isBusy = true
        statusText = "Updating \(selected.count) package(s)..."
        log("Updating \(selected.count) selected package(s).")

        for package in selected {
            await performUpdate(package)
        }

        let failed = selected.filter { $0.status == .failed }.count
        statusText = failed == 0
            ? "Updates complete."
            : "Updates finished with \(failed) failure(s)."
        log("Update run finished.")
        isBusy = false
    }

    func updateSingle(_ package: PackageUpdate) async {
        guard !isBusy else { return }

        isBusy = true
        statusText = "Updating \(package.name)..."
        log("Updating \(package.name).")

        await performUpdate(package)

        statusText = package.status == .failed
            ? "Update failed: \(package.name)."
            : "Updates complete."
        isBusy = false
    }

    func applySort() {
        packages = packages.sorted(using: sortOrder)
    }

    private func performUpdate(_ package: PackageUpdate) async {
        package.status = .updating
        package.statusMessage = nil
        let name = package.name

        do {
            try await package.sourceRef.update(packageID: package.packageID, sourceDetail: package.sourceDetail) { line in
                Task { @MainActor [weak self] in
                    self?.logOutput(name: name, line: line)
                }
            }
            package.status = .succeeded
            package.currentVersion = package.availableVersion
            log("[OK] \(name) -> \(package.availableVersion)")
        } catch {
            package.status = .failed
            package.statusMessage = error.userMessage
            log("[FAIL] \(name): \(error.userMessage)")
        }
    }

    func selectAll() {
        guard !isBusy else { return }
        for package in packages { package.isSelected = true }
    }

    func selectNone() {
        guard !isBusy else { return }
        for package in packages { package.isSelected = false }
    }

    private func logOutput(name: String, line: String) {
        let trimmed = line.trimmed
        guard !trimmed.isEmpty, trimmed != lastOutputLine else { return }
        lastOutputLine = trimmed
        log("  \(name): \(trimmed)")
    }

    private func log(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }
}

extension Error {
    var userMessage: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return decodingDescription
    }
}
