import Foundation
import Combine
import Security

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: String
    var content: String

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

/// Owns the DeepSeek transcript and launches Harness only for an explicit send.
@MainActor
final class AIService: ObservableObject {
    @Published private(set) var statusText = "DeepSeek AI 未开启"
    @Published private(set) var isReady = false
    @Published private(set) var isGenerating = false
    @Published private(set) var hasAPIKey = false
    @Published private(set) var authRequired = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var messages: [ChatMessage] = []

    let modelName = "deepseek-flash"
    private let historyURL: URL
    private let runtime: HarnessRuntime?
    private let readCredential: () throws -> String?
    private var transport: HarnessTransport?
    private var turnID: UUID?
    private var pendingMessageID: UUID?

    init(dataDirectory: URL? = nil,
         runtime: HarnessRuntime? = HarnessRuntime.bundled,
         readCredential: (() throws -> String?)? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let directory = dataDirectory ?? environment["STASHCAT_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StashCat", isDirectory: true)
        historyURL = directory.appendingPathComponent("deepseek-history.json")
        self.runtime = runtime
        self.readCredential = readCredential ?? Self.readKeychain
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = Array(saved.filter { ["user", "assistant"].contains($0.role) && !$0.content.isEmpty }.suffix(80))
        }
    }

    func startIfNeeded() {
        guard !isGenerating else { return }
        do {
            _ = try prepareToSend()
        } catch { showError(error) }
    }

    func saveAPIKey(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw HarnessError.invalidKeyFormat
        }
        let data = Data(key.utf8)
        let updated = SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = Self.keychainQuery
            item[kSecValueData] = data
            item[kSecAttrLabel] = "蓝匣 · DeepSeek"
            try Self.checkKeychain(SecItemAdd(item as CFDictionary, nil))
        } else { try Self.checkKeychain(updated) }

        stopGeneration()
        startIfNeeded()
    }

    func removeAPIKey() throws {
        let removed = SecItemDelete(Self.keychainQuery as CFDictionary)
        if removed != errSecItemNotFound { try Self.checkKeychain(removed) }
        stopGeneration()
        hasAPIKey = false
        authRequired = true
        isReady = false
        errorMessage = nil
        statusText = "请先设置 DeepSeek API Key"
    }

    func send(_ input: String, imageURLs: [URL] = []) async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }
        guard question.count <= 20_000 else {
            errorMessage = "这段内容较长，请缩短到 20000 字以内再发送。"
            return
        }

        let turn = UUID()
        turnID = turn
        defer {
            if turnID == turn {
                transport?.close()
                transport = nil
                turnID = nil
                isGenerating = false
                if let pendingMessageID { messages.removeAll { $0.id == pendingMessageID } }
                pendingMessageID = nil
            }
        }
        do {
            let (runtime, key) = try prepareToSend()
            let images: [HarnessPromptImage]
            if imageURLs.isEmpty {
                images = []
            } else {
                isGenerating = true
                statusText = "正在准备发送图片…"
                images = try await Task.detached(priority: .userInitiated) {
                    try HarnessPromptImage.load(imageURLs)
                }.value
                guard turnID == turn else { return }
                try Task.checkCancellation()
            }
            let prompt = promptWithHistory(question)
            let pending = ChatMessage(role: "user", content: question)
            pendingMessageID = pending.id
            messages.append(pending)
            isGenerating = true
            statusText = "正在连接 DeepSeek Harness…"
            let process = try HarnessTransport(runtime: runtime, apiKey: key)
            transport = process
            let result = try await process.request("initialize", [
                "cwd": process.workspace.path,
                "provider": "deepseek-official",
                "model": modelName,
                "maxTokens": 8192
            ], timeoutSeconds: 25)
            let server = result["serverInfo"] as? [String: Any]
            guard server?["name"] as? String == "deepseek-harness-sdk-runtime" else {
                throw HarnessError.protocolError
            }
            guard turnID == turn else { return }
            statusText = "DeepSeek 正在回答…"
            var contentBlocks = [["type": "text", "text": prompt]]
            contentBlocks += images.map { ["type": "image", "mimeType": $0.mimeType, "data": $0.data] }
            let receipt = try await process.request("session/prompt", [
                "sessionId": process.sessionID,
                "contentBlocks": contentBlocks
            ], timeoutSeconds: 20)
            guard let messageID = receipt["messageId"] as? String, !messageID.isEmpty else {
                throw HarnessError.protocolError
            }
            guard turnID == turn else { return }
            _ = try await process.request("session/wait", ["sessionId": process.sessionID], timeoutSeconds: 180)
            guard turnID == turn else { return }
            let answer = try process.finalAnswer()
            pendingMessageID = nil
            messages.append(ChatMessage(role: "assistant", content: answer))
            statusText = "DeepSeek Harness 已就绪"
            saveHistory()
        } catch {
            // A cancelled or superseded operation cannot alter a newer turn.
            guard turnID == turn, !(error is CancellationError) else { return }
            showError(error)
        }
    }

    func stopGeneration() {
        guard turnID != nil else { return }
        turnID = nil
        transport?.close()
        transport = nil
        if let pendingMessageID { messages.removeAll { $0.id == pendingMessageID } }
        pendingMessageID = nil
        isGenerating = false
        statusText = isReady ? "DeepSeek Harness 已就绪 · 已停止回答" : "DeepSeek 已停止"
    }

    func clearConversation() {
        stopGeneration()
        messages = []
        errorMessage = nil
        saveHistory()
    }

    func shutdown() {
        stopGeneration()
        isReady = false
        errorMessage = nil
        statusText = "DeepSeek 已关闭"
    }

    private func prepareToSend() throws -> (HarnessRuntime, String) {
        errorMessage = nil
        let key = try readCredential()
        hasAPIKey = key?.isEmpty == false
        authRequired = !hasAPIKey
        guard let key, !key.isEmpty else { throw HarnessError.missingKey }
        guard let runtime, runtime.isInstalled else { throw HarnessError.missingRuntime }
        isReady = true
        statusText = "DeepSeek Harness 已就绪"
        return (runtime, key)
    }

    private func showError(_ error: Error) {
        let harnessError = (error as? HarnessError) ?? .launchFailed
        if harnessError == .missingKey || harnessError == .rejectedKey {
            authRequired = true
            isReady = false
            statusText = "请检查 DeepSeek API Key"
        } else {
            if harnessError == .missingRuntime || harnessError == .keychainError { isReady = false }
            statusText = "DeepSeek 请求未完成"
        }
        errorMessage = harnessError.localizedDescription
    }

    private func promptWithHistory(_ question: String) -> String {
        var context: [String] = []
        var length = 0
        for message in messages.suffix(16).reversed() {
            let role = message.role == "user" ? "用户" : "助手"
            let entry = "\(role)：\(message.content)"
            guard length + entry.count <= 12_000 else { break }
            length += entry.count
            context.append(entry)
        }
        guard !context.isEmpty else { return question }
        return """
        以下是同一 DeepSeek 对话中的历史内容，仅供理解上下文。
        <conversation-history>
        \(context.reversed().joined(separator: "\n\n"))
        </conversation-history>

        本轮用户消息：
        \(question)
        """
    }

    private func saveHistory() {
        messages = Array(messages.suffix(80))
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(messages)
            try data.write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch { errorMessage = "DeepSeek 对话记录未能保存，请检查磁盘空间或文件权限。" }
    }

    private static var keychainQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "StashCat.DeepSeekHarness",
            kSecAttrAccount: "api-key"
        ]
    }

    private static func readKeychain() throws -> String? {
        var query = keychainQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try checkKeychain(status)
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw HarnessError.keychainError
        }
        return key
    }

    private static func checkKeychain(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw HarnessError.keychainError }
    }
}
