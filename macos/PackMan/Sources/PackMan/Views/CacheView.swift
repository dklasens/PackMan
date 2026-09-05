import SwiftUI

struct CacheView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Package Caches").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Preview locations and scope before cleanup. Shared caches are cleaned once; sizes are estimates.").foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.sourceOptions) { option in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Toggle(option.name, isOn: Binding(get: { viewModel.selectedCacheSources.contains(option.id) }, set: { enabled in
                                    if enabled { viewModel.selectedCacheSources.insert(option.id) } else { viewModel.selectedCacheSources.remove(option.id) }
                                    viewModel.cachePreviews = []; viewModel.cacheResults = [:]
                                })).fontWeight(.medium).disabled(viewModel.isBusy || option.id == .appStore)
                                Spacer()
                                if let preview = viewModel.cachePreviews.first(where: { $0.id == option.id }) {
                                    Text(preview.sizeText).font(.callout).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("cacheSize-\(option.id.rawValue)")
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                if option.id == .appStore { Text("Managed by macOS").font(.caption).foregroundStyle(.secondary) }
                                if let preview = viewModel.cachePreviews.first(where: { $0.id == option.id }) {
                                    Text(preview.scope).font(.callout)
                                    ForEach(preview.paths, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                    if let issue = preview.issue { Text(issue).foregroundStyle(.orange) }
                                    if !preview.removalPreview.trimmed.isEmpty {
                                        DisclosureGroup("Planned Homebrew removals") {
                                            Text(preview.removalPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        }
                                    }
                                }
                                if let result = viewModel.cacheResults[option.id] { Text(result).fontWeight(.medium).textSelection(.enabled) }
                            }.padding(.leading, 22)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        Divider()
                    }
                    if viewModel.selectedCacheSources.contains(.dotnet) {
                        Toggle("Also remove NuGet global packages", isOn: $viewModel.includeNugetGlobalPackages)
                            .disabled(viewModel.isBusy)
                            .onChange(of: viewModel.includeNugetGlobalPackages) { _, _ in viewModel.cachePreviews = []; viewModel.cacheResults = [:] }
                        Text("Other projects will need to restore those packages again.").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                }.padding(.trailing, 8)
            }
            Divider()
            HStack {
                if viewModel.isBusy { ProgressView().controlSize(.small); Button("Cancel operation") { viewModel.cancelOperation() } }
                Spacer()
                Button("Preview selected caches") { viewModel.startCachePreview() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("previewCachesButton")
                    .disabled(viewModel.isBusy || viewModel.selectedCacheSources.isEmpty)
                Button("Clear Selected…") { viewModel.startCachePreview(clearAfterConfirmation: true) }
                    .disabled(viewModel.isBusy || viewModel.selectedCacheSources.isEmpty)
            }
        }.padding(20).frame(width: 760, height: 560)
        .accessibilityElement(children: .contain).accessibilityIdentifier("packageCaches")
        .interactiveDismissDisabled(viewModel.isBusy)
    }
}
