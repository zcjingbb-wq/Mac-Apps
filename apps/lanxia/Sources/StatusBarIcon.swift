import AppKit

@MainActor enum StatusBarIcon {
    static let frames = [leafHare, emberFox, waveOtter].map(makeImage)

    static func image() -> NSImage {
        frames[0]
    }

    private static func makeImage(pixels: [String]) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.shouldAntialias = false
            NSColor.black.setFill()

            // Each sprite uses a 16-point grid with a one-point transparent border.
            let width = rect.width / size.width
            let height = rect.height / size.height
            for (row, line) in pixels.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    NSRect(x: rect.minX + CGFloat(column + 1) * width,
                           y: rect.minY + CGFloat(row + 1) * height,
                           width: width, height: height).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "蓝匣"
        return image
    }

    private static let leafHare = [
        "................",
        ".......#...##...",
        "......###.###...",
        "......##.###....",
        "......##.##.....",
        ".......###......",
        ".......#####....",
        ".....########...",
        "....#######.##..",
        "...############.",
        ".#.############.",
        ".#############..",
        "..###########...",
        "...###########..",
        "....###..#####..",
        "................"
    ]

    private static let emberFox = [
        "................",
        ".............#..",
        "..##.##.....##..",
        "..##.###...##.#.",
        "..######..##.##.",
        "..##.###..#####.",
        ".########...###.",
        "..###########...",
        "...##########...",
        ".....########...",
        ".....########...",
        ".....###...##...",
        ".....##....###..",
        "....###...###...",
        "................",
        "................"
    ]

    private static let waveOtter = [
        "................",
        "................",
        ".........#..#...",
        "........######..",
        ".......###.####.",
        ".......########.",
        "...##.####.###..",
        "..###########...",
        "...#######......",
        "....########....",
        ".##...###..##...",
        "###..####.####..",
        "###########.###.",
        ".####..#######..",
        "...##....###....",
        "................"
    ]
}
