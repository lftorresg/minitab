import CoreGraphics

// Undocumented but long-stable CoreGraphics/SkyLight symbol.
// It toggles the system's built-in "symbolic hotkeys" for the current login session.
// IDs: 1 = ⌘Tab, 2 = ⌘⇧Tab.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

/// Turns the system ⌘Tab app switcher off (so MiniTab can own ⌘Tab) or back on.
enum NativeSwitcher {
    private static let hotKeys: [Int32] = [1, 2]

    static func setEnabled(_ enabled: Bool) {
        for key in hotKeys { _ = CGSSetSymbolicHotKeyEnabled(key, enabled) }
    }
}
