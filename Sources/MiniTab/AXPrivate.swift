import ApplicationServices

// Undocumented but long-stable HIServices symbol: maps an Accessibility element to the
// CGWindowID of the window that contains it.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Values returned by the Accessibility API are produced by the *target app*, which controls
/// their type. Never cast them blindly: a buggy or hostile app could otherwise crash MiniTab.
enum AXSafe {
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        var result: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let item = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            if let el = Self.element(item) { result.append(el) }
        }
        return result
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Note: this returns the window number for ANY element inside a window (a button, the web
    /// area…), not only for the window element itself. Check the role when that matters.
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}

/// Windows on other Spaces: the public AX API won't list them, but it can still talk to them
/// if their element handles ("remote tokens") are rebuilt by enumerating element IDs.
/// `_AXUIElementCreateWithRemoteToken` is loaded with dlsym; if it's ever missing, this is a no-op.
enum AXRemote {
    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let create: CreateWithRemoteTokenFn? = {
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
              let pointer = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(pointer, to: CreateWithRemoteTokenFn.self)
    }()

    static var isAvailable: Bool { create != nil }

    /// Looks for the AX elements of `ids` (windows of one app) within a time budget.
    /// `complete == true` means the whole ID range was scanned, so anything not found has no
    /// AX window element (typically an overlay or helper window).
    static func findWindows(pid: pid_t, ids: Set<CGWindowID>,
                            budget: Duration) -> (found: [CGWindowID: AXUIElement], complete: Bool) {
        guard let create, !ids.isEmpty else { return ([:], true) }

        // Token layout: pid (4 bytes), 0 (4), 'coco' magic (4), element ID (8).
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }

        let clock = ContinuousClock()
        let deadline = clock.now + budget
        var found: [CGWindowID: AXUIElement] = [:]

        for elementID: UInt64 in 0..<1500 {
            if found.count == ids.count { return (found, true) }
            if clock.now > deadline { return (found, false) }
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            // Elements *inside* the window report the same window ID; only the window element
            // itself can be raised, so keep scanning until we hit the one with the window role.
            if let id = AXSafe.windowID(element), ids.contains(id), found[id] == nil,
               (AXSafe.attribute(element, kAXRoleAttribute) as? String) == kAXWindowRole {
                found[id] = element
            }
        }
        return (found, true)
    }
}
