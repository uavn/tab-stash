import AppKit

/// Session-level CGEventTap that swallows Cmd+Tab (so the system switcher never
/// appears) and forwards navigation keys to the switcher while it is open.
final class HotkeyTap {
    private var tap: CFMachPort?

    var onCmdTab: ((_ reverse: Bool) -> Void)?
    var onCmdReleased: (() -> Void)?
    /// Return true to swallow the key.
    var onKeyWhileActive: ((_ keyCode: Int64, _ flags: CGEventFlags) -> Bool)?
    var isActive: () -> Bool = { false }

    private static let keyTab: Int64 = 48

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let ctrlOrOpt = flags.contains(.maskControl) || flags.contains(.maskAlternate)

        switch type {
        case .keyDown:
            if keyCode == Self.keyTab && cmd && !ctrlOrOpt {
                onCmdTab?(flags.contains(.maskShift))
                return nil
            }
            if isActive(), onKeyWhileActive?(keyCode, flags) == true { return nil }
        case .keyUp:
            if isActive() && keyCode == Self.keyTab { return nil }
        case .flagsChanged:
            if isActive() && !cmd { onCmdReleased?() }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
