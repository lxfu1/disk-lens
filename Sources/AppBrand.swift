import AppKit

// One vector artwork for the Dock, sidebar and settings, rendered at each target size.
enum AppBrand {
    static var image: NSImage {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
            let tile = NSBezierPath(roundedRect: CGRect(x: 7, y: 7, width: 114, height: 114), xRadius: 26, yRadius: 26)
            NSGradient(colors: [rgb(0x318F91), rgb(0x15565D), rgb(0x103C48)])!
                .draw(in: tile, angle: -65)

            // A restrained edge highlight keeps the silhouette clear on dark Docks.
            let rim = NSBezierPath(roundedRect: CGRect(x: 7.5, y: 7.5, width: 113, height: 113), xRadius: 25.5, yRadius: 25.5)
            NSColor.white.withAlphaComponent(0.16).setStroke()
            rim.lineWidth = 1
            rim.stroke()

            // Center the complete mark (y: 26...112) within the tile (y: 7...121).
            NSGraphicsContext.saveGraphicsState()
            let alignment = NSAffineTransform()
            alignment.translateX(by: 0, yBy: -5)
            alignment.concat()
            let platter = NSBezierPath(ovalIn: CGRect(x: 27, y: 43, width: 69, height: 69))
            NSGradient(colors: [rgb(0xFCFDF8), rgb(0xCBE6E2)])!.draw(in: platter, angle: -70)
            let groove = NSBezierPath(ovalIn: CGRect(x: 32, y: 48, width: 59, height: 59))
            rgb(0x3B7C80).withAlphaComponent(0.18).setStroke()
            groove.lineWidth = 1
            groove.stroke()
            rgb(0x246B72).setFill()
            NSBezierPath(ovalIn: CGRect(x: 53, y: 69, width: 17, height: 17)).fill()
            rgb(0xE6F3ED).setFill()
            NSBezierPath(ovalIn: CGRect(x: 58, y: 74, width: 7, height: 7)).fill()

            let arm = NSBezierPath()
            arm.move(to: CGPoint(x: 71, y: 63)); arm.line(to: CGPoint(x: 94, y: 33))
            arm.lineCapStyle = .round
            // Separate the read head from the platter without a heavy outline.
            rgb(0x164F58).setStroke()
            arm.lineWidth = 12
            arm.stroke()
            rgb(0xF2F7EF).setStroke()
            arm.lineWidth = 7
            arm.stroke()
            rgb(0xF2F7EF).setFill()
            NSBezierPath(ovalIn: CGRect(x: 87, y: 26, width: 14, height: 14)).fill()
            rgb(0x35787C).setFill()
            NSBezierPath(ovalIn: CGRect(x: 91.5, y: 30.5, width: 5, height: 5)).fill()

            rgb(0xA8E5CF).setFill()
            NSBezierPath(roundedRect: CGRect(x: 28, y: 27, width: 17, height: 4), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.cacheMode = .never
        return image
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
