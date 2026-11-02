import AppKit

// MARK: - Icons

enum EyeIcon {
    // Paths are traced from the 1536x1024 reference artwork (y grows downward)
    // and scaled to menu bar height.
    private static let menuHeight: CGFloat = 18

    /// Where the pupils look, in a unit circle with y pointing down: (1, 0) is hard right.
    /// The default matches the reference artwork.
    static let defaultLook = CGVector(dx: 1, dy: 0.17)

    static func make(open: Bool, look: CGVector = defaultLook) -> NSImage {
        let bounds = open
            ? NSRect(x: 280, y: 240, width: 975, height: 585)
            : NSRect(x: 280, y: 220, width: 975, height: 590)
        let scale = menuHeight / bounds.height
        let size = NSSize(width: (bounds.width * scale).rounded(.up), height: menuHeight)
        let image = NSImage(size: size, flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.translateX(by: -bounds.minX, yBy: -bounds.minY)
            t.concat()
            NSColor.black.set()
            open ? drawOpen(look: look) : drawClosed()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private static func drawOpen(look: CGVector) {
        // Clamp to the unit circle, then map onto how far a pupil can travel inside the ring.
        let length = max(1, hypot(look.dx, look.dy))
        let ux = look.dx / length, uy = look.dy / length
        let offsetX = ux * 92
        let offsetY = uy * 120
        // The highlight rides on the pupil's edge facing the look direction, a little above
        // centre, as in the artwork (where it sits upper right while looking right).
        let glintX = ux * 63
        let glintY = min(70, max(-70, uy * 63 - 45))
        let glintTilt = -18 * ux

        for cx in [520.0, 1012.0] as [CGFloat] {
            let cy: CGFloat = 532
            let ring = ellipse(cx, cy, 206, 260)
            ring.lineWidth = 52
            ring.stroke()

            // Pupil; at full deflection it merges into the ring, as in the artwork.
            let px = cx + offsetX, py = cy + offsetY
            let pupil = ellipse(px, py, 92, 110)
            NSGraphicsContext.saveGraphicsState()
            ellipse(cx, cy, 232, 286).addClip()
            pupil.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Highlight punched out of the pupil.
            NSGraphicsContext.saveGraphicsState()
            pupil.addClip()
            NSGraphicsContext.current?.compositingOperation = .clear
            let glint = ellipse(0, 0, 21, 34)
            glint.transform(using: AffineTransform(rotationByDegrees: glintTilt))
            glint.transform(using: AffineTransform(translationByX: px + glintX, byY: py + glintY))
            glint.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawClosed() {
        func stroke(_ path: NSBezierPath, _ width: CGFloat) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        func z(_ top: (CGFloat, CGFloat, CGFloat), _ bottom: (CGFloat, CGFloat, CGFloat), _ width: CGFloat) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: top.0, y: top.2))
            p.line(to: NSPoint(x: top.1, y: top.2))
            p.line(to: NSPoint(x: bottom.0, y: bottom.2))
            p.line(to: NSPoint(x: bottom.1, y: bottom.2))
            stroke(p, width)
        }
        // (left x, right x, y) for the top and bottom bars of each letter.
        z((450, 582, 388), (436, 572, 527), 48)
        z((658, 872, 258), (643, 860, 497), 62)
        z((938, 1105, 342), (926, 1103, 521), 55)

        let left = NSBezierPath()
        left.move(to: NSPoint(x: 326, y: 650))
        left.curve(to: NSPoint(x: 704, y: 658),
                   controlPoint1: NSPoint(x: 380, y: 802), controlPoint2: NSPoint(x: 650, y: 802))
        stroke(left, 58)

        let right = NSBezierPath()
        right.move(to: NSPoint(x: 834, y: 658))
        right.curve(to: NSPoint(x: 1210, y: 650),
                    controlPoint1: NSPoint(x: 888, y: 802), controlPoint2: NSPoint(x: 1156, y: 802))
        stroke(right, 58)
    }
}
