import Foundation

@main
enum DeepSeekHarnessIntegration {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw Failure("需要运行组件和独立测试数据目录。") }
        let runtime = HarnessRuntime(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let data = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let ai = AIService(dataDirectory: data, runtime: runtime, readCredential: { "sk-stashcat-loopback-test" })
        let codex = CodexService(dataDirectory: data)
        guard let defaults = UserDefaults(suiteName: "StashCat-Harness-Test-\(UUID().uuidString)") else {
            throw Failure("无法隔离测试偏好。")
        }
        let chat = ChatCoordinator(deepseek: ai, codex: codex, defaults: defaults)

        try await checkDisabled(chat)
        chat.setEnabled(true)
        await chat.startIfNeeded()
        try check(chat.isReady && !chat.authRequired, "测试钥匙和运行组件应该就绪")
        let first = await chat.send("第一次联调")
        try check(first, "真实 SDK 首轮协议完成。\(chat.errorMessage ?? chat.statusText)")
        try check(chat.messages.map(\.content) == ["第一次联调", "本地联调成功。"], "首轮记录不匹配")

        let second = await chat.send("第二次联调")
        try check(second, "真实 SDK 二轮协议完成。\(chat.errorMessage ?? chat.statusText)")
        try check(chat.messages.count == 4, "第二轮应有两条新记录")

        let reload = AIService(dataDirectory: data, runtime: runtime, readCredential: { nil })
        try check(reload.messages == chat.messages, "重启后应读取真实已完成的对话")
        reload.startIfNeeded()
        try check(reload.authRequired && !reload.isReady, "缺少密钥时应要求配置")

        let requestReceived = data.deletingLastPathComponent().appendingPathComponent("cancel-request-received")
        let slow = Task { await chat.send("模拟中断") }
        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: requestReceived.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(chat.isGenerating && FileManager.default.fileExists(atPath: requestReceived.path), "模拟 API 应已收到正在进行的请求")
        chat.setEnabled(false)
        let stopped = await slow.value
        try check(!stopped && !chat.isGenerating && chat.messages.count == 4, "关闭应终止生成并移除未提交消息")
        try await checkDisabled(chat)

        chat.setEnabled(true)
        let afterStop = await chat.send("中断后重试")
        try check(afterStop && chat.messages.count == 6, "重新开启后应能继续对话")
        let authFailure = await chat.send("模拟鉴权失败")
        try check(!authFailure && !chat.isReady && chat.authRequired && chat.messages.count == 6, "SDK 401 应提示配置并回滚失败消息")
        chat.shutdown()
        try check(!chat.isEnabled && !chat.isReady, "关闭后应回到未开启")
        print("PASS Swift gate, SDK response, saved history, cancel, and re-enable.")
    }

    @MainActor
    private static func checkDisabled(_ chat: ChatCoordinator) async throws {
        await chat.startIfNeeded()
        let sent = await chat.send("关闭时不能发送")
        try check(!sent && !chat.isReady && !chat.isGenerating, "关闭状态拒绝发送")
    }

    private static func check(_ result: Bool, _ detail: String) throws {
        if !result { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }
}
