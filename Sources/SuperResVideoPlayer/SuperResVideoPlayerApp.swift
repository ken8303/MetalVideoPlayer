import SwiftUI
import AppKit

@main
struct SuperResVideoPlayerApp: App {
    /// Owned here (rather than in ContentView) so the menu-bar commands
    /// below can drive playback too — that's what gives us real keyboard
    /// shortcuts (Space, arrows) instead of mouse-only controls.
    @StateObject private var playerViewModel = PlayerViewModel()

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
            ContentView(playerViewModel: playerViewModel)
        }
        .windowResizability(.contentSize)
        .commands {
            PlaybackCommands(viewModel: playerViewModel)
        }
    }
}

/// Menu-bar commands — these are what register the keyboard shortcuts.
struct PlaybackCommands: Commands {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some Commands {
        // Replace "New" with "Open Video…" (⌘O).
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") {
                viewModel.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(viewModel.isExportingVideo)
        }

        CommandMenu("Playback") {
            Button(viewModel.isPlaying ? "Pause" : "Play") {
                viewModel.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(viewModel.duration == 0)

            Divider()

            Button("Back 10 Seconds") { viewModel.step(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(viewModel.duration == 0)
            Button("Forward 10 Seconds") { viewModel.step(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(viewModel.duration == 0)

            Divider()

            Button("Volume Up") { viewModel.adjustVolume(by: 5) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Volume Down") { viewModel.adjustVolume(by: -5) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button(viewModel.isMuted ? "Unmute" : "Mute") { viewModel.toggleMute() }
                .keyboardShortcut("m", modifiers: [])

            Divider()

            Button("Toggle Full Screen") { WindowControl.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])
        }
    }
}

/// Full-screen toggling. SwiftUI has no direct API for this on macOS, so we
/// reach for the key window — which is also what makes plain `F` (no
/// modifier) work as a player-style shortcut alongside macOS's own ⌃⌘F.
enum WindowControl {
    static func toggleFullScreen() {
        (NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first)?
            .toggleFullScreen(nil)
    }
}
