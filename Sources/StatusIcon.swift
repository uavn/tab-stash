import AppKit

/// The TabStash glyph: an app tile with a Tab arrow (⇥) cut out of it.
enum StatusIcon {
    /// 18pt template image for the menu bar (tile filled, arrow knocked out).
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            tile(in: rect).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setStroke()
            strokeTabArrow(in: rect, lineWidth: 1.9)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Rounded app tile filling `rect` with a 1pt inset (in 18pt units).
    static func tile(in rect: NSRect) -> NSBezierPath {
        let s = rect.width / 18
        return NSBezierPath(roundedRect: rect.insetBy(dx: 1 * s, dy: 1 * s), xRadius: 4.5 * s, yRadius: 4.5 * s)
    }

    /// Strokes ⇥ with the current stroke colour: shaft, arrow head and end bar.
    static func strokeTabArrow(in rect: NSRect, lineWidth: CGFloat) {
        let s = rect.width / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: p(4, 9)); path.line(to: p(11, 9))            // shaft
        path.move(to: p(8, 5.8)); path.line(to: p(11.2, 9)); path.line(to: p(8, 12.2))   // head
        path.move(to: p(13.6, 5.2)); path.line(to: p(13.6, 12.8))  // bar
        path.stroke()
    }
}
