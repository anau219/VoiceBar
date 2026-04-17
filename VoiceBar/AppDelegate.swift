import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    // Prevents applicationShouldHandleReopen from firing during initial launch.
    // When showInDock=true the app has .regular activation policy, and macOS calls
    // shouldHandleReopen immediately at startup (no windows open yet), which would
    // open the main window before the user has interacted with anything.
    private var readyForReopen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.readyForReopen = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && readyForReopen {
            NotificationCenter.default.post(name: .voiceBarReopen, object: nil)
        }
        return true
    }
}

extension Notification.Name {
    static let voiceBarReopen = Notification.Name("com.voicebar.reopen")
}
