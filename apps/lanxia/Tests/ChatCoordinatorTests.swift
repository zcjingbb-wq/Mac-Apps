import Foundation

@main
struct ChatCoordinatorTests {
    @MainActor static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-CoordinatorTests-" + UUID().uuidString)
        let suite = "StashCat.CoordinatorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("codex", forKey: "onlineAIProvider")
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let codex = CodexService(cliURL: project.appendingPathComponent("Tests/CodexMockServer.py"), dataDirectory: root)
        let coordinator = ChatCoordinator(deepseek: AIService(), codex: codex, defaults: defaults)
        defer { coordinator.shutdown() }
        var providerChanges = 0
        coordinator.onProviderSwitch = { providerChanges += 1 }
        await coordinator.startIfNeeded()
        let blocked = await coordinator.send("TEST_STREAM", hasAttachments: true)
        precondition(!coordinator.isEnabled && !coordinator.isReady && !codex.isReady && !blocked,
                     "AI requires explicit activation and must not connect or send while disabled")
        coordinator.setEnabled(true)
        await coordinator.startIfNeeded()
        let success = await coordinator.send("TEST_STREAM", hasAttachments: true)
        precondition(success)
        coordinator.clearConversation()
        let cancelled = Task { await coordinator.send("TEST_WAIT", hasAttachments: true) }
        try await Task.sleep(for: .milliseconds(300))
        coordinator.stopGeneration()
        let cancelledResult = await cancelled.value
        precondition(!cancelledResult, "Cancelled sends must retain attachments for retry")
        let failed = await coordinator.send("TEST_IMAGE", imageURLs: [root.appendingPathComponent("missing.png")], hasAttachments: true)
        precondition(!failed)
        coordinator.clearConversation()
        let resumed = await coordinator.send("TEST_STREAM", hasAttachments: true)
        precondition(resumed)
        coordinator.switchProvider(.codex)
        precondition(providerChanges == 0, "Reselecting the same provider should not interrupt voice")
        let pending = Task { await coordinator.send("TEST_WAIT", hasAttachments: true) }
        try await Task.sleep(for: .milliseconds(300))
        coordinator.setEnabled(false)
        let disabledResult = await pending.value
        precondition(!coordinator.isEnabled && !coordinator.isGenerating && !disabledResult)
        coordinator.switchProvider(.deepseek)
        precondition(providerChanges == 1)
        print("PASS coordinator: explicit activation, disable cancellation, attachment completion/failure and provider switch")
    }
}
