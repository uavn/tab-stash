import AppKit

struct SpaceApp {
    let app: NSRunningApplication
    /// Windows this entry stands for, front to back. Exactly one when grouping is off.
    let windowIDs: [CGWindowID]
    /// True when nothing of this entry is visible (all minimised, or the app is hidden).
    let isMinimized: Bool
    /// Window title, set only when windows are listed separately.
    let title: String?
    /// False when this entry only has windows on other Spaces.
    let isOnCurrentSpace: Bool

    var name: String { app.localizedName ?? "?" }
    /// Caption under the icon: the window title when windows are listed separately.
    var label: String {
        guard let title, !title.isEmpty else { return name }
        return title
    }
    var icon: NSImage? { app.icon }
}

enum SpaceApps {
    private struct WindowInfo {
        let wid: CGWindowID
        let onscreen: Bool
        /// Lives on a Space that is not in front. Not on screen, but not minimised either.
        let elsewhere: Bool
        let title: String?
    }

    /// Window IDs Accessibility has confirmed for an app, remembered because it only
    /// answers about apps on the Space in front. Seen once, a window stays trustworthy.
    private static var confirmedWindows: [pid_t: Set<CGWindowID>] = [:]

    /// Notes the windows Accessibility vouches for right now. Worth calling whenever an
    /// app activates: it is then on the Space in front, the only time Accessibility says
    /// anything about it, and the answer stays useful from other Spaces.
    static func rememberWindows(of pid: pid_t) {
        guard let ax = axWindows(pid: pid), !ax.isEmpty else { return }
        confirmedWindows[pid] = Set(ax.keys)
    }

    /// Apps (or single windows, when grouping is off) the switcher should offer.
    /// `mru` orders the apps, `windowMRU` orders the windows inside one app.
    static func currentSpaceApps(mru: [pid_t], windowMRU: [CGWindowID] = []) -> [SpaceApp] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let settings = Settings.shared
        let hidden = settings.hiddenBundleIDs
        let limitToSpace = settings.currentSpaceOnly
        // Always needed, even when every Space is listed: a window on another Space is
        // away, not minimised, and must not be dropped with the minimised ones.
        let activeSpaces = PrivateSpaces.activeSpaceIDs()
        let usePrivate = !activeSpaces.isEmpty

        var entries: [pid_t: [WindowInfo]] = [:]
        var pidsInZOrder: [pid_t] = []

        for w in list {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha == 0 { continue }
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               let width = (b["Width"] as? NSNumber)?.doubleValue,
               let height = (b["Height"] as? NSNumber)?.doubleValue,
               width < 40 || height < 40 { continue }

            let onscreen = (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            // Public fallback when SkyLight is gone: on-screen means the current Space,
            // and minimised windows cannot be told apart.
            let spaces = usePrivate ? PrivateSpaces.spaceIDs(forWindow: wid) : []
            // Belongs to no Space and is not on screen: not something you can switch to.
            // Menu-bar apps park their popovers like this (Macs Fan Control keeps eleven),
            // while a genuinely minimised window keeps the Space it was minimised on.
            if usePrivate, !onscreen, spaces.isEmpty { continue }
            let onCurrentSpace = usePrivate ? !spaces.isDisjoint(with: activeSpaces) : onscreen
            if limitToSpace, !onCurrentSpace { continue }
            let elsewhere = usePrivate && !spaces.isEmpty && !onCurrentSpace

            let title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if entries[pid] == nil { pidsInZOrder.append(pid) }
            entries[pid, default: []].append(WindowInfo(wid: wid, onscreen: onscreen, elsewhere: elsewhere, title: title))
        }

        var result: [SpaceApp] = []
        for pid in pidsInZOrder {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated, let windows = entries[pid] else { continue }
            // Apps park internal windows in the window list (Chrome keeps several) that
            // look real but are not. Only Accessibility can tell them apart, and it
            // answers about the Space in front only - hence the remembered set, which
            // makes the same judgement possible from another Space. An app we have never
            // heard from keeps all its windows: better an extra entry than a lost one.
            var axTitles: [CGWindowID: String] = [:]
            if windows.contains(where: { !$0.onscreen }) || !settings.groupWindows {
                axTitles = axWindows(pid: pid) ?? [:]
                if !axTitles.isEmpty { confirmedWindows[pid] = Set(axTitles.keys) }
            }
            var visible = windows
            let confirmed = confirmedWindows[pid] ?? []
            if !confirmed.isEmpty {
                visible = visible.filter { $0.onscreen || $0.title != nil || confirmed.contains($0.wid) }
            }
            guard !visible.isEmpty else { continue }
            // Present = on this Space, or on another one; only the rest is minimised.
            let anyPresent = visible.contains { $0.onscreen || $0.elsewhere }
            let anyOnscreen = visible.contains { $0.onscreen }
            switch app.activationPolicy {
            case .regular: break
            // Menu-bar apps (including TabStash itself) count only while one of their
            // windows is open, e.g. a settings window - on this Space or another one.
            case .accessory: if !anyPresent { continue }
            default: continue
            }
            if let bid = app.bundleIdentifier, hidden.contains(bid) { continue }
            let appMinimized = app.isHidden || !anyPresent
            if appMinimized, !settings.showMinimized { continue }
            if let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier {
                settings.remember(bundleID: bid, path: app.bundleURL?.path)
            }

            if settings.groupWindows {
                result.append(SpaceApp(app: app, windowIDs: visible.map { $0.wid },
                                       isMinimized: appMinimized, title: nil,
                                       isOnCurrentSpace: visible.contains { !$0.elsewhere }))
                continue
            }
            // One entry per window. kCGWindowName stays empty without Screen Recording
            // access, so fall back to Accessibility, which the app already has.
            // One entry per window, named where possible. Apps that name nothing - which
            // is common for a window on another Space - still get one entry per window;
            // they just fall back to the app name. Windows that are not really windows
            // were dropped above, by Space membership and by the Accessibility check.
            let fallback = axTitles
            for win in visible {
                let minimized = app.isHidden || !(win.onscreen || win.elsewhere)
                if minimized && !settings.showMinimized { continue }
                let title = (win.title ?? fallback[win.wid]).flatMap { $0.isEmpty ? nil : $0 }
                result.append(SpaceApp(app: app, windowIDs: [win.wid], isMinimized: minimized,
                                       title: title, isOnCurrentSpace: !win.elsewhere))
            }
        }

        switch settings.sortOrder {
        case "name":
            result.sort {
                let byApp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byApp == .orderedSame
                    ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    : byApp == .orderedAscending
            }
            return result
        case "windows":
            return result       // already in the window server's front-to-back order
        default:
            break
        }

        // Order: most recently activated first, unknown ones keep window z-order.
        // Within one app the window in focus leads, then the ones used most recently,
        // so the next Cmd+Tab lands on a different window instead of the current one.
        let rank: [pid_t: Int] = Dictionary(uniqueKeysWithValues: mru.enumerated().map { ($1, $0) })
        let windowRank: [CGWindowID: Int] = Dictionary(uniqueKeysWithValues: windowMRU.enumerated().map { ($1, $0) })
        let focused = focusedWindowOfFrontApp()
        func windowOrder(_ item: SpaceApp) -> Int {
            guard let wid = item.windowIDs.first else { return Int.max }
            if wid == focused { return -1 }
            return windowRank[wid] ?? Int.max
        }
        let indexed = result.enumerated().map { ($0, $1) }
        result = indexed.sorted { a, b in
            let ra = rank[a.1.app.processIdentifier] ?? Int.max
            let rb = rank[b.1.app.processIdentifier] ?? Int.max
            let wa = windowOrder(a.1), wb = windowOrder(b.1)
            if settings.groupWindows {
                if ra != rb { return ra < rb }
                if wa != wb { return wa < wb }
            } else {
                // Windows are listed one by one, so each stands on its own: a second
                // window you never touch sinks behind everything you do use, instead of
                // riding along with the window of the same app.
                if wa != wb { return wa < wb }
                if ra != rb { return ra < rb }
            }
            return a.0 < b.0
        }.map { $0.1 }

        // Keep the frontmost app first so a quick Cmd+Tab goes to the previous one.
        // Only if it has a window here: a windowless frontmost app (the Finder after a
        // click on the desktop) used to be added anyway, so it came and went. With
        // windows listed separately the window in focus already leads, and pulling the
        // app forward would drag its other windows along.
        if settings.groupWindows,
           let front = NSWorkspace.shared.frontmostApplication,
           let idx = result.firstIndex(where: { $0.app.processIdentifier == front.processIdentifier }) {
            result.insert(result.remove(at: idx), at: 0)
        }
        return result
    }

    /// Window IDs the app itself reports through Accessibility, with their titles.
    /// nil when the app does not answer, in which case nothing is filtered out.
    /// The window the user is actually in right now, so it can be put first.
    private static func focusedWindowOfFrontApp() -> CGWindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(raw as! AXUIElement, &wid) == .success else { return nil }
        return wid
    }

    private static func axWindows(pid: pid_t) -> [CGWindowID: String]? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var titles: [CGWindowID: String] = [:]
        for w in windows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &wid) == .success else { continue }
            var raw: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &raw)
            titles[wid] = (raw as? String) ?? ""
        }
        return titles
    }

    /// Diagnostics for `--dump`: every candidate window with the facts the filter
    /// uses, then the resulting list.
    static func dumpDiagnostics() {
        var out: [String] = []
        let settings = Settings.shared
        out.append("currentSpaceOnly=\(settings.currentSpaceOnly) groupWindows=\(settings.groupWindows) "
            + "showMinimized=\(settings.showMinimized) sortOrder=\(settings.sortOrder)")
        out.append("active spaces: \(PrivateSpaces.activeSpaceIDs().sorted())")
        out.append("accessibility trusted: \(AXIsProcessTrusted())")

        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids: Set<pid_t> = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = (b["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (b["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width >= 40, height >= 40 else { continue }
            pids.insert(pid)
            let title = (w[kCGWindowName as String] as? String) ?? "<nil>"
            out.append("window wid=\(wid) pid=\(pid) \((w[kCGWindowOwnerName as String] as? String) ?? "?") "
                + "\(Int(width))x\(Int(height)) onscreen=\((w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false) "
                + "spaces=\(PrivateSpaces.spaceIDs(forWindow: wid).sorted()) title='\(title)'")
        }
        for pid in pids.sorted() {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
            switch axWindows(pid: pid) {
            case nil: out.append("ax pid=\(pid) \(name): no answer")
            case let map?: out.append("ax pid=\(pid) \(name): \(map.isEmpty ? "empty" : map.map { "\($0.key)='\($0.value)'" }.joined(separator: ", "))")
            }
        }
        out.append("--- result ---")
        for item in currentSpaceApps(mru: []) {
            out.append("\(item.name) wids=\(item.windowIDs) minimized=\(item.isMinimized) title=\(item.title ?? "<nil>")")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TabStash-dump.txt")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
