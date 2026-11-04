import Foundation
import CoreGraphics
import ApplicationServices

/// Optional private SkyLight functions, loaded at runtime
/// with dlsym. If any disappears in a future macOS, MiniTab falls back to showing only the
/// current Space instead of failing to launch. "Include Other Spaces" in the menu turns all of
/// this off.
enum Spaces {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecordToFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnectionID = symbol(skyLight, "SLSMainConnectionID", as: MainConnectionIDFn.self)
    private static let copySpacesForWindows = symbol(skyLight, "SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let setFrontProcess = symbol(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecordTo = symbol(skyLight, "SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let getProcessForPID = symbol(defaultHandle, "GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let connection: Int32? = mainConnectionID?()

    static var isAvailable: Bool { connection != nil && copySpacesForWindows != nil }
    static var canFocus: Bool { setFrontProcess != nil && getProcessForPID != nil }

    /// True if the window lives on some Space: the current one, another desktop, or a
    /// full-screen Space. Ordered-out helper windows belong to none.
    static func isOnAnySpace(_ id: CGWindowID) -> Bool {
        guard let connection, let copySpacesForWindows else { return false }
        let ids = [NSNumber(value: id)] as CFArray
        guard let spaces = copySpacesForWindows(connection, 0x7 /* all Spaces */, ids)?.takeRetainedValue() else {
            return false
        }
        return CFArrayGetCount(spaces) > 0
    }

    /// Focus sequence, part 1: make that window's process frontmost *for that
    /// window* and make the window key. The caller then sends an AX raise. Together these make
    /// macOS switch to the window's Space (desktop or full screen).
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        guard setFrontProcess(&psn, windowID, 0x200 /* user-generated */) == 0 else { return false }
        makeKeyWindow(&psn, windowID)
        return true
    }

    /// The "make key window" event record (layout as used by the yabai window manager).
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        guard let postEventRecordTo else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecordTo(&psn, &bytes)
    }
}
