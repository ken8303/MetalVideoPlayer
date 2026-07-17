import SwiftUI
import AppKit

@main
struct SuperResVideoPlayerApp: App {
    init() {
        // A plain SPM executable has no .app bundle, so macOS launches it
        // as a background process: no Dock icon, no menu bar, and the
        // window can appear behind everything (or not at all). Promote it
        // to a regular foreground app and bring it to the front.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
