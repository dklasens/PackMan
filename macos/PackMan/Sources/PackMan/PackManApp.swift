import SwiftUI

@main
struct PackManApp: App {
    @NSApplicationDelegateAdaptor(PackManApplicationDelegate.self) private var appDelegate
    @State private var viewModel: AppViewModel

    init() {
        _viewModel = State(initialValue: AppEnvironment.makeViewModel())
    }

    var body: some Scene {
        Window("PackMan", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 820, minHeight: 540)
                .onAppear { appDelegate.viewModel = viewModel }
        }
        .defaultSize(width: 1_020, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    viewModel.checkForUpdates()
                }
            }

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

            CommandMenu("Activity") {
                Button("Update History…") { viewModel.isHistoryPresented = true }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Package Details…") {
                    if let package = viewModel.selectedPackages.first ?? viewModel.filteredPackages.first { viewModel.detailPackage = package }
                }.keyboardShortcut("i", modifiers: .command).disabled(viewModel.filteredPackages.isEmpty)
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

                Button("Select Visible Updates") { viewModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(viewModel.isBusy || viewModel.updateCount == 0)
                Button("Select None") { viewModel.selectNone() }
                    .disabled(viewModel.isBusy || viewModel.updateCount == 0)
            }
        }
    }
}


@MainActor
final class PackManApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?
    private var waitingForQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isBusy else { return .terminateNow }
        if waitingForQuit { return .terminateLater }
        let alert = NSAlert()
        alert.messageText = "An operation is still running"
        alert.informativeText = "Cancel and wait for command cleanup before quitting? Packages already changed will remain changed."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Cancel and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        waitingForQuit = true
        Task {
            await viewModel.cancelAndWait()
            waitingForQuit = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
