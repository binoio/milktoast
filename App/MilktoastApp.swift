import SwiftUI
import MilktoastCore

@main
struct MilktoastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    #if canImport(Sparkle)
    @StateObject private var updater = UpdaterModel()
    #endif

    var body: some Scene {
        Window("Milktoast", id: "main") {
            MainView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentSize)
        .commands {
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
            CommandGroup(replacing: .newItem) {
                Button("Open Movie…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Clear Remux Cache") { model.clearCache() }
                Button("Reveal Cache in Finder") { model.revealCache() }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// SwiftUI has no scene-level hook for Finder "Open With" on macOS, so the app
/// delegate forwards the opened URLs into the model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet {
            guard let model else { return }
            let pending = queuedBeforeModelReady
            queuedBeforeModelReady = []
            if !pending.isEmpty { model.enqueue(pending) }
        }
    }

    /// Launch-time opens arrive before the first `onAppear`, so hold them.
    private var queuedBeforeModelReady: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.enqueue(urls)
        } else {
            queuedBeforeModelReady.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasWorkInFlight else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop the remux in progress?"
        alert.informativeText = "Milktoast is still preparing a movie for QuickTime Player."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Going")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            model.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }
}
