import Foundation

@main
struct AttachmentPromptTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-PromptTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<4).map { index in
            let url = root.appendingPathComponent(String(repeating: "n", count: 115) + "\(index).txt")
            try String(repeating: "这是一段供验证输入长度的正文。", count: 1_000).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let store = AttachmentStore(cacheRoot: root)
        await store.add(urls: urls)
        precondition(store.items.count == 4)
        let question = String(repeating: "问", count: 1_200)
        let local = try AttachmentPrompt.prepare(question: question, items: store.items, online: false)
        precondition(local.text.count <= 6_000, "Local input must fit AIService's hard limit")
        precondition(local.text.contains(question) && local.isTruncated && local.imageURLs.isEmpty)
        precondition(local.text.contains("设备端 OCR") && local.text.contains("部分附件有截断"))
        precondition(!local.text.contains(root.path))
        for index in 1...4 { precondition(local.text.contains("<attachment-data-\(index)>")) }
        let online = try AttachmentPrompt.prepare(question: question, items: store.items, online: true)
        precondition(online.text.count <= 20_000 && online.text.count > local.text.count)
        do {
            _ = try AttachmentPrompt.prepare(question: question + "多", items: store.items, online: false)
            preconditionFailure("Oversized question must be rejected before clearing pending attachments")
        } catch is AttachmentPrompt.InputError { }
        let automatic = try AttachmentPrompt.prepare(question: "", items: store.items, online: true)
        precondition(automatic.text.contains("请概括这些附件"))
        store.clear()
        print("PASS attachment prompt integration: four long filenames/documents, local/online budgets, question retention, truncation disclosure, data boundaries, no source paths")
    }
}
