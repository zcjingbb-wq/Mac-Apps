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
        let branding = resources.appendingPathComponent("Branding", isDirectory: true)
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: branding, withIntermediateDirectories: true)

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let destination = iconSet.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                try render(pixels: size * scale).write(to: destination, options: .atomic)
            }
        }
        let preview = branding.appendingPathComponent("AppIcon-2048.png")
        try render(pixels: 2048).write(to: preview, options: .atomic)
    }

    @MainActor private static func render(pixels: Int) throws -> Data {
        // Large ICNS representations share a native 64-pixel grid. The visible
        // tile is 52 pixels across. Smaller images are drawn on their own grid.
        let grid = min(pixels, 64)
        let artwork = newBitmap(size: grid)
        drawArtwork(into: artwork, grid: grid)
        applyPalette(to: artwork)

        let bitmap: NSBitmapImageRep
        if pixels == grid {
            bitmap = artwork
        } else {
            bitmap = newBitmap(size: pixels)
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
            context.draw(artwork.cgImage!, in: bounds)
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode the \(pixels) px icon")
        }
        return png
    }

    private static func newBitmap(size: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: size * 4, bitsPerPixel: 32)!
    }

    @MainActor private static func drawArtwork(into bitmap: NSBitmapImageRep, grid: Int) {
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        let context = graphics.cgContext
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let scale = CGFloat(grid) / 1024
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        drawTile(in: context, compact: grid <= 32)
        drawThrone(in: context, compact: grid <= 32)
    }

    private static let palette: [UInt32] = [
        0x0A0B24, 0x11102D, 0x181335, 0x251C44, 0x322650, 0x423462, 0x514176,
        0x645385, 0x766798, 0x8A7BAB, 0xA392C7, 0xC2B1E5,
        0x7C5CC1, 0x9A7EDC, 0xBA9DF2, 0xD8C2FF,
        0x271924, 0x523244, 0x79493C, 0x996047, 0xB98351, 0xC9935E, 0xDEA764,
        0xE9BB79, 0xF3CF8B, 0xF9DFA5, 0xFFEBBA, 0xFFF5D4
    ]

    private static func applyPalette(to bitmap: NSBitmapImageRep) {
        var sample = [Int](repeating: 0, count: 4)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                bitmap.getPixel(&sample, atX: x, y: y)
                guard sample[3] != 0 else { continue }
                func distance(to shade: UInt32) -> Int {
                    let dr = sample[0] - Int((shade >> 16) & 0xFF)
                    let dg = sample[1] - Int((shade >> 8) & 0xFF)
                    let db = sample[2] - Int(shade & 0xFF)
                    return dr * dr * 2 + dg * dg * 3 + db * db
                }
                let nearest = palette.min { distance(to: $0) < distance(to: $1) }!
                sample[0] = Int((nearest >> 16) & 0xFF)
                sample[1] = Int((nearest >> 8) & 0xFF)
                sample[2] = Int(nearest & 0xFF)
                sample[3] = 255
                bitmap.setPixel(&sample, atX: x, y: y)
            }
        }
    }

    private static func drawTile(in context: CGContext, compact: Bool) {
        let face = NSBezierPath(roundedRect: NSRect(x: 100, y: 104, width: 824, height: 824),
                                xRadius: 184, yRadius: 184)
        let edge = NSBezierPath(roundedRect: face.bounds.offsetBy(dx: 0, dy: -24), xRadius: 184, yRadius: 184)
        color(0x0A0B24).setFill()
        edge.fill()

        context.saveGState()
        face.addClip()
        NSGradient(colors: [color(0x423963), color(0x201943), color(0x0A0B24), color(0x10132C)])!
            .draw(in: face.bounds, angle: -75)
        NSGradient(starting: color(0x7866C4, 0.55), ending: color(0x7866C4, 0))!
            .draw(fromCenter: NSPoint(x: 484, y: 565), radius: 24,
                  toCenter: NSPoint(x: 484, y: 565), radius: 464,
                  options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])

        let reflection = NSBezierPath()
        reflection.move(to: NSPoint(x: 96, y: 934))
        reflection.line(to: NSPoint(x: 930, y: 934))
        reflection.line(to: NSPoint(x: 930, y: 796))
        reflection.curve(to: NSPoint(x: 96, y: 685),
                         controlPoint1: NSPoint(x: 660, y: 697), controlPoint2: NSPoint(x: 304, y: 745))
        reflection.close()
        NSGradient(starting: color(0xC1B6F6, 0.36), ending: color(0x8D86CA, 0))!
            .draw(in: reflection, angle: -90)
        context.restoreGState()

        let rim = NSBezierPath(roundedRect: face.bounds.insetBy(dx: 5, dy: 5), xRadius: 179, yRadius: 179)
        metallicStroke(rim, width: compact ? 26 : 16, colors: [0xB5A4EC, 0x635480, 0x332850], in: context)
    }

    private static func drawThrone(in context: CGContext, compact: Bool) {
        let center = NSPoint(x: 512, y: 518)
        if !compact {
            let field = NSBezierPath(ovalIn: NSRect(x: 198, y: 204, width: 628, height: 628))
            stroke(field, width: 2, color: color(0xCAB6E6, 0.28))
            for point in [NSPoint(x: 512, y: 833), NSPoint(x: 512, y: 203)] {
                let glint = diamond(at: point, width: 16, height: 30)
                color(0xF9D684, 0.85).setFill()
                glint.fill()
            }
        }

        drawWing(in: context, compact: compact)
        context.saveGState()
        context.translateBy(x: 1024, y: 0)
        context.scaleBy(x: -1, y: 1)
        drawWing(in: context, compact: compact)
        context.restoreGState()

        let firstRing = orbit(center: center, rotation: .pi / 3.65)
        let secondRing = orbit(center: center, rotation: -.pi / 3.65)
        let width: CGFloat = compact ? 43 : 29
        stroke(firstRing, width: width + 13, color: color(0x161122))
        metallicStroke(firstRing, width: width, colors: [0xFFF1BC, 0xC18848, 0xE9B56D], in: context)
        stroke(secondRing, width: width + 11, color: color(0x161122))
        metallicStroke(secondRing, width: width, colors: [0xFFF9DB, 0xF0BE74, 0xA0613C], in: context)
        if !compact {
            stroke(secondRing, width: 3, color: color(0xFFF0CB, 0.50))
        }
        // Bring the first orbit in front at the upper crossing to weave the rings.
        context.saveGState()
        context.clip(to: CGRect(x: 440, y: 724, width: 144, height: 89))
        stroke(firstRing, width: width + 13, color: color(0x161122))
        metallicStroke(firstRing, width: width, colors: [0xFFF1BC, 0xC18848, 0xE9B56D], in: context)
        context.restoreGState()
        drawEye(in: context, center: center, compact: compact)
    }

    private static func drawWing(in context: CGContext, compact: Bool) {
        let wing = NSBezierPath()
        wing.move(to: NSPoint(x: 412, y: 492))
        wing.curve(to: NSPoint(x: 158, y: 662),
                   controlPoint1: NSPoint(x: 328, y: 534), controlPoint2: NSPoint(x: 236, y: 565))
        wing.curve(to: NSPoint(x: 247, y: 540),
                   controlPoint1: NSPoint(x: 165, y: 610), controlPoint2: NSPoint(x: 200, y: 571))
        wing.line(to: NSPoint(x: 174, y: 569))
        wing.curve(to: NSPoint(x: 255, y: 489),
                   controlPoint1: NSPoint(x: 184, y: 534), controlPoint2: NSPoint(x: 216, y: 505))
        wing.line(to: NSPoint(x: 196, y: 503))
        wing.curve(to: NSPoint(x: 277, y: 444),
                   controlPoint1: NSPoint(x: 211, y: 476), controlPoint2: NSPoint(x: 238, y: 448))
        wing.line(to: NSPoint(x: 224, y: 449))
        wing.curve(to: NSPoint(x: 412, y: 492),
                   controlPoint1: NSPoint(x: 273, y: 403), controlPoint2: NSPoint(x: 347, y: 406))
        wing.close()
        stroke(wing, width: compact ? 18 : 9, color: color(0x171124))
        gradientFill(wing, colors: [0xFFF1CC, 0xE4B773, 0x986447], in: context)

        if !compact {
            for (start, middle, end) in [
                (NSPoint(x: 183, y: 616), NSPoint(x: 266, y: 542), NSPoint(x: 376, y: 484)),
                (NSPoint(x: 204, y: 536), NSPoint(x: 255, y: 498), NSPoint(x: 358, y: 462)),
                (NSPoint(x: 231, y: 480), NSPoint(x: 289, y: 448), NSPoint(x: 344, y: 448))
            ] {
                let barb = NSBezierPath()
                barb.move(to: start)
                barb.curve(to: end, controlPoint1: middle, controlPoint2: middle)
                stroke(barb, width: 3.5, color: color(0x6D4538, 0.58))
            }
        }
    }

    private static func drawEye(in context: CGContext, center: NSPoint, compact: Bool) {
        let halfWidth: CGFloat = compact ? 225 : 200
        let rise: CGFloat = compact ? 140 : 125
        let eye = NSBezierPath()
        let left = NSPoint(x: center.x - halfWidth, y: center.y)
        let right = NSPoint(x: center.x + halfWidth, y: center.y)
        eye.move(to: left)
        eye.curve(to: right, controlPoint1: NSPoint(x: center.x - 96, y: center.y + rise),
                  controlPoint2: NSPoint(x: center.x + 96, y: center.y + rise))
        eye.curve(to: left, controlPoint1: NSPoint(x: center.x + 96, y: center.y - rise),
                  controlPoint2: NSPoint(x: center.x - 96, y: center.y - rise))
        eye.close()
        stroke(eye, width: compact ? 42 : 32, color: color(0x1B1327))
        gradientFill(eye, colors: [0xFFF8D7, 0xF5D89D, 0xA9785D], in: context)
        metallicStroke(eye, width: compact ? 19 : 12, colors: [0xFFF3C8, 0xF2C983, 0x986744], in: context)

        let radius: CGFloat = compact ? 77 : 70
        let iris = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
        gradientFill(iris, colors: [0x17102F, 0x463474, 0x9881D8, 0xD4C3FF], in: context)
        stroke(iris, width: compact ? 12 : 7, color: color(0x271B47))
        let pupilRadius: CGFloat = compact ? 38 : 34
        let pupil = NSBezierPath(ovalIn: NSRect(x: center.x - pupilRadius, y: center.y - pupilRadius,
                                               width: pupilRadius * 2, height: pupilRadius * 2))
        color(0x130E22).setFill()
        pupil.fill()
        let reflection = diamond(at: NSPoint(x: center.x - 15, y: center.y + 26),
                                 width: compact ? 38 : 29, height: compact ? 49 : 37)
        color(0xFFF3D2).setFill()
        reflection.fill()
    }

    private static func orbit(center: NSPoint, rotation: CGFloat) -> NSBezierPath {
        let ring = NSBezierPath(ovalIn: NSRect(x: -300, y: -188, width: 600, height: 376))
        let transform = AffineTransform(translationByX: center.x, byY: center.y)
        ring.transform(using: AffineTransform(rotationByRadians: rotation))
        ring.transform(using: transform)
        return ring
    }

    private static func diamond(at center: NSPoint, width: CGFloat, height: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y + height / 2))
        path.line(to: NSPoint(x: center.x + width / 2, y: center.y))
        path.line(to: NSPoint(x: center.x, y: center.y - height / 2))
        path.line(to: NSPoint(x: center.x - width / 2, y: center.y))
        path.close()
        return path
    }

    private static func gradientFill(_ path: NSBezierPath, colors: [UInt32], in context: CGContext) {
        context.saveGState()
        path.addClip()
        NSGradient(colors: colors.map { color($0) })!.draw(in: path.bounds, angle: -90)
        context.restoreGState()
    }

    private static func metallicStroke(_ path: NSBezierPath, width: CGFloat, colors: [UInt32], in context: CGContext) {
        context.saveGState()
        context.addPath(path.cgPath)
        context.setLineJoin(.round)
        context.setLineWidth(width)
        context.replacePathWithStrokedPath()
        context.clip()
        let bounds = path.bounds.insetBy(dx: -width / 2, dy: -width / 2)
        NSGradient(colors: colors.map { color($0) })!.draw(in: bounds, angle: -90)
        context.restoreGState()
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat, color: NSColor) {
        color.setStroke()
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
