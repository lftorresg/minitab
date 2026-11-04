import Cocoa

/// Remembers which windows you used most recently, across apps, Spaces and displays,
/// so the switcher lists them most recent first.
///
/// Event-driven, nothing polls:
/// - app switches (NSWorkspace),
/// - window focus changes *inside* an app (an AXObserver per app: clicking another browser
///   window, ⌘`, a window on the other display),
/// - switches made through MiniTab.
/// Only window IDs are kept, never titles.
@MainActor
final class WindowMRU {
    static let shared = WindowMRU()

    private(set) var order: [CGWindowID] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private let maxEntries = 128

    func start() {
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated {
                    self?.observe(pid) // apps launched before Accessibility was granted, or slow starters
                    self?.recordFocusedWindow(of: pid)
                }
            })
            workspaceObservers.append(center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.observe(pid) }
            })
            workspaceObservers.append(center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.stopObserving(pid) }
            })
        }
        observeRunningApps()
        recordFrontmostWindow()
    }

    /// Call again once Accessibility is granted (observers can't be created before that).
    func observeRunningApps() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app.processIdentifier)
        }
    }

    /// Adds IDs not seen yet at the end, keeping known order. Used once at launch, so the first
    /// switch before any focus event is still sensible (current stacking order).
    func seed(_ ids: [CGWindowID]) {
        for id in ids where !order.contains(id) { order.append(id) }
        trim()
    }

    func record(_ id: CGWindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        trim()
    }

    /// Records the window you're on right now and returns its ID (nil if the frontmost app
    /// has no focused window, e.g. an empty desktop). Called on every press, so index 0 is
    /// always correct even if some event was missed.
    @discardableResult
    func recordFrontmostWindow() -> CGWindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return recordFocusedWindow(of: front.processIdentifier)
    }

    // MARK: - Private

    private func trim() {
        if order.count > maxEntries { order.removeLast(order.count - maxEntries) }
    }

    @discardableResult
    private func recordFocusedWindow(of pid: pid_t) -> CGWindowID? {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = AXSafe.element(AXSafe.attribute(app, kAXFocusedWindowAttribute)),
              let id = AXSafe.windowID(window) else { return nil }
        record(id)
        return id
    }

    private func observe(_ pid: pid_t) {
        guard axObservers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let mru = Unmanaged<WindowMRU>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            // Background apps can move focus between their own windows without you doing
            // anything; only the frontmost app's focus changes count as "used".
            guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let id = AXSafe.windowID(element) else { return }
            MainActor.assumeIsolated { mru.record(id) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon) == .success
        else { return } // app not ready yet; retried on its next activation
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer
    }

    private func stopObserving(_ pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
