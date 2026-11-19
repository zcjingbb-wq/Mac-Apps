import Foundation

/// Opt-in real account/network check. Uses the CLI's supported login; no token or email is read.
@main
struct CodexIntegration {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-CodexLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = CodexService(dataDirectory: folder)
        await service.startIfNeeded()
        guard service.isReady else {
            print("LIVE NOT READY: \(service.errorMessage ?? service.statusText)")
            service.shutdown()
            Foundation.exit(2)
        }
        print("Account ready through supported account/read. Model: \(service.modelName)")
        let started = Date()
        await service.send("这是暂存喵 App 的连接测试。请用中文简短回答：x 的平方的导数是什么？不要调用工具。")
        guard let answer = service.messages.last, answer.role == "assistant", !answer.content.isEmpty,
              service.errorMessage == nil else {
            print("LIVE ANSWER FAILED: \(service.errorMessage ?? "No answer")")
            service.shutdown()
            Foundation.exit(3)
        }
        print("PASS actual streamed answer (\(String(format: "%.1f", Date().timeIntervalSince(started)))s): \(answer.content)")
        let cancelled = Task { await service.send("请依次列出从 1 到 1000 的整数，每行一个数字，不要省略。") }
        try await Task.sleep(nanoseconds: 500_000_000)
        service.stopGeneration()
        await cancelled.value
        guard !service.isGenerating else { Foundation.exit(4) }
        print("PASS actual generation cancellation and send completion")
        service.clearConversation()
        await service.send("仅回复：停止后连接正常")
        guard service.messages.last?.role == "assistant", service.messages.last?.content.contains("停止后连接正常") == true,
              service.errorMessage == nil else {
            print("LIVE RECONNECT FAILED: \(service.errorMessage ?? "No answer")")
            service.shutdown()
            Foundation.exit(5)
        }
        print("PASS new ephemeral conversation answers after cancellation")
        service.clearConversation()
        service.shutdown()
        print("All live checks passed; temporary test transcript removed.")
    }
}
