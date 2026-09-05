import AppKit
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
    var environmentDescription: String?

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
    var sourceFilter: SourceID?
    var statusFilter: PackageStatusFilter = .all
    var detailPackage: PackageUpdate?
    var isHistoryPresented = false
    var isCachePresented = false
    var selectedCacheSources = Set<SourceID>()
    var cachePreviews: [CachePreview] = []
    var cacheResults: [SourceID: String] = [:]
    var includeNugetGlobalPackages = false
    var confirmCacheCleanup: ([CachePreview]) -> Bool = AppViewModel.confirmCacheAlert
    @ObservationIgnored private let cacheInspector: any CacheInspecting
    var history: [UpdateHistoryEntry] = []
    var diagnosticsPreview: String?
    var lastScanDate: Date?
    var sourceSetupSuggested = false
    var includeSelfUpdatingCasks = false
    var hasProbedSources = false
    @ObservationIgnored private let brewInventory = BrewInventory()
    @ObservationIgnored private var forceMetadataRefresh = false
    var ignoredCounts: [SourceID: Int] = [:]
    var skippedCounts: [SourceID: Int] = [:]
    @ObservationIgnored private let historyStore: any UpdateHistoryStoring
    var isLogVisible = false
    var availableUpdate: AppUpdateInfo?
    var confirmAppUpdate: (String) -> Bool = AppViewModel.confirmInstallAlert
    var terminateAfterStagingUpdate: () -> Void = { NSApplication.shared.terminate(nil) }

    let sourceOptions: [SourceOption]

    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let updater: (any AppUpdateChecking)?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var lastOutputByCommandAndStream: [String: String] = [:]
    @ObservationIgnored private var isCheckingForUpdates = false
    @ObservationIgnored internal private(set) var startedOperations = 0
    @ObservationIgnored internal private(set) var completedOperations = 0

    private static let maxLogLines = 1000

    init(
        sources: [any PackageSource]? = nil,
        settings: any SettingsStoring = SettingsStore.shared,
        updater: (any AppUpdateChecking)? = nil,
        historyStore: (any UpdateHistoryStoring)? = nil,
        cacheInspector: any CacheInspecting = CacheInspector()
    ) {
        self.settings = settings
        self.cacheInspector = cacheInspector
        self.historyStore = historyStore ?? UpdateHistoryStore(url: sources == nil ? UpdateHistoryStore.defaultURL : nil)
        self.history = self.historyStore.read()
        self.updater = updater ?? AppUpdateService(settings: settings)
        let configuredSources = sources ?? [
            BrewSource(kind: .formula, inventory: brewInventory, settings: settings),
            BrewSource(kind: .cask, inventory: brewInventory, settings: settings),
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
        sourceSetupSuggested = !settings.hasCompletedSourceSetup()
        includeSelfUpdatingCasks = settings.includesSelfUpdatingCasks()
        if let issue = self.historyStore.loadIssue { appendLog(issue, level: .warning) }
        if let issue = settings.loadIssue {
            appendLog(issue, level: .warning)
        }
    }

    var isBusy: Bool { operation.isBusy || activeTask != nil }
    var enabledSourceCount: Int { sourceOptions.filter(\.isEnabled).count }

    var filteredPackages: [PackageUpdate] {
        let query = searchText.trimmed.lowercased()
        return packages.filter { package in
            (sourceFilter == nil || package.sourceID == sourceFilter) && statusFilter.matches(package) &&
            (query.isEmpty || [package.name, package.packageID, package.source, package.currentVersion, package.availableVersion]
                .contains { $0.lowercased().contains(query) })
        }
    }

    var actionablePackages: [PackageUpdate] { packages.filter(\.isActionable) }
    var visibleActionablePackages: [PackageUpdate] { filteredPackages.filter(\.isActionable) }
    var selectedPackages: [PackageUpdate] { visibleActionablePackages.filter(\.isSelected) }
    var selectedCount: Int { selectedPackages.count }
    var totalSelectedCount: Int { actionablePackages.filter(\.isSelected).count }
    var updateCount: Int { actionablePackages.count }
    var manualCount: Int { packages.filter(\.isManual).count }
    var ignoredCount: Int { ignoredCounts.values.reduce(0, +) }
    var skippedCount: Int { skippedCounts.values.reduce(0, +) }
    var detectedCount: Int { packages.count + ignoredCount }
    var canUpdate: Bool { !isBusy && selectedCount > 0 }
    var issueSources: [SourceOption] { sourceOptions.filter { $0.isEnabled && $0.scanState.hasIssue } }
    var hasIgnoredUpdates: Bool { !ignoredUpdates.isEmpty }
    var isSourcesSheetPresented = false
    var showsAppUpdateBanner: Bool { availableUpdate != nil }
    var canInstallAppUpdate: Bool { !isBusy && availableUpdate != nil }
    var appUpdateText: String {
        guard let availableUpdate else { return "" }
        return "PackMan \(availableUpdate.version) is available (you have \(Self.appVersion))."
    }

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
            return lastScanDate
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
        case .updatingApp(let version):
            return "Installing PackMan \(version)…"
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
            if updateSummary.verified > 0 { parts.append("\(updateSummary.verified) verified") }
            if updateSummary.notStarted > 0 { parts.append("\(updateSummary.notStarted) not started") }
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
        case .upToDate: return detectedCount > 0 ? "No automatic updates pending; \(ignoredCount) ignored, \(manualCount) manual." : "No updates found in the sources checked."
        case .completedWithIssues(let updates, let issues, _):
            return "Scan completed with \(Self.count(issues, singular: "issue", plural: "issues")) and \(Self.count(updates, singular: "update", plural: "updates"))."
        case .allUnavailable: return "No enabled sources could be scanned."
        case .noSources: return "No sources selected."
        case .cancelled: return "Scan cancelled; displayed results may be partial."
        }
    }

    var footerText: String {
        "\(selectedCount) visible selected · \(totalSelectedCount) selected total · \(updateCount) automatic · \(manualCount) manual · \(ignoredCount) ignored · \(skippedCount) skipped"
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
        guard !isBusy else { return }
        selectedCacheSources = Set(sourceOptions.filter { $0.isEnabled && $0.id != .appStore }.map(\.id))
        cachePreviews = []; cacheResults = [:]; isCachePresented = true
    }

    func startClearCacheSingle(_ option: SourceOption) {
        guard !isBusy else { return }
        selectedCacheSources = [option.id]
        cachePreviews = []; cacheResults = [:]; isCachePresented = true
    }

    func startCachePreview(clearAfterConfirmation: Bool = false) {
        guard !isBusy, !selectedCacheSources.isEmpty else { return }
        let ids = selectedCacheSources
        let includeGlobal = includeNugetGlobalPackages
        activeTask = Task { [weak self] in
            await self?.runCachePreview(ids: ids, includeGlobal: includeGlobal, clearAfterConfirmation: clearAfterConfirmation)
        }
        startedOperations += 1
    }

    private func runCachePreview(ids: Set<SourceID>, includeGlobal: Bool, clearAfterConfirmation: Bool) async {
        operation = .clearingCache(current: "Preview", completed: 0, total: ids.count)
        defer { operation = .idle; activeTask = nil; completedOperations += 1 }
        cachePreviews = []; cacheResults = [:]
        var shared: [String: CachePreview] = [:]
        for option in sourceOptions where ids.contains(option.id) {
            if Task.isCancelled { return }
            do {
                guard case .available(let context) = await option.source.probe() else {
                    throw SourceError.commandFailed("Manager unavailable. Recheck availability in Sources.")
                }
                let key = option.descriptor.toolID.rawValue + "|" + context.installationKey
                var preview: CachePreview
                if let existing = shared[key] {
                    preview = existing; preview.sourceID = option.id; preview.sourceName = option.name
                    preview.scope += " Shared with another selected source; cleaned once."
                } else {
                    preview = try await cacheInspector.preview(source: option.source, context: context, includeGlobalPackages: includeGlobal)
                    shared[key] = preview
                }
                cachePreviews.append(preview)
            } catch {
                if Task.isCancelled { return }
                cachePreviews.append(CachePreview(sourceID: option.id, sourceName: option.name,
                    scope: CacheInspector.scope(option.id, includeGlobalPackages: includeGlobal), issue: error.userMessage))
            }
        }
        guard clearAfterConfirmation, !Task.isCancelled else { return }
        let available = cachePreviews.filter { $0.supported && $0.issue == nil }
        guard !available.isEmpty, confirmCacheCleanup(cachePreviews), !Task.isCancelled else { return }
        var resultsByTool: [String: String] = [:]
        for preview in cachePreviews {
            if Task.isCancelled { cacheResults[preview.id] = "Not started — cancelled"; continue }
            guard preview.supported, preview.issue == nil, let context = preview.context else {
                cacheResults[preview.id] = preview.issue ?? "Managed by macOS"; continue
            }
            let tool = sourceOptions.first { $0.id == preview.id }!.descriptor.toolID
            let key = tool.rawValue + "|" + context.installationKey
            if let result = resultsByTool[key] { cacheResults[preview.id] = "Shared cleanup: " + result; continue }
            operation = .clearingCache(current: preview.sourceName, completed: cacheResults.count, total: cachePreviews.count)
            let message: String
            do {
                try await cacheInspector.clear(preview, includeGlobalPackages: includeGlobal) { [weak self] event in
                    await self?.appendOutput(commandID: "cache-\(preview.id.rawValue)", scope: preview.sourceName, event: event)
                }
                let after = try await CacheInspector.measure(preview.paths)
                if let before = preview.bytes, preview.measurementComplete && after.complete {
                    message = "Cleared; measured cache reduction \(SourceSupport.formatBytes(max(0, before - after.bytes)))."
                } else { message = "Cleanup completed; space reclaimed was not fully measurable." }
            } catch {
                message = Task.isCancelled ? "Cancelled; some files may already have been removed." : "Failed: \(error.userMessage)"
            }
            resultsByTool[key] = message; cacheResults[preview.id] = message
            appendLog("\(preview.sourceName): \(message)")
        }
    }

    private static func confirmCacheAlert(_ previews: [CachePreview]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Clear the selected caches?"
        alert.informativeText = previews.map { "\($0.sourceName): \($0.issue ?? $0.scope)\n\($0.paths.joined(separator: "\n"))\n\($0.sizeText)" }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Clear Selected"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func refreshMetadataAndScan() {
        guard !isBusy else { return }
        forceMetadataRefresh = true
        startScan()
    }

    func setCaskPolicy(_ enabled: Bool) {
        guard !isBusy else { return }
        do {
            try settings.setIncludesSelfUpdatingCasks(enabled)
            includeSelfUpdatingCasks = enabled
            packages.removeAll { $0.sourceID == .homebrewCasks }
            scanSummary = .notStarted
        } catch { appendLog("Could not save cask policy: \(error.userMessage)", level: .error) }
    }

    func recheckSources() {
        guard !isBusy else { return }
        activeTask = Task { [weak self] in await self?.probeSources() }
        startedOperations += 1
    }

    private func probeSources() async {
        operation = .scanning(completed: 0, total: sourceOptions.count)
        defer { operation = .idle; activeTask = nil; completedOperations += 1 }
        for option in sourceOptions {
            if Task.isCancelled { break }
            try? settings.setCachedContext(nil, for: option.id)
            switch await option.source.probe() {
            case .available(let context):
                option.toolContext = context; option.probeIssue = nil
                option.scanState = option.isEnabled ? .notScanned : .disabled
                try? settings.setCachedContext(context, for: option.id)
                option.environmentDescription = await SourceEnvironmentInspector.describe(option.id, context: context)
            case .unavailable(let issue):
                option.toolContext = nil; option.probeIssue = issue
                option.scanState = option.isEnabled ? .unavailable(issue, completedAt: .now) : .disabled
            }
        }
        hasProbedSources = !Task.isCancelled
    }

    func useDetectedSources() {
        guard !isBusy, hasProbedSources else { return }
        for option in sourceOptions { setSourceEnabled(option, enabled: option.toolContext != nil) }
        hasProbedSources = false
        finishSourceSetup()
    }

    func finishSourceSetup() {
        do { try settings.setSourceSetupCompleted(); sourceSetupSuggested = false }
        catch { appendLog("Could not save source setup: \(error.userMessage)", level: .error) }
    }

    func beginStartupUpdateCheck() {
        if sourceSetupSuggested { isSourcesSheetPresented = true; recheckSources() }
        if let notice = try? String(contentsOf: UpdateApplier.resultLogURL, encoding: .utf8), !notice.isEmpty {
            appendLog("Previous self-update: " + notice, level: notice.contains("failed") || notice.contains("aborted") ? .warning : .info)
        }
        Task { await checkForAppUpdates(force: false) }
    }

    func checkForUpdates() {
        Task { await checkForAppUpdates(force: true) }
    }

    func installAvailableUpdate() {
        guard let update = availableUpdate, updater != nil, !isBusy else { return }
        let message = "Download and install PackMan \(update.version)?\n\n"
            + "PackMan closes while the update is applied and restarts automatically."
        guard confirmAppUpdate(message) else { return }
        activeTask = Task { [weak self] in
            await self?.runAppUpdate(update)
        }
        startedOperations += 1
    }

    func skipAvailableUpdate() {
        guard let update = availableUpdate else { return }
        do {
            try settings.setSkippedAppUpdateVersion(update.version)
            try settings.setAvailableAppUpdate(nil)
            appendLog("PackMan \(update.version) will not be offered again.")
            availableUpdate = nil
        } catch {
            appendLog("Could not save the skipped version: \(error.userMessage)", level: .error)
        }
    }

    func dismissAvailableUpdate() {
        availableUpdate = nil
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
            ignoredCounts[option.id] = 0
            skippedCounts[option.id] = 0
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
        for package in visibleActionablePackages { package.isSelected = true }
    }

    func selectNone() {
        guard !isBusy else { return }
        for package in visibleActionablePackages { package.isSelected = false }
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
            ignoredCounts[package.sourceID, default: 0] += 1
            packages.removeAll { $0.id == package.id }
            appendLog("Ignored \(package.name)\(versionOnly ? " \(package.availableVersion)" : ""); it will stay hidden.")
            deriveScanSummary(completedAt: lastScanDate ?? .now)
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

        await brewInventory.beginScan()
        if forceMetadataRefresh { await BrewRefresh.shared.invalidate(); forceMetadataRefresh = false }
        updateSummary = nil
        if fresh {
            ignoredCounts.removeAll()
            skippedCounts.removeAll()
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
        lastScanDate = completedAt
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
            skippedCounts[option.id] = report.skippedCount
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
        ignoredCounts[source.id] = hiddenCount
        if hiddenCount > 0 {
            appendLog("\(source.name): \(Self.count(hiddenCount, singular: "update", plural: "updates")) hidden by ignore rules.")
        }
        let grouped = Dictionary(grouping: visible, by: \.id)
        packages.append(contentsOf: grouped.values.map { group in
            var info = group[0]
            if group.count > 1 { info.isIdentityAmbiguous = true; info.statusMessage = "Multiple source records share this identity; verify before updating." }
            let package = PackageUpdate(info: info, source: source, context: context)
            if group.count > 1 { package.isSelected = false }
            return package
        })
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
        } else if detectedCount == 0 && skippedCount == 0 {
            scanSummary = .upToDate(completedAt)
        } else {
            scanSummary = .updatesAvailable(packages.count)
        }
    }

    private func startUpdate(packages selected: [PackageUpdate], verificationOnly: Bool = false) {
        guard activeTask == nil, !selected.isEmpty else { return }
        activeTask = Task { [weak self] in
            await self?.runUpdates(selected, verificationOnly: verificationOnly)
        }
        startedOperations += 1
    }

    func startVerify(_ package: PackageUpdate) {
        guard !isBusy else { return }
        startUpdate(packages: [package], verificationOnly: true)
    }

    func previewDiagnostics() {
        do { diagnosticsPreview = try DiagnosticRedactor.export(history: history, log: logEntries) }
        catch { appendLog("Could not prepare diagnostics: \(error.userMessage)", level: .error) }
    }

    func recoverHistory(_ entry: UpdateHistoryEntry, verifyOnly: Bool) {
        guard !isBusy, let source = sourceOptions.first(where: { $0.id == entry.sourceID })?.source else { return }
        let context = ToolContext(executablePath: entry.toolPath, version: "", pathEntries: [], origin: .knownPath)
        let row = packages.first(where: { $0.sourceID == entry.sourceID && $0.packageID == entry.packageID }) ??
            PackageUpdate(info: PackageInfo(id: entry.packageID, name: entry.name, currentVersion: entry.installedVersion ?? entry.beforeVersion,
                availableVersion: entry.targetVersion, registryID: entry.registryID), source: source, context: context)
        if !packages.contains(where: { $0.id == row.id }) { packages.append(row) }
        if !verifyOnly && row.isManual { detailPackage = row; return }
        startUpdate(packages: [row], verificationOnly: verifyOnly)
    }

    func recordExternalAction(_ package: PackageUpdate) {
        guard !isBusy else { return }
        let entry = UpdateHistoryEntry(runID: UUID(), sourceID: package.sourceID, packageID: package.packageID,
            registryID: package.registryID, name: package.name, beforeVersion: package.currentVersion,
            targetVersion: package.availableVersion, outcome: .external, toolPath: package.toolContext.executablePath,
            evidence: "Handed off to the user. No installed version has been verified.")
        _ = saveHistory([entry])
    }

    @discardableResult
    private func saveHistory(_ entries: [UpdateHistoryEntry]) -> Bool {
        do {
            try historyStore.save(entries)
            history = historyStore.read()
            return true
        } catch {
            appendLog("Could not save update history: \(error.userMessage)", level: .error)
            isLogVisible = true
            return false
        }
    }

    func cancelAndWait() async {
        guard let task = activeTask else { return }
        cancelOperation()
        await task.value
    }

    private func runUpdates(_ selected: [PackageUpdate], verificationOnly: Bool) async {
        updateSummary = nil
        isLogVisible = true
        operation = .updating(current: nil, completed: 0, total: selected.count)
        defer { operation = .idle; activeTask = nil; completedOperations += 1 }
        let runID = UUID()
        var attempts = Dictionary(selected.map { package in
            let entry = UpdateHistoryEntry(runID: runID, sourceID: package.sourceID, packageID: package.packageID,
                registryID: package.registryID, name: package.name, beforeVersion: package.currentVersion,
                targetVersion: package.availableVersion, toolPath: package.toolContext.executablePath, verificationOnly: verificationOnly)
            package.attemptID = entry.id
            package.output = ""
            return (package.id, entry)
        }, uniquingKeysWith: { first, _ in first })
        guard saveHistory(Array(attempts.values)) else { return }
        appendLog("\(verificationOnly ? "Verifying" : "Updating") \(selected.count) selected package(s).")
        var summary = UpdateRunSummary()
        var completed = 0
        var batches: [VerificationBatch] = []
        var stop = false

        for option in sourceOptions {
            let rows = selected.filter { $0.sourceID == option.id }
            guard !rows.isEmpty, !Task.isCancelled, !stop else { continue }
            // Reprobe at the operation boundary: a history entry or scan may hold
            // a now-replaced manager or obsolete npm/mas version.
            guard case .available(let context) = await option.source.probe() else {
                for row in rows {
                    row.status = .failed(.update, "The selected manager is unavailable. Recheck it in Sources.")
                    attempts[row.id]?.outcome = .failed
                    attempts[row.id]?.evidence = row.statusMessage ?? "Manager unavailable."
                    attempts[row.id]?.finishedAt = .now
                    summary.failed += 1
                }
                stop = !saveHistory(rows.compactMap { attempts[$0.id] })
                continue
            }
            setSourceContext(context, for: option.id)
            var verifyRows: [PackageUpdate] = []
            for row in rows {
                row.toolContext = context
                guard !Task.isCancelled, !stop else { break }
                operation = .updating(current: row.name, completed: completed, total: selected.count)
                attempts[row.id]?.toolPath = context.executablePath
                attempts[row.id]?.outcome = .running
                guard saveHistory([attempts[row.id]!]) else {
                    attempts[row.id]?.outcome = .queued
                    stop = true
                    break
                }
                row.status = verificationOnly ? .verifying : .updating
                row.verificationEvidence = nil
                let commandID = row.attemptID!.uuidString
                do {
                    if !verificationOnly {
                        try await option.source.update(request: row.updateRequest, context: context) { [weak self, weak row] event in
                            await self?.appendPackageOutput(row, commandID: commandID, event: event)
                        }
                        // Invalidate all cached capabilities after mutation, including
                        // package managers which were themselves updated by another manager.
                        for sourceOption in sourceOptions { try? settings.setCachedContext(nil, for: sourceOption.id) }
                    }
                    row.status = .verifying
                    verifyRows.append(row)
                    attempts[row.id]?.outcome = .unverified
                    attempts[row.id]?.evidence = "Installed state has not yet been verified."
                } catch {
                    let cancelled = Task.isCancelled || (error as? ProcessError)?.isCancellation == true || error is CancellationError
                    row.status = cancelled ? .cancelled : .failed(.update, error.userMessage)
                    row.isSelected = !row.isManual
                    attempts[row.id]?.outcome = cancelled ? .cancelled : .failed
                    attempts[row.id]?.evidence = cancelled ? "Command cancelled; package changes may already have occurred. Verify before retrying." : error.userMessage
                    attempts[row.id]?.finishedAt = .now
                    if cancelled { summary.cancelled += 1 } else { summary.failed += 1 }
                    appendLog("\(row.name): \(attempts[row.id]!.evidence)", level: .warning)
                }
                attempts[row.id]?.output = row.output
                stop = !saveHistory([attempts[row.id]!])
                completed += 1
                applySort()
            }
            if !verifyRows.isEmpty { batches.append(VerificationBatch(source: option.source, context: context, packages: verifyRows)) }
        }

        let outcomes = await withTaskGroup(of: VerificationOutcome.self, returning: [SourceID: VerificationOutcome.Result].self) { group in
            for batch in batches {
                let source = batch.source, context = batch.context, requests = batch.packages.map(\.updateRequest)
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return VerificationOutcome(sourceID: source.id, result: .verified(try await source.verify(requests: requests, context: context)))
                    } catch {
                        if Task.isCancelled || error is CancellationError || (error as? ProcessError)?.isCancellation == true {
                            return VerificationOutcome(sourceID: source.id, result: .cancelled)
                        }
                        return VerificationOutcome(sourceID: source.id, result: .failed(error.userMessage))
                    }
                }
            }
            var results: [SourceID: VerificationOutcome.Result] = [:]
            for await outcome in group { results[outcome.sourceID] = outcome.result }
            return results
        }
        var removeIDs = Set<String>()
        for batch in batches {
            for row in batch.packages {
                let result: UpdateVerification
                switch outcomes[batch.source.id] {
                case .verified(let results): result = results[row.packageID] ?? .inconclusive(installedVersion: nil, evidence: "No verification result returned.")
                case .failed(let message): result = .inconclusive(installedVersion: nil, evidence: message)
                case .cancelled: result = .inconclusive(installedVersion: nil, evidence: "Verification was cancelled. Verify again before retrying installation.")
                case nil: result = .inconclusive(installedVersion: nil, evidence: "No verification outcome returned.")
                }
                row.verificationEvidence = result.evidence
                if let installed = result.installedVersion { row.currentVersion = installed }
                attempts[row.id]?.installedVersion = result.installedVersion
                attempts[row.id]?.evidence = result.evidence
                attempts[row.id]?.finishedAt = .now
                switch result {
                case .satisfied(let installed) where installed != nil:
                    row.status = .completed(verificationOnly: verificationOnly)
                    row.isSelected = false
                    removeIDs.insert(row.id)
                    attempts[row.id]?.outcome = verificationOnly ? .verified : .updated
                    if verificationOnly { summary.verified += 1 } else { summary.updated += 1 }
                    appendLog("\(row.name): \(verificationOnly ? "verified" : "updated") at \(installed!).", level: .success)
                case .stillOutdated(let info):
                    row.availableVersion = info.availableVersion
                    row.status = .failed(.update, result.evidence)
                    row.isSelected = !row.isManual
                    attempts[row.id]?.outcome = .failed
                    summary.failed += 1
                default:
                    row.status = .failed(.verification, result.evidence)
                    row.isSelected = !row.isManual
                    attempts[row.id]?.outcome = .unverified
                    summary.verificationFailed += 1
                }
            }
        }
        for row in selected where attempts[row.id]?.outcome == .queued {
            attempts[row.id]?.outcome = .notStarted
            attempts[row.id]?.finishedAt = .now
            attempts[row.id]?.evidence = "The run stopped before this package was started."
            summary.notStarted += 1
        }
        _ = saveHistory(Array(attempts.values))
        packages.removeAll { removeIDs.contains($0.id) }
        applySort()
        updateSummary = summary
        deriveScanSummary(completedAt: lastScanDate ?? .now)
        if packages.isEmpty && ignoredCount == 0 && issueSources.isEmpty { scanSummary = .updatesCompleted(.now) }
        appendLog("Run finished: \(summary.updated) updated, \(summary.verified) verified, \(summary.failed) failed, \(summary.verificationFailed) unverified, \(summary.cancelled) cancelled, \(summary.notStarted) not started.")
    }

    private func appendPackageOutput(_ package: PackageUpdate?, commandID: String, event: ProcessOutputEvent) {
        guard let package else { return }
        package.output = UpdateHistoryStore.bounded(package.output + "[\(event.stream.rawValue)] \(event.line.terminalSanitized)\n")
        appendOutput(commandID: commandID, scope: package.name, event: event)
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

    nonisolated static var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        return "Development"
    }

    private func checkForAppUpdates(force: Bool) async {
        guard let updater, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            if let update = try await updater.check(force: force) {
                availableUpdate = update
                appendLog("PackMan \(update.version) is available; use the banner to install it.", level: .success)
            } else if force {
                appendLog("PackMan is up to date.")
            }
        } catch {
            if force {
                appendLog("Update check failed — \(error.userMessage)", level: .warning)
            }
        }
    }

    private func runAppUpdate(_ update: AppUpdateInfo) async {
        guard let updater else {
            operation = .idle
            activeTask = nil
            completedOperations += 1
            return
        }
        isLogVisible = true
        operation = .updatingApp(version: update.version)
        appendLog("Updating PackMan to \(update.version).")
        do {
            try await updater.apply(update) { [weak self] message in
                Task { @MainActor in
                    self?.appendLog(message)
                }
            }
            appendLog("PackMan \(update.version) is staged; restarting…", level: .success)
            operation = .idle
            activeTask = nil
            terminateAfterStagingUpdate()
        } catch is CancellationError {
            appendLog("The PackMan update was cancelled.", level: .warning)
        } catch {
            appendLog("The PackMan update failed — \(error.userMessage)", level: .error)
        }
        operation = .idle
        activeTask = nil
        completedOperations += 1
    }

    private static func confirmInstallAlert(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install PackMan Update"
        alert.informativeText = message
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
