import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PackageDetailsView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var package: PackageUpdate
    @Environment(\.dismiss) private var dismiss
    @State private var links: [PackageLink] = []
    @State private var metadataIssue: String?
    @State private var loadingLinks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(package.name).font(.title2.bold()).textSelection(.enabled)
                    Text(package.source).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                        field("Package identity", package.packageID)
                        if let registryID = package.registryID { field("Registry package", registryID) }
                        field("Observed version", package.currentVersion.isEmpty ? "Unknown" : package.currentVersion)
                        field("Requested version", package.availableVersion)
                        field("Manager", package.toolContext.executablePath)
                        field("Manager version", package.toolContext.version)
                        field("Tool search paths", package.toolContext.pathEntries.joined(separator: "\n"))
                        field("Status", package.status.title)
                    }
                    if let warning = package.warning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if let issue = package.statusMessage { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                    if let evidence = package.verificationEvidence { Text(evidence).textSelection(.enabled).accessibilityIdentifier("verificationEvidence") }
                    if package.isManual {
                        Text("Complete the update in the App Store or Terminal, then choose Verify again. PackMan does not install this update itself.")
                    }
                    HStack {
                        if package.isManual {
                            Button("Update in App Store") { openAppStore() }.buttonStyle(.borderedProminent)
                            Button("Copy Terminal Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(MasSource.terminalUpdateCommand(forADAMID: package.packageID), forType: .string)
                                viewModel.recordExternalAction(package)
                            }
                        } else {
                            Button("Update / retry install") { viewModel.startUpdateSingle(package) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!package.isActionable)
                        }
                        Button("Verify again") { viewModel.startVerify(package) }.accessibilityIdentifier("verifyAgainButton")
                    }
                    .disabled(viewModel.isBusy)
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        ForEach(links) { link in Link(link.title, destination: link.url) }
                        Button(loadingLinks ? "Loading…" : "Load package links") {
                            loadingLinks = true
                            Task {
                                defer { loadingLinks = false }
                                do { links = try await PackageMetadataService().links(source: package.sourceID,
                                    id: package.registryID ?? package.packageID, context: package.toolContext) }
                                catch { metadataIssue = error.localizedDescription }
                            }
                        }.buttonStyle(.link).disabled(loadingLinks)
                    }
                    if let metadataIssue { Text(metadataIssue).font(.caption).foregroundStyle(.secondary) }
                    Text("Output for this attempt").font(.headline)
                    Text(package.output.isEmpty ? "No command output recorded." : package.output)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }.padding(.trailing, 8)
            }
        }
        .padding(20).frame(width: 760, height: 560)
        .accessibilityElement(children: .contain).accessibilityIdentifier("packageDetails")
        .onAppear { links = PackageMetadataService.packageLink(source: package.sourceID, id: package.registryID ?? package.packageID).map { [$0] } ?? [] }
    }

    private func field(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 132, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openAppStore() {
        guard let url = MasSource.appStorePageURL(forADAMID: package.packageID) else { return }
        if NSWorkspace.shared.open(url) { viewModel.recordExternalAction(package) }
    }
}

struct HistoryView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    private var selected: UpdateHistoryEntry? { viewModel.history.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Update History").font(.title2.bold())
                Spacer()
                Button("Export redacted diagnostics") { viewModel.previewDiagnostics() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(runs, id: \.self) { run in
                        Section("Run \(viewModel.history.first(where: { $0.runID == run })!.startedAt.formatted())") {
                            ForEach(viewModel.history.filter { $0.runID == run }) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name).fontWeight(.medium)
                                    Text("\(entry.outcome.rawValue) · \(entry.versionText)").font(.caption).foregroundStyle(.secondary)
                                }.tag(entry.id)
                            }
                        }
                    }
                }.listStyle(.sidebar).frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                ScrollView {
                    if let entry = selected {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.name).font(.headline)
                            Text("\(entry.sourceID.rawValue) · \(entry.packageID)")
                            Text(entry.versionText)
                            Text(entry.outcome.rawValue).fontWeight(.semibold)
                            Text(entry.startedAt.formatted())
                            Text(entry.toolPath)
                            Text(entry.evidence)
                            HStack {
                                Button("Verify again") { viewModel.recoverHistory(entry, verifyOnly: true) }
                                Button(entry.sourceID == .appStore ? "Manual update details" : "Retry install") {
                                    viewModel.recoverHistory(entry, verifyOnly: false)
                                }
                            }.disabled(viewModel.isBusy)
                            Text(entry.output.isEmpty ? "No command output recorded." : entry.output).font(.system(.caption, design: .monospaced))
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    } else {
                        ContentUnavailableView("Select an attempt", systemImage: "clock.arrow.circlepath",
                            description: Text("The latest 500 attempts are stored on this Mac."))
                    }
                }.frame(minWidth: 350)
            }
        }.padding(20).frame(width: 840, height: 560).accessibilityElement(children: .contain).accessibilityIdentifier("updateHistory")
        .sheet(item: $viewModel.detailPackage) { PackageDetailsView(viewModel: viewModel, package: $0) }
        .sheet(isPresented: Binding(get: { viewModel.diagnosticsPreview != nil }, set: { if !$0 { viewModel.diagnosticsPreview = nil } })) {
            DiagnosticsView(text: viewModel.diagnosticsPreview ?? "")
        }
    }

    private var runs: [UUID] {
        var seen = Set<UUID>()
        return viewModel.history.map(\.runID).filter { seen.insert($0).inserted }
    }
}

struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review diagnostic export").font(.title2.bold())
            Text("Common credentials and home paths have been removed. Review the preview for other private information before sharing.")
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save JSON…") {
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "PackMan-diagnostics.json"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try text.write(to: url, atomically: true, encoding: .utf8); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 760, height: 520)
    }
}


/// SwiftUI's single Window restores scene state; also preserve its frame explicitly.
struct WindowPersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PersistentWindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class PersistentWindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName.isEmpty else { return }
            window.setFrameAutosaveName("PackMan.mainWindow")
            window.setFrameUsingName("PackMan.mainWindow")
        }
    }
}
