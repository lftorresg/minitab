import Foundation

/// User preferences, stored in UserDefaults (domain: the bundle ID, io.github.lftorresg.minitab).
enum Settings {
    enum ScreenChoice: String, CaseIterable {
        case mouse, activeWindow, primary

        var title: String {
            switch self {
            case .mouse: return "Screen with Mouse"
            case .activeWindow: return "Screen with Active Window"
            case .primary: return "Primary Display"
            }
        }
    }

    private static var defaults: UserDefaults { .standard }

    /// One-time copy of settings from the old bundle ID (local.minitab).
    static func migrateIfNeeded() {
        let flag = "migratedFromLocalMinitab"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard let old = UserDefaults(suiteName: "local.minitab") else { return }
        for name in ["useCommandTab", "showThumbnails", "includeOtherSpaces", "screen"]
        where defaults.object(forKey: name) == nil {
            if let value = old.object(forKey: name) { defaults.set(value, forKey: name) }
        }
    }

    static var useCommandTab: Bool {
        get { defaults.bool(forKey: "useCommandTab") }
        set { defaults.set(newValue, forKey: "useCommandTab") }
    }

    /// Off = icons-only mode: no ScreenCaptureKit, no Screen Recording permission needed.
    static var showThumbnails: Bool {
        get { defaults.object(forKey: "showThumbnails") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showThumbnails") }
    }

    /// Off = current Space only, and none of the SkyLight / remote-AX private APIs are used.
    static var includeOtherSpaces: Bool {
        get { defaults.object(forKey: "includeOtherSpaces") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "includeOtherSpaces") }
    }

    static var screen: ScreenChoice {
        get { defaults.string(forKey: "screen").flatMap(ScreenChoice.init(rawValue:)) ?? .activeWindow }
        set { defaults.set(newValue.rawValue, forKey: "screen") }
    }
}
