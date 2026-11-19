import AppKit

@MainActor enum StatusBarIcon {
    // Original pixel art for the status bar, sized to whole points at 1× and 2×.
    private static let pixels = [
        "..................",
        "......OOOOO.....Y.",
        "....OOHHBBBOO..YYW",
        "...OHHBBBBYDCO..Y.",
        "..OHWBBBYWWDCCO...",
        ".OHBBBYWWYDCCCO...",
        ".OBBYWWYDDCCCCDO..",
        ".OBYWWYDDCCCDDCO..",
        ".OBWYBDDCCCCDDCO..",
        ".OIDDDOOOIIIDDDO..",
        ".ODDDOWWYOIDCCDO..",
        ".ODCCOWYYODCCCO...",
        "..OCCDOOODCCDO....",
        "...OCCDDDDCDO.....",
        "....OOCCCCOO......",
        "......OOOO........",
        "..................",
        ".................."
    ]

    private static let palette: [Character: NSColor] = [
        "O": .init(srgbRed: 0.05, green: 0.15, blue: 0.26, alpha: 1),
        "H": .init(srgbRed: 0.61, green: 0.93, blue: 0.98, alpha: 1),
        "B": .init(srgbRed: 0.25, green: 0.72, blue: 0.93, alpha: 1),
        "C": .init(srgbRed: 0.15, green: 0.53, blue: 0.79, alpha: 1),
        "D": .init(srgbRed: 0.12, green: 0.36, blue: 0.60, alpha: 1),
        "I": .init(srgbRed: 0.08, green: 0.23, blue: 0.40, alpha: 1),
        "Y": .init(srgbRed: 1, green: 0.72, blue: 0.18, alpha: 1),
        "W": .init(srgbRed: 1, green: 0.94, blue: 0.58, alpha: 1)
    ]

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.shouldAntialias = false

            let xStep = rect.width / 18
            let yStep = rect.height / 18
            for (row, line) in pixels.enumerated() {
                for (column, pixel) in line.enumerated() {
                    guard let color = palette[pixel] else { continue }
                    color.setFill()
                    NSRect(x: rect.minX + CGFloat(column) * xStep,
                           y: rect.minY + CGFloat(row) * yStep,
                           width: xStep,
                           height: yStep).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "蓝匣"
        return image
    }
}
