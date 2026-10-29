import SwiftUI
import AppKit

/// Needed so the app behaves like a normal foreground Mac app
/// even when launched as a Swift Package executable.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct iCarusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = PlayerEngine()
    @StateObject private var skins = SkinManager()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("iCarus") {
            RootView()
                .environmentObject(engine)
                .environmentObject(skins)
                .environmentObject(downloads)
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Mode") {
                Button("Play") { appState.section = .play }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Get") { appState.section = .get }
                    .keyboardShortcut("2", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Add Files…") {
                    appState.section = .play
                    appState.showingImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Equalizer") {
                    appState.section = .play
                    appState.showingEQ = true
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Playlist") {
                    appState.section = .play
                    appState.showingPlaylist = true
                }
                .keyboardShortcut("l", modifiers: .command)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { engine.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Next") { engine.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { engine.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Stop") { engine.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }

        Settings {
            SkinSettingsView()
                .environmentObject(skins)
        }
    }
}

/// Injects the active skin into the environment so every view can read it.
struct RootView: View {
    @EnvironmentObject private var skins: SkinManager
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.section {
            case .play: PlayerView()
            case .get: GetView()
            }
        }
        .environment(\.skin, skins.active)
        .background(WindowConfigurator(
            shaped: skins.active.isShaped && appState.section == .play,
            contentSize: CGSize(width: skins.active.manifest.metrics.windowWidth,
                                height: skins.active.manifest.metrics.windowHeight)))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $appState.section) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
        }
        .onAppear {
            // Finished downloads flow into the player's queue without auto-starting playback.
            downloads.onFileReady = { [weak engine] url in
                engine?.add(urls: [url], autoplay: false)
            }
            // Start with everything already in the downloads folder.
            engine.add(urls: LibraryScanner.audioFiles(in: downloads.folder), autoplay: false)
        }
    }
}
