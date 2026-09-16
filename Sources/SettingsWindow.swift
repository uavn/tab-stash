import AppKit
import UniformTypeIdentifiers

/// Preferences window: toggles and a per-app "show in switcher" list.
final class SettingsWindowController: NSWindowController {
    private let settings = Settings.shared
    private let minimizedBox = NSButton(checkboxWithTitle: "Show minimized and hidden (Cmd+H) apps", target: nil, action: nil)
    private let spaceBox = NSButton(checkboxWithTitle: "Show only apps from the current Space", target: nil, action: nil)
    private let groupBox = NSButton(checkboxWithTitle: "Group all windows of an app into one entry", target: nil, action: nil)
    private let appearanceButton = NSPopUpButton()
    private let sortButton = NSPopUpButton()
    private let glassButton = NSPopUpButton()
    private let listStack = NSStackView()

    private struct Row { let bundleID: String; let name: String; let icon: NSImage? }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "TabStash Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }

        minimizedBox.target = self; minimizedBox.action = #selector(toggleMinimized)
        spaceBox.target = self; spaceBox.action = #selector(toggleSpace)
        groupBox.target = self; groupBox.action = #selector(toggleGroup)
        spaceBox.toolTip = "Off lists apps from every Space, like the system Cmd+Tab."
        groupBox.toolTip = "Off gives every window its own entry, labelled with the window title."

        appearanceButton.addItems(withTitles: ["System", "Light", "Dark"])
        appearanceButton.target = self
        appearanceButton.action = #selector(changeAppearance)
        sortButton.addItems(withTitles: ["Recently used", "Name", "Window order"])
        sortButton.target = self
        sortButton.action = #selector(changeSort)

        glassButton.addItems(withTitles: ["Frosted", "Light", "Clear"])
        glassButton.target = self
        glassButton.action = #selector(changeGlass)
        glassButton.toolTip = "How solid the panel background is. The blur behind it belongs to the system and cannot be turned off."

        let appearanceRow = NSStackView(views: [NSTextField(labelWithString: "Order:"), sortButton,
                                                NSTextField(labelWithString: "  Appearance:"), appearanceButton,
                                                NSTextField(labelWithString: "  Glass:"), glassButton])
        appearanceRow.orientation = .horizontal
        appearanceRow.spacing = 8



        let header = NSTextField(labelWithString: "Apps in the switcher")
        header.font = .boldSystemFont(ofSize: 13)
        let hint = NSTextField(wrappingLabelWithString: "Uncheck an app to never show it. Every app the switcher has shown stays in this list, even when it is not running.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(addApp))
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let coffeeButton = NSButton(title: "Buy me a coffee ☕", target: self, action: #selector(buyCoffee))
        coffeeButton.bezelStyle = .rounded
        coffeeButton.toolTip = Self.coffeeURL

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [addButton, refreshButton, spacer, coffeeButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let root = NSStackView(views: [spaceBox, groupBox, minimizedBox, appearanceRow, header, hint, scroll, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.spacing = 8
        root.setCustomSpacing(12, after: minimizedBox)
        root.setCustomSpacing(18, after: appearanceRow)
        root.setCustomSpacing(4, after: header)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor),
            hint.widthAnchor.constraint(equalTo: root.widthAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: Data

    private func rows() -> [Row] {
        var byID: [String: Row] = [:]
        let myID = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, bid != myID else { continue }
            byID[bid] = Row(bundleID: bid, name: app.localizedName ?? bid, icon: app.icon)
        }
        // Not running: everything the switcher has ever shown, plus anything already
        // blacklisted (which may never have been seen, e.g. added with "Add App…").
        var offline = settings.seenApps
        for bid in settings.hiddenBundleIDs where offline[bid] == nil { offline[bid] = "" }
        for (bid, path) in offline where byID[bid] == nil && bid != myID {
            byID[bid] = row(bundleID: bid, path: path)
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func row(bundleID bid: String, path: String) -> Row {
        let url = path.isEmpty ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                               : URL(fileURLWithPath: path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return Row(bundleID: bid, name: bid, icon: nil)
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return Row(bundleID: bid, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    @objc private func reload() {
        minimizedBox.state = settings.showMinimized ? .on : .off
        spaceBox.state = settings.currentSpaceOnly ? .on : .off
        groupBox.state = settings.groupWindows ? .on : .off
        appearanceButton.selectItem(at: Self.appearanceOrder.firstIndex(of: settings.appearance) ?? 0)
        sortButton.selectItem(at: Self.sortOrders.firstIndex(of: settings.sortOrder) ?? 0)
        glassButton.selectItem(at: Self.glassLevels.firstIndex { abs($0 - settings.glassOpacity) < 0.01 } ?? 0)

        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hidden = settings.hiddenBundleIDs
        for row in rows() {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleApp(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(row.bundleID)
            check.state = hidden.contains(row.bundleID) ? .off : .on

            let iconView = NSImageView(image: row.icon ?? NSImage())
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

            let label = NSTextField(labelWithString: row.name)
            label.lineBreakMode = .byTruncatingTail

            let line = NSStackView(views: [check, iconView, label])
            line.orientation = .horizontal
            line.spacing = 6
            listStack.addArrangedSubview(line)
        }
    }

    // MARK: Actions

    @objc private func toggleMinimized() { settings.showMinimized = minimizedBox.state == .on }
    @objc private func toggleSpace() { settings.currentSpaceOnly = spaceBox.state == .on }
    @objc private func toggleGroup() { settings.groupWindows = groupBox.state == .on }

    private static let glassLevels = [1.0, 0.7, 0.45]
    @objc private func changeGlass() {
        let index = min(max(0, glassButton.indexOfSelectedItem), Self.glassLevels.count - 1)
        settings.glassOpacity = Self.glassLevels[index]
    }

    private static let sortOrders = ["recent", "name", "windows"]
    @objc private func changeSort() {
        let index = min(max(0, sortButton.indexOfSelectedItem), Self.sortOrders.count - 1)
        settings.sortOrder = Self.sortOrders[index]
    }

    private static let appearanceOrder = ["system", "light", "dark"]
    @objc private func changeAppearance() {
        let index = min(max(0, appearanceButton.indexOfSelectedItem), Self.appearanceOrder.count - 1)
        settings.appearance = Self.appearanceOrder[index]
    }

    @objc private func toggleApp(_ sender: NSButton) {
        guard let bid = sender.identifier?.rawValue else { return }
        var hidden = settings.hiddenBundleIDs
        if sender.state == .on { hidden.remove(bid) } else { hidden.insert(bid) }
        settings.hiddenBundleIDs = hidden
    }

    private static let coffeeURL = "https://www.buymeacoffee.com/artbonvic"

    @objc private func buyCoffee() {
        guard let url = URL(string: Self.coffeeURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps that should never appear in the switcher"
        guard panel.runModal() == .OK else { return }
        var hidden = settings.hiddenBundleIDs
        for url in panel.urls {
            if let bid = Bundle(url: url)?.bundleIdentifier { hidden.insert(bid) }
        }
        settings.hiddenBundleIDs = hidden
        reload()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
