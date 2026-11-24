import AppKit
import Combine
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ChatAttachmentKind: String, Sendable {
    case document
    case image
}

struct ImageRecognitionResult: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let recognizedText: String
    let labels: [String]
}

/// An explicitly selected file. Only its extracted text and prepared image are sent to providers.
struct ChatAttachment: Identifiable, Sendable {
    let id: UUID
    let name: String
    let kind: ChatAttachmentKind
    let extractedText: String
    let notice: String?
    let isTruncated: Bool
    let imageURL: URL?
    let imageRecognition: ImageRecognitionResult?
    let byteCount: Int64
    fileprivate let ownedDirectory: URL
}

@MainActor
final class AttachmentStore: ObservableObject {
    @Published private(set) var items: [ChatAttachment] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    nonisolated static let maximumAttachments = 4
    nonisolated static let maximumFileBytes: Int64 = 25 * 1_024 * 1_024
    nonisolated static let maximumTextCharacters = 12_000
    nonisolated static let maximumImagePixels = 40_000_000
    nonisolated static let maximumImageDimension = 2_048
    static let supportedTypes: [UTType] = [
        .image, .pdf, .plainText, .sourceCode, .rtf, .json, .commaSeparatedText, .xml,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "yaml") ?? .plainText,
        UTType(filenameExtension: "toml") ?? .plainText
    ]

    private let cacheURL: URL
    private var generation = UUID()

    /// cacheRoot is injectable for isolated tests; every store owns a random child directory.
    init(cacheRoot: URL? = nil) {
        let root = cacheRoot ?? FileManager.default.temporaryDirectory
        cacheURL = root.appendingPathComponent("StashCatAttachments-" + UUID().uuidString, isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: cacheURL) }

    func add(urls: [URL], imagesOnly: Bool = false) async {
        guard !isLoading else {
            errorMessage = "附件仍在读取，请稍候再添加。"
            return
        }
        guard !urls.isEmpty else { return }
        guard items.count < Self.maximumAttachments else {
            errorMessage = "每次最多添加 4 个附件。"
            return
        }
        errorMessage = nil
        isLoading = true
        let operation = UUID()
        generation = operation
        let available = Self.maximumAttachments - items.count
        let acceptedURLs = Array(urls.prefix(available))
        let root = cacheURL
        var errors: [String] = urls.count > available ? ["每次最多添加 4 个附件，超出的文件未读取。"] : []
        for url in acceptedURLs {
            guard generation == operation else { break }
            let scoped = url.startAccessingSecurityScopedResource()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AttachmentReader.read(url: url, cacheRoot: root, imagesOnly: imagesOnly) }
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard generation == operation else {
                if case .success(let item) = result { try? FileManager.default.removeItem(at: item.ownedDirectory) }
                break
            }
            switch result {
            case .success(let item): items.append(item)
            case .failure(let error): errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        guard generation == operation else { return }
        isLoading = false
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        try? FileManager.default.removeItem(at: item.ownedDirectory)
    }

    func clear() {
        generation = UUID()
        for item in items { try? FileManager.default.removeItem(at: item.ownedDirectory) }
        items = []
        isLoading = false
        errorMessage = nil
    }
}

private enum AttachmentReadError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

private enum AttachmentReader {
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "log", "yaml", "yml", "xml",
        "html", "htm", "swift", "py", "js", "ts", "tsx", "jsx", "c", "cc", "cpp", "h", "hpp", "java",
        "go", "rs", "sh", "zsh", "bash", "sql", "tex", "css", "scss", "ini", "toml", "r", "rb", "kt",
        "kts", "m", "mm", "srt", "vtt", "ipynb", "conf", "cfg"
    ]

    static func read(url: URL, cacheRoot: URL, imagesOnly: Bool) throws -> ChatAttachment {
        guard url.isFileURL else { throw AttachmentReadError.invalid("仅支持选择本机文件。") }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let isImage = type?.conforms(to: .image) == true
        guard !imagesOnly || isImage else { throw AttachmentReadError.invalid("此处仅支持图片，请选择 PNG、JPEG 或 HEIC 等图片文件。") }
        let id = UUID()
        let directory = cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let source = directory.appendingPathComponent("source" + (ext.isEmpty ? "" : "." + ext))
        let byteCount = try copyRegularFile(url, to: source)
        let result: (String, String?, Bool, URL?, ChatAttachmentKind)
        var imageRecognition: ImageRecognitionResult?
        if isImage {
            let image = try imageText(source, directory: directory)
            result = (image.text, image.notice, image.truncated, image.url, .image)
            imageRecognition = image.recognition
        } else if ext == "pdf" {
            let text = try pdfText(source)
            result = (text.text, text.notice, text.truncated, nil, .document)
        } else if ext == "docx" {
            let text = try docxText(source)
            let bounded = limit(text)
            result = (bounded.text, bounded.truncated ? "文档较长，只提取前 12000 字；未读取图片、批注或附件。" : "已提取正文；未读取图片、批注或附件。", bounded.truncated, nil, .document)
        } else if ext == "rtf" {
            let data = try Data(contentsOf: source)
            let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            let bounded = limit(attributed.string)
            result = (bounded.text, bounded.truncated ? "文档较长，只提取前 12000 字。" : nil, bounded.truncated, nil, .document)
        } else if textExtensions.contains(ext) || type?.conforms(to: .plainText) == true || type?.conforms(to: .sourceCode) == true {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            let byteTruncated = byteCount > Int64(data.count)
            let decoded = try decode(data, prefixMayBeIncomplete: byteTruncated)
            let bounded = limit(decoded)
            let truncated = byteTruncated || bounded.truncated
            result = (bounded.text, truncated ? "文件较长，只提取前 12000 字以内的文本。" : nil, truncated, nil, .document)
        } else {
            throw AttachmentReadError.invalid("暂不支持这种文件。请选择文本、代码、PDF、RTF、DOCX 或图片。")
        }
        succeeded = true
        return ChatAttachment(id: id, name: url.lastPathComponent, kind: result.4,
                              extractedText: result.0, notice: result.1, isTruncated: result.2,
                              imageURL: result.3, imageRecognition: imageRecognition,
                              byteCount: byteCount, ownedDirectory: directory)
    }

    /// O_NOFOLLOW + fstat keep symbolic links and special files out, including a replacement race.
    static func copyRegularFile(_ url: URL, to destination: URL) throws -> Int64 {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else {
            throw AttachmentReadError.invalid(errno == ELOOP ? "不读取符号链接，请选择原始文件。" : "无法打开文件，请检查访问权限。")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AttachmentReadError.invalid("无法读取文件信息。") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AttachmentReadError.invalid("仅支持普通文件，不读取文件夹、符号链接或设备。") }
        guard info.st_size <= AttachmentStore.maximumFileBytes else { throw AttachmentReadError.invalid("单个文件不能超过 25 MiB。") }
        let outputFD = destination.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard outputFD >= 0 else { throw AttachmentReadError.invalid("无法创建私有附件副本。") }
        defer { Darwin.close(outputFD) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: Int64 = 0
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw AttachmentReadError.invalid("读取文件失败。") }
            total += Int64(count)
            guard total <= AttachmentStore.maximumFileBytes else { throw AttachmentReadError.invalid("单个文件不能超过 25 MiB。") }
            var written = 0
            try buffer.withUnsafeBytes { bytes in
                while written < count {
                    let size = Darwin.write(outputFD, bytes.baseAddress!.advanced(by: written), count - written)
                    if size < 0 { if errno == EINTR { continue }; throw AttachmentReadError.invalid("保存附件副本失败。") }
                    guard size > 0 else { throw AttachmentReadError.invalid("保存附件副本失败。") }
                    written += size
                }
            }
        }
        return total
    }

    static func limit(_ text: String) -> (text: String, truncated: Bool) {
        let normalized = text.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(normalized.prefix(AttachmentStore.maximumTextCharacters)), normalized.count > AttachmentStore.maximumTextCharacters)
    }

    static func decode(_ data: Data, prefixMayBeIncomplete: Bool) throws -> String {
        if data.isEmpty { return "" }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        guard !data.contains(0) else { throw AttachmentReadError.invalid("内容似乎是二进制数据，无法作为文本读取。") }
        var decoded = String(data: data, encoding: .utf8)
        if decoded == nil, prefixMayBeIncomplete {
            for dropped in 1...min(3, data.count) {
                if let text = String(data: data.dropLast(dropped), encoding: .utf8) { decoded = text; break }
            }
        }
        if decoded == nil {
            let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            decoded = String(data: data, encoding: gbEncoding)
        }
        guard let text = decoded else { throw AttachmentReadError.invalid("无法识别文字编码，请另存为 UTF-8 后再添加。") }
        let badControls = text.unicodeScalars.filter { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard badControls * 100 <= max(text.unicodeScalars.count, 1) else { throw AttachmentReadError.invalid("内容似乎是二进制数据，无法作为文本读取。") }
        return text
    }

    static func pdfText(_ url: URL) throws -> (text: String, notice: String?, truncated: Bool) {
        guard let document = PDFDocument(url: url) else { throw AttachmentReadError.invalid("PDF 已损坏或无法读取。") }
        guard !document.isLocked else { throw AttachmentReadError.invalid("PDF 已加密，请解锁或导出未加密副本后添加。") }
        var text = ""
        var pagesRead = 0
        let pageLimit = min(document.pageCount, 200)
        for index in 0..<pageLimit {
            guard let page = document.page(at: index) else { continue }
            pagesRead = index + 1
            if let pageText = page.string { text += "\n[第 \(index + 1) 页]\n" + pageText }
            if text.count > AttachmentStore.maximumTextCharacters { break }
        }
        let bounded = limit(text)
        let truncated = bounded.truncated || pagesRead < document.pageCount
        let notice: String?
        if bounded.text.isEmpty { notice = "PDF 中没有可提取文字；当前 PDF 读取不对扫描页执行 OCR，可将页面导出为图片后识别。" }
        else if truncated { notice = "只提取前 12000 字及最多 200 页；未读取图片、附件或链接内容。" }
        else { notice = "已读取 PDF 文字层；未读取图片、附件或链接内容。" }
        return (bounded.text, notice, truncated)
    }

    static func docxText(_ url: URL) throws -> String {
        // Read only this bounded XML entry; neither Office macros nor linked resources are run.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let handle = pipe.fileHandleForReading
        defer { try? handle.close(); if process.isRunning { process.terminate() } }
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        let deadline = Date().addingTimeInterval(8)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 2_097_152 else { process.terminate(); throw AttachmentReadError.invalid("DOCX 展开的正文超过 2 MiB，请导出为文本或 PDF。") }
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR { throw AttachmentReadError.invalid("DOCX 正文读取失败。") }
            if Date() > deadline { process.terminate(); throw AttachmentReadError.invalid("DOCX 读取超时，请导出为文本或 PDF。") }
            if count < 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw AttachmentReadError.invalid("DOCX 已损坏或不含正文。") }
        let delegate = DocxTextDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw AttachmentReadError.invalid("DOCX 正文格式无法读取。") }
        return delegate.text
    }

    static func imageText(_ url: URL, directory: URL) throws -> (text: String, notice: String?, truncated: Bool, url: URL, recognition: ImageRecognitionResult) {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw AttachmentReadError.invalid("图片无法解码。") }
        guard width <= AttachmentStore.maximumImagePixels / height else { throw AttachmentReadError.invalid("图片超过 4000 万像素，请缩小后再添加。") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AttachmentStore.maximumImageDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AttachmentReadError.invalid("无法生成图片预览。") }
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        let preparedURL = directory.appendingPathComponent(hasAlpha ? "image.png" : "image.jpg")
        let outputType = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(preparedURL as CFURL, outputType.identifier as CFString, 1, nil) else { throw AttachmentReadError.invalid("无法保存图片预览。") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentReadError.invalid("无法保存图片预览。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preparedURL.path)

        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = true
        recognition.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        recognition.automaticallyDetectsLanguage = true
        let classifier = VNClassifyImageRequest()
        var notices = ["本地图片识别使用系统 OCR 和基础分类，可能漏字或误判，不等同于视觉大模型。"]
        var recognizedText = ""
        var labels: [String] = []
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([recognition])
            recognizedText = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch { notices.append("OCR 未能完成。") }
        do {
            try handler.perform([classifier])
            labels = (classifier.results ?? []).filter { $0.confidence >= 0.12 }.prefix(5).map { "\($0.identifier)（\(Int(($0.confidence * 100).rounded()))%）" }
        } catch { notices.append("基础图像分类未能完成。") }
        if CGImageSourceGetCount(source) > 1 { notices.append("动态或多页图片只读取第一帧。") }
        if recognizedText.isEmpty { notices.append("没有识别到可读文字。") }
        var text = "图片尺寸：\(width) × \(height) 像素。\n"
        if !labels.isEmpty { text += "系统基础标签（可能不准确）：" + labels.joined(separator: "、") + "\n" }
        text += recognizedText.isEmpty ? "OCR：未识别到文字。" : "OCR 识别文字：\n" + recognizedText
        let bounded = limit(text)
        if bounded.truncated { notices.append("识别结果较长，只保留前 12000 字。") }
        let details = ImageRecognitionResult(pixelWidth: width, pixelHeight: height,
                                             recognizedText: limit(recognizedText).text, labels: labels)
        return (bounded.text, notices.joined(separator: " "), bounded.truncated, preparedURL, details)
    }
}

private final class DocxTextDelegate: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private var insideText = false
    private func append(_ string: String) {
        let remaining = AttachmentStore.maximumTextCharacters + 1 - text.count
        if remaining > 0 { text += string.prefix(remaining) }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "t" { insideText = true }
        else if local == "tab" { append("\t") }
        else if local == "br" { append("\n") }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if insideText { append(string) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "t" { insideText = false }
        else if local == "p" { append("\n") }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
