import Cocoa

enum WindowState: Sendable { case normal, minimized, hidden }

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appLaunchDate: Date?          // guards against PID reuse before destructive actions
    var windowTitle: String
    let appName: String
    let icon: CGImage?
    var state: WindowState
    /// Global CG coordinates (top-left origin). .zero for windows found only via Accessibility.
    let bounds: CGRect
    /// On the Space you're looking at now (vs. another desktop or a full-screen Space).
    let onCurrentSpace: Bool
    var isFullScreen: Bool
    /// Untitled overlay on another Space (e.g. a browser's full-screen toolbar). Filtered out;
    /// only kept for diagnostics.
    let isLikelyHelper: Bool

    var title: String { windowTitle.isEmpty ? appName : windowTitle }

    var label: String {
        switch state {
        case .normal: return isFullScreen ? "\(title) · Full Screen" : title
        case .minimized: return "\(title) · Minimized"
        case .hidden: return "\(title) · Hidden"
        }
    }
}

/// What Accessibility says about one window (plain values, safe across threads).
struct AXWindowSnapshot: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let subrole: String
    let isMinimized: Bool
    let isFullScreen: Bool

    var isStandard: Bool { subrole == kAXStandardWindowSubrole }
    var isRealWindow: Bool { subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole }
}

/// Result of the background Accessibility pass (each app's kAXWindows list).
struct AXPassResult: Sendable {
    var windows: [AXWindowSnapshot] = []
    /// Apps that answered with at least one window, so their list can be trusted.
    var listedPIDs: Set<pid_t> = []
}

@MainActor
enum WindowProvider {
    /// App icons rendered once per process and reused (NSImage -> CGImage is not free).
    private static var iconCache: [pid_t: CGImage] = [:]

    // MARK: - Fast path (runs on every press)

    /// App windows on all Spaces (including full-screen ones), most recent first
    /// (index 0 = the window you're on).
    static func currentWindows(includeHelpers: Bool = false) -> [WindowInfo] {
        let allSpaces = Settings.includeOtherSpaces && Spaces.isAvailable
        let options: CGWindowListOption = allSpaces
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let canReadTitles = Permissions.screenRecording
        var apps: [pid_t: NSRunningApplication] = [:]
        var found: [(info: WindowInfo, z: Int)] = []

        for (z, entry) in list.enumerated() {
            guard
                (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid != ownPID,
                ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width >= 80, bounds.height >= 60
            else { continue }

            let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
            guard let app, app.activationPolicy == .regular else { continue }
            apps[pid] = app

            let title = entry[kCGWindowName as String] as? String ?? ""
            let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            var isHelper = false
            var isFullScreen = false
            if !onScreen {
                // Off-screen: keep only windows that live on some Space (another desktop or a
                // full-screen Space). Ordered-out windows belong to none.
                guard Spaces.isOnAnySpace(number) else { continue }
                // Overlays there (toolbars, bookmark bars) have no title; real windows do.
                // Without Screen Recording no title is readable, so fall back to their shape.
                isHelper = canReadTitles ? title.isEmpty : bounds.height < 150
                if isHelper && !includeHelpers { continue }
                isFullScreen = fillsAScreen(bounds)
            }

            let info = WindowInfo(id: number,
                                  pid: pid,
                                  appLaunchDate: app.launchDate,
                                  windowTitle: title,
                                  appName: app.localizedName ?? (entry[kCGWindowOwnerName as String] as? String) ?? "?",
                                  icon: icon(for: app),
                                  state: app.isHidden ? .hidden : .normal,
                                  bounds: bounds,
                                  onCurrentSpace: onScreen,
                                  isFullScreen: isFullScreen,
                                  isLikelyHelper: isHelper)
            found.append((info: info, z: z))
        }
        return recencyOrder(found)
    }

    /// A full-screen window covers its whole display (minus the notch area on MacBooks).
    private static func fillsAScreen(_ bounds: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let size = screen.frame.size
            guard abs(size.width - bounds.width) < 1 else { return false }
            return abs(size.height - bounds.height) < 1
                || abs(size.height - screen.safeAreaInsets.top - bounds.height) < 1
        }
    }

    /// Most recently used first (WindowMRU, fed by focus events). Windows never focused since
    /// MiniTab started go after those, current Space first, each group in stacking order.
    private static func recencyOrder(_ found: [(info: WindowInfo, z: Int)]) -> [WindowInfo] {
        var rank: [CGWindowID: Int] = [:]
        for (i, id) in WindowMRU.shared.order.enumerated() where rank[id] == nil { rank[id] = i }

        let tracked = found
            .compactMap { item -> (info: WindowInfo, rank: Int)? in
                guard let r = rank[item.info.id] else { return nil }
                return (info: item.info, rank: r)
            }
            .sorted { $0.rank < $1.rank }
            .map { $0.info }
        let untracked = found
            .filter { rank[$0.info.id] == nil }
            .sorted { a, b in
                if a.info.onCurrentSpace != b.info.onCurrentSpace { return a.info.onCurrentSpace }
                return a.z < b.z
            }
            .map { $0.info }
        return tracked + untracked
    }

    // MARK: - Accessibility pass (after the panel is already on screen)

    /// Apps worth asking via Accessibility, and which of them are hidden.
    static func axTargets() -> (pids: [pid_t], hidden: Set<pid_t>) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        return (apps.map(\.processIdentifier), Set(apps.filter(\.isHidden).map(\.processIdentifier)))
    }

    /// Runs OFF the main thread. Short timeouts everywhere, so a hung app can't stall it.
    nonisolated static func axPass(pids: [pid_t]) -> AXPassResult {
        var result = AXPassResult()
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let windows = AXSafe.elements(AXSafe.attribute(app, kAXWindowsAttribute))
            if !windows.isEmpty { result.listedPIDs.insert(pid) }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.1)
                guard let id = AXSafe.windowID(window),
                      let snapshot = snapshot(of: window, id: id, pid: pid) else { continue }
                result.windows.append(snapshot)
            }
        }
        return result
    }

    nonisolated static func snapshot(of window: AXUIElement, id: CGWindowID, pid: pid_t) -> AXWindowSnapshot? {
        let attributes = [kAXTitleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen"] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
              let list = values as? [AnyObject], list.count == 4 else { return nil }
        return AXWindowSnapshot(id: id,
                                pid: pid,
                                title: list[0] as? String ?? "",
                                subrole: list[1] as? String ?? "",
                                isMinimized: list[2] as? Bool ?? false,
                                isFullScreen: list[3] as? Bool ?? false)
    }

    enum Verdict: String {
        case ok = "ok"
        case helperOffSpace = "FILTERED: other Space, untitled overlay"
        case helperCurrentSpace = "FILTERED: current Space, not in the app's AX window list"
    }

    /// Only rejects with positive evidence. Not being reachable through Accessibility is not
    /// evidence: Electron apps and full-screen windows are often unreachable but real.
    static func verdict(for window: WindowInfo, ax: AXWindowSnapshot?, pass: AXPassResult) -> Verdict {
        if window.isLikelyHelper { return .helperOffSpace }
        if window.onCurrentSpace && pass.listedPIDs.contains(window.pid) && !(ax?.isRealWindow ?? false) {
            return .helperCurrentSpace
        }
        return .ok
    }

    /// Drops current-Space helpers, fills in titles / full-screen / minimized state, and appends
    /// minimized or hidden windows the fast path didn't list. Nothing is cached.
    static func merge(_ windows: [WindowInfo], with pass: AXPassResult, hidden: Set<pid_t>) -> [WindowInfo] {
        var byID: [CGWindowID: AXWindowSnapshot] = [:]
        for item in pass.windows { byID[item.id] = item }

        var result: [WindowInfo] = []
        for var window in windows {
            let ax = byID[window.id]
            guard verdict(for: window, ax: ax, pass: pass) == .ok else { continue }
            if let ax {
                if window.windowTitle.isEmpty { window.windowTitle = ax.title }
                if ax.isMinimized && window.state == .normal { window.state = .minimized }
                window.isFullScreen = window.isFullScreen || ax.isFullScreen
            }
            result.append(window)
        }

        let known = Set(windows.map(\.id))
        for item in pass.windows where item.isStandard && !known.contains(item.id) {
            let state: WindowState
            if hidden.contains(item.pid) {
                state = .hidden
            } else if item.isMinimized {
                state = .minimized
            } else {
                continue
            }
            guard let app = NSRunningApplication(processIdentifier: item.pid) else { continue }
            result.append(WindowInfo(id: item.id,
                                     pid: item.pid,
                                     appLaunchDate: app.launchDate,
                                     windowTitle: item.title,
                                     appName: app.localizedName ?? "?",
                                     icon: icon(for: app),
                                     state: state,
                                     bounds: .zero,
                                     onCurrentSpace: false,
                                     isFullScreen: false,
                                     isLikelyHelper: false))
        }
        return result
    }

    /// Plain-text report of every candidate window and what MiniTab decided about it,
    /// plus a self-test of the remote-AX lookup used to reach other Spaces.
    static func diagnostics(_ windows: [WindowInfo], pass: AXPassResult, remoteTest: String) -> String {
        var byID: [CGWindowID: AXWindowSnapshot] = [:]
        for item in pass.windows { byID[item.id] = item }

        var lines = [
            "MiniTab diagnostics: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "SkyLight spaces: \(Spaces.isAvailable) · focus: \(Spaces.canFocus) · remote AX: \(AXRemote.isAvailable)"
                + " · include other Spaces: \(Settings.includeOtherSpaces) · titles readable: \(Permissions.screenRecording)",
            "Remote AX self-test: \(remoteTest)",
            "Last focus attempt: \(WindowActions.lastFocusReport)",
            "",
        ]
        for window in windows {
            let ax = byID[window.id]
            let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
            let space = window.onCurrentSpace ? "current Space" : "other Space"
            lines.append("#\(window.id) \(window.appName) | \"\(window.windowTitle)\" | \(size) | \(space)"
                + " | subrole=\(ax?.subrole ?? "-") fullScreen=\(window.isFullScreen || (ax?.isFullScreen ?? false))"
                + " | \(verdict(for: window, ax: ax, pass: pass).rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    /// Can the remote-token lookup find windows we already know (minimized ones, which the
    /// normal AX list includes)? Tells whether focusing other-Space windows can use it.
    nonisolated static func remoteSelfTest(_ pass: AXPassResult) -> String {
        guard AXRemote.isAvailable else { return "unavailable" }
        var byPID: [pid_t: Set<CGWindowID>] = [:]
        for item in pass.windows where item.isMinimized { byPID[item.pid, default: []].insert(item.id) }
        guard !byPID.isEmpty else { return "no minimized windows to test with" }
        var parts: [String] = []
        for (pid, ids) in byPID.prefix(4) {
            let start = ContinuousClock.now
            let scan = AXRemote.findWindows(pid: pid, ids: ids, budget: .milliseconds(400))
            let ms = (ContinuousClock.now - start).components.attoseconds / 1_000_000_000_000_000
                + (ContinuousClock.now - start).components.seconds * 1000
            parts.append("pid \(pid): found \(scan.found.count)/\(ids.count), complete=\(scan.complete), \(ms) ms")
        }
        return parts.joined(separator: "; ")
    }

    private static func icon(for app: NSRunningApplication) -> CGImage? {
        let pid = app.processIdentifier
        if let cached = iconCache[pid] { return cached }
        if iconCache.count > 64 { iconCache.removeAll() } // crude bound; quit apps fall out
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        let image = app.icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        iconCache[pid] = image
        return image
    }
}
