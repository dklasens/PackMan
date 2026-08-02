import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showsSources = false

    var body: some View {
        VStack(spacing: 0) {
            if hasPersistentIssueBanner {
                IssueBanner(viewModel: viewModel) {
                    showsSources = true
                }
            }

            if isScanning {
                SourceProgressView(options: viewModel.sourceOptions.filter(\.isEnabled))
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if viewModel.isLogVisible {
                VSplitView {
                    mainContent
                        .frame(minHeight: 240)
                    LogView(
                        entries: viewModel.logEntries,
                        onClear: viewModel.clearLog)
                        .frame(minHeight: 100, idealHeight: 170)
                }
            } else {
                mainContent
            }

            Divider()
            FooterView(viewModel: viewModel)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsSources) {
            SourcesView(viewModel: viewModel)
                .frame(minWidth: 620, minHeight: 430)
        }
        .onChange(of: viewModel.sortOrder) { _, _ in
            viewModel.applySort()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if shouldShowTable {
            PackageTable(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        } else {
            EmptyStateView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
    }

    private var shouldShowTable: Bool {
        !viewModel.packages.isEmpty
    }

    private var isScanning: Bool {
        if case .scanning = viewModel.operation { return true }
        if case .cancelling = viewModel.operation,
           viewModel.sourceOptions.contains(where: { state in
               if case .scanning = state.scanState { return true }
               return false
           }) { return true }
        return false
    }

    private var hasPersistentIssueBanner: Bool {
        switch viewModel.scanSummary {
        case .completedWithIssues, .allUnavailable, .cancelled: return true
        default: return false
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                if viewModel.isBusy {
                    viewModel.cancelOperation()
                } else {
                    viewModel.startScan()
                }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(viewModel.isBusy ? "Cancel" : "Scan")
                }
                .frame(width: 76)
            }
            .disabled(viewModel.operation == .cancelling)
            .keyboardShortcut("r", modifiers: .command)
            .help(viewModel.isBusy ? "Cancel the active operation" : "Scan enabled sources for available updates")
            .accessibilityLabel(viewModel.isBusy ? "Cancel" : "Scan")
            .accessibilityIdentifier("scanCancelButton")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                viewModel.startUpdateSelected()
            } label: {
                Label(updateButtonTitle, systemImage: "arrow.up.circle")
                    .frame(minWidth: 104)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canUpdate)
            .keyboardShortcut("u", modifiers: .command)
            .help("Update all checked packages")
            .accessibilityIdentifier("updateSelectedButton")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Select All Updates") { viewModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Select None") { viewModel.selectNone() }
            } label: {
                Label("Selection", systemImage: "checklist")
            }
            .disabled(viewModel.isBusy || viewModel.updateCount == 0)
            .help("Select or deselect actionable updates")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showsSources = true
            } label: {
                Label("Sources", systemImage: viewModel.issueSources.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "exclamationmark.triangle")
            }
            .help("Configure sources and executable locations")
            .accessibilityIdentifier("sourcesButton")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.isLogVisible.toggle()
            } label: {
                Label(viewModel.isLogVisible ? "Hide Log" : "Show Log", systemImage: "text.alignleft")
            }
            .help(viewModel.isLogVisible ? "Hide command log" : "Show command log")
        }
    }

    private var updateButtonTitle: String {
        viewModel.selectedCount > 0 ? "Update \(viewModel.selectedCount)" : "Update Selected"
    }
}

private struct PackageTable: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    allSelected ? viewModel.selectNone() : viewModel.selectAll()
                } label: {
                    Label(
                        allSelected ? "Deselect All Updates" : "Select All Updates",
                        systemImage: selectionSymbol)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy || viewModel.updateCount == 0)
                .accessibilityIdentifier("selectAllUpdates")

                Spacer()
                Text(viewModel.footerText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Table(of: PackageUpdate.self, sortOrder: $viewModel.sortOrder) {
                TableColumn("Select") { package in
                    Toggle("Select \(package.name) for update", isOn: Binding(
                        get: { package.isSelected },
                        set: { package.isSelected = $0 }))
                        .labelsHidden()
                        .disabled(viewModel.isBusy || !package.isActionable)
                        .accessibilityLabel("Select \(package.name) for update")
                }
                .width(48)

                TableColumn("Name", sortUsing: PackageSortComparator(field: .name)) { package in
                    Text(package.name)
                        .lineLimit(1)
                        .help(package.name)
                        .accessibilityIdentifier("package-\(package.sourceID.rawValue)-\(package.packageID)")
                }
                TableColumn("Source", sortUsing: PackageSortComparator(field: .source)) { package in
                    Text(package.source)
                        .lineLimit(1)
                        .help(package.source)
                }
                .width(min: 90, ideal: 115, max: 150)
                TableColumn("Current", sortUsing: PackageSortComparator(field: .currentVersion)) { package in
                    Text(package.currentVersion)
                        .lineLimit(1)
                        .help(package.currentVersion)
                }
                .width(min: 78, ideal: 105)
                TableColumn("Available", sortUsing: PackageSortComparator(field: .availableVersion)) { package in
                    Text(package.availableVersion)
                        .lineLimit(1)
                        .help(package.availableVersion)
                }
                .width(min: 78, ideal: 105)
                TableColumn("Status", sortUsing: PackageSortComparator(field: .status)) { package in
                    StatusCell(status: package.status, packageName: package.name)
                }
                .width(min: 100, ideal: 120, max: 170)
            } rows: {
                ForEach(viewModel.packages) { package in
                    TableRow(package)
                        .contextMenu {
                            Button {
                                viewModel.startUpdateSingle(package)
                            } label: {
                                Label(contextActionTitle(for: package), systemImage: contextActionIcon(for: package))
                            }
                            .disabled(viewModel.isBusy || !package.isActionable)

                            Divider()

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(package.packageID, forType: .string)
                            } label: {
                                Label("Copy Package ID", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
            .accessibilityIdentifier("updatesTable")
        }
    }

    private var allSelected: Bool {
        viewModel.updateCount > 0 && viewModel.selectedCount == viewModel.updateCount
    }

    private var selectionSymbol: String {
        if viewModel.selectedCount == 0 { return "square" }
        if allSelected { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func contextActionTitle(for package: PackageUpdate) -> String {
        package.status.needsVerificationOnly ? "Retry Verification" : "Update \(package.name)"
    }

    private func contextActionIcon(for package: PackageUpdate) -> String {
        package.status.needsVerificationOnly ? "checkmark.arrow.trianglehead.counterclockwise" : "arrow.up.circle"
    }
}

private struct StatusCell: View {
    let status: UpdateStatus
    let packageName: String
    @State private var showsDetail = false

    var body: some View {
        Button {
            if status.message != nil { showsDetail.toggle() }
        } label: {
            HStack(spacing: 5) {
                statusIcon
                Text(status.title)
                    .lineLimit(1)
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .disabled(status.message == nil)
        .popover(isPresented: $showsDetail) {
            if let message = status.message {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(packageName) — \(status.title)")
                        .font(.headline)
                    Text(message)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(width: 330)
            }
        }
        .accessibilityLabel("\(packageName) status")
        .accessibilityValue(status.message.map { "\(status.title): \($0)" } ?? status.title)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
        case .updating, .verifying:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .cancelled:
            Image(systemName: "xmark.circle")
        }
    }

    private var color: Color {
        switch status {
        case .pending: return .secondary
        case .updating, .verifying: return .accentColor
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

private struct SourceProgressView: View {
    let options: [SourceOption]

    var body: some View {
        GroupBox("Scan Progress") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(options) { option in
                    GridRow {
                        SourceStateIcon(state: option.scanState)
                        Text(option.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(progressText(option.scanState))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(4)
        }
        .accessibilityIdentifier("sourceProgress")
    }

    private func progressText(_ state: SourceScanState) -> String {
        switch state {
        case .disabled: return "Disabled"
        case .notScanned: return "Not scanned"
        case .waiting: return "Waiting"
        case .probing(let started): return "Checking • \(elapsed(since: started))"
        case .scanning(let phase, let started): return "\(phase.rawValue) • \(elapsed(since: started))"
        case .succeeded(let count, _): return count == 1 ? "1 update" : "\(count) updates"
        case .partial(let count, _, _): return "Partial • \(count) update\(count == 1 ? "" : "s")"
        case .unavailable: return "Unavailable"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SourceStateIcon: View {
    let state: SourceScanState

    var body: some View {
        Group {
            switch state {
            case .probing, .scanning:
                ProgressView().controlSize(.mini)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .partial, .unavailable, .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .cancelled:
                Image(systemName: "xmark.circle").foregroundStyle(.orange)
            case .disabled:
                Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            case .notScanned, .waiting:
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

private struct EmptyStateView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        switch viewModel.scanSummary {
        case .notStarted:
            state(
                title: "Ready to Scan",
                systemImage: "shippingbox.and.arrow.backward",
                description: "Check your enabled package managers for available updates.",
                action: "Scan",
                actionHandler: viewModel.startScan)
        case .running:
            ContentUnavailableView(
                "Scanning Sources",
                systemImage: "arrow.clockwise",
                description: Text("Updates will appear as each source completes."))
        case .updatesAvailable:
            ContentUnavailableView("No Displayable Updates", systemImage: "shippingbox")
        case .updatesCompleted(let date):
            state(
                title: "Updates Completed",
                systemImage: "checkmark.circle",
                description: "The selected packages were updated and verified at \(date.formatted(date: .omitted, time: .shortened)).",
                action: "Scan Again",
                actionHandler: viewModel.startScan)
        case .upToDate(let date):
            state(
                title: "System is Up to Date",
                systemImage: "checkmark.circle",
                description: "Every enabled source completed successfully. Last scanned \(date.formatted(date: .omitted, time: .shortened)).",
                action: "Scan Again",
                actionHandler: viewModel.startScan)
        case .completedWithIssues:
            state(
                title: "Scan Completed with Issues",
                systemImage: "exclamationmark.triangle",
                description: "Some sources could not be checked, so these results may be incomplete.",
                action: "Retry Issues",
                actionHandler: viewModel.retryIssues)
        case .allUnavailable:
            state(
                title: "No Sources Could Be Scanned",
                systemImage: "exclamationmark.triangle",
                description: "Open Sources to review executable paths and installation guidance.",
                action: "Retry",
                actionHandler: viewModel.retryIssues)
        case .noSources:
            ContentUnavailableView(
                "No Sources Selected",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Enable at least one package manager in Sources."))
        case .cancelled:
            state(
                title: "Scan Cancelled",
                systemImage: "xmark.circle",
                description: "Completed source results were preserved; the result is not a full system check.",
                action: "Scan Again",
                actionHandler: viewModel.startScan)
        }
    }

    private func state(
        title: String,
        systemImage: String,
        description: String,
        action: String,
        actionHandler: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button(action, action: actionHandler)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
        }
    }
}

private struct IssueBanner: View {
    @Bindable var viewModel: AppViewModel
    let onShowSources: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(viewModel.statusText)
                .lineLimit(2)
            Spacer()
            if !viewModel.issueSources.isEmpty {
                Button("Retry Issues") { viewModel.retryIssues() }
                    .disabled(viewModel.isBusy)
            }
            Button("Sources", action: onShowSources)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .accessibilityIdentifier("scanIssueBanner")
    }
}

private struct FooterView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(viewModel.statusText)
                .lineLimit(1)
            Spacer()
            if !viewModel.issueSources.isEmpty {
                Label("\(viewModel.issueSources.count) source issue\(viewModel.issueSources.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text(viewModel.footerText)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct LogView: View {
    let entries: [LogEntry]
    let onClear: () -> Void
    @State private var followsOutput = true

    var body: some View {
        GroupBox {
            VStack(spacing: 4) {
                HStack {
                    Label("Command Log", systemImage: "text.alignleft")
                        .font(.headline)
                    Spacer()
                    Button {
                        followsOutput.toggle()
                    } label: {
                        Label(followsOutput ? "Pause Following" : "Follow Latest", systemImage: followsOutput ? "pause" : "arrow.down.to.line")
                    }
                    .labelStyle(.iconOnly)
                    .help(followsOutput ? "Pause automatic scrolling" : "Follow new output")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(formattedLog, forType: .string)
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy log")
                    .disabled(entries.isEmpty)
                    Button(action: onClear) {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .help("Clear log")
                    .disabled(entries.isEmpty)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                Text(formatted(entry))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: entries.last?.id) { _, id in
                        if followsOutput, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("commandLog")
    }

    private var formattedLog: String {
        entries.map(formatted).joined(separator: "\n")
    }

    private func formatted(_ entry: LogEntry) -> String {
        let time = entry.timestamp.formatted(date: .omitted, time: .standard)
        let scope = entry.scope.map { " [\($0)]" } ?? ""
        let stream = entry.stream == .stderr ? " [stderr]" : ""
        return "[\(time)]\(scope)\(stream) \(entry.message)"
    }

    private func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info, .output: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

private struct SourcesView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources").font(.title2.bold())
                    Text("Choose package managers and the executables PackMan should use.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.sourceOptions) { option in
                        SourceSettingsRow(viewModel: viewModel, option: option)
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
    }
}

private struct SourceSettingsRow: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var option: SourceOption

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(option.name, isOn: Binding(
                get: { option.isEnabled },
                set: { viewModel.setSourceEnabled(option, enabled: $0) }))
                .toggleStyle(.checkbox)
                .frame(width: 150, alignment: .leading)
                .disabled(viewModel.isBusy)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SourceStateIcon(state: option.scanState)
                    Text(sourceStatus)
                        .foregroundStyle(statusColor)
                }

                if let context = option.toolContext {
                    Text(context.executablePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .help(context.executablePath)
                    Text("\(context.version) • \(context.origin.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let override = viewModel.executableOverride(for: option.descriptor.toolID) {
                    Text(override)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(override)
                }

                if let issue = option.probeIssue ?? option.scanState.issues.first {
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let recovery = issue.recovery {
                        Text(recovery)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Choose…") { chooseExecutable() }
                    .disabled(viewModel.isBusy)
                if viewModel.executableOverride(for: option.descriptor.toolID) != nil {
                    Button("Use Automatic") {
                        viewModel.setExecutableOverride(nil, for: option.descriptor.toolID)
                    }
                    .buttonStyle(.link)
                    .disabled(viewModel.isBusy)
                }
                if let url = option.descriptor.installationURL,
                   option.scanState.isUnavailable || option.probeIssue != nil {
                    Link("Installation Help", destination: url)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sourceStatus: String {
        switch option.scanState {
        case .disabled: return "Disabled"
        case .notScanned, .waiting: return "Not checked"
        case .probing: return "Checking availability"
        case .scanning(let phase, _): return phase.rawValue
        case .succeeded(let count, _): return count == 1 ? "Available • 1 update" : "Available • \(count) updates"
        case .partial: return "Partial result"
        case .unavailable: return "Not available"
        case .failed: return "Scan failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch option.scanState {
        case .partial, .unavailable, .failed, .cancelled: return .orange
        default: return .secondary
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(option.descriptor.executableName)"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let path = panel.url?.path {
            viewModel.setExecutableOverride(path, for: option.descriptor.toolID)
        }
    }
}
