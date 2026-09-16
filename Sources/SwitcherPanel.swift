import AppKit

/// Floating, non-activating HUD laid out like the system switcher: a row of large
/// icons with the name of the highlighted one underneath.
final class SwitcherPanel: NSPanel {
    private enum Metrics {
        static let icon: CGFloat = 112
        static let cell: CGFloat = 132          // square tile around an icon
        static let gap: CGFloat = 4
        static let padding: CGFloat = 20
        static let labelHeight: CGFloat = 26
        static let corner: CGFloat = 30
    }

    private let container = NSView()
    /// The NSGlassEffectView, when this system has one.
    private var glass: NSView?
    /// Whatever paints the background, kept behind the icons so that making it
    /// see-through does not fade them too.
    private var backdrop: NSView?
    private let nameLabel = NSTextField(labelWithString: "")
    private var items: [ItemView] = []
    private var apps: [SpaceApp] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        container.addSubview(nameLabel)

        let root = NSView()
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glassClass.init(frame: .zero)
            view.setValue(NSNumber(value: Double(Metrics.corner)), forKey: "cornerRadius")
            glass = view
            backdrop = view
        } else {
            backdrop = Self.visualEffectBackground(corner: Metrics.corner)
        }
        if let backdrop { root.addSubview(backdrop) }
        root.addSubview(container)
        contentView = root
    }

    /// nil follows the system, which is what "system" in Settings means.
    private static func chosenAppearance() -> NSAppearance? {
        switch Settings.shared.appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// Follows System Settings -> Appearance -> Liquid Glass, read on every open so no
    /// restart is needed. `NSGlassTintAmount` is 0 for the clear look, where the glass
    /// keeps a faint tint of its own: fully clear, the panel is hard to make out.
    private func applyGlassStyle() {
        guard let glass else { return }
        let tint = UserDefaults.standard.double(forKey: "NSGlassTintAmount")
        var clear = tint <= 0
        // Hidden knob for comparing the two looks: `defaults write dev.artem.tabstash
        // glassStyle -int 0|1`, removed again to follow the system.
        if let forced = UserDefaults.standard.object(forKey: "glassStyle") as? Int {
            clear = forced == 1
        }
        glass.setValue(NSNumber(value: clear ? 1 : 0), forKey: "style")
        glass.setValue(NSColor.labelColor.withAlphaComponent(clear ? 0.05 : min(tint, 1) * 0.2),
                       forKey: "tintColor")
    }

    /// The blur of Liquid Glass cannot be turned down, so "see-through" means a less
    /// opaque backdrop. Only the backdrop fades; the icons on top stay solid.
    private func applyBackdropOpacity() {
        backdrop?.alphaValue = CGFloat(Settings.shared.glassOpacity)
    }

    /// Fallback for systems without Liquid Glass (before macOS 26).
    private static func visualEffectBackground(corner: CGFloat) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = corner
        effect.layer?.masksToBounds = true
        return effect
    }

    func show(apps: [SpaceApp], selected: Int) {
        // Re-read on every open so a change in Settings needs no restart.
        appearance = Self.chosenAppearance()
        applyGlassStyle()
        applyBackdropOpacity()
        self.apps = apps
        items.forEach { $0.removeFromSuperview() }
        items = apps.map { ItemView(app: $0, iconSize: Metrics.icon) }

        let screen = targetScreen()
        let usable = screen.visibleFrame.width - 2 * Metrics.padding - 80
        let maxCols = max(1, Int(usable / (Metrics.cell + Metrics.gap)))
        let cols = max(1, min(apps.count, maxCols))
        let rows = max(1, Int(ceil(Double(apps.count) / Double(cols))))

        let width = 2 * Metrics.padding + CGFloat(cols) * Metrics.cell + CGFloat(cols - 1) * Metrics.gap
        let height = 2 * Metrics.padding + CGFloat(rows) * Metrics.cell + CGFloat(rows - 1) * Metrics.gap
            + Metrics.labelHeight

        for (i, item) in items.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = Metrics.padding + CGFloat(col) * (Metrics.cell + Metrics.gap)
            let y = height - Metrics.padding - CGFloat(row + 1) * Metrics.cell - CGFloat(row) * Metrics.gap
            item.frame = NSRect(x: x, y: y, width: Metrics.cell, height: Metrics.cell)
            container.addSubview(item)
        }
        let origin = NSPoint(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        let bounds = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        backdrop?.frame = bounds
        container.frame = bounds
        select(selected)
        orderFrontRegardless()
    }

    func select(_ index: Int) {
        for (i, item) in items.enumerated() { item.isSelected = (i == index) }
        guard apps.indices.contains(index) else {
            nameLabel.stringValue = ""
            return
        }
        nameLabel.stringValue = apps[index].label

        // The caption sits under the highlighted icon and moves with it, as in the
        // system switcher; it is only pushed inwards when it would leave the panel.
        nameLabel.sizeToFit()
        let maxWidth = frame.width - 2 * Metrics.padding
        let width = min(nameLabel.frame.width, maxWidth)
        let centre = items[index].frame.midX
        let x = min(max(Metrics.padding, centre - width / 2), frame.width - Metrics.padding - width)
        nameLabel.frame = NSRect(x: x, y: Metrics.padding - 6, width: width, height: Metrics.labelHeight)
    }

    func hide() {
        orderOut(nil)
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private final class ItemView: NSView {
    private let imageView = NSImageView()

    var isSelected = false {
        didSet { applyHighlight() }
    }

    /// CGColors do not follow appearance changes on their own, so the tile is
    /// repainted whenever the effective appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlight()
    }

    private func applyHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected
                ? NSColor.labelColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
        }
    }

    init(app: SpaceApp, iconSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 22

        imageView.image = app.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.alphaValue = app.isMinimized ? 0.45 : 1
        addSubview(imageView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
