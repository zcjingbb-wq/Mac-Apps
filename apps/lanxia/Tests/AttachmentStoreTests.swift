import AppKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

private enum AttachmentTestFailure: Error { case failed(String) }

@main
struct AttachmentStoreTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw AttachmentTestFailure.failed(message) }
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("StashCatAttachmentTests-" + UUID().uuidString)
        let cache = base.appendingPathComponent("cache")
        let source = base.appendingPathComponent("sources")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let store = AttachmentStore(cacheRoot: cache)

        let textURL = source.appendingPathComponent("课程笔记.txt")
        let original = Data("Calculus notes\n积分与日程提醒 2026".utf8)
        try original.write(to: textURL)
        await store.add(urls: [textURL])
        try require(store.items.count == 1 && store.items[0].kind == .document, "Plain text loads")
        try require(store.items[0].extractedText.contains("积分与日程提醒"), "UTF-8 Chinese survives")
        try require(store.items[0].imageURL == nil && !store.items[0].isTruncated, "Text is not represented as an image")
        try require(store.items[0].byteCount == original.count, "Original byte count is exact")
        let firstID = store.items[0].id
        try Data("later edit".utf8).write(to: textURL)
        try require(store.items[0].extractedText.contains("Calculus"), "Extraction is independent of later source edits")
        store.remove(id: firstID)
        try require(store.items.isEmpty, "Remove updates published items")
        try require(try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).allSatisfy { (try? fm.contentsOfDirectory(atPath: $0.path).isEmpty) == true }, "Remove deletes owned copies")
        try require(try Data(contentsOf: textURL) == Data("later edit".utf8), "Remove preserves the original")

        let utf16 = source.appendingPathComponent("utf16.txt")
        try "UTF16 中文".data(using: .utf16)!.write(to: utf16)
        await store.add(urls: [utf16])
        try require(store.items.last?.extractedText == "UTF16 中文", "UTF-16 BOM is recognized")
        let csv = source.appendingPathComponent("table.csv")
        try Data("name,value\n微积分,42".utf8).write(to: csv)
        let script = source.appendingPathComponent("never-executed.sh")
        let marker = source.appendingPathComponent("EXECUTED")
        try Data(("#!/bin/sh\ntouch " + marker.path).utf8).write(to: script)
        await store.add(urls: [csv, script])
        try require(store.items.count == 3 && store.items[1].extractedText.contains("微积分"), "CSV is plain data")
        try require(!fm.fileExists(atPath: marker.path), "Source scripts are read without execution")
        store.clear()

        let long = source.appendingPathComponent("long.json")
        try Data((String(repeating: "中", count: 13_000) + "END").utf8).write(to: long)
        await store.add(urls: [long])
        try require(store.items[0].extractedText.count == 12_000 && store.items[0].isTruncated, "Long text has exact character budget")
        try require(store.items[0].notice?.contains("12000") == true, "Truncation is visible")
        store.clear()

        let rtf = source.appendingPathComponent("sample.rtf")
        let rich = NSAttributedString(string: "RTF 中文内容", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        try rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!.write(to: rtf)
        let pdf = source.appendingPathComponent("sample.pdf")
        try makePDF(pdf, text: "PDF text layer 2026")
        await store.add(urls: [rtf, pdf])
        try require(store.items.count == 2, "RTF and PDF load")
        try require(store.items[0].extractedText == "RTF 中文内容", "RTF returns text only")
        try require(store.items[1].extractedText.contains("PDF text layer 2026"), "PDF text layer is extracted")
        try require(store.items[1].notice?.contains("文字层") == true, "PDF extraction limits are disclosed")
        store.clear()

        let package = source.appendingPathComponent("package")
        try fm.createDirectory(at: package.appendingPathComponent("word"), withIntermediateDirectories: true)
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>DOCX 中文正文</w:t></w:r></w:p><w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p></w:body></w:document>"
        try Data(xml.utf8).write(to: package.appendingPathComponent("word/document.xml"))
        let docx = source.appendingPathComponent("sample.docx")
        try zipDocument(package: package, output: docx)
        await store.add(urls: [docx])
        try require(store.items.first?.extractedText == "DOCX 中文正文\nSecond paragraph", "DOCX bounded XML retains paragraphs")
        store.clear()
        let external = "<?xml version=\"1.0\"?><!DOCTYPE document [<!ENTITY secret SYSTEM \"file://\(textURL.path)\">]><w:document xmlns:w=\"urn:test\"><w:body><w:p><w:r><w:t>&secret;</w:t></w:r></w:p></w:body></w:document>"
        try Data(external.utf8).write(to: package.appendingPathComponent("word/document.xml"))
        try fm.removeItem(at: docx)
        try zipDocument(package: package, output: docx)
        await store.add(urls: [docx])
        try require(!store.items.contains { $0.extractedText.contains("later edit") }, "DOCX external entities do not read other files")
        store.clear()

        let symlink = source.appendingPathComponent("symlink.txt")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: textURL)
        let fifo = source.appendingPathComponent("pipe.txt")
        try require(mkfifo(fifo.path, 0o600) == 0, "Synthetic FIFO created")
        let unsupported = source.appendingPathComponent("unknown.bin")
        try Data([1, 2, 3]).write(to: unsupported)
        let binary = source.appendingPathComponent("binary.txt")
        try Data([0, 1, 2, 3, 0, 5]).write(to: binary)
        await store.add(urls: [symlink, source, fifo, binary])
        try require(store.items.isEmpty, "Symlinks, directories, FIFOs and binary text are rejected")
        try require(store.errorMessage?.contains("符号链接") == true && store.errorMessage?.contains("二进制") == true, "Unsafe and invalid inputs have clear explanations")
        await store.add(urls: [unsupported, URL(string: "https://example.invalid/sample.txt")!])
        try require(store.items.isEmpty && store.errorMessage?.contains("本机文件") == true, "Unsupported and non-file URLs are rejected")
        let oversized = source.appendingPathComponent("large.txt")
        fm.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(AttachmentStore.maximumFileBytes + 1))
        try handle.close()
        await store.add(urls: [oversized])
        try require(store.items.isEmpty && store.errorMessage?.contains("25 MiB") == true, "Size guard applies before reading sparse oversized files")

        await store.add(urls: [textURL, textURL, textURL, textURL, textURL])
        try require(store.items.count == 4 && Set(store.items.map(\.id)).count == 4, "Maximum four independently owned attachments")
        try require(store.errorMessage?.contains("超出") == true, "Skipped fifth file is reported")
        store.clear()
        try require(store.items.isEmpty && !store.isLoading && store.errorMessage == nil, "Clear resets state")

        let image = source.appendingPathComponent("OCR.png")
        let imageData = try makeImage(image, text: "STASHCAT FILE TEST 2026\n日程提醒 图片识别")
        await store.add(urls: [image])
        try require(store.items.count == 1 && store.items[0].kind == .image, "PNG loads as image")
        let attachment = store.items[0]
        try require(attachment.extractedText.uppercased().contains("STASHCAT") && attachment.extractedText.contains("2026"), "Real Apple Vision OCR reads synthetic English")
        try require(attachment.extractedText.contains("日程") || attachment.extractedText.contains("图片"), "Real Apple Vision OCR reads synthetic Chinese")
        try require(attachment.notice?.contains("视觉大模型") == true, "OCR limitations are explicit")
        guard let prepared = attachment.imageURL,
              let preparedSource = CGImageSourceCreateWithURL(prepared as CFURL, nil),
              let preparedInfo = CGImageSourceCopyPropertiesAtIndex(preparedSource, 0, nil) as? [CFString: Any] else {
            throw AttachmentTestFailure.failed("Missing prepared image")
        }
        try require((preparedInfo[kCGImagePropertyPixelWidth] as? Int ?? Int.max) <= 2_048 && (preparedInfo[kCGImagePropertyPixelHeight] as? Int ?? Int.max) <= 2_048, "Provider image is bounded to 2048 pixels")
        try require(preparedInfo[kCGImagePropertyGPSDictionary] == nil, "Prepared image contains no GPS metadata")
        try require(prepared.path != image.path, "Provider gets private prepared copy")
        try require((try fm.attributesOfItem(atPath: prepared.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Prepared image is owner-only")
        store.remove(id: attachment.id)
        try require(!fm.fileExists(atPath: prepared.path) && fm.fileExists(atPath: image.path), "Removing image deletes cache and preserves original")

        let oriented = source.appendingPathComponent("oriented.jpg")
        guard let rawSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let rawImage = CGImageSourceCreateImageAtIndex(rawSource, 0, nil),
              let orientedDestination = CGImageDestinationCreateWithURL(oriented as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentTestFailure.failed("JPEG fixture creation")
        }
        CGImageDestinationAddImage(orientedDestination, rawImage, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 32.0, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        try require(CGImageDestinationFinalize(orientedDestination), "Oriented JPEG fixture is encoded")
        await store.add(urls: [oriented])
        guard let orientedPrepared = store.items.first?.imageURL,
              let orientedSource = CGImageSourceCreateWithURL(orientedPrepared as CFURL, nil),
              let orientedInfo = CGImageSourceCopyPropertiesAtIndex(orientedSource, 0, nil) as? [CFString: Any] else {
            throw AttachmentTestFailure.failed("Oriented JPEG preparation")
        }
        try require((orientedInfo[kCGImagePropertyPixelHeight] as? Int ?? 0) > (orientedInfo[kCGImagePropertyPixelWidth] as? Int ?? 0), "EXIF orientation is applied to pixels")
        try require(orientedInfo[kCGImagePropertyGPSDictionary] == nil, "Actual JPEG GPS metadata is stripped")
        store.clear()

        if (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.heic.identifier) {
            let heic = source.appendingPathComponent("sample.heic")
            guard let heicDestination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw AttachmentTestFailure.failed("HEIC fixture creation") }
            CGImageDestinationAddImage(heicDestination, rawImage, nil)
            try require(CGImageDestinationFinalize(heicDestination), "HEIC fixture is encoded")
            await store.add(urls: [heic])
            try require(store.items.first?.kind == .image && store.items.first?.imageURL != nil, "HEIC is decoded and prepared")
            store.clear()
        }

        let pending = Task { await store.add(urls: [image]) }
        while !store.isLoading { await Task.yield() }
        store.clear()
        await pending.value
        try require(store.items.isEmpty && !store.isLoading, "Clearing during analysis discards stale result")

        let tooManyPixels = source.appendingPathComponent("huge-pixels.png")
        var hugeHeader = imageData
        writeBE32(40_001, into: &hugeHeader, offset: 16)
        writeBE32(1_000, into: &hugeHeader, offset: 20)
        writeBE32(crc32(hugeHeader.subdata(in: 12..<29)), into: &hugeHeader, offset: 29)
        try hugeHeader.write(to: tooManyPixels)
        await store.add(urls: [tooManyPixels])
        try require(store.items.isEmpty && store.errorMessage?.contains("4000 万") == true, "Pixel guard rejects oversized header before decoding")

        store.clear()
        try require(try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).allSatisfy { (try? fm.contentsOfDirectory(atPath: $0.path).isEmpty) == true }, "All owned attachment files are cleaned")
        print("PASS: \(checks) attachment assertions, including actual bilingual Vision OCR, text/PDF/RTF/DOCX extraction, bounded image preparation, unsafe-file rejection and cache cleanup")
    }

    @MainActor
    static func makePDF(_ url: URL, text: String) throws {
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &rect, nil) else { throw AttachmentTestFailure.failed("PDF creation") }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 40, y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    @MainActor
    static func makeImage(_ url: URL, text: String) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2_400, pixelsHigh: 900, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw AttachmentTestFailure.failed("Image creation") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 2_400, height: 900).fill()
        (text as NSString).draw(in: NSRect(x: 120, y: 230, width: 2_180, height: 460), withAttributes: [.font: NSFont.systemFont(ofSize: 96), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AttachmentTestFailure.failed("PNG encoding") }
        try data.write(to: url)
        return data
    }

    static func zipDocument(package: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", output.path, "word/document.xml"]
        process.currentDirectoryURL = package
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw AttachmentTestFailure.failed("DOCX fixture zip") }
    }

    static func writeBE32(_ value: UInt32, into data: inout Data, offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (24 - index * 8)) & 255) }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        }
        return ~value
    }
}
