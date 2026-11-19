import Foundation
import Combine

struct PreparedScreenQuestion {
    let id: UUID
    let prompt: PreparedAttachmentPrompt
}

/// Keeps a reviewed screenshot separate from normal drafts and attachments. The
/// prepared image lives until the send finishes, even after the raw preview closes.
@MainActor
final class ScreenQuestionService: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    private var operation: UUID?
    private var store: AttachmentStore?
    private let cacheRoot: URL?

    init(cacheRoot: URL? = nil) { self.cacheRoot = cacheRoot }

    func prepare(url: URL, question: String, online: Bool) async -> PreparedScreenQuestion? {
        guard !isPreparing else { return nil }
        cancel()
        let id = UUID()
        operation = id
        errorMessage = nil
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 1_200 else {
            errorMessage = "屏幕问题请控制在 1200 字以内。"
            operation = nil
            return nil
        }
        let batch = AttachmentStore(cacheRoot: cacheRoot)
        store = batch
        isPreparing = true
        await batch.add(urls: [url])
        guard operation == id else { batch.clear(); return nil }
        guard batch.items.count == 1, batch.items.first?.kind == .image else {
            let message = batch.errorMessage ?? "截图未能读取，请重新选择。"
            cancel()
            errorMessage = message
            return nil
        }
        do {
            let prompt = try AttachmentPrompt.prepare(
                question: trimmed.isEmpty
                    ? "请根据我选择的这张屏幕截图识别题目并回答，给出可核查的思路；如有选项，请引用选项文字。只依据截图可见信息，不清楚或被遮挡时说明缺失处，不猜测未显示内容。"
                    : trimmed,
                items: batch.items, online: online)
            isPreparing = false
            return PreparedScreenQuestion(id: id, prompt: prompt)
        } catch {
            cancel()
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func finish(_ id: UUID) {
        guard operation == id else { return }
        cancel()
    }

    func cancel() {
        operation = nil
        store?.clear()
        store = nil
        isPreparing = false
        errorMessage = nil
    }
}
