import AppKit

struct SpaceApp {
    enum State { case normal, minimized, hidden, otherSpace }

    let app: NSRunningApplication
    /// Windows this entry stands for, front to back. Exactly one when grouping is off.
    var windowIDs: [CGWindowID]
    /// True when nothing of this entry is visible (all minimised, or the app is hidden).
    var isMinimized: Bool
    /// Window title, set only when windows are listed separately.
    let title: String?
    /// False when this entry only has windows on other Spaces.
    let isOnCurrentSpace: Bool
    /// Number of the desktop the entry lives on, as Mission Control counts them, when
    /// that is not the current one.
    let spaceNumber: Int?

    /// What the badge on the icon says. Hidden wins over minimised, which wins over
    /// "on another Space".
    var state: State {
        if app.isHidden { return .hidden }
        if isMinimized { return .minimized }
        if !isOnCurrentSpace { return .otherSpace }
        return .normal
    }

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
        /// The Space it belongs to, for the badge.
        let space: UInt64?
        /// Placed on its Space, as opposed to minimised or put away in a tray.
        let orderedIn: Bool
        let title: String?
    }

    /// Window IDs Accessibility has confirmed for an app, remembered because it only
    /// answers about apps on the Space in front. Seen once, a window stays trustworthy.
    private static var confirmedWindows: [pid_t: Set<CGWindowID>] = [:]
    /// Window titles from earlier answers, for when there is no time to ask again.
    private static var titleCache: [CGWindowID: String] = [:]
    /// Windows Accessibility owns up to but does not call proper windows - Chrome's
    /// "Find in page" bar and the like. Remembered so they stay out from other Spaces too.
    private static var rejectedWindows: [pid_t: Set<CGWindowID>] = [:]
    /// All Accessibility work while building one list must fit in this. A slow app
    /// answers each question within the per-call cap, but dozens of windows times that
    /// cap once held Cmd+Tab up for 15 seconds.
    private static let axBudget: TimeInterval = 0.15

    /// Notes the windows Accessibility vouches for right now. Worth calling whenever an
    /// app activates: it is then on the Space in front, the only time Accessibility says
    /// anything about it, and the answer stays useful from other Spaces.
    /// Runs off the main thread: a busy app can take its time answering, and that must
    /// never hold up key handling.
    static func rememberWindows(of pid: pid_t) {
        axQueue.async {
            guard let ax = axWindows(pid: pid, deadline: Date().addingTimeInterval(1)), !ax.titles.isEmpty else { return }
            DispatchQueue.main.async {
                confirmedWindows[pid] = Set(ax.titles.keys)
                rejectedWindows[pid] = ax.rejected
                for (wid, title) in ax.titles where !title.isEmpty { titleCache[wid] = title }
            }
        }
    }
    private static let axQueue = DispatchQueue(label: "dev.artem.tabstash.ax", qos: .utility)

    /// Apps (or single windows, when grouping is off) the switcher should offer.
    /// `mru` orders the apps, `windowMRU` orders the windows inside one app.
    static func currentSpaceApps(mru: [pid_t], windowMRU: [CGWindowID] = []) -> [SpaceApp] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let axDeadline = Date().addingTimeInterval(axBudget)
        if titleCache.count > 2000 { titleCache.removeAll() }
        let settings = Settings.shared
        let hidden = settings.hiddenBundleIDs
        let limitToSpace = settings.currentSpaceOnly
        // Always needed, even when every Space is listed: a window on another Space is
        // away, not minimised, and must not be dropped with the minimised ones.
        let activeSpaces = PrivateSpaces.activeSpaceIDs()
        let usePrivate = !activeSpaces.isEmpty
        // Desktop numbers as Mission Control counts them, for the "other Space" badge.
        var desktopNumber: [UInt64: Int] = [:]
        for display in PrivateSpaces.displaySpaces() {
            for (i, id) in display.spaces.enumerated() { desktopNumber[id] = i + 1 }
        }

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
            let orderedIn = onscreen || (PrivateSpaces.isOrderedIn(wid) ?? true)
            entries[pid, default: []].append(WindowInfo(wid: wid, onscreen: onscreen, elsewhere: elsewhere,
                                                        space: spaces.first, orderedIn: orderedIn, title: title))
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
            // Which windows are real. On screen, or placed on another Space, always is.
            // Anything else is out of sight - minimised, closed into a tray (Macs Fan
            // Control), or an app's internal scaffolding (Chrome) - and needs vouching for.
            // Accessibility vouches for minimised windows but answers only about the Space
            // in front, so its answers are remembered for looking from other Spaces.
            var axAnswer: AXWindows?
            let hereToo = windows.contains { !$0.elsewhere }
            if hereToo, windows.contains(where: { !$0.onscreen }) || !settings.groupWindows {
                if Date() < axDeadline { axAnswer = axWindows(pid: pid, deadline: axDeadline) }
                if let answer = axAnswer {
                    confirmedWindows[pid] = Set(answer.titles.keys)
                    rejectedWindows[pid] = answer.rejected
                    for (wid, title) in answer.titles where !title.isEmpty { titleCache[wid] = title }
                }
            }
            let axTitles = axAnswer?.titles ?? [:]
            let rejected = axAnswer?.rejected ?? rejectedWindows[pid] ?? []
            let known = confirmedWindows[pid]
            // Asked and got no answer (a busy app): keep what is here rather than lose it.
            let unanswered = hereToo && axAnswer == nil
            func present(_ w: WindowInfo) -> Bool { w.onscreen || (w.elsewhere && w.orderedIn) }
            let visible = windows.filter { win in
                // Disowned by its own app: never a switcher entry, even while on screen.
                if rejected.contains(win.wid) { return false }
                // On another Space and placed there: a real window, whatever else we know.
                if win.elsewhere && win.orderedIn { return true }
                // Cmd+H: Accessibility lists nothing until the app is shown again.
                if app.isHidden { return true }
                // The app answered in full, so its word is final: Chrome keeps on-screen
                // scaffolding it never mentions, and that is not somewhere to switch to.
                if let answer = axAnswer { return answer.titles[win.wid] != nil }
                if win.onscreen || (unanswered && known == nil) { return true }
                if win.title != nil { return true }
                return known?.contains(win.wid) ?? false
            }
            guard !visible.isEmpty else { continue }
            // Present = on this Space, or on another one; only the rest is minimised.
            let anyPresent = visible.contains(where: present)
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
                let here = visible.contains { !$0.elsewhere }
                result.append(SpaceApp(app: app, windowIDs: visible.map { $0.wid },
                                       isMinimized: appMinimized, title: nil,
                                       isOnCurrentSpace: here,
                                       spaceNumber: here ? nil : visible.first?.space.flatMap { desktopNumber[$0] }))
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
                let minimized = app.isHidden || !present(win)
                if minimized && !settings.showMinimized { continue }
                let title = (win.title ?? fallback[win.wid] ?? titleCache[win.wid]).flatMap { $0.isEmpty ? nil : $0 }
                result.append(SpaceApp(app: app, windowIDs: [win.wid], isMinimized: minimized,
                                       title: title, isOnCurrentSpace: !win.elsewhere,
                                       spaceNumber: win.elsewhere ? win.space.flatMap { desktopNumber[$0] } : nil))
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
        let focused = focusedWindowOfFrontApp(deadline: axDeadline)
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
    private static func focusedWindowOfFrontApp(deadline: Date = .distantFuture) -> CGWindowID? {
        guard Date() < deadline, let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(raw as! AXUIElement, &wid) == .success else { return nil }
        return wid
    }

    /// What an app says about its own windows.
    struct AXWindows {
        /// Windows worth switching to, with their titles.
        var titles: [CGWindowID: String] = [:]
        /// Listed, but not a window in its own right: a find bar, a palette, a popover.
        var rejected: Set<CGWindowID> = []
    }

    /// nil when the app gave no complete answer in time. A partial answer is never
    /// returned: windows missing from it would be taken for fakes and dropped.
    private static func axWindows(pid: pid_t, deadline: Date = .distantFuture) -> AXWindows? {
        let started = Date()
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var answer = AXWindows()
        for w in windows {
            guard Date() < deadline else {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                SlowLog.note("Accessibility: \(name) ran out of time after \(SlowLog.ms(since: started)) ms, \(answer.titles.count) of \(windows.count) windows")
                return nil
            }
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &wid) == .success else { continue }
            // Only a standard window or a dialog is something to switch to. Chrome files
            // its "Find in page" bar as a window with the subrole AXUnknown.
            var subroleRaw: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subroleRaw)
            let subrole = (subroleRaw as? String) ?? ""
            guard subrole == "AXStandardWindow" || subrole == "AXDialog" else {
                answer.rejected.insert(wid)
                continue
            }
            var raw: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &raw)
            answer.titles[wid] = (raw as? String) ?? ""
        }
        if Date().timeIntervalSince(started) > 0.1 {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            SlowLog.note("Accessibility: \(name) took \(SlowLog.ms(since: started)) ms for \(windows.count) windows")
        }
        return answer
    }

    /// Diagnostics for `--dump`: every candidate window with the facts the filter
    /// uses, then the resulting list.
    static func dumpDiagnostics() {
        var out: [String] = []
        let settings = Settings.shared
        out.append("currentSpaceOnly=\(settings.currentSpaceOnly) groupWindows=\(settings.groupWindows) "
            + "showMinimized=\(settings.showMinimized) sortOrder=\(settings.sortOrder)")
        out.append("active spaces: \(PrivateSpaces.activeSpaceIDs().sorted())")
        for display in PrivateSpaces.displaySpaces() {
            out.append("display \(display.displayID): current \(display.current), all \(display.spaces)")
        }
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
                + "spaces=\(PrivateSpaces.spaceIDs(forWindow: wid).sorted()) "
                + "orderedIn=\(PrivateSpaces.isOrderedIn(wid).map(String.init) ?? "?") title='\(title)'")
        }
        func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }
        for pid in pids.sorted() {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
            let started = Date()
            let answer = axWindows(pid: pid)
            let took = ms(started)
            switch answer {
            case nil: out.append("ax pid=\(pid) \(name): no answer (\(took))")
            case let map?: out.append("ax pid=\(pid) \(name): \(map.titles.isEmpty ? "no real windows" : "\(map.titles.count) windows")"
                + "\(map.rejected.isEmpty ? "" : ", \(map.rejected.count) not switchable") (\(took))")
            }
        }
        for pid in pids.sorted() {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
            let appElement = AXUIElementCreateApplication(pid)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw) == .success,
                  let axWindowList = raw as? [AXUIElement], !axWindowList.isEmpty else { continue }
            for window in axWindowList {
                var wid: CGWindowID = 0
                _ = _AXUIElementGetWindow(window, &wid)
                func text(_ attribute: String) -> String {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
                          let value else { return "-" }
                    if let string = value as? String { return string }
                    if CFGetTypeID(value) == AXValueGetTypeID() {
                        var size = CGSize.zero
                        if AXValueGetValue(value as! AXValue, .cgSize, &size) { return "\(Int(size.width))x\(Int(size.height))" }
                    }
                    return "?"
                }
                var names: CFArray?
                AXUIElementCopyAttributeNames(window, &names)
                let attributes = (names as? [String]) ?? []
                out.append("axwindow \(name) wid=\(wid) role=\(text(kAXRoleAttribute)) subrole=\(text(kAXSubroleAttribute)) "
                    + "size=\(text(kAXSizeAttribute)) close=\(attributes.contains(kAXCloseButtonAttribute)) "
                    + "minimizeButton=\(attributes.contains(kAXMinimizeButtonAttribute)) title='\(text(kAXTitleAttribute).prefix(40))'")
            }
        }

        let focusStart = Date()
        _ = focusedWindowOfFrontApp()
        out.append("focused window lookup: \(ms(focusStart))")
        let listStart = Date()
        let items = currentSpaceApps(mru: [])
        out.append("--- result (built in \(ms(listStart))) ---")
        for item in items {
            out.append("\(item.name) wids=\(item.windowIDs) state=\(item.state) desktop=\(item.spaceNumber.map(String.init) ?? "-") title=\(item.title ?? "<nil>")")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TabStash-dump.txt")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
