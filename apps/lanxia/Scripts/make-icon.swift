import AppKit

@main
enum MakeIcon {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: make-icon /absolute/path/to/StashCat")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let iconSet = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let destination = iconSet.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                try render(pixels: size * scale).write(to: destination, options: .atomic)
            }
        }
        let preview = resources.appendingPathComponent("Branding/AppIcon-2048.png")
        try render(pixels: 2048).write(to: preview, options: .atomic)
    }

    @MainActor private static func render(pixels: Int) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        let context = graphics.cgContext
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let scale = CGFloat(pixels) / 1024
        context.scaleBy(x: scale, y: scale)
        let face = NSBezierPath(roundedRect: NSRect(x: 100, y: 104, width: 824, height: 824),
                                xRadius: 184, yRadius: 184)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0x04132A, 0.38).cgColor)
        color(0x122D52).setFill()
        face.fill()
        context.restoreGState()

        context.saveGState()
        face.addClip()
        NSGradient(colors: [color(0x538EC2), color(0x183A68), color(0x0A1A36)])!
            .draw(in: face.bounds, angle: -55)
        NSGradient(starting: color(0x52D8F6, 0.48), ending: color(0x52D8F6, 0))!
            .draw(fromCenter: NSPoint(x: 350, y: 682), radius: 32,
                  toCenter: NSPoint(x: 350, y: 682), radius: 540, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        let glassHighlight = NSBezierPath()
        glassHighlight.move(to: NSPoint(x: 95, y: 943))
        glassHighlight.line(to: NSPoint(x: 927, y: 943))
        glassHighlight.line(to: NSPoint(x: 927, y: 805))
        glassHighlight.curve(to: NSPoint(x: 90, y: 625), controlPoint1: NSPoint(x: 752, y: 776),
                             controlPoint2: NSPoint(x: 395, y: 646))
        glassHighlight.close()
        NSGradient(starting: color(0xD4F1FF, 0.30), ending: color(0xAACDF0, 0.02))!
            .draw(in: glassHighlight, angle: -90)

        let tray = NSBezierPath(roundedRect: NSRect(x: 284, y: 223, width: 456, height: 121),
                                xRadius: 56, yRadius: 56)
        NSGradient(starting: color(0x152F58, 0.85), ending: color(0x60AFE2, 0.26))!
            .draw(in: tray, angle: -90)
        color(0x8DCEEF, 0.36).setStroke()
        tray.lineWidth = 3
        tray.stroke()

        NSGradient(starting: color(0x04102B, 0.74), ending: color(0x04102B, 0))!
            .draw(fromCenter: NSPoint(x: 493, y: 326), radius: 42,
                  toCenter: NSPoint(x: 493, y: 326), radius: 266, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        context.restoreGState()

        let outerRim = NSBezierPath(roundedRect: face.bounds.insetBy(dx: 2.5, dy: 2.5),
                                    xRadius: 181.5, yRadius: 181.5)
        color(0x071831, 0.88).setStroke()
        outerRim.lineWidth = 5
        outerRim.stroke()
        let innerRim = NSBezierPath(roundedRect: face.bounds.insetBy(dx: 8, dy: 8),
                                    xRadius: 176, yRadius: 176)
        context.saveGState()
        innerRim.setClipForStroke()
        NSGradient(starting: color(0xDCFAFF, 0.9), ending: color(0x7CB1E5, 0.24))!
            .draw(in: face.bounds, angle: -102)
        context.restoreGState()

        let emblem = StatusBarIcon.image()
        let emblemRect = NSRect(x: 256, y: 249, width: 540, height: 540)
        graphics.imageInterpolation = .none
        emblem.draw(in: emblemRect, from: .zero, operation: .sourceOver, fraction: 1)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode the \(pixels) px icon")
        }
        return png
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private extension NSBezierPath {
    func setClipForStroke() {
        lineWidth = 4
        let context = NSGraphicsContext.current!.cgContext
        context.addPath(cgPath)
        context.setLineWidth(lineWidth)
        context.replacePathWithStrokedPath()
        context.clip()
    }
}
