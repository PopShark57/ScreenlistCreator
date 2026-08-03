import SwiftUI
import AppKit

@main
struct Entry {
    static func main() {
        if CommandLine.arguments.contains("--cli") {
            let exitCode = CLIRunner.run(arguments: CommandLine.arguments)
            exit(exitCode)
        }
        ScreenlistCreatorApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Receives videos dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        AppViewModel.shared.addVideos(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ScreenlistCreatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var model = AppViewModel.shared

    var body: some Scene {
        WindowGroup("Screenlist Creator") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…") {
                    model.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
