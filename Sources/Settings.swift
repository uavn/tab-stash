import Foundation

/// User preferences, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let hidden = "hiddenBundleIDs"
        static let showMinimized = "showMinimized"
        static let seen = "seenApps"
        static let currentSpaceOnly = "currentSpaceOnly"
        static let groupWindows = "groupWindows"
        static let appearance = "appearance"
        static let sortOrder = "sortOrder"
        static let glassOpacity = "glassOpacity"
    }

    init() {
        d.register(defaults: [Key.showMinimized: true, Key.currentSpaceOnly: true, Key.groupWindows: true])
    }

    /// Bundle IDs that never appear in the switcher (blacklist).
    var hiddenBundleIDs: Set<String> {
        get { Set(d.stringArray(forKey: Key.hidden) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.hidden) }
    }

    /// Every app that has ever appeared in the switcher: bundle ID -> path of its
    /// bundle. Kept so the settings list can offer apps that are not running now.
    private(set) lazy var seenApps: [String: String] = d.dictionary(forKey: Key.seen) as? [String: String] ?? [:]

    /// Records an app the switcher has shown. Writes only when something is new,
    /// so the common case costs a dictionary lookup.
    func remember(bundleID: String, path: String?) {
        let known = seenApps[bundleID]
        guard known == nil || (path.map { !$0.isEmpty && $0 != known } ?? false) else { return }
        seenApps[bundleID] = path ?? known ?? ""
        d.set(seenApps, forKey: Key.seen)
    }

    /// How solid the panel background is: 1 is the full frosted glass, less is
    /// see-through. The blur itself cannot be turned off, so this is what "clear" means.
    var glassOpacity: Double {
        get { d.object(forKey: Key.glassOpacity) as? Double ?? 1 }
        set { d.set(newValue, forKey: Key.glassOpacity) }
    }

    /// Order of the icons: "recent" (default), "name" or "windows".
    var sortOrder: String {
        get { d.string(forKey: Key.sortOrder) ?? "recent" }
        set { d.set(newValue, forKey: Key.sortOrder) }
    }

    /// Switcher appearance: "system" (default), "light" or "dark".
    var appearance: String {
        get { d.string(forKey: Key.appearance) ?? "system" }
        set { d.set(newValue, forKey: Key.appearance) }
    }

    /// List only apps with a window on the Space in front; off means every Space.
    var currentSpaceOnly: Bool {
        get { d.bool(forKey: Key.currentSpaceOnly) }
        set { d.set(newValue, forKey: Key.currentSpaceOnly) }
    }

    /// One entry per app; off gives one entry per window, labelled with its title.
    var groupWindows: Bool {
        get { d.bool(forKey: Key.groupWindows) }
        set { d.set(newValue, forKey: Key.groupWindows) }
    }

    /// Show apps whose windows on this Space are all minimised (or the app is hidden with Cmd+H).
    var showMinimized: Bool {
        get { d.bool(forKey: Key.showMinimized) }
        set { d.set(newValue, forKey: Key.showMinimized) }
    }
}
