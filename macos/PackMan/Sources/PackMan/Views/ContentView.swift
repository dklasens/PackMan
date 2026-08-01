import SwiftUI

struct ContentView: View {
    @State private var viewModel = AppViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 0) {
            Table(viewModel.packages, sortOrder: $viewModel.sortOrder) {
                TableColumn("") { package in
                    Toggle("", isOn: Binding(
                        get: { package.isSelected },
                        set: { package.isSelected = $0 }))
                        .labelsHidden()
                }
                .width(30)

                TableColumn("Name", value: \.name)
                TableColumn("Source", value: \.source)
                    .width(110)
                TableColumn("Current", value: \.currentVersion)
                    .width(ideal: 100)
                TableColumn("Available", value: \.availableVersion)
                    .width(ideal: 100)

                TableColumn("Status", value: \.status.rawValue) { package in
                    StatusCell(status: package.status, message: package.statusMessage)
                }
                .width(90)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            LogView(lines: viewModel.logLines)
                .frame(height: 140)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            HStack {
                Text(viewModel.statusText)
                Spacer()
                Text("\(viewModel.packages.count) update(s)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan enabled sources for available updates")
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await viewModel.updateSelected() }
                } label: {
                    Label("Update Selected", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
                .help("Update all checked packages")
            }

            if viewModel.isBusy {
                ToolbarItem(placement: .navigation) {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Select All") { viewModel.selectAll() }
                    Button("Select None") { viewModel.selectNone() }
                } label: {
                    Label("Selection", systemImage: "checklist")
                }
                .disabled(viewModel.isBusy)
                .help("Select or deselect all packages")
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(viewModel.sourceOptions) { option in
                        Toggle(option.name, isOn: Bindable(option).isEnabled)
                    }
                } label: {
                    Label("Sources", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Choose which package managers to include in scans")
            }
        }
    }
}

private struct StatusCell: View {
    let status: UpdateStatus
    let message: String?

    var body: some View {
        HStack(spacing: 4) {
            if status == .updating {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(status.rawValue)
                .foregroundStyle(color)
        }
        .help(message ?? "")
    }

    private var color: Color {
        switch status {
        case .pending: return .secondary
        case .updating: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        GroupBox("Log") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}
