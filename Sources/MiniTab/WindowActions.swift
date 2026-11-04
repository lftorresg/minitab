import Cocoa
import ApplicationServices

/// Everything MiniTab does to other apps' windows.
@MainActor
enum WindowActions {
    /// What happened on the last focus attempt (window ID + strategy results, no titles).
    /// Shown in "Copy Window Diagnostics".
    private(set) static var lastFocusReport = "none yet"

    /// Activates an app from MiniTab, which is never the active app itself. Since macOS 14,
    /// `NSRunningApplication.activate` from a background app can be silently ignored
    /// (cooperative activation); setting AXFrontmost through Accessibility is not.
    private static func bringToFront(_ appElement: AXUIElement, _ app: NSRunningApplication?) {
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app?.activate(options: [])
    }

    /// Brings one specific window (not just its app) to the front: un-hides its app,
    /// un-minimizes it, or switches to its Space / full-screen Space as needed.
    static func focus(_ target: WindowInfo) {
        WindowMRU.shared.record(target.id)
        let app = NSRunningApplication(processIdentifier: target.pid)
        if target.state == .hidden { app?.unhide() }

        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        // Current Space, minimized, or hidden: the regular AX window list can reach it.
        if let window = findAXWindow(in: appElement, matching: target, allowTitleMatch: target.onCurrentSpace) {
            if isMinimized(window) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            bringToFront(appElement, app)
            lastFocusReport = "#\(target.id): accessibility window list (current Space / minimized / hidden)"
            return
        }

        // Another desktop or a full-screen Space. Strategies, best first:
        guard !target.onCurrentSpace else {
            bringToFront(appElement, app)
            lastFocusReport = "#\(target.id): not found in the app's window list; activated the app only"
            return
        }
        let pid = target.pid, id = target.id, title = target.windowTitle
        lastFocusReport = "#\(id): other Space, in progress…"
        Task {
            // 1. Rebuild the window's AX handle, make its process frontmost for
            //    that window + key, then AX-raise. macOS switches to the window's Space.
            let element = await Task.detached(priority: .userInitiated) {
                AXRemote.findWindows(pid: pid, ids: [id], budget: .milliseconds(300)).found[id]
            }.value
            var remote = "not found"
            if let element {
                let keyed = Spaces.focus(pid: pid, windowID: id)
                let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                bringToFront(appElement, app)
                remote = "found; front+key=\(keyed), raise=\(raised.rawValue)"
                if raised == .success {
                    lastFocusReport = "#\(id): remote AX \(remote)"
                    return
                }
            }

            // 2. Public API: press the window's entry in the app's own Window menu, as a user
            //    would. The app orders that window front; making the app
            //    frontmost then takes macOS to the window's Space.
            let menu = await Task.detached(priority: .userInitiated) {
                WindowMenu.press(pid: pid, windowTitle: title)
            }.value
            let keyed = Spaces.focus(pid: pid, windowID: id)
            bringToFront(appElement, app)
            lastFocusReport = "#\(id): remote AX \(remote); Window menu: \(menu.description); front+key=\(keyed)"
        }
    }

    /// Presses the window's close button (the app may still ask to save).
    static func close(_ target: WindowInfo) {
        withWindowElement(target) { window in
            guard let button = AXSafe.element(AXSafe.attribute(window, kAXCloseButtonAttribute)) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    static func minimize(_ target: WindowInfo) {
        withWindowElement(target) { window in
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Exact window-ID match only (never by title). Windows on other Spaces are reached through
    /// the remote-token lookup, off the main thread.
    private static func withWindowElement(_ target: WindowInfo,
                                          _ action: @escaping @MainActor (AXUIElement) -> Void) {
        if let window = axWindow(for: target) { action(window); return }
        guard !target.onCurrentSpace else { return }
        let pid = target.pid, id = target.id
        Task {
            let element = await Task.detached(priority: .userInitiated) {
                AXRemote.findWindows(pid: pid, ids: [id], budget: .milliseconds(300)).found[id]
            }.value
            if let element { action(element) }
        }
    }

    /// Normal quit, same as ⌘Q (the app may still ask to save). Checks it's still the same
    /// app instance, so a reused PID can't make us quit something else.
    static func quit(_ target: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.launchDate == target.appLaunchDate else { return }
        app.terminate()
    }

    /// Frame (global, top-left origin) of the focused window of the frontmost app.
    static func frontmostWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        guard let window = AXSafe.element(AXSafe.attribute(appElement, kAXFocusedWindowAttribute)),
              let origin = AXSafe.point(AXSafe.attribute(window, kAXPositionAttribute)),
              let size = AXSafe.size(AXSafe.attribute(window, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Helpers

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        (AXSafe.attribute(window, kAXMinimizedAttribute) as? Bool) ?? false
    }

    /// For destructive actions: exact window ID only, never a title match.
    private static func axWindow(for target: WindowInfo) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        return findAXWindow(in: appElement, matching: target, allowTitleMatch: false)
    }

    private static func findAXWindow(in app: AXUIElement, matching target: WindowInfo,
                                     allowTitleMatch: Bool) -> AXUIElement? {
        let windows = AXSafe.elements(AXSafe.attribute(app, kAXWindowsAttribute))
        if let exact = windows.first(where: { AXSafe.windowID($0) == target.id }) { return exact }
        // Fallback for focusing only: match by title.
        guard allowTitleMatch, !target.windowTitle.isEmpty else { return nil }
        return windows.first { (AXSafe.attribute($0, kAXTitleAttribute) as? String) == target.windowTitle }
    }
}
