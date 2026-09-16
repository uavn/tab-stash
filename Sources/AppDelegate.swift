import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let switcher = SwitcherController()
    private let tap = HotkeyTap()
    private lazy var settingsWindow = SettingsWindowController()
    private var retryTimer: Timer?
    private var permissionItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var promptedForPermission = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        wireTap()
        startTapWhenPossible()
        if CommandLine.arguments.contains("--settings") { settingsWindow.show() }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.menuBarImage()
        let menu = NSMenu()

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())

        permissionItem = NSMenuItem(title: "Accessibility: checking…", action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TabStash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    // MARK: Event tap + permission

    private func wireTap() {
        tap.isActive = { [switcher] in switcher.isActive }
        tap.onCmdTab = { [switcher] reverse in switcher.handleCmdTab(reverse: reverse) }
        tap.onCmdReleased = { [switcher] in switcher.commit() }
        tap.onKeyWhileActive = { [switcher] keyCode, flags in switcher.handleKey(keyCode: keyCode, flags: flags) }
    }

    /// Installs the event tap as soon as macOS lets us. The tap needs Accessibility
    /// access; the grant can arrive while the app is running, so keep retrying
    /// instead of failing once. A stale grant (old signature) is the usual cause
    /// of "trusted but tap fails", so the alert explains how to fix that.
    private func startTapWhenPossible() {
        if tryStartTap() { return }
        if !AXIsProcessTrusted() && !promptedForPermission {
            promptedForPermission = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { return }
            if self.tryStartTap() {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    private var tapRunning = false

    private func tryStartTap() -> Bool {
        guard !tapRunning, AXIsProcessTrusted() else { return false }
        tapRunning = tap.start()
        if !tapRunning { NSLog("Event tap creation failed although Accessibility is trusted; retrying") }
        return tapRunning
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if tapRunning {
            permissionItem.title = "Accessibility: granted ✓ (Cmd+Tab active)"
        } else if AXIsProcessTrusted() {
            permissionItem.title = "Accessibility: granted, waiting for event tap…"
        } else {
            permissionItem.title = "Accessibility: not granted ✗ (remove old entry, then add the app)"
        }
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
    }
}
