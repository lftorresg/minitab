import Cocoa
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyTap()
    private lazy var switcher = SwitcherPanel()
    private var signalSources: [DispatchSourceSignal] = []

    // Menu
    private var statusItem: NSStatusItem?
    private var secureInputItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var commandTabItem: NSMenuItem?
    private var thumbnailsItem: NSMenuItem?
    private var otherSpacesItem: NSMenuItem?
    private var screenItems: [NSMenuItem] = []

    // Switcher state
    private var allWindows: [WindowInfo] = []
    private var visibleWindows: [WindowInfo] = []   // allWindows filtered by the search query
    private var selected = 0
    private var query: String?                      // nil = not in search mode
    private var screen: NSScreen?
    private var showTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    // Thumbnails are reused for a few seconds, so rapid re-opens don't recapture everything.
    private struct CachedThumbnail { let image: CGImage; let capturedAt: ContinuousClock.Instant }
    private var thumbnailCache: [CGWindowID: CachedThumbnail] = [:]
    private var thumbnailTask: Task<Void, Never>?
    private var purgeTask: Task<Void, Never>?
    private let thumbnailMaxAge: Duration = .seconds(5)
    /// Thumbnails are wiped this long after the switcher closes (they can show anything).
    private let thumbnailRetention: Duration = .seconds(30)
    private var lastSearchInput = ContinuousClock.now
    private var quitHoldTask: Task<Void, Never>?
    private let quitHoldDuration: Duration = .milliseconds(700)
    private let searchIdleTimeout: Duration = .seconds(30)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one MiniTab at a time (two key taps / hotkeys would fight). exit() rather than
        // terminate, so we don't touch the system ⌘Tab the other instance may own.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            exit(0)
        }
        Settings.migrateIfNeeded()

        // If a previous run crashed with "Replace ⌘Tab" on, give the system ⌘Tab back first;
        // applyShortcut() below turns it off again only once our hotkey is live.
        NativeSwitcher.setEnabled(true)
        // Process-wide cap on every Accessibility call, so a hung or hostile app can't freeze us.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        setupStatusItem()
        WindowMRU.shared.start()
        switcher.onPick = { [weak self] index in self?.commit(index: index) }
        switcher.onClose = { [weak self] index in self?.perform(.close, at: index) }
        switcher.onHover = { [weak self] index in self?.hoverSelect(index) }
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        restoreNativeSwitcherOnSignals()
        applyShortcut()

        if Settings.showThumbnails && !Permissions.screenRecording { Permissions.requestScreenRecording() }
        if !Permissions.accessibility { Permissions.promptAccessibility() }
        startHotkeyWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeSwitcher.setEnabled(true)
    }

    // MARK: - Hotkey

    private func startHotkeyWhenTrusted() {
        if hotkey.start() { applyShortcut(); seedRecency(); return }
        // Accessibility not granted yet: retry until the user enables it.
        Task { [weak self] in
            while let self, !self.hotkey.start() {
                try? await Task.sleep(for: .seconds(2))
            }
            self?.applyShortcut()
            self?.seedRecency()
        }
    }

    /// Focus observers need Accessibility; once it's there, start them and seed the recency
    /// list with the current stacking order so the very first switch is already sensible.
    private func seedRecency() {
        WindowMRU.shared.observeRunningApps()
        WindowMRU.shared.recordFrontmostWindow()
        WindowMRU.shared.seed(WindowProvider.currentWindows().filter(\.onCurrentSpace).map(\.id))
    }

    private func handle(_ event: HotkeyTap.Event) {
        switch event {
        case .start(let backwards):
            // Cheap part only: the window list. Nothing is drawn or captured yet.
            // Record where you are right now first, so index 0 is always the current window.
            let current = WindowMRU.shared.recordFrontmostWindow()
            allWindows = WindowProvider.currentWindows()
            guard !allWindows.isEmpty else { hotkey.reset(); return }
            visibleWindows = allWindows
            query = nil
            // Tab goes to the previous window, unless you're not on any window (empty desktop),
            // in which case the most recent one is the target.
            let onAWindow = current != nil && allWindows.first?.id == current
            if backwards {
                selected = allWindows.count - 1
            } else {
                selected = onAWindow && allWindows.count > 1 ? 1 : 0
            }
            scheduleShow()

        case .quickSwitch:
            let windows = WindowProvider.currentWindows()
            if windows.count > 1 { WindowActions.focus(windows[1]) }

        case .step(let delta):
            let n = visibleWindows.count
            guard n > 0 else { return }
            cancelQuitHold() // moving the selection aborts a quit in progress
            selected = ((selected + delta) % n + n) % n
            switcher.select(selected) // moves one layer; no redraw of the grid

        case .commit:
            commit(index: selected)

        case .cancel:
            hide()

        case .action(let action):
            perform(action)

        case .quitHold(let pressed):
            if pressed { beginQuitHold() } else { cancelQuitHold() }

        case .searchBegan:
            query = ""
            lastSearchInput = .now
            applyFilter()

        case .search(let text):
            query = text
            lastSearchInput = .now
            applyFilter()
        }
    }

    // MARK: - Switcher

    private func scheduleShow() {
        showTask?.cancel()
        showTask = Task { [weak self] in
            // A quick tap never draws anything or asks other apps about their windows.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, self.hotkey.isSwitching else { return }

            // Show right away with the fast list; nothing on the way to the first frame waits
            // for other apps.
            self.purgeTask?.cancel()
            let ids = Set(self.allWindows.map(\.id))
            self.thumbnailCache = self.thumbnailCache.filter { ids.contains($0.key) } // drop closed windows
            self.screen = self.targetScreen()
            self.applyFilter(resetSelection: false)
            self.render()
            self.startWatchdog()
            self.refreshStaleThumbnails()

            // Then refine in the background: titles, minimized / hidden windows, current-Space
            // helpers. The selection stays on the same window across the update.
            let (pids, hidden) = WindowProvider.axTargets()
            let pass = await Task.detached(priority: .userInitiated) {
                WindowProvider.axPass(pids: pids)
            }.value
            guard !Task.isCancelled, self.hotkey.isSwitching else { return }
            let selectedID = self.visibleWindows.indices.contains(self.selected)
                ? self.visibleWindows[self.selected].id : nil
            self.allWindows = WindowProvider.merge(self.allWindows, with: pass, hidden: hidden)
            if self.allWindows.isEmpty { self.hide(); return }
            self.applyFilter(resetSelection: false, keeping: selectedID)
        }
    }

    private func render() {
        guard let screen = screen ?? NSScreen.main else { return }
        let thumbnails = Settings.showThumbnails ? thumbnailCache.mapValues(\.image) : [:]
        switcher.show(visibleWindows, selected: selected, thumbnails: thumbnails,
                      iconsOnly: !Settings.showThumbnails, searchQuery: query, on: screen)
    }

    private func applyFilter(resetSelection: Bool = true, keeping keepID: CGWindowID? = nil) {
        if let query, !query.isEmpty {
            visibleWindows = allWindows.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.appName.localizedCaseInsensitiveContains(query)
            }
            if resetSelection { selected = 0 } // best match first
        } else {
            visibleWindows = allWindows
        }
        if let keepID, let i = visibleWindows.firstIndex(where: { $0.id == keepID }) { selected = i }
        selected = visibleWindows.isEmpty ? 0 : min(selected, visibleWindows.count - 1)
        if switcher.isVisible { render() }
    }

    /// W / M / Q on the selected tile, or the close button on any tile (`index`).
    private func perform(_ action: HotkeyTap.Action, at index: Int? = nil) {
        let i = index ?? selected
        guard visibleWindows.indices.contains(i) else { return }
        let target = visibleWindows[i]
        // Keep the highlight on the same window if it survives the action.
        let selectedID = visibleWindows.indices.contains(selected) ? visibleWindows[selected].id : nil
        switch action {
        case .close:
            WindowActions.close(target)
            allWindows.removeAll { $0.id == target.id }
        case .minimize:
            WindowActions.minimize(target)
            if let i = allWindows.firstIndex(where: { $0.id == target.id }) { allWindows[i].state = .minimized }
        case .quit:
            WindowActions.quit(target)
            allWindows.removeAll { $0.pid == target.pid }
        }
        if allWindows.isEmpty { hide(); return }
        applyFilter(resetSelection: false, keeping: selectedID)
    }

    /// Safety net while the panel is open: if the tap ever misses the modifier release
    /// (e.g. Secure Input kicked in mid-switch), commit instead of getting stuck.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if !self.hotkey.isSwitching { self.hide(); return }
                // Secure Input blinds the key tap, and an abandoned search would keep
                // swallowing every key: close in both cases.
                if IsSecureEventInputEnabled() { self.hide(); return }
                if self.hotkey.isSearching && ContinuousClock.now - self.lastSearchInput > self.searchIdleTimeout {
                    self.hide(); return
                }
                if !self.hotkey.isSearching && !self.hotkey.isModifierHeld {
                    self.commit(index: self.selected)
                    return
                }
            }
        }
    }

    private func refreshStaleThumbnails() {
        guard Settings.showThumbnails, thumbnailTask == nil, Permissions.screenRecording else { return }
        let now = ContinuousClock.now
        let stale = allWindows.filter { $0.state == .normal }.map(\.id).filter { id in
            guard let cached = thumbnailCache[id] else { return true }
            return now - cached.capturedAt > thumbnailMaxAge
        }
        guard !stale.isEmpty else { return }

        let pixelSize = switcher.thumbnailPixelSize
        thumbnailTask = Task { [weak self] in
            let images = await Thumbnailer.capture(ids: stale, pixelSize: pixelSize)
            guard let self else { return }
            let capturedAt = ContinuousClock.now
            for (id, image) in images {
                self.thumbnailCache[id] = CachedThumbnail(image: image, capturedAt: capturedAt)
            }
            self.switcher.setThumbnails(images) // no-op if already closed; the cache still fills
            self.thumbnailTask = nil
        }
    }

    /// The mouse moved onto a tile: it becomes the selection, exactly like pressing Tab to it,
    /// so releasing the modifier (or Return) opens the window under the mouse.
    private func hoverSelect(_ index: Int) {
        guard visibleWindows.indices.contains(index), index != selected else { return }
        cancelQuitHold()
        selected = index
        switcher.select(index)
    }

    /// Quitting an app takes a ~0.7 s hold of Q, so a stray key press can't close a browser
    /// (and every window in it) by accident.
    private func beginQuitHold() {
        guard quitHoldTask == nil, switcher.isVisible, visibleWindows.indices.contains(selected) else { return }
        let target = visibleWindows[selected]
        switcher.showQuitHold(at: selected, appName: target.appName,
                              duration: Double(quitHoldDuration.components.attoseconds) / 1e18
                                  + Double(quitHoldDuration.components.seconds))
        quitHoldTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.quitHoldDuration)
            guard !Task.isCancelled else { return }
            self.quitHoldTask = nil
            self.switcher.hideQuitHold()
            guard let i = self.visibleWindows.firstIndex(where: { $0.id == target.id }) else { return }
            self.perform(.quit, at: i)
        }
    }

    private func cancelQuitHold() {
        quitHoldTask?.cancel()
        quitHoldTask = nil
        switcher.hideQuitHold()
    }

    private func hide() {
        cancelQuitHold()
        showTask?.cancel(); showTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        switcher.hide()
        hotkey.reset()
        query = nil
        schedulePurge()
    }

    /// Window snapshots can contain anything (banking, passwords, private windows),
    /// so they don't outlive their usefulness.
    private func schedulePurge() {
        purgeTask?.cancel()
        purgeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.thumbnailRetention)
            guard !Task.isCancelled, !self.switcher.isVisible else { return }
            self.thumbnailCache.removeAll()
        }
    }

    private func commit(index: Int) {
        let target = visibleWindows.indices.contains(index) ? visibleWindows[index] : nil
        hide()
        if let target { WindowActions.focus(target) }
    }

    private func targetScreen() -> NSScreen? {
        switch Settings.screen {
        case .mouse:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        case .activeWindow:
            // The window you're actually in (works in full screen, where the cursor is hidden
            // and may sit on the other display), then the top window, then the mouse.
            if let frame = WindowActions.frontmostWindowFrame(), let match = display(containing: frame) {
                return match
            }
            if let bounds = allWindows.first(where: { $0.onCurrentSpace })?.bounds,
               let match = display(containing: bounds) {
                return match
            }
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        case .primary:
            return NSScreen.screens.first
        }
    }

    /// Screen showing most of a rect given in global CG coordinates (top-left origin).
    private func display(containing cgRect: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        // CG is top-left based; NSScreen frames are bottom-left based.
        let rect = CGRect(x: cgRect.minX, y: primary.frame.maxY - cgRect.maxY,
                          width: cgRect.width, height: cgRect.height)
        return NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }.flatMap { $0.frame.intersects(rect) ? $0 : nil }
    }

    // MARK: - ⌥Tab vs ⌘Tab

    @objc private func toggleCommandTab() {
        Settings.useCommandTab.toggle()
        applyShortcut()
    }

    private func applyShortcut() {
        if Settings.useCommandTab {
            // Only switch the system ⌘Tab off while our hotkey can actually work,
            // so you're never left with no ⌘Tab at all.
            NativeSwitcher.setEnabled(!hotkey.isRunning)
            hotkey.modifier = .maskCommand
        } else {
            hotkey.modifier = .maskAlternate
            NativeSwitcher.setEnabled(true)
        }
        hotkey.refreshHotKeys()
        refreshMenuState()
    }

    /// Quit via `kill`/`pkill` (e.g. `build.sh --install`) skips applicationWillTerminate,
    /// so also give the system ⌘Tab back on SIGTERM/SIGINT/SIGHUP.
    private func restoreNativeSwitcherOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NativeSwitcher.setEnabled(true)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                     accessibilityDescription: "MiniTab")
        let menu = NSMenu()
        menu.delegate = self

        let secure = menu.addItem(withTitle: "⚠︎ Secure Input is on: only quick switching works",
                                  action: nil, keyEquivalent: "")
        secure.isEnabled = false
        secure.isHidden = true
        secureInputItem = secure

        addItem(to: menu, "Check Permissions…", #selector(checkPermissions))
        launchAtLoginItem = addItem(to: menu, "Launch at Login", #selector(toggleLaunchAtLogin))
        menu.addItem(.separator())
        commandTabItem = addItem(to: menu, "Replace ⌘Tab", #selector(toggleCommandTab))
        thumbnailsItem = addItem(to: menu, "Show Thumbnails", #selector(toggleThumbnails))
        otherSpacesItem = addItem(to: menu, "Include Other Spaces", #selector(toggleOtherSpaces))

        let screenMenu = NSMenu()
        for choice in Settings.ScreenChoice.allCases {
            let choiceItem = screenMenu.addItem(withTitle: choice.title, action: #selector(selectScreen(_:)),
                                                keyEquivalent: "")
            choiceItem.target = self
            choiceItem.representedObject = choice.rawValue
            screenItems.append(choiceItem)
        }
        let screenParent = menu.addItem(withTitle: "Show Switcher On", action: nil, keyEquivalent: "")
        menu.setSubmenu(screenMenu, for: screenParent)

        menu.addItem(.separator())
        addItem(to: menu, "Copy Window Diagnostics", #selector(copyDiagnostics))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MiniTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        secureInputItem?.isHidden = !IsSecureEventInputEnabled()
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        commandTabItem?.state = Settings.useCommandTab ? .on : .off
        thumbnailsItem?.state = Settings.showThumbnails ? .on : .off
        otherSpacesItem?.state = Settings.includeOtherSpaces ? .on : .off
        // Make the fallback (full-time key tap) visible, not just in a dialog.
        let symbol = hotkey.usesFallbackTap ? "exclamationmark.triangle" : "rectangle.on.rectangle"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MiniTab")
        for choiceItem in screenItems {
            choiceItem.state = (choiceItem.representedObject as? String) == Settings.screen.rawValue ? .on : .off
        }
    }

    @objc private func toggleThumbnails() {
        Settings.showThumbnails.toggle()
        if Settings.showThumbnails {
            if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        } else {
            thumbnailCache.removeAll()
        }
        refreshMenuState()
    }

    @objc private func toggleOtherSpaces() {
        Settings.includeOtherSpaces.toggle()
        refreshMenuState()
    }

    /// Copies what MiniTab sees about every window, to diagnose phantom or missing entries.
    /// Only on explicit request, only to the clipboard; it contains window titles.
    @objc private func copyDiagnostics() {
        let windows = WindowProvider.currentWindows(includeHelpers: true)
        let (pids, _) = WindowProvider.axTargets()
        Task { [weak self] in
            let (pass, remoteTest) = await Task.detached(priority: .userInitiated) {
                let pass = WindowProvider.axPass(pids: pids)
                return (pass, WindowProvider.remoteSelfTest(pass))
            }.value
            let text = WindowProvider.diagnostics(windows, pass: pass, remoteTest: remoteTest)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            guard self != nil else { return }
            let alert = NSAlert()
            alert.messageText = "Diagnostics copied"
            alert.informativeText = "Details for \(windows.count) windows are on the clipboard. They include window titles, so review them before sharing."
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let choice = Settings.ScreenChoice(rawValue: raw) {
            Settings.screen = choice
        }
        refreshMenuState()
    }

    // MARK: - Launch at login (SMAppService, macOS 13+)

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        // macOS may ask the user to approve it in Login Items first.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshMenuState()
    }

    @objc private func checkPermissions() {
        let screenRecording: String
        if Permissions.screenRecording {
            screenRecording = "granted"
        } else {
            screenRecording = Settings.showThumbnails ? "MISSING" : "not needed (thumbnails off)"
        }
        let keyboard = hotkey.usesFallbackTap
            ? "fallback: full-time key tap (hotkey registration failed)"
            : "hotkey only; key tap is off while the switcher is closed"

        let alert = NSAlert()
        alert.messageText = "MiniTab permissions"
        alert.informativeText = """
        Accessibility (hotkey, focusing and window actions): \(Permissions.accessibility ? "granted" : "MISSING")
        Screen Recording (thumbnails only): \(screenRecording)
        Keyboard: \(keyboard)
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: Permissions.openSettings(.accessibility)
        case .alertSecondButtonReturn:
            // Make sure MiniTab is listed there (it may have been removed by a reset).
            if !Permissions.screenRecording { Permissions.requestScreenRecording() }
            Permissions.openSettings(.screenRecording)
        default: break
        }
    }
}
