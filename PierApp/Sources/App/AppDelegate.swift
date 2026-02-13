import Cocoa
import SwiftUI

/// App delegate for macOS-specific lifecycle management.
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure app appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Set up global keyboard shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return self.handleKeyEvent(event)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up terminal sessions
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Global key handling (if needed beyond SwiftUI)
        return event
    }
}

extension Notification.Name {
    static let appWillTerminate = Notification.Name("pier.appWillTerminate")
}
