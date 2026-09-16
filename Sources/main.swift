import AppKit

// `--list` prints the apps that would be shown in the switcher and exits.
// Handy for checking Space detection without granting Accessibility rights.
if CommandLine.arguments.contains("--list") {
    let apps = SpaceApps.currentSpaceApps(mru: [])
    print("Private SkyLight API available: \(PrivateSpaces.isAvailable)")
    for d in PrivateSpaces.displaySpaces() {
        print("Display \(d.displayID): current Space \(d.current), all \(d.spaces)")
    }
    print("Apps on the current Space (\(apps.count)):")
    for a in apps {
        print("  \(a.name)  pid=\(a.app.processIdentifier)  bundle=\(a.app.bundleIdentifier ?? "-")\(a.isMinimized ? "  [minimized]" : "")")
    }
    exit(0)
}

// `--dump` writes what the app itself sees (its own Accessibility and Screen
// Recording rights, unlike a binary started from a terminal) and exits.
if CommandLine.arguments.contains("--dump") {
    SpaceApps.dumpDiagnostics()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
