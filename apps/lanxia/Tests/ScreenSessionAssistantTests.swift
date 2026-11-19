import Foundation
import AppKit

@MainActor private final class SessionTestClock { var date = Date() }
@MainActor private final class AssistantCaptureDriver: ScreenSessionCaptureDriver {
    struct Call {
        let selection: (ScreenWindowTarget?) -> Void
        let started: () -> Void
        let frame: (CGImage, Date, ScreenWindowTarget?) -> Void
        let idle: (Date, ScreenWindowTarget?) -> Void
        let stopped: (ScreenSessionFailure?) -> Void
    }
    var calls: [Call] = []
    var stops = 0
    func chooseContent(onSelection: @escaping (ScreenWindowTarget?) -> Void, onStarted: @escaping () -> Void,
                       onFrame: @escaping (CGImage, Date, ScreenWindowTarget?) -> Void,
                       onIdle: @escaping (Date, ScreenWindowTarget?) -> Void,
                       onStopped: @escaping (ScreenSessionFailure?) -> Void) {
        calls.append(Call(selection: onSelection, started: onStarted, frame: onFrame, idle: onIdle, stopped: onStopped))
    }
    func stop() async { stops += 1 }
}
@main struct ScreenSessionAssistantTests {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    @MainActor private static func until(_ predicate: () -> Bool, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        preconditionFailure("Screen assistant state timed out")
    }
    private static func image(dark: Bool = false) -> CGImage {
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        (dark ? NSColor.lightGray : NSColor.white).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        let paragraph = "Question: derivative of x squared?\nA. x\nB. 2x\nC. 0"
        paragraph.draw(in: NSRect(x: 30, y: 40, width: 580, height: 320), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        image.unlockFocus()
        var rect = NSRect(x: 0, y: 0, width: 640, height: 400)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }
    @MainActor static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-AssistantTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldData = getenv("STASHCAT_DATA_DIR").map { String(cString: $0) }
        setenv("STASHCAT_DATA_DIR", root.appendingPathComponent("local").path, 1)
        let suite = "StashCat.Session." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("codex", forKey: "onlineAIProvider")
        defer {
            if let oldData { setenv("STASHCAT_DATA_DIR", oldData, 1) } else { unsetenv("STASHCAT_DATA_DIR") }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        // An isolated deterministic peer; no real CLI, account or UI is invoked.
        let peer = try String(contentsOf: project.appendingPathComponent("Tests/CodexMockServer.py"), encoding: .utf8)
        let script = root.appendingPathComponent("synthetic-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let codex = CodexService(cliURL: script, dataDirectory: root.appendingPathComponent("online"))
        let chat = ChatCoordinator(deepseek: AIService(), codex: codex, defaults: defaults)
        defer { chat.shutdown() }
        chat.setEnabled(true)
        await chat.startIfNeeded()
        expect(chat.isReady, "Isolated synthetic provider connected")
        let clock = SessionTestClock()
        let target = ScreenWindowTarget(pid: 987_654, windowID: 33, frame: CGRect(x: 0, y: 0, width: 640, height: 400), appName: "Synthetic Quiz")
        let driver = AssistantCaptureDriver()
        let capture = ScreenSessionCapture(driver: driver, temporaryDirectory: root)
        let assistant = ScreenSessionAssistant(capture: capture, now: { clock.date })
        let firstImage = image(), nextImage = image(dark: true)
        expect(driver.calls.isEmpty && chat.messages.isEmpty, "Constructing assistant never observes or sends")
        assistant.start()
        expect(driver.calls.count == 1 && capture.isSelecting, "Start opens only a synthetic selection")
        driver.calls[0].selection(target); driver.calls[0].started(); driver.calls[0].frame(firstImage, clock.date, target)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(capture.isRunning && capture.latestFrame != nil, "Confirmed synthetic window has a frame")
        try await Task.sleep(nanoseconds: 3_200_000_000)
        expect(chat.messages.isEmpty, "Long observation alone never sends")
        await assistant.analyze(question: "TEST_IMAGE", chat: chat)
        expect(!assistant.isAnalyzing && assistant.answerText.contains("图片输入已收到"), "Actual preparation supplies a valid independent localImage to the fake peer")
        expect(assistant.answerText == chat.messages.last?.content, "Answers are displayed intact without a control payload transformation")
        expect(assistant.answerCapturedAt == capture.latestFrame?.capturedAt, "Answer is associated with its actual observed frame")
        let previous = capture.latestFrame!.id
        let previousAnswer = assistant.answerText, previousAnswerTime = assistant.answerCapturedAt
        clock.date.addTimeInterval(2)
        driver.calls[0].frame(nextImage, clock.date, target)
        try await Task.sleep(nanoseconds: 50_000_000)
        expect(capture.latestFrame?.id != previous, "Changed picture receives a new observation version")
        expect(assistant.answerText == previousAnswer && assistant.answerCapturedAt == previousAnswerTime,
               "Prior explanation remains associated with its original observation after a picture change")
        clock.date.addTimeInterval(7)
        let beforeStale = chat.messages.count
        await assistant.analyze(question: "TEST_IMAGE", chat: chat)
        expect(chat.messages.count == beforeStale && assistant.errorMessage?.contains("过期") == true, "Unobserved old frames are not sent")
        clock.date.addTimeInterval(15)
        driver.calls[0].idle(clock.date, target)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        expect(chat.messages.count == beforeStale, "Idle or changed frames never submit automatically")
        assistant.providerDidChange()
        expect(capture.isRunning, "Provider change leaves user-authorized observation running")
        let beforeProviderStop = chat.messages.count
        let switching = Task { await assistant.analyze(question: "TEST_WAIT", chat: chat) }
        try await until({ chat.isGenerating })
        assistant.providerDidChange()
        await switching.value
        expect(!assistant.isAnalyzing && !chat.isGenerating && assistant.answerText.isEmpty,
               "Provider change cancels the pending explanation and rejects its result")
        expect(chat.messages.count >= beforeProviderStop, "Provider cancellation preserves the provider's conversation history")
        let waiting = Task { await assistant.analyze(question: "TEST_WAIT", chat: chat) }
        try await until({ chat.isGenerating })
        assistant.stop()
        await waiting.value
        try await until({ !capture.isStopping })
        expect(!capture.isRunning && capture.latestFrame == nil && !assistant.isAnalyzing, "Stop cancels both observation and its pending answer")
        expect(assistant.answerText.isEmpty, "Stop rejects the pending answer")
        let prompt = ScreenSessionAssistant.analysisQuestion("")
        expect(prompt.contains("引用正确选项的原文") && prompt.contains("参考数据"), "Prompt asks for explanations and treats the image as source data")
        expect(!prompt.contains("answerText") && !prompt.contains("```") && !prompt.contains("点击"),
               "Analysis prompt contains no structured control proposal or clicking instruction")
        expect(ScreenSessionAssistant.analysisQuestion(String(repeating: "x", count: 700)).count <= 1_200, "UI question bound leaves room for explanation instruction")
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        expect(!children.contains { $0.lastPathComponent.hasPrefix("StashCat-ScreenLease-") }, "All independent analysis leases are cleaned")
        print("PASS \(checks) continuous-assistant integration checks: synthetic observation, actual image preparation, fake Codex, explanation-only prompt, freshness, manual submission, provider isolation and stop; no live screen/control/network")
    }
}
