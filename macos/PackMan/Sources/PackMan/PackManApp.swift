import SwiftUI

@main
struct PackManApp: App {
    var body: some Scene {
        WindowGroup("PackMan") {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)
    }
}
