import AppKit
import Foundation

@main
struct CodexVisionIntegration {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixtures" {
            let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try drawFixture().write(to: folder.appendingPathComponent("vision-fixture.png"))
            try "这是功能测试资料，不是真实日程。\n项目代号：青柠 7265。\n待办一：校对报告。\n待办二：准备演示。".write(to: folder.appendingPathComponent("reading-fixture.txt"), atomically: true, encoding: .utf8)
            print("Synthetic UI fixtures ready")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-VisionLive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("vision-fixture.png")
        try drawFixture().write(to: imageURL)
        let service = CodexService(dataDirectory: root)
        defer { service.shutdown() }
        await service.startIfNeeded()
        guard service.isReady else { throw NSError(domain: "VisionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: service.errorMessage ?? service.statusText]) }
        await service.send("只根据附带图片回答：写出图中的四位数字，分别说出两个几何图形的颜色和形状。请用中文简短回答，不要调用工具。", imageURLs: [imageURL])
        guard service.errorMessage == nil, let answer = service.messages.last, answer.role == "assistant", answer.content.contains("5839") else {
            throw NSError(domain: "VisionTest", code: 2, userInfo: [NSLocalizedDescriptionKey: service.errorMessage ?? "Actual vision response did not identify the number"])
        }
        print("PASS actual localImage vision input, without OCR text in prompt. Model: \(service.modelName)")
        print("Synthetic-image answer: \(answer.content)")
        try FileManager.default.removeItem(at: imageURL)
        await service.send("继续刚才这张图：左侧是哪一个图形？只需一句话，不调用工具。")
        guard service.errorMessage == nil, service.messages.last?.role == "assistant", service.messages.last?.content.contains("圆") == true else {
            throw NSError(domain: "VisionTest", code: 3, userInfo: [NSLocalizedDescriptionKey: service.errorMessage ?? "Image follow-up failed after prepared-file cleanup"])
        }
        print("PASS visual conversation continues after prepared image file cleanup")
    }

    @MainActor static func drawFixture() throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor.red.setFill(); NSBezierPath(ovalIn: NSRect(x: 90, y: 65, width: 130, height: 130)).fill()
        NSColor.blue.setFill(); NSRect(x: 400, y: 65, width: 130, height: 130).fill()
        ("5839" as NSString).draw(at: NSPoint(x: 215, y: 265), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}
