import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A regular app, not a menu-bar accessory: sketcher is something you
        // launch and keep open, so it belongs in the Dock and ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(appName: "Sketcher")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open a blank canvas on launch — the app's whole premise is that one is
    /// already waiting for you.
    ///
    /// AppKit suppresses this by itself when it has autosaved untitled
    /// documents to reopen, so no coordination is needed here.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
