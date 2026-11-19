import AppKit
import Foundation
import ImageIO

private enum ScreenQuestionTestFailure: Error { case failed(String) }

@main
struct ScreenQuestionTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw ScreenQuestionTestFailure.failed(message) }
        }

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("StashCat-ScreenQuestionTests-" + UUID().uuidString)
        let sources = base.appendingPathComponent("sources", isDirectory: true)
        let cache = base.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let service = ScreenQuestionService(cacheRoot: cache)
        let raw = sources.appendingPathComponent("截图-中英求导题.png")
        let png = try makeQuestionImage(at: raw)

        // A reviewed screenshot is converted to an owned provider image before the
        // picker preview closes. Removing the raw capture must not invalidate it.
        guard let online = await service.prepare(url: raw, question: "", online: true),
              let preparedURL = online.prompt.imageURLs.first else {
            throw ScreenQuestionTestFailure.failed("Online screenshot preparation failed: " + (service.errorMessage ?? "unknown"))
        }
        try require(!service.isPreparing && service.errorMessage == nil, "Online preparation completes cleanly")
        try require(online.prompt.imageURLs.count == 1, "Online prompt owns exactly one image")
        try require(preparedURL != raw && preparedURL.path.hasPrefix(cache.path + "/"), "Provider image is an independent copy in the injected cache")
        try require(online.prompt.text.contains("截图可见信息") && online.prompt.text.contains("不猜测未显示内容"), "Default screen question limits analysis to visible information")
        try require(online.prompt.text.uppercased().contains("SCREEN ASSISTANT") && online.prompt.text.contains("2026"), "Real Vision OCR reads synthetic English")
        try require(online.prompt.text.contains("求导"), "Real Vision OCR reads synthetic Chinese absent from the default question")
        try require(online.prompt.text.lowercased().contains("x") && online.prompt.text.contains("3") && online.prompt.text.contains("2"), "Synthetic mathematics is present in the extracted prompt")
        try require(!online.prompt.text.contains(base.path), "Prompt does not expose raw or private cache paths")
        try require(isReadableImage(preparedURL), "Prepared online image decodes")
        try fm.removeItem(at: raw)
        try require(!fm.fileExists(atPath: raw.path) && isReadableImage(preparedURL), "Prepared image survives deletion of the raw screenshot")
        service.finish(online.id)
        try require(!fm.fileExists(atPath: preparedURL.path), "Finish removes the prepared image")
        try require(try cacheIsEmpty(cache), "Finish leaves no owned cache entries")

        try png.write(to: raw)
        guard let local = await service.prepare(url: raw, question: "解释这道求导题", online: false) else {
            throw ScreenQuestionTestFailure.failed("Local screenshot preparation failed")
        }
        try require(local.prompt.imageURLs.isEmpty, "Local prompt never includes image URLs")
        try require(local.prompt.text.contains("设备端 OCR") && local.prompt.text.contains("基础分类标签"), "Local OCR limitations are disclosed")
        try require(local.prompt.text.contains("解释这道求导题"), "Explicit user question survives preparation")
        try require(local.prompt.text.uppercased().contains("SCREEN ASSISTANT"), "Local prompt includes the screenshot's actual OCR text")
        service.finish(local.id)
        try require(try cacheIsEmpty(cache), "Local finish also removes private image preparation")
        try require(fm.fileExists(atPath: raw.path), "Cleanup preserves the selected source file")

        // Reject missing, corrupt and non-image inputs without keeping copied data.
        let missing = sources.appendingPathComponent("不存在.png")
        let corrupt = sources.appendingPathComponent("损坏.png")
        try Data("not a PNG".utf8).write(to: corrupt)
        let document = sources.appendingPathComponent("不是截图.txt")
        try Data("A document is not a screenshot.".utf8).write(to: document)
        for invalid in [missing, corrupt, document] {
            let result = await service.prepare(url: invalid, question: "请读题", online: true)
            try require(result == nil && !service.isPreparing, "Invalid screenshot fails without a prepared result")
            try require(service.errorMessage?.isEmpty == false, "Invalid screenshot has a visible error")
            try require(try cacheIsEmpty(cache), "Invalid screenshot leaves no cache entries")
        }
        let tooLong = await service.prepare(url: raw, question: String(repeating: "问", count: 1_201), online: true)
        try require(tooLong == nil && service.errorMessage?.contains("1200") == true, "Oversized screen question is rejected explicitly")
        try require(!service.isPreparing && (try cacheIsEmpty(cache)), "Oversized question does not start preparation or retain files")

        // Wait for the real asynchronous image/OCR pipeline to suspend before
        // cancelling. Its eventual detached result must not resurrect any files.
        let pending = Task { await service.prepare(url: raw, question: "请读题", online: true) }
        try await waitUntilPreparing(service)
        service.cancel()
        try require(!service.isPreparing && service.errorMessage == nil, "Cancel resets visible preparation state immediately")
        let cancelled = await pending.value
        try require(cancelled == nil, "Cancelled asynchronous preparation discards its result")
        try require(try cacheIsEmpty(cache), "Cancelled asynchronous image work cleans its late result")

        // An old sender's completion must not clear the next screenshot's owned
        // image. This is the same ordering as cancelling/replacing a prior send.
        guard let first = await service.prepare(url: raw, question: "第一题", online: true),
              let firstURL = first.prompt.imageURLs.first else {
            throw ScreenQuestionTestFailure.failed("First replacement fixture failed")
        }
        guard let second = await service.prepare(url: raw, question: "第二题", online: true),
              let secondURL = second.prompt.imageURLs.first else {
            throw ScreenQuestionTestFailure.failed("Second replacement fixture failed")
        }
        try require(first.id != second.id && firstURL != secondURL, "Replacement has an independent operation ID and prepared image")
        try require(!fm.fileExists(atPath: firstURL.path), "Replacing preparation cleans the old owned image")
        service.finish(first.id)
        try require(isReadableImage(secondURL), "Old finish does not clean the current operation")
        try require(second.prompt.text.contains("第二题") && service.errorMessage == nil, "Current prompt stays valid after old finish")
        service.finish(second.id)
        try require(!fm.fileExists(atPath: secondURL.path) && (try cacheIsEmpty(cache)), "Current finish cleans its own operation")

        // Starting a new operation immediately after cancelling an in-flight one
        // also keeps stale asynchronous completion out of the new result.
        let oldPending = Task { await service.prepare(url: raw, question: "已取消的问题", online: true) }
        try await waitUntilPreparing(service)
        service.cancel()
        let newPending = Task { await service.prepare(url: raw, question: "保留的新问题", online: true) }
        let oldResult = await oldPending.value
        let newResult = await newPending.value
        try require(oldResult == nil, "Old in-flight operation stays cancelled after replacement starts")
        guard let latest = newResult, let latestURL = latest.prompt.imageURLs.first else {
            throw ScreenQuestionTestFailure.failed("New operation was lost to stale completion")
        }
        try require(latest.prompt.text.contains("保留的新问题") && isReadableImage(latestURL), "New operation survives old asynchronous completion")
        service.cancel()
        try require(!fm.fileExists(atPath: latestURL.path) && (try cacheIsEmpty(cache)), "Final cancellation clears the newest owned image")
        try require(try Data(contentsOf: raw) == png, "All preparation and cancellation preserve the source PNG")

        print("PASS: \(checks) screen-question assertions: synthetic bilingual/math OCR, independent provider image lifetime, local limits, invalid-input cleanup, cancellation and operation isolation; no screen capture or network")
    }

    @MainActor
    private static func waitUntilPreparing(_ service: ScreenQuestionService) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !service.isPreparing {
            guard Date() < deadline else { throw ScreenQuestionTestFailure.failed("Preparation did not begin within the bounded wait") }
            await Task.yield()
        }
    }

    private static func cacheIsEmpty(_ cache: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).isEmpty
    }

    private static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    @MainActor
    private static func makeQuestionImage(at url: URL) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2_400, pixelsHigh: 1_100,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                           bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ScreenQuestionTestFailure.failed("Synthetic question bitmap creation failed")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 2_400, height: 1_100).fill()
        let lines = ["SCREEN ASSISTANT 2026", "题目：求导 x^3 + 2*x", "What is the derivative?", "A. 3*x^2 + 2", "B. x^2 + 2"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 120, y: 900 - CGFloat(index) * 175),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 88), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenQuestionTestFailure.failed("Synthetic question PNG encoding failed")
        }
        try data.write(to: url)
        return data
    }
}
