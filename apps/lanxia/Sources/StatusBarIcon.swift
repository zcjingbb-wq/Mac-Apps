import AppKit

@MainActor enum StatusBarIcon {
    static func image() -> NSImage { wing }

    // One pixel per point at 1×, with corners and feather tips on the same grid at 2×.
    private static let pixels = [
        "..................",
        "..................",
        "...............##.",
        ".............####.",
        "...........#####..",
        ".........######...",
        ".......#######....",
        "......######......",
        ".....##########...",
        "....##########....",
        "...#########......",
        "...#######........",
        "..##########......",
        "..########........",
        "...#####..........",
        "....##............",
        "..................",
        ".................."
    ]

    private static let wing: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let graphics = NSGraphicsContext.current else { return false }
            let context = graphics.cgContext
            context.saveGState()
            defer { context.restoreGState() }
            context.setShouldAntialias(false)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 18, y: rect.height / 18)
            context.setFillColor(NSColor.black.cgColor)

            for (row, line) in pixels.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    context.addRect(CGRect(x: column, y: row, width: 1, height: 1))
                }
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "羽"
        return image
    }()
}
