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
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0x052641, 0.40).cgColor)
        color(0x134870).setFill()
        face.fill()
        context.restoreGState()

        context.saveGState()
        face.addClip()
        NSGradient(colors: [color(0xC4F5FF), color(0x46A9D8), color(0x175A9D), color(0x10335E)])!
            .draw(in: face.bounds, angle: -62)
        NSGradient(starting: color(0xE2FBFF, 0.54), ending: color(0xE2FBFF, 0))!
            .draw(fromCenter: NSPoint(x: 280, y: 790), radius: 26,
                  toCenter: NSPoint(x: 280, y: 790), radius: 590, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        let glassHighlight = NSBezierPath()
        glassHighlight.move(to: NSPoint(x: 95, y: 943))
        glassHighlight.line(to: NSPoint(x: 927, y: 943))
        glassHighlight.line(to: NSPoint(x: 927, y: 805))
        glassHighlight.curve(to: NSPoint(x: 90, y: 625), controlPoint1: NSPoint(x: 752, y: 776),
                             controlPoint2: NSPoint(x: 395, y: 646))
        glassHighlight.close()
        NSGradient(starting: color(0xFFFFFF, 0.42), ending: color(0xD9F8FF, 0.02))!
            .draw(in: glassHighlight, angle: -90)

        context.saveGState()
        context.translateBy(x: 521, y: 232)
        context.scaleBy(x: 1, y: 0.33)
        NSGradient(starting: color(0x081F41, 0.70), ending: color(0x081F41, 0))!
            .draw(fromCenter: .zero, radius: 30,
                  toCenter: .zero, radius: 325, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        context.restoreGState()
        context.restoreGState()

        let outerRim = NSBezierPath(roundedRect: face.bounds.insetBy(dx: 2.5, dy: 2.5),
                                    xRadius: 181.5, yRadius: 181.5)
        color(0x12365A, 0.84).setStroke()
        outerRim.lineWidth = 5
        outerRim.stroke()
        let innerRim = NSBezierPath(roundedRect: face.bounds.insetBy(dx: 8, dy: 8),
                                    xRadius: 176, yRadius: 176)
        context.saveGState()
        innerRim.setClipForStroke()
        NSGradient(starting: color(0xF6FFFF, 0.98), ending: color(0x8FC7EF, 0.31))!
            .draw(in: face.bounds, angle: -102)
        context.restoreGState()

        drawOrb(in: context, compact: pixels < 64)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode the \(pixels) px icon")
        }
        return png
    }

    // Stepped shell contours, an angled seam, and a faceted amber latch.
    private static let orb = [
        ".............................",
        "..........OOOOOOOOO..........",
        "........OOOLLRRRRROOO........",
        "......OOOLLLRRRRRRDDOOO......",
        ".....OOHHHHHHLRRRRRRDDOO.....",
        "....OOHHHHHHHLLRRRRRRDDOO....",
        "...OOLLLLLLLLRRRRRRRRRRDOO...",
        "..OOLLRRRRRRRRRRRRRRRRRDDO...",
        "..OLLRRRRRRRRRRRRRRRRRRRDOO..",
        ".OOORRRRRRRRRRRRRRRRRRRRMDO..",
        ".OOOOOORRRRRRRROORRRRRMMMDOO.",
        ".OINNOOOOORRRROOAORRRMMMMMDO.",
        ".OIIIINNNOOOOOOAAAOMMMMMMMDO.",
        ".OIIIIIIINNNOOAYYANOMMMMMMDO.",
        ".OIIIIIIIIIOOAYYPUNNOMMMDDDO.",
        ".OIIIIIWWWWOAAYPPUNNOODDDDDO.",
        ".OIIIIIWWWWWOAAUUNNOOOOOODDO.",
        ".OIIIWWWWWIIIONNNNOOINNNOOOO.",
        ".OIIIWWWWIIIIIONNOOIIIIINNOO.",
        ".OOIIIIIIIIIIIIOOOIIIIIIIGO..",
        "..OIIIIIIIIIIIIIOIIIIIIIIGO..",
        "..OOIIIIIIIIIIIIIIIIIIISGO...",
        "...OOIIIIIIIIIIIIIIIIISGOO...",
        "....OGGIIIIIIIIIIIIISSGOO....",
        ".....OOGIIIIIIIIIIISSGOO.....",
        "......OOGGIIIIIIISSGGOO......",
        ".......OOOGGGGGGGGGOOO.......",
        ".........OOOOOOOOOOO.........",
        "............................."
    ]

    private static let compactOrb = [
        "....OOO....",
        "..OOLRDOO..",
        ".OLHHRRRDO.",
        ".ORRRRRRDO.",
        "OOORRRODMDO",
        "OINOOOAPODO",
        "OIIIIOAYNDO",
        ".OIWIIOOOO.",
        ".OIIIISSGO.",
        "..OGGGGOO..",
        "....OOO...."
    ]

    private static let palette: [Character: UInt32] = [
        "O": 0x251A31, "D": 0x951C34, "M": 0xCC283F, "R": 0xF6454F,
        "L": 0xFF8581, "H": 0xFFB9A6, "N": 0x513B50, "W": 0xFFFEED,
        "I": 0xFCE6C6, "S": 0xE6BA9D, "G": 0xBA8F88, "A": 0xB59152,
        "U": 0xDA963B, "Y": 0xFFC451, "P": 0xFFF1A8
    ]

    private static func drawOrb(in context: CGContext, compact: Bool) {
        let rows = compact ? compactOrb : orb
        let cell: CGFloat = compact ? 64 : 22
        let origin = NSPoint(x: (1024 - CGFloat(rows.count) * cell) / 2,
                             y: (1024 - CGFloat(rows.count) * cell) / 2 + (compact ? 0 : 18))
        context.saveGState()
        context.setShouldAntialias(false)
        defer { context.restoreGState() }
        for (lineIndex, line) in rows.reversed().enumerated() {
            for (column, pixel) in line.enumerated() {
                guard let shade = palette[pixel] else { continue }
                color(shade).setFill()
                NSRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(lineIndex) * cell,
                       width: cell, height: cell).fill()
            }
        }
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
