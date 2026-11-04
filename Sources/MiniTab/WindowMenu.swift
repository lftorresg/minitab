import ApplicationServices

/// Focuses a window through its app's own Window menu (public Accessibility API only).
/// Used for windows on other Spaces when the private remote-AX lookup can't reach them.
enum WindowMenu {
    /// "Window" in the languages macOS apps commonly use. Only that menu is searched: other
    /// menus (History, Bookmarks…) can contain items with the same title as a window, and
    /// pressing those would open a page instead.
    private static let windowMenuNames: Set<String> = [
        "Window", "Janela", "Ventana", "Fenêtre", "Fenster", "Finestra", "Venster",
        "Fönster", "Vindue", "Vindu", "Ikkuna", "Okno", "Окно", "ウインドウ", "窗口", "視窗", "윈도우",
    ]

    enum Result: CustomStringConvertible {
        case pressed, pressFailed(Int32), noTitle, noMenuBar, noWindowMenu([String]), noMatchingItem(Int)

        var description: String {
            switch self {
            case .pressed: return "pressed"
            case .pressFailed(let code): return "press failed (AXError \(code))"
            case .noTitle: return "window has no title"
            case .noMenuBar: return "no menu bar"
            case .noWindowMenu(let names): return "no Window menu (menus: \(names.joined(separator: ", ")))"
            case .noMatchingItem(let count): return "Window menu has \(count) items, none matched"
            }
        }
    }

    static func press(pid: pid_t, windowTitle: String) -> Result {
        guard !windowTitle.isEmpty else { return .noTitle }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let menuBar = AXSafe.element(AXSafe.attribute(app, kAXMenuBarAttribute)) else { return .noMenuBar }
        var menuNames: [String] = []

        // The Window menu sits near the end (just before Help), so search right to left.
        for barItem in AXSafe.elements(AXSafe.attribute(menuBar, kAXChildrenAttribute)).reversed() {
            guard let name = AXSafe.attribute(barItem, kAXTitleAttribute) as? String else { continue }
            menuNames.append(name)
            guard windowMenuNames.contains(name),
                  let menu = AXSafe.elements(AXSafe.attribute(barItem, kAXChildrenAttribute)).first
            else { continue }
            let items = AXSafe.elements(AXSafe.attribute(menu, kAXChildrenAttribute))
            for item in items {
                guard let itemTitle = AXSafe.attribute(item, kAXTitleAttribute) as? String,
                      matches(menuTitle: itemTitle, windowTitle: windowTitle) else { continue }
                let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
                return error == .success ? .pressed : .pressFailed(error.rawValue)
            }
            return .noMatchingItem(items.count) // found the Window menu, but the window isn't in it
        }
        return .noWindowMenu(Array(menuNames.reversed()))
    }

    /// Apps shorten long titles in the middle: "Quarterly Planning Notes and Ro…ap for Next Year".
    static func matches(menuTitle: String, windowTitle: String) -> Bool {
        if menuTitle == windowTitle { return true }
        let parts = menuTitle.components(separatedBy: "…")
        guard parts.count == 2, parts[0].count >= 8, parts[1].count >= 4 else { return false }
        return windowTitle.hasPrefix(parts[0]) && windowTitle.hasSuffix(parts[1])
    }
}
