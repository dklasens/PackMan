import SwiftUI

@main
struct PackManApp: App {
    @State private var viewModel: AppViewModel

    init() {
        _viewModel = State(initialValue: AppEnvironment.makeViewModel())
    }

    var body: some Scene {
        Window("PackMan", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1_020, height: 680)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Sources…") {
                    viewModel.isSourcesSheetPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Sources") {
                Button("Configure Sources…") {
                    viewModel.isSourcesSheetPresented = true
                }

                Divider()

                Button("Clear Cache for All Sources") {
                    viewModel.startClearAllCaches()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(viewModel.isBusy)

                Menu("Clear Cache for") {
                    ForEach(viewModel.sourceOptions) { option in
                        Button(option.name) {
                            viewModel.startClearCacheSingle(option)
                        }
                        .disabled(viewModel.isBusy || !option.isEnabled)
                    }
                }
            }

            CommandMenu("Packages") {
                Button(viewModel.isBusy ? "Cancel Operation" : "Scan for Updates") {
                    viewModel.isBusy ? viewModel.cancelOperation() : viewModel.startScan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.operation == .cancelling)

                Button("Update Selected") {
                    viewModel.startUpdateSelected()
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!viewModel.canUpdate)

                Divider()

                Button("Select All Updates") { viewModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(viewModel.isBusy || viewModel.updateCount == 0)
                Button("Select None") { viewModel.selectNone() }
                    .disabled(viewModel.isBusy || viewModel.updateCount == 0)
            }
        }
    }
}
