import Cocoa
import Carbon.HIToolbox

/// Keyboard handling, designed so MiniTab does NOT see your typing:
/// - The opening shortcut (⌥Tab or ⌘Tab) is a registered system hotkey (RegisterEventHotKey).
///   macOS only notifies us when that exact combination is pressed.
/// - A CGEventTap is switched on only while the switcher is open (Tab, arrows, Esc, search
///   typing, quick actions, modifier release) and switched off again right after.
/// - If hotkey registration ever fails, it falls back to a full-time tap (shown in
///   "Check permissions…").
final class HotkeyTap {
    enum Action { case close, minimize, quit }

    enum Event {
        case start(backwards: Bool)
        case quickSwitch          // hotkey pressed while Secure Input blocks the tap
        case step(Int)
        case commit
        case cancel
        case action(Action)
        case searchBegan
        case search(String)       // full current query
        case quitHold(Bool)       // Q pressed (true) / released (false): quitting needs a hold
    }

    /// Always delivered on the main thread.
    var onEvent: (@MainActor (Event) -> Void)?

    /// .maskAlternate (⌥Tab) or .maskCommand (⌘Tab).
    var modifier: CGEventFlags = .maskAlternate {
        didSet { if modifier != oldValue { registerHotKeys() } }
    }

    private(set) var isSwitching = false
    private(set) var isSearching = false
    private var query = ""

    var isRunning: Bool { tap != nil }
    var usesFallbackTap: Bool { tapAlwaysOn }
    var isModifierHeld: Bool { CGEventSource.flagsState(.combinedSessionState).contains(modifier) }

    private var tap: CFMachPort?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var tapAlwaysOn = false

    // MARK: - Setup

    /// Creates the (normally disabled) tap and registers the hotkey.
    /// Returns false if Accessibility isn't granted yet.
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        installHotKeyHandler()
        registerHotKeys() // also turns the tap off unless we need the fallback
        return true
    }

    /// Re-register (e.g. right after the system ⌘Tab was switched off).
    func refreshHotKeys() { registerHotKeys() }

    /// The switcher closed for a non-keyboard reason (mouse click, watchdog).
    func reset() { endSwitching() }

    private func installHotKeyHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            Unmanaged<HotkeyTap>.fromOpaque(userData).takeUnretainedValue()
                .hotKeyPressed(backwards: hotKeyID.id == 2)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func registerHotKeys() {
        guard handlerRef != nil, !isSwitching else { return }
        unregisterHotKeys()
        let base = modifier == .maskCommand ? cmdKey : optionKey
        var ok = true
        for (id, mods) in [(UInt32(1), base), (UInt32(2), base | shiftKey)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Tab), UInt32(mods),
                                             EventHotKeyID(signature: OSType(0x4D54_4142), id: id), // 'MTAB'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeyRefs.append(ref) } else { ok = false }
        }
        tapAlwaysOn = !ok
        if let tap { CGEvent.tapEnable(tap: tap, enable: tapAlwaysOn) }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    // MARK: - Switching lifecycle

    private func hotKeyPressed(backwards: Bool) {
        if isSwitching { emit(.step(backwards ? -1 : 1)); return }
        // Secure Input (password fields etc.) blocks event taps, so we couldn't track the
        // modifier release. Just jump to the previous window instead.
        if IsSecureEventInputEnabled() { emit(.quickSwitch); return }

        beginSwitching()
        emit(.start(backwards: backwards))
        // Modifier already released (very quick tap)? Finish right away.
        if !isModifierHeld { finish(.commit) }
    }

    private func beginSwitching() {
        isSwitching = true
        isSearching = false
        query = ""
        unregisterHotKeys() // every Tab now goes through the tap
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func endSwitching() {
        guard isSwitching else { return }
        isSwitching = false
        isSearching = false
        query = ""
        if tapAlwaysOn { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) } // stop seeing keystrokes
        registerHotKeys()
    }

    private func finish(_ event: Event) {
        endSwitching()
        emit(event)
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onEvent else { return }
            MainActor.assumeIsolated { handler(event) }
        }
    }

    // MARK: - Tap (only enabled while the switcher is open)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, isSwitching || tapAlwaysOn { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch type {
        case .keyDown:
            if !isSwitching {
                // Only reachable in fallback mode (hotkey registration failed).
                let others = CGEventFlags([.maskAlternate, .maskCommand, .maskControl]).subtracting(modifier)
                guard keyCode == kVK_Tab,
                      flags.contains(modifier),
                      flags.intersection(others).isEmpty else { return pass }
                beginSwitching()
                emit(.start(backwards: flags.contains(.maskShift)))
                return nil
            }
            handleSwitcherKey(keyCode: keyCode, flags: flags, event: event)
            return nil // swallow everything while the switcher is open

        case .keyUp:
            guard isSwitching else { return pass }
            if keyCode == kVK_ANSI_Q && !isSearching { emit(.quitHold(false)) }
            return nil

        case .flagsChanged:
            if isSwitching && !isSearching && !flags.contains(modifier) { finish(.commit) }
            return pass

        default:
            return pass
        }
    }

    private func handleSwitcherKey(keyCode: Int, flags: CGEventFlags, event: CGEvent) {
        switch keyCode {
        case kVK_Tab: emit(.step(flags.contains(.maskShift) ? -1 : 1))
        case kVK_LeftArrow, kVK_UpArrow: emit(.step(-1))
        case kVK_RightArrow, kVK_DownArrow: emit(.step(1))
        case kVK_Escape: finish(.cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter: finish(.commit)
        case kVK_Delete where isSearching:
            if !query.isEmpty {
                query.removeLast()
                emit(.search(query))
            }
        default:
            if isSearching {
                appendSearchText(from: event)
                return
            }
            switch keyCode {
            case kVK_Space: finish(.commit)
            case kVK_ANSI_S: isSearching = true; emit(.searchBegan)
            case kVK_ANSI_W: emit(.action(.close))
            case kVK_ANSI_M: emit(.action(.minimize))
            case kVK_ANSI_Q:
                // Ignore key repeat: the hold itself is timed by the app.
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { emit(.quitHold(true)) }
            default: break
            }
        }
    }

    private func appendSearchText(from event: CGEvent) {
        guard let text = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && !(0xF700...0xF8FF).contains(scalar.value) // function/arrow keys
              })
        else { return }
        query += text
        emit(.search(query))
    }
}
