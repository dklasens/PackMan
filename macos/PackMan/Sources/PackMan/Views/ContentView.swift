import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showsAppUpdateBanner {
                AppUpdateBanner(viewModel: viewModel)
            }

            if viewModel.showsIssueBanner {
                IssueBanner(viewModel: viewModel)
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
        .searchable(text: $viewModel.searchText, prompt: "Filter packages…")
        .toolbar { toolbarContent }
        .background(WindowPersistence())
        .sheet(item: Binding(get: { viewModel.isHistoryPresented ? nil : viewModel.detailPackage }, set: { viewModel.detailPackage = $0 })) { package in PackageDetailsView(viewModel: viewModel, package: package) }
        .sheet(isPresented: $viewModel.isHistoryPresented) { HistoryView(viewModel: viewModel) }
        .sheet(isPresented: Binding(get: { viewModel.isCachePresented && !viewModel.isSourcesSheetPresented }, set: { if !$0 { viewModel.isCachePresented = false } })) { CacheView(viewModel: viewModel) }
        .sheet(isPresented: $viewModel.isSourcesSheetPresented) {
            SourcesView(viewModel: viewModel)
                .frame(width: 760, height: 580)
                .sheet(isPresented: $viewModel.isCachePresented) { CacheView(viewModel: viewModel) }
        }
        .onChange(of: viewModel.sortOrder) { _, _ in
            viewModel.applySort()
        }
        .onAppear {
            viewModel.beginStartupUpdateCheck()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if !viewModel.packages.isEmpty || viewModel.sourceFilter != nil || viewModel.statusFilter != .all {
                HStack {
                    Picker("Source", selection: $viewModel.sourceFilter) {
                        Text("All sources").tag(nil as SourceID?)
                        ForEach(viewModel.sourceOptions) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 220)
                    Picker("Status", selection: $viewModel.statusFilter) {
                        ForEach(PackageStatusFilter.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 230)
                    Spacer()
                    Text("\(viewModel.filteredPackages.count) of \(viewModel.packages.count) shown").foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.top, 8)
            }
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

    }

    private var shouldShowTable: Bool {
        !viewModel.filteredPackages.isEmpty
    }

    private var isScanning: Bool {
        if case .scanning = viewModel.operation { return true }
        if case .clearingCache = viewModel.operation { return true }
        if case .cancelling = viewModel.operation,
           viewModel.sourceOptions.contains(where: { state in
               if case .scanning = state.scanState { return true }
               return false
           }) { return true }
        return false
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
                Label(updateButtonTitle, systemImage: "arrow.up.circle").labelStyle(.titleAndIcon)
                    .frame(minWidth: 104)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canUpdate)
            .keyboardShortcut("u", modifiers: .command)
            .help("Update all checked packages")
            .accessibilityIdentifier("updateSelectedButton")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { viewModel.isHistoryPresented = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                .accessibilityIdentifier("historyButton")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Refresh Metadata and Scan") { viewModel.refreshMetadataAndScan() }.disabled(viewModel.isBusy)
                Divider()
                Button("Select Visible Updates") { viewModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Select None") { viewModel.selectNone() }
            } label: {
                Label("Selection", systemImage: "checklist")
            }
            .disabled(viewModel.isBusy)
            .help("Refresh metadata or change visible update selection")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.isSourcesSheetPresented = true
            } label: {
                Label("Sources", systemImage: viewModel.issueSources.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "exclamationmark.triangle")
            }
            .help("Configure sources and executable locations")
            .accessibilityIdentifier("sourcesButton")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.startClearAllCaches()
                } label: {
                    Label("Package Caches…", systemImage: "internaldrive")
                }
                .disabled(viewModel.isBusy)

                Menu("Clear Cache for") {
                    ForEach(viewModel.sourceOptions) { option in
                        Button(option.name) {
                            viewModel.startClearCacheSingle(option)
                        }
                        .disabled(viewModel.isBusy || !option.isEnabled)
                    }
                }
            } label: {
                Label("Clear Cache", systemImage: "internaldrive")
            }
            .help("Clear package manager caches")
            .accessibilityIdentifier("clearCacheMenu")
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

private struct PackageSourceIcon: View {
    let sourceID: SourceID

    var body: some View {
        Image(systemName: iconName)
            .font(.caption)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        switch sourceID {
        case .homebrew, .homebrewCasks: return "cup.and.saucer.fill"
        case .appStore: return "app.badge.fill"
        case .npm: return "shippingbox.fill"
        case .pip: return "doc.text.fill"
        case .pipx: return "terminal.fill"
        case .dotnet: return "square.stack.3d.up.fill"
        }
    }

    private var iconColor: Color {
        switch sourceID {
        case .homebrew, .homebrewCasks: return .orange
        case .appStore: return .blue
        case .npm: return .red
        case .pip: return .teal
        case .pipx: return .indigo
        case .dotnet: return .purple
        }
    }
}

private struct PackageTable: View {
    @Bindable var viewModel: AppViewModel
    @SceneStorage("PackMan.packageColumns") private var columns: TableColumnCustomization<PackageUpdate>

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    allSelected ? viewModel.selectNone() : viewModel.selectAll()
                } label: {
                    Label(
                        allSelected ? "Deselect Visible Updates" : "Select Visible Updates",
                        systemImage: selectionSymbol)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy || viewModel.updateCount == 0)
                .accessibilityIdentifier("selectAllUpdates")

                Spacer()
                Text("\(viewModel.selectedPackages.count) visible selected · \(viewModel.totalSelectedCount) selected total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Table(of: PackageUpdate.self, sortOrder: $viewModel.sortOrder, columnCustomization: $columns) {
                TableColumn("Select") { package in
                    Toggle("Select \(package.name) for update", isOn: Binding(
                        get: { package.isSelected },
                        set: { package.isSelected = $0 }))
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(viewModel.isBusy || !package.isActionable)
                        .accessibilityLabel("Select \(package.name) for update")
                }
                .width(48)

                TableColumn("Name", sortUsing: PackageSortComparator(field: .name)) { package in
                    Button(package.name) { viewModel.detailPackage = package }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Details for \(package.name)")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(package.name)
                        .accessibilityIdentifier("package-\(package.sourceID.rawValue)-\(package.packageID)")
                }
                .customizationID("name")
                TableColumn("Source", sortUsing: PackageSortComparator(field: .source)) { package in
                    HStack(spacing: 6) {
                        PackageSourceIcon(sourceID: package.sourceID)
                        Text(package.source)
                            .lineLimit(1)
                    }
                    .help(package.source)
                }
                .width(min: 100, ideal: 125, max: 160)
                .customizationID("source")
                TableColumn("Current", sortUsing: PackageSortComparator(field: .currentVersion)) { package in
                    Text(package.currentVersion)
                        .lineLimit(1)
                        .help(package.currentVersion)
                }
                .width(min: 78, ideal: 105)
                .customizationID("current")
                TableColumn("Available", sortUsing: PackageSortComparator(field: .availableVersion)) { package in
                    Text(package.availableVersion)
                        .lineLimit(1)
                        .help(package.availableVersion)
                }
                .width(min: 78, ideal: 105)
                .customizationID("available")
                TableColumn("Status", sortUsing: PackageSortComparator(field: .status)) { package in
                    StatusCell(status: package.status, packageName: package.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 110, ideal: 130, max: 180)
                .customizationID("status")
            } rows: {
                ForEach(viewModel.filteredPackages) { package in
                    TableRow(package)
                        .contextMenu {
                            Button("Package details…") { viewModel.detailPackage = package }
                            Button("Verify again") { viewModel.startVerify(package) }.disabled(viewModel.isBusy)
                            Button {
                                viewModel.startUpdateSingle(package)
                            } label: {
                                Label(contextActionTitle(for: package), systemImage: contextActionIcon(for: package))
                            }
                            .disabled(viewModel.isBusy || !package.isActionable)

                            Button {
                                if let option = viewModel.sourceOptions.first(where: { $0.id == package.sourceID }) {
                                    viewModel.startClearCacheSingle(option)
                                }
                            } label: {
                                Label("Clear Cache for \(package.source)", systemImage: "internaldrive")
                            }
                            .disabled(viewModel.isBusy)

                            Divider()

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(package.packageID, forType: .string)
                            } label: {
                                Label("Copy Package ID", systemImage: "doc.on.doc")
                            }

                            if package.sourceID == .appStore {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        MasSource.terminalUpdateCommand(forADAMID: package.packageID),
                                        forType: .string)
                                } label: {
                                    Label("Copy Terminal Update Command", systemImage: "terminal")
                                }

                                if let appStoreURL = MasSource.appStorePageURL(forADAMID: package.packageID) {
                                    Button {
                                        if NSWorkspace.shared.open(appStoreURL) { viewModel.recordExternalAction(package) }
                                    } label: {
                                        Label("Open in App Store", systemImage: "app.badge")
                                    }
                                }
                            }

                            Divider()

                            Button {
                                viewModel.ignore(package, versionOnly: true)
                            } label: {
                                Label("Ignore Version \(package.availableVersion)", systemImage: "eye.slash")
                            }
                            .disabled(viewModel.isBusy)

                            Button {
                                viewModel.ignore(package, versionOnly: false)
                            } label: {
                                Label("Ignore All Updates for \(package.name)", systemImage: "nosign")
                            }
                            .disabled(viewModel.isBusy)
                        }
                }
            }
            .accessibilityIdentifier("updatesTable")
        }
    }

    private var allSelected: Bool {
        !viewModel.visibleActionablePackages.isEmpty && viewModel.selectedCount == viewModel.visibleActionablePackages.count
    }

    private var selectionSymbol: String {
        if viewModel.selectedCount == 0 { return "square" }
        if allSelected { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func contextActionTitle(for package: PackageUpdate) -> String {
        "Update / retry install"
    }

    private func contextActionIcon(for package: PackageUpdate) -> String {
        "arrow.up.circle"
    }
}

private struct StatusCell: View {
    let status: UpdateStatus
    let packageName: String
    @State private var showsDetail = false

    var body: some View {
        Group {
            if status.message != nil {
                Button { showsDetail.toggle() } label: { badge }
                    .buttonStyle(.plain)
                    .help("Show details for \(packageName)")
            } else {
                badge
            }
        }
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
    private var badge: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(status.title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
        case .manual:
            Image(systemName: "arrow.up.forward.app")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
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
        case .pending, .manual: return .secondary
        case .updating, .verifying: return .accentColor
        case .failed: return .red
        case .cancelled: return .orange
        case .completed: return .green
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
                        HStack(spacing: 6) {
                            PackageSourceIcon(sourceID: option.id)
                            Text(option.name)
                        }
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
        if !viewModel.searchText.trimmed.isEmpty || viewModel.sourceFilter != nil || viewModel.statusFilter != .all {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
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
                ContentUnavailableView(
                    "No Displayable Updates",
                    systemImage: "shippingbox",
                    description: Text("\(viewModel.ignoredCount) ignored updates; \(viewModel.skippedCount) source exclusions. Review Sources for coverage and ignored updates."))
            case .updatesCompleted(let date):
                state(
                    title: "Updates Completed",
                    systemImage: "checkmark.circle",
                    description: "The selected packages were verified at \(date.formatted(date: .omitted, time: .shortened)).",
                    action: "Scan Again",
                    actionHandler: viewModel.startScan)
            case .upToDate(let date):
                state(
                    title: "No Updates Found",
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

private struct AppUpdateBanner: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill")
                .foregroundStyle(.blue)
            Text(viewModel.appUpdateText)
                .lineLimit(2)
            Spacer()
            Button("Install and Restart") { viewModel.installAvailableUpdate() }
                .disabled(!viewModel.canInstallAppUpdate)
                .accessibilityIdentifier("installUpdateButton")
            Button("Later") { viewModel.dismissAvailableUpdate() }
                .disabled(viewModel.isBusy)
            Button("Skip") { viewModel.skipAvailableUpdate() }
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("skipUpdateButton")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.12))
        .accessibilityIdentifier("appUpdateBanner")
    }
}

private struct IssueBanner: View {
    @Bindable var viewModel: AppViewModel

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
            Button("Sources") { viewModel.isSourcesSheetPresented = true }
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
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.footerStatusText)
                Text(viewModel.footerText).font(.caption)
            }
            Spacer()
            if !viewModel.issueSources.isEmpty {
                Label("\(viewModel.issueSources.count) source issue\(viewModel.issueSources.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("v\(AppViewModel.appVersion)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityIdentifier("appVersionTag")
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Sources").font(.title2.bold())
                    Text("v\(AppViewModel.appVersion)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Package Caches…") { viewModel.startClearAllCaches() }
                        .disabled(viewModel.isBusy || viewModel.sourceOptions.allSatisfy { !$0.isEnabled })
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                Text("Choose the package managers and environments to use on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.sourceSetupSuggested {
                            Text("Choose the sources to use on this Mac").font(.headline)
                            Text("Detection does not change your choices until you apply it.")
                        }
                        HStack {
                            Button("Recheck availability") { viewModel.recheckSources() }.disabled(viewModel.isBusy)
                            Button("Use detected sources") { viewModel.useDetectedSources() }.disabled(viewModel.isBusy || !viewModel.hasProbedSources)
                            if viewModel.sourceSetupSuggested {
                                Button("Keep current choices") { viewModel.finishSourceSetup() }.disabled(viewModel.isBusy)
                            }
                        }
                        Toggle("Check casks that update themselves", isOn: Binding(get: { viewModel.includeSelfUpdatingCasks }, set: viewModel.setCaskPolicy))
                            .disabled(viewModel.isBusy)
                        Text("Homebrew pins are respected. Unversioned casks and applications outside the selected managers are not fully covered.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(20)
                    Divider()
                    ForEach(viewModel.sourceOptions) { option in
                        SourceSettingsRow(viewModel: viewModel, option: option)
                        Divider().padding(.horizontal, 20)
                    }

                    if viewModel.hasIgnoredUpdates {
                        IgnoredUpdatesView(viewModel: viewModel)
                    }
                }
            }
        }
    }
}

private struct IgnoredUpdatesView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ignored Updates")
                .font(.headline)
            Text("Restored updates become visible the next time you scan.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(viewModel.ignoredUpdates, id: \.self) { key in
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(AppViewModel.displayName(forIgnoreKey: key))
                        .lineLimit(1)
                        .help(key)
                    Spacer()
                    Button("Restore") { viewModel.removeIgnored(key) }
                        .disabled(viewModel.isBusy)
                        .accessibilityLabel("Restore \(AppViewModel.displayName(forIgnoreKey: key))")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ignoredUpdates")
    }
}

private struct SourceSettingsRow: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var option: SourceOption

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Toggle(option.name, isOn: Binding(
                    get: { option.isEnabled },
                    set: { viewModel.setSourceEnabled(option, enabled: $0) }))
                    .toggleStyle(.checkbox)
                    .fontWeight(.medium)
                    .disabled(viewModel.isBusy)
                Spacer(minLength: 12)
                if option.id != .appStore {
                    Button("Cache…") { viewModel.startClearCacheSingle(option) }
                        .disabled(viewModel.isBusy || !option.isEnabled)
                        .help("Preview caches for \(option.name)")
                }
                Button("Choose Executable…") { chooseExecutable() }
                    .disabled(viewModel.isBusy)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SourceStateIcon(state: option.scanState)
                    Text(sourceStatus).foregroundStyle(statusColor)
                    if let completedAt = option.scanState.completedAt {
                        Spacer()
                        Text("Scanned \(completedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }.font(.caption)

                if let context = option.toolContext {
                    Text(context.executablePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .help(context.executablePath)
                    Text("\(context.version) • \(context.origin.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let override = viewModel.executableOverride(for: option.descriptor.toolID) {
                    Text(override).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let description = option.environmentDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if let context = option.toolContext {
                    Text(SourceEnvironmentInspector.scope(option.id, context: context)).font(.caption).foregroundStyle(.secondary)
                }
                if let hint = option.source.requirementHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if let issue = option.probeIssue ?? option.scanState.issues.first {
                    Text(issue.message).font(.caption).foregroundStyle(.orange)
                    if let recovery = issue.recovery { Text(recovery).font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 14) {
                    if viewModel.executableOverride(for: option.descriptor.toolID) != nil {
                        Button("Use Automatic") { viewModel.setExecutableOverride(nil, for: option.descriptor.toolID) }
                            .buttonStyle(.link).disabled(viewModel.isBusy)
                    }
                    if let url = option.descriptor.installationURL,
                       option.scanState.isUnavailable || option.probeIssue != nil {
                        Link("Installation Help", destination: url)
                    }
                }.font(.caption)
            }
            .padding(.leading, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sourceStatus: String {
        switch option.scanState {
        case .disabled: return "Disabled"
        case .notScanned, .waiting: return option.toolContext == nil ? "Not checked" : "Available • Not scanned yet"
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
