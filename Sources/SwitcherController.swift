import AppKit

/// State machine: Cmd+Tab opens, Tab/Shift+Tab/arrows move, releasing Cmd commits,
/// Esc cancels, Cmd+Q quits the highlighted app, Cmd+H hides it.
final class SwitcherController {
    private let panel = SwitcherPanel()
    private var apps: [SpaceApp] = []
    private var selected = 0
    private(set) var isActive = false

    /// Most recently activated PIDs, newest first.
    private var mru: [pid_t] = []
    /// Most recently activated windows, newest first, for switching inside one app.
    private var windowMRU: [CGWindowID] = []
    private var observer: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { mru = [front.processIdentifier] }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.noteActivated(app.processIdentifier)
            SpaceApps.rememberWindows(of: app.processIdentifier)
            self.noteFocusedWindow(of: app.processIdentifier)
        }
    }

    /// Moves a pid to the head of the MRU list. Called for our own activations
    /// too: focusing through the window server posts no activation notification,
    /// so without this the order would lag behind by one switch.
    func noteActivated(_ pid: pid_t) {
        mru.removeAll { $0 == pid }
        mru.insert(pid, at: 0)
        if mru.count > 64 { mru.removeLast() }
    }

    /// Records the window an app was activated with, so switching by mouse counts
    /// towards the window order too, not only picks made here.
    private func noteFocusedWindow(of pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(raw as! AXUIElement, &wid) == .success, wid != 0 else { return }
        noteWindow(wid)
    }

    private func noteWindow(_ wid: CGWindowID) {
        windowMRU.removeAll { $0 == wid }
        windowMRU.insert(wid, at: 0)
        if windowMRU.count > 128 { windowMRU.removeLast() }
    }

    func handleCmdTab(reverse: Bool) {
        if !isActive {
            apps = SpaceApps.currentSpaceApps(mru: mru, windowMRU: windowMRU)
            guard !apps.isEmpty else { return }
            isActive = true
            // Skip the first item only when it is the app already in front.
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let firstIsFront = apps[0].app.processIdentifier == frontPid || apps[0].app.processIdentifier == mru.first
            if reverse {
                selected = apps.count - 1
            } else {
                selected = firstIsFront && apps.count > 1 ? 1 : 0
            }
            panel.show(apps: apps, selected: selected)
        } else {
            move(reverse ? -1 : 1)
        }
    }

    func handleKey(keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 53: cancel(); return true                  // Esc
        case 123, 126: move(-1); return true            // Left / Up
        case 124, 125: move(1); return true             // Right / Down
        case 12 where flags.contains(.maskCommand):     // Cmd+Q
            apps[selected].app.terminate()
            removeSelected()
            return true
        case 4 where flags.contains(.maskCommand):      // Cmd+H
            apps[selected].app.hide()
            removeSelected()
            return true
        default:
            return false
        }
    }

    func commit() {
        guard isActive else { return }
        isActive = false
        panel.hide()
        guard apps.indices.contains(selected) else { return }
        activate(apps[selected])
    }

    func cancel() {
        isActive = false
        panel.hide()
    }

    private func move(_ delta: Int) {
        guard !apps.isEmpty else { return }
        selected = (selected + delta + apps.count) % apps.count
        panel.select(selected)
    }

    private func removeSelected() {
        apps.remove(at: selected)
        if apps.isEmpty { cancel(); return }
        selected = min(selected, apps.count - 1)
        panel.show(apps: apps, selected: selected)
    }

    private func activate(_ item: SpaceApp) {
        let app = item.app
        if item.isMinimized {
            restore(item)
            return
        }
        noteActivated(app.processIdentifier)
        if let wid = item.windowIDs.first { noteWindow(wid) }
        if app.isHidden { app.unhide() }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let window = axWindow(for: item, appElement: appElement)
        if let window {
            // Restore a minimised window so the user actually sees something.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // A window on another Space is reached the ordinary way, so macOS follows us
        // there. The window-server shortcut below deliberately never changes Space.
        if item.isOnCurrentSpace, let wid = item.windowIDs.first,
           WindowFocus.focus(pid: app.processIdentifier, windowID: wid) {
            // Focused through the window server: the Dock never sees an activation,
            // so it cannot jump to another Space of the same app.
            if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            return
        }

        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Brings back a minimised window, or an app hidden with Cmd+H. Accessibility
    /// lists nothing for such an app until it is active again, so the window is
    /// unminimised after activating, with a couple of retries.
    private func restore(_ item: SpaceApp) {
        let app = item.app
        noteActivated(app.processIdentifier)
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        func unminimise() -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], !windows.isEmpty else { return false }
            let wanted = item.windowIDs.first
            var target: AXUIElement?
            for window in windows {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(window, &wid) == .success, wid == wanted { target = window; break }
                var minimised: CFTypeRef?
                if target == nil,
                   AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimised) == .success,
                   (minimised as? Bool) == true {
                    target = window
                }
            }
            guard let target = target ?? windows.first else { return false }
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            return true
        }

        if unminimise() { return }
        for delay in [0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = unminimise() }
        }
    }

    /// Finds the AX element of the app's frontmost window on the current Space.
    private func axWindow(for item: SpaceApp, appElement: AXUIElement) -> AXUIElement? {
        guard !item.windowIDs.isEmpty else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var byID: [CGWindowID: AXUIElement] = [:]
        for w in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success { byID[wid] = w }
        }
        for wid in item.windowIDs {
            if let w = byID[wid] { return w }
        }
        return nil
    }
}

/// Undocumented but long-standing HIServices function mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
