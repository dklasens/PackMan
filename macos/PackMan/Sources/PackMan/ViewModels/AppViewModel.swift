import Foundation
import SwiftUI

@Observable
@MainActor
final class SourceOption: Identifiable {
    let source: any PackageSource
    var isEnabled: Bool
    var scanState: SourceScanState
    var toolContext: ToolContext?
    var probeIssue: SourceIssue?

    nonisolated var id: SourceID { source.id }
    var name: String { source.name }
    var descriptor: SourceDescriptor { source.descriptor }

    init(source: any PackageSource, isEnabled: Bool) {
        self.source = source
        self.isEnabled = isEnabled
        scanState = isEnabled ? .notScanned : .disabled
    }
}

private struct SourceOutcome: Sendable {
    enum Result: Sendable {
        case unavailable(SourceIssue)
        case report(SourceScanReport, ToolContext)
        case failed(SourceIssue)
        case cancelled
    }

    let source: any PackageSource
    let result: Result
}

private struct VerificationBatch {
    let source: any PackageSource
    let context: ToolContext
    let packages: [PackageUpdate]
}

private struct VerificationOutcome: Sendable {
    enum Result: Sendable {
        case verified([String: UpdateVerification])
        case failed(String)
        case cancelled
    }

    let sourceID: SourceID
    let result: Result
}

@Observable
@MainActor
final class AppViewModel {
    var packages: [PackageUpdate] = []
    var logEntries: [LogEntry] = []
    var operation: AppOperation = .idle
    var scanSummary: ScanSummary = .notStarted
    var updateSummary: UpdateRunSummary?
    var ignoredUpdates: [String] = []
    var sortOrder: [PackageSortComparator] = [
        PackageSortComparator(field: .source),
        PackageSortComparator(field: .name),
    ]
    var searchText = ""
    var isLogVisible = false

    let sourceOptions: [SourceOption]

    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var lastOutputByCommandAndStream: [String: String] = [:]
    @ObservationIgnored internal private(set) var startedOperations = 0
    @ObservationIgnored internal private(set) var completedOperations = 0

    private static let maxLogLines = 1000

    init(
        sources: [any PackageSource]? = nil,
        settings: any SettingsStoring = SettingsStore.shared
    ) {
        self.settings = settings
        let configuredSources = sources ?? [
            BrewSource(kind: .formula),
            BrewSource(kind: .cask),
            MasSource(),
            NpmSource(),
            PipSource(),
            PipxSource(),
            DotnetSource(),
        ]
        sourceOptions = configuredSources.map {
            SourceOption(source: $0, isEnabled: settings.isSourceEnabled($0.id))
        }
        ignoredUpdates = settings.ignoredUpdateKeys().sorted()
        if let issue = settings.loadIssue {
            appendLog(issue, level: .warning)
        }
    }

    var isBusy: Bool { operation.isBusy }
    var enabledSourceCount: Int { sourceOptions.filter(\.isEnabled).count }

    var filteredPackages: [PackageUpdate] {
        guard !searchText.trimmed.isEmpty else { return packages }
        let query = searchText.trimmed.lowercased()
        return packages.filter { package in
            package.name.lowercased().contains(query) ||
            package.packageID.lowercased().contains(query) ||
            package.source.lowercased().contains(query) ||
            package.currentVersion.lowercased().contains(query) ||
            package.availableVersion.lowercased().contains(query)
        }
    }

    var actionablePackages: [PackageUpdate] { filteredPackages.filter(\.isActionable) }
    var selectedPackages: [PackageUpdate] { actionablePackages.filter(\.isSelected) }
    var selectedCount: Int { selectedPackages.count }
    var updateCount: Int { actionablePackages.count }
    var canUpdate: Bool { !isBusy && selectedCount > 0 }
    var issueSources: [SourceOption] { sourceOptions.filter { $0.isEnabled && $0.scanState.hasIssue } }
    var hasIgnoredUpdates: Bool { !ignoredUpdates.isEmpty }
    var isSourcesSheetPresented = false

    var showsIssueBanner: Bool {
        switch scanSummary {
        case .completedWithIssues, .allUnavailable, .cancelled: return true
        default: return false
        }
    }

    var scanCompletedAt: Date? {
        switch scanSummary {
        case .updatesCompleted(let date), .upToDate(let date),
             .completedWithIssues(_, _, let date), .allUnavailable(let date), .cancelled(let date):
            return date
        default:
            return nil
        }
    }

    var footerStatusText: String {
        if showsIssueBanner, !isBusy, let completedAt = scanCompletedAt {
            return "Last scanned \(completedAt.formatted(date: .omitted, time: .shortened))."
        }
        return statusText
    }

    var statusText: String {
        switch operation {
        case .scanning(let completed, let total):
            return "Scanning sources (\(completed) of \(total))…"
        case .updating(let current, let completed, let total):
            if let current { return "Updating \(current) (\(completed + 1) of \(total))…" }
            return "Preparing updates…"
        case .clearingCache(let current, let completed, let total):
            if let current { return "Clearing cache for \(current) (\(completed + 1) of \(total))…" }
            return "Clearing caches…"
        case .cancelling:
            return "Cancelling…"
        case .idle:
            break
        }

        if let updateSummary, updateSummary.total > 0 {
            var parts: [String] = []
            if updateSummary.updated > 0 { parts.append(Self.count(updateSummary.updated, singular: "updated package", plural: "updated packages")) }
            if updateSummary.failed > 0 { parts.append(Self.count(updateSummary.failed, singular: "failure", plural: "failures")) }
            if updateSummary.verificationFailed > 0 { parts.append(Self.count(updateSummary.verificationFailed, singular: "verification issue", plural: "verification issues")) }
            if updateSummary.cancelled > 0 { parts.append(Self.count(updateSummary.cancelled, singular: "cancelled update", plural: "cancelled updates")) }
            return parts.joined(separator: ", ").capitalized + "."
        }

        switch scanSummary {
        case .notStarted: return "Ready to scan."
        case .running: return "Scanning…"
        case .updatesAvailable(let count): return Self.count(count, singular: "update available", plural: "updates available").capitalized + "."
        case .updatesCompleted: return "Selected updates completed."
        case .upToDate: return "System is up to date."
        case .completedWithIssues(let updates, let issues, _):
            return "Scan completed with \(Self.count(issues, singular: "issue", plural: "issues")) and \(Self.count(updates, singular: "update", plural: "updates"))."
        case .allUnavailable: return "No enabled sources could be scanned."
        case .noSources: return "No sources selected."
        case .cancelled: return "Scan cancelled; displayed results may be partial."
        }
    }

    var footerText: String {
        guard updateCount > 0 else { return "No actionable updates" }
        return "\(selectedCount) selected of \(updateCount)"
    }

    func startScan() {
        guard activeTask == nil else { return }
        let enabled = sourceOptions.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else {
            scanSummary = .noSources
            return
        }
        activeTask = Task { [weak self] in
            await self?.runScan(sourceIDs: Set(enabled), fresh: true)
        }
        startedOperations += 1
    }

    func retryIssues() {
        guard activeTask == nil else { return }
        let ids = Set(issueSources.map(\.id))
        guard !ids.isEmpty else { return }
        activeTask = Task { [weak self] in
            await self?.runScan(sourceIDs: ids, fresh: false)
        }
        startedOperations += 1
    }

    func cancelOperation() {
        guard let activeTask else { return }
        operation = .cancelling
        activeTask.cancel()
    }

    func startUpdateSelected() {
        startUpdate(packages: selectedPackages)
    }

    func startUpdateSingle(_ package: PackageUpdate) {
        guard package.isActionable else { return }
        startUpdate(packages: [package])
    }

    func startClearAllCaches() {
        guard activeTask == nil else { return }
        let enabledOptions = sourceOptions.filter(\.isEnabled)
        guard !enabledOptions.isEmpty else { return }
        activeTask = Task { [weak self] in
            await self?.runClearCaches(options: enabledOptions)
        }
        startedOperations += 1
    }

    func startClearCacheSingle(_ option: SourceOption) {
        guard activeTask == nil, option.isEnabled else { return }
        activeTask = Task { [weak self] in
            await self?.runClearCaches(options: [option])
        }
        startedOperations += 1
    }

    private func runClearCaches(options: [SourceOption]) async {
        isLogVisible = true
        appendLog("Cache cleanup started (\(options.map(\.name).joined(separator: ", "))).")
        operation = .clearingCache(current: nil, completed: 0, total: options.count)

        var completed = 0
        var succeededCount = 0
        var failedCount = 0
        var totalBytesFreed: Int64 = 0
        var processedToolIDs = Set<ToolID>()

        for option in options {
            if Task.isCancelled { break }
            operation = .clearingCache(current: option.name, completed: completed, total: options.count)

            let toolID = option.descriptor.toolID
            if options.count > 1 && processedToolIDs.contains(toolID) {
                completed += 1
                succeededCount += 1
                appendLog("\(option.name): cache cleanup already executed via \(toolID.rawValue).")
                continue
            }
            processedToolIDs.insert(toolID)

            let context: ToolContext?
            if let existingContext = option.toolContext ?? settings.cachedContext(for: option.id) {
                context = existingContext
            } else {
                let probe = await option.source.probe()
                if case .available(let probedContext) = probe {
                    context = probedContext
                    setSourceContext(probedContext, for: option.id)
                } else {
                    context = nil
                }
            }

            guard let context else {
                completed += 1
                failedCount += 1
                appendLog("\(option.name): cache clear skipped — tool executable not available.", level: .warning)
                continue
            }

            let sourceName = option.name
            let commandID = "clear-cache-\(option.id.rawValue)"
            do {
                let bytesFreed = try await option.source.clearCache(context: context) { [weak self] event in
                    await self?.appendOutput(commandID: commandID, scope: sourceName, event: event)
                }
                succeededCount += 1
                totalBytesFreed += bytesFreed
                if bytesFreed > 0 {
                    appendLog("\(option.name): cache cleared successfully (\(SourceSupport.formatBytes(bytesFreed)) freed).", level: .success)
                } else {
                    appendLog("\(option.name): cache cleared successfully.", level: .success)
                }
            } catch is CancellationError {
                appendLog("\(option.name): cache clear cancelled.", level: .warning)
                break
            } catch let error as ProcessError where error.isCancellation {
                appendLog("\(option.name): cache clear cancelled.", level: .warning)
                break
            } catch {
                failedCount += 1
                appendLog("\(option.name): cache clear failed — \(error.userMessage)", level: .error)
            }
            completed += 1
        }

        if Task.isCancelled {
            appendLog("Cache cleanup cancelled.", level: .warning)
        } else {
            let freedFormatted = SourceSupport.formatBytes(totalBytesFreed)
            appendLog("Cache cleanup completed (\(succeededCount) succeeded, \(failedCount) failed). Total space freed: \(freedFormatted).", level: failedCount > 0 ? .warning : .success)
        }

        operation = .idle
        activeTask = nil
        completedOperations += 1
    }

    func setSourceEnabled(_ option: SourceOption, enabled: Bool) {
        guard !isBusy else { return }
        do {
            try settings.setSource(option.id, enabled: enabled)
            option.isEnabled = enabled
            option.scanState = enabled ? .notScanned : .disabled
            option.toolContext = nil
            option.probeIssue = nil
            packages.removeAll { $0.sourceID == option.id }
            scanSummary = .notStarted
            updateSummary = nil
            applySort()
        } catch {
            appendLog("Could not save source settings: \(error.userMessage)", level: .error)
            isLogVisible = true
        }
    }

    func setExecutableOverride(_ path: String?, for toolID: ToolID) {
        guard !isBusy else { return }
        do {
            try settings.setExecutableOverride(path, for: toolID)
            for option in sourceOptions where option.descriptor.toolID == toolID {
                try settings.setCachedContext(nil, for: option.id)
                option.toolContext = nil
                option.probeIssue = nil
                option.scanState = option.isEnabled ? .notScanned : .disabled
                packages.removeAll { $0.sourceID == option.id }
            }
            scanSummary = .notStarted
            updateSummary = nil
            appendLog(path == nil ? "Using automatic discovery for \(toolID.rawValue)." : "Executable override saved for \(toolID.rawValue).")
        } catch {
            appendLog("Could not save executable setting: \(error.userMessage)", level: .error)
            isLogVisible = true
        }
    }

    func executableOverride(for toolID: ToolID) -> String? {
        settings.executableOverride(for: toolID)
    }

    func selectAll() {
        guard !isBusy else { return }
        for package in actionablePackages { package.isSelected = true }
    }

    func selectNone() {
        guard !isBusy else { return }
        for package in actionablePackages { package.isSelected = false }
    }

    func ignore(_ package: PackageUpdate, versionOnly: Bool) {
        guard !isBusy else { return }
        let key = Self.ignoreKey(for: package, versionOnly: versionOnly)
        do {
            try settings.setUpdateIgnored(key, ignored: true)
            if !ignoredUpdates.contains(key) {
                ignoredUpdates.append(key)
                ignoredUpdates.sort()
            }
            packages.removeAll { $0.id == package.id }
            appendLog("Ignored \(package.name)\(versionOnly ? " \(package.availableVersion)" : ""); it will stay hidden.")
            deriveScanSummary(completedAt: .now)
            applySort()
        } catch {
            appendLog("Could not save the ignore rule: \(error.userMessage)", level: .error)
            isLogVisible = true
        }
    }

    func removeIgnored(_ key: String) {
        guard !isBusy else { return }
        do {
            try settings.setUpdateIgnored(key, ignored: false)
            ignoredUpdates.removeAll { $0 == key }
            appendLog("Restored \(Self.displayName(forIgnoreKey: key)); it will appear after the next scan.")
        } catch {
            appendLog("Could not remove the ignore rule: \(error.userMessage)", level: .error)
            isLogVisible = true
        }
    }

    func clearLog() {
        logEntries.removeAll()
        lastOutputByCommandAndStream.removeAll()
    }

    func applySort() {
        packages = packages.sorted(using: sortOrder)
    }

    private func runScan(sourceIDs: Set<SourceID>, fresh: Bool) async {
        let options = sourceOptions.filter { sourceIDs.contains($0.id) && $0.isEnabled }
        guard !options.isEmpty else {
            activeTask = nil
            completedOperations += 1
            return
        }

        updateSummary = nil
        if fresh {
            packages.removeAll()
            for option in sourceOptions {
                option.scanState = option.isEnabled ? .waiting : .disabled
                option.toolContext = nil
                option.probeIssue = nil
            }
            appendLog("Scan started (\(options.map(\.name).joined(separator: ", "))).")
        } else {
            for option in options { option.scanState = .waiting }
            appendLog("Retrying sources with issues (\(options.map(\.name).joined(separator: ", "))).")
        }

        scanSummary = .running
        operation = .scanning(completed: 0, total: options.count)
        var completed = 0
        var wasCancelled = false
        let settingsStore = settings

        await withTaskGroup(of: SourceOutcome.self) { group in
            for option in options {
                let source = option.source
                let cachedContext = option.toolContext ?? settingsStore.cachedContext(for: option.id)
                group.addTask { [weak self] in
                    await self?.setSourceProbing(source.id)
                    if Task.isCancelled {
                        return SourceOutcome(source: source, result: .cancelled)
                    }
                    let probe: SourceProbe
                    if let cachedContext {
                        probe = .available(cachedContext)
                    } else {
                        probe = await source.probe()
                    }
                    if Task.isCancelled {
                        return SourceOutcome(source: source, result: .cancelled)
                    }
                    switch probe {
                    case .unavailable(let issue):
                        return SourceOutcome(source: source, result: .unavailable(issue))
                    case .available(let context):
                        await self?.setSourceContext(context, for: source.id)
                        do {
                            let report = try await source.scan(context: context) { [weak self] phase in
                                await self?.setSourcePhase(phase, for: source.id)
                            }
                            try Task.checkCancellation()
                            return SourceOutcome(source: source, result: .report(report, context))
                        } catch is CancellationError {
                            return SourceOutcome(source: source, result: .cancelled)
                        } catch let error as ProcessError where error.isCancellation {
                            return SourceOutcome(source: source, result: .cancelled)
                        } catch {
                            if cachedContext != nil {
                                await self?.clearCachedContext(for: source.id)
                            }
                            return SourceOutcome(source: source, result: .failed(SourceIssue(
                                kind: .command,
                                message: error.userMessage,
                                recovery: "Open the log for details and retry.")))
                        }
                    }
                }
            }

            for await outcome in group {
                completed += 1
                apply(outcome)
                if case .cancelled = outcome.result { wasCancelled = true }
                if operation != .cancelling {
                    operation = .scanning(completed: completed, total: options.count)
                }
            }
        }

        let completedAt = Date.now
        if wasCancelled || Task.isCancelled {
            scanSummary = .cancelled(completedAt)
            appendLog("Scan cancelled. Completed source results were preserved.", level: .warning)
        } else {
            deriveScanSummary(completedAt: completedAt)
            appendLog("Scan complete. \(Self.count(updateCount, singular: "update", plural: "updates")) found.")
        }
        applySort()
        operation = .idle
        activeTask = nil
        completedOperations += 1
    }

    private func apply(_ outcome: SourceOutcome) {
        guard let option = sourceOptions.first(where: { $0.id == outcome.source.id }) else { return }
        let now = Date.now
        switch outcome.result {
        case .unavailable(let issue):
            option.probeIssue = issue
            option.scanState = .unavailable(issue, completedAt: now)
            appendLog("\(option.name): unavailable — \(issue.message)", level: .warning)
        case .report(let report, let context):
            option.toolContext = context
            option.probeIssue = nil
            do {
                try settings.setCachedContext(context, for: option.id)
            } catch {
                appendLog("Could not save the \(option.name) tool cache: \(error.userMessage)", level: .warning)
            }
            replacePackages(for: outcome.source, context: context, with: report.updates)
            if report.issues.isEmpty {
                option.scanState = .succeeded(updateCount: report.updates.count, completedAt: now)
                appendLog("\(option.name): \(Self.count(report.updates.count, singular: "update", plural: "updates")).")
            } else {
                option.scanState = .partial(updateCount: report.updates.count, issues: report.issues, completedAt: now)
                appendLog("\(option.name): partial result — \(report.issues.map(\.message).joined(separator: "; "))", level: .warning)
                isLogVisible = true
            }
        case .failed(let issue):
            option.scanState = .failed(issue, completedAt: now)
            appendLog("\(option.name): scan failed — \(issue.message)", level: .error)
            isLogVisible = true
        case .cancelled:
            option.scanState = .cancelled(completedAt: now)
            appendLog("\(option.name): cancelled.", level: .warning)
        }
    }

    private func replacePackages(
        for source: any PackageSource,
        context: ToolContext,
        with infos: [PackageInfo]
    ) {
        packages.removeAll { $0.sourceID == source.id }
        let ignored = settings.ignoredUpdateKeys()
        let visible = infos.filter { info in
            !ignored.contains("\(source.id.rawValue):\(info.id)")
                && !ignored.contains("\(source.id.rawValue):\(info.id)@\(info.availableVersion)")
        }
        let hiddenCount = infos.count - visible.count
        if hiddenCount > 0 {
            appendLog("\(source.name): \(Self.count(hiddenCount, singular: "update", plural: "updates")) hidden by ignore rules.")
        }
        packages.append(contentsOf: visible.map { PackageUpdate(info: $0, source: source, context: context) })
        applySort()
    }

    private func deriveScanSummary(completedAt: Date) {
        let enabled = sourceOptions.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            scanSummary = .noSources
            return
        }
        if enabled.allSatisfy({ $0.scanState.isUnavailable }) {
            scanSummary = .allUnavailable(completedAt)
            return
        }
        let issueCount = enabled.reduce(0) { count, option in
            count + option.scanState.issues.count + (option.scanState.hasIssue && option.scanState.issues.isEmpty ? 1 : 0)
        }
        if issueCount > 0 {
            scanSummary = .completedWithIssues(updateCount: updateCount, issueCount: issueCount, completedAt: completedAt)
        } else if updateCount == 0 {
            scanSummary = .upToDate(completedAt)
        } else {
            scanSummary = .updatesAvailable(updateCount)
        }
    }

    private func startUpdate(packages selected: [PackageUpdate]) {
        guard activeTask == nil, !selected.isEmpty else { return }
        activeTask = Task { [weak self] in
            await self?.runUpdates(selected)
        }
        startedOperations += 1
    }

    private func runUpdates(_ selected: [PackageUpdate]) async {
        updateSummary = nil
        isLogVisible = true
        appendLog("Updating \(Self.count(selected.count, singular: "selected package", plural: "selected packages")).")
        operation = .updating(current: nil, completed: 0, total: selected.count)

        var summary = UpdateRunSummary()
        var completed = 0
        var cancelled = false
        let sourceOrder = sourceOptions.map(\.id)
        var verificationBatches: [VerificationBatch] = []

        for sourceID in sourceOrder {
            let sourcePackages = selected.filter { $0.sourceID == sourceID }
            guard !sourcePackages.isEmpty else { continue }
            guard let source = sourcePackages.first?.sourceRef,
                  let context = sourcePackages.first?.toolContext else { continue }

            var verificationPackages: [PackageUpdate] = []
            for package in sourcePackages {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                operation = .updating(current: package.name, completed: completed, total: selected.count)

                if package.status.needsVerificationOnly {
                    package.status = .verifying
                    verificationPackages.append(package)
                    continue
                }

                package.status = .updating
                let commandID = package.id
                let packageName = package.name
                lastOutputByCommandAndStream = lastOutputByCommandAndStream.filter { !$0.key.hasPrefix(commandID + "|") }
                do {
                    try await source.update(
                        request: package.updateRequest,
                        context: context
                    ) { [weak self] event in
                        await self?.appendOutput(commandID: commandID, scope: packageName, event: event)
                    }
                    package.status = .verifying
                    verificationPackages.append(package)
                } catch is CancellationError {
                    package.status = .cancelled
                    package.isSelected = true
                    summary.cancelled += 1
                    cancelled = true
                    break
                } catch let error as ProcessError where error.isCancellation {
                    package.status = .cancelled
                    package.isSelected = true
                    summary.cancelled += 1
                    cancelled = true
                    break
                } catch {
                    package.status = .failed(.update, error.userMessage)
                    package.isSelected = true
                    summary.failed += 1
                    completed += 1
                    appendLog("\(package.name): update failed — \(error.userMessage)", level: .error)
                }
                applySort()
            }

            if !verificationPackages.isEmpty {
                verificationBatches.append(VerificationBatch(
                    source: source,
                    context: context,
                    packages: verificationPackages))
            }

            applySort()
            if cancelled { break }
        }

        if !verificationBatches.isEmpty {
            operation = .updating(current: nil, completed: completed, total: selected.count)
        }
        let verificationOutcomes = await withTaskGroup(
            of: VerificationOutcome.self,
            returning: [SourceID: VerificationOutcome.Result].self
        ) { group in
            for batch in verificationBatches {
                let source = batch.source
                let context = batch.context
                let requests = batch.packages.map(\.updateRequest)
                group.addTask {
                    do {
                        let results = try await source.verify(requests: requests, context: context)
                        return VerificationOutcome(sourceID: source.id, result: .verified(results))
                    } catch is CancellationError {
                        return VerificationOutcome(sourceID: source.id, result: .cancelled)
                    } catch let error as ProcessError where error.isCancellation {
                        return VerificationOutcome(sourceID: source.id, result: .cancelled)
                    } catch {
                        return VerificationOutcome(sourceID: source.id, result: .failed(error.userMessage))
                    }
                }
            }

            var results: [SourceID: VerificationOutcome.Result] = [:]
            for await outcome in group { results[outcome.sourceID] = outcome.result }
            return results
        }

        var removeIDs = Set<String>()
        for batch in verificationBatches {
            let outcome = verificationOutcomes[batch.source.id]
            for package in batch.packages {
                switch outcome {
                case .verified(let results):
                    switch results[package.packageID] {
                    case .satisfied(let installedVersion):
                        if let installedVersion { package.currentVersion = installedVersion }
                        package.isSelected = false
                        removeIDs.insert(package.id)
                        summary.updated += 1
                        appendLog("\(package.name) updated to \(package.currentVersion).", level: .success)
                    case .stillOutdated(let info):
                        package.currentVersion = info.currentVersion
                        package.availableVersion = info.availableVersion
                        package.status = .failed(.update, "The package is still outdated after the update command completed.")
                        package.isSelected = true
                        summary.failed += 1
                        appendLog("\(package.name) is still outdated after updating.", level: .error)
                    case nil:
                        package.status = .failed(.verification, "The source did not return a verification result.")
                        package.isSelected = true
                        summary.verificationFailed += 1
                    }
                case .cancelled:
                    package.status = .failed(
                        .verification,
                        "Verification was cancelled after the update command completed. Retry to verify it.")
                    package.isSelected = true
                    summary.verificationFailed += 1
                    cancelled = true
                case .failed(let message):
                    package.status = .failed(
                        .verification,
                        "The update command completed, but verification failed: \(message)")
                    package.isSelected = true
                    summary.verificationFailed += 1
                case nil:
                    package.status = .failed(.verification, "The source did not return a verification outcome.")
                    package.isSelected = true
                    summary.verificationFailed += 1
                }
                completed += 1
            }

            switch outcome {
            case .cancelled:
                appendLog("\(batch.source.name): update verification cancelled.", level: .warning)
            case .failed(let message):
                appendLog("\(batch.source.name): update verification failed — \(message)", level: .error)
            default:
                break
            }
        }
        packages.removeAll { removeIDs.contains($0.id) }
        applySort()

        updateSummary = summary
        if updateCount == 0 && issueSources.isEmpty {
            scanSummary = .updatesCompleted(.now)
        } else if issueSources.isEmpty {
            scanSummary = .updatesAvailable(updateCount)
        } else {
            let issueCount = issueSources.reduce(0) { $0 + max(1, $1.scanState.issues.count) }
            scanSummary = .completedWithIssues(updateCount: updateCount, issueCount: issueCount, completedAt: .now)
        }
        if cancelled || Task.isCancelled {
            appendLog("Update run cancelled. Unverified packages remain selected and retryable.", level: .warning)
        } else {
            appendLog("Update run finished.", level: summary.failed + summary.verificationFailed > 0 ? .warning : .success)
        }
        operation = .idle
        activeTask = nil
        completedOperations += 1
    }

    private func setSourceProbing(_ id: SourceID) {
        sourceOptions.first(where: { $0.id == id })?.scanState = .probing(startedAt: .now)
    }

    private func setSourceContext(_ context: ToolContext, for id: SourceID) {
        guard let option = sourceOptions.first(where: { $0.id == id }) else { return }
        option.toolContext = context
        option.probeIssue = nil
    }

    private func clearCachedContext(for id: SourceID) {
        sourceOptions.first(where: { $0.id == id })?.toolContext = nil
        do {
            try settings.setCachedContext(nil, for: id)
        } catch {
            appendLog("Could not clear a stale tool cache: \(error.userMessage)", level: .warning)
        }
    }

    private func setSourcePhase(_ phase: SourcePhase, for id: SourceID) {
        guard let option = sourceOptions.first(where: { $0.id == id }) else { return }
        let startedAt: Date
        switch option.scanState {
        case .probing(let date), .scanning(_, let date): startedAt = date
        default: startedAt = .now
        }
        option.scanState = .scanning(phase: phase, startedAt: startedAt)
    }

    private func appendOutput(commandID: String, scope: String, event: ProcessOutputEvent) {
        let trimmed = event.line.terminalSanitized.trimmed
        guard !trimmed.isEmpty else { return }
        let key = "\(commandID)|\(event.stream.rawValue)"
        guard lastOutputByCommandAndStream[key] != trimmed else { return }
        lastOutputByCommandAndStream[key] = trimmed
        appendLog(trimmed, level: .output, scope: scope, stream: event.stream)
    }

    private func appendLog(
        _ message: String,
        level: LogEntry.Level = .info,
        scope: String? = nil,
        stream: ProcessOutputStream? = nil
    ) {
        nextLogID += 1
        logEntries.append(LogEntry(
            id: nextLogID,
            timestamp: .now,
            level: level,
            scope: scope,
            stream: stream,
            message: message.terminalSanitized))
        if logEntries.count > Self.maxLogLines {
            logEntries.removeFirst(logEntries.count - Self.maxLogLines)
        }
    }

    private static func count(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private static func ignoreKey(for package: PackageUpdate, versionOnly: Bool) -> String {
        let packageKey = "\(package.sourceID.rawValue):\(package.packageID)"
        return versionOnly ? "\(packageKey)@\(package.availableVersion)" : packageKey
    }

    static var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        return "1.7.2"
    }

    static func displayName(forIgnoreKey key: String) -> String {
        guard let separator = key.firstIndex(of: ":") else { return key }
        let source = String(key[..<separator])
        let package = String(key[key.index(after: separator)...])
        let sourceName: String
        switch SourceID(rawValue: source) {
        case .homebrew: sourceName = "Homebrew"
        case .homebrewCasks: sourceName = "Homebrew Casks"
        case .appStore: sourceName = "App Store"
        case .npm: sourceName = "npm"
        case .pip: sourceName = "pip"
        case .pipx: sourceName = "pipx"
        case .dotnet: sourceName = ".NET Tools"
        case nil: sourceName = source
        }
        return "\(package) (\(sourceName))"
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
