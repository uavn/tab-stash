import AppKit
import ApplicationServices

/// Deprecated Carbon call, hidden from Swift but still exported by HIServices.
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Focuses one specific window straight through the window server, the way
/// AltTab and yabai do. This bypasses the Dock's app-activation logic (and its
/// "switch to a Space with open windows for the application" jump), so the
/// window that lives on the current Space comes forward and nothing else moves.
enum WindowFocus {
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let fns: (setFront: SetFrontFn, postEvent: PostEventFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let a = dlsym(h, "_SLPSSetFrontProcessWithOptions"),
              let b = dlsym(h, "SLPSPostEventRecordTo") else { return nil }
        return (unsafeBitCast(a, to: SetFrontFn.self), unsafeBitCast(b, to: PostEventFn.self))
    }()

    static var isAvailable: Bool { fns != nil }

    /// Fronts the process for this window and makes the window key.
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier {
            NSApp.activate(ignoringOtherApps: true)
            // Compared as Int: window numbers do not always fit in a CGWindowID,
            // and converting one that does not would trap.
            let target = NSApp.windows.first { $0.windowNumber == Int(windowID) }
                ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
            target?.makeKeyAndOrderFront(nil)
            return true
        }
        guard let f = fns, var psn = serialNumber(for: pid) else { return false }

        f.setFront(&psn, windowID, 0x200)   // kCPSUserGenerated

        // A CGSEventRecord "left mouse down" addressed to the window by id, aimed far
        // outside its content so no control is hit (layout as reverse-engineered by AltTab).
        var wid = windowID
        var point = CGPoint(x: 300_000, y: 300_000)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8          // record length
        bytes[0x08] = 0x01          // kCGEventLeftMouseDown
        bytes[0x3a] = 0x10          // undocumented flag, set by yabai/Hammerspoon/AltTab
        memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)
        memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size)
        f.postEvent(&psn, &bytes)
        return true
    }

    private static func serialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return nil }
        return psn
    }
}
