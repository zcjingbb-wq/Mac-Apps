import Foundation

@main
struct CodexServiceTests {
    @MainActor private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure(message)
    }

    private static func setQuotaMode(_ mode: String, in directory: URL) throws {
        try mode.write(to: directory.appendingPathComponent("OnlineWorkspace/quota-mode.txt"), atomically: true, encoding: .utf8)
    }

    private static func startupAudit(in directory: URL) throws -> [String: Int] {
        let data = try Data(contentsOf: directory.appendingPathComponent("OnlineWorkspace/startup-audit.json"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    @MainActor private static func checkStartupAccountChanges(cli: URL, directory: URL) async throws {
        // Handshake, config and catalog lookups are all account-sensitive.
        // A one-shot notification prevents a mock reconnect from causing a loop.
        for stage in ["initialize", "config", "model"] {
            let logoutFolder = directory.appendingPathComponent("Startup-\(stage)-logout", isDirectory: true)
            let logout = CodexService(cliURL: cli, dataDirectory: logoutFolder)
            try "\(stage)-logout".write(to: logoutFolder.appendingPathComponent("OnlineWorkspace/startup-mode.txt"), atomically: true, encoding: .utf8)
            logout.setUsageMonitoring(true)
            await logout.startIfNeeded()
            try await waitUntil("Logout during startup was not handled") { logout.authRequired }
            // Let all callers resume from the old startup task before asserting that
            // an old result did not restore readiness or schedule another connection.
            for _ in 0..<5 { await Task.yield() }
            precondition(!logout.isReady && logout.authRequired, "Old \(stage) result revived logged-out startup")
            precondition(logout.usageState.snapshot == nil && logout.usageState.updatedAt == nil)
            precondition(logout.messages.isEmpty && !logout.isGenerating)
            let logoutAudit = try startupAudit(in: logoutFolder)
            precondition(logoutAudit["changes"] == 1 && logoutAudit["accountReads"] == (stage == "initialize" ? 0 : 1))
            precondition(logoutAudit["initializes"] == 1 && logoutAudit["initializedNotifications"] == 1, "Account change must not leave the server handshake incomplete")
            precondition(logoutAudit["modelLists"] == (stage == "model" ? 1 : 0), "Logged-out startup must stop at the invalidated response")
            logout.shutdown()

            let changedFolder = directory.appendingPathComponent("Startup-\(stage)-change", isDirectory: true)
            let changed = CodexService(cliURL: cli, dataDirectory: changedFolder)
            try "\(stage)-change".write(to: changedFolder.appendingPathComponent("OnlineWorkspace/startup-mode.txt"), atomically: true, encoding: .utf8)
            changed.setUsageMonitoring(true)
            await changed.startIfNeeded()
            try await waitUntil("Authenticated account change did not restart initialization") {
                changed.isReady && changed.usageState.snapshot?.primary?.remainingPercent == 93
            }
            precondition(!changed.authRequired && changed.modelName == "Changed Account Model")
            precondition(changed.usageState.snapshot?.secondary?.remainingPercent == 89)
            precondition(changed.usageState.error == nil && changed.messages.isEmpty)
            let changedAudit = try startupAudit(in: changedFolder)
            precondition(changedAudit["changes"] == 1, "One-shot account notification must not loop")
            let expectedAccountReads = stage == "initialize" ? 1 : 2
            precondition(changedAudit["accountReads"] == expectedAccountReads && changedAudit["configReads"] == expectedAccountReads, "New account must rerun actual account/config RPCs")
            precondition(changedAudit["modelLists"] == (stage == "model" ? 2 : 1), "New account must use a newly requested catalog")
            precondition(changedAudit["initializes"] == 1 && changedAudit["initializedNotifications"] == 1, "New account must reuse exactly one fully completed handshake")
            changed.shutdown()
        }
        print("PASS logout and authenticated account change during pending initialize/config/model RPCs, including complete reused handshake")
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-CodexTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await checkStartupAccountChanges(cli: root.appendingPathComponent("Tests/CodexMockServer.py"), directory: folder)
        let service = CodexService(cliURL: root.appendingPathComponent("Tests/CodexMockServer.py"), dataDirectory: folder)
        service.setUsageMonitoring(true)
        precondition(!service.isReady && service.usageState.snapshot == nil, "Enabling monitoring must not create a connection")
        await service.startIfNeeded()
        precondition(service.isReady, service.errorMessage ?? "Not ready")
        precondition(service.modelName == "Mock Model")
        try await waitUntil("Initial quota RPC did not arrive") { service.usageState.snapshot != nil }
        precondition(service.usageState.snapshot?.primary?.remainingPercent == 82)
        precondition(service.usageState.snapshot?.secondary?.remainingPercent == 54)
        precondition(service.usageCompactText == "5h 82% · 周 54%")
        precondition(service.usageState.updatedAt != nil && service.usageState.error == nil)
        precondition(service.messages.isEmpty, "Quota lookup must not create a chat message or turn")
        print("PASS initial quota RPC after connection without opening a model turn")

        try setQuotaMode("notification", in: folder)
        await service.refreshUsage()
        precondition(service.usageState.snapshot?.primary?.remainingPercent == 79)
        precondition(service.usageState.snapshot?.secondary?.remainingPercent == 53)
        precondition(service.messages.isEmpty && service.isReady && !service.isGenerating)
        precondition(!service.usageState.isRefreshing, "Notification/RPC race must finish its refreshing state")
        print("PASS account notification with no thread updates quota and wins over older RPC snapshot")

        let previousQuota = service.usageState.snapshot
        let previousQuotaDate = service.usageState.updatedAt
        try setQuotaMode("failure", in: folder)
        await service.refreshUsage()
        precondition(service.usageState.snapshot == previousQuota && service.usageState.updatedAt == previousQuotaDate)
        precondition(service.usageState.error != nil && service.usageCompactText.hasPrefix("上次 "))
        precondition(service.isReady && service.errorMessage == nil && !service.authRequired)
        precondition(!service.usageState.isRefreshing)
        print("PASS failed quota refresh preserves explicitly old sample without breaking AI readiness")

        try setQuotaMode("recovered", in: folder)
        await service.refreshUsage()
        precondition(service.usageState.snapshot?.primary?.remainingPercent == 70)
        precondition(service.usageState.snapshot?.secondary?.remainingPercent == 55)
        precondition(service.usageState.error == nil && !service.usageCompactText.hasPrefix("上次 "))
        precondition(service.isReady && !service.usageState.isRefreshing)
        print("PASS subsequent quota RPC recovers automatically from lookup failure")

        let unsupportedFolder = folder.appendingPathComponent("UnsupportedEndpoint", isDirectory: true)
        let unsupported = CodexService(cliURL: root.appendingPathComponent("Tests/CodexMockServer.py"), dataDirectory: unsupportedFolder)
        try setQuotaMode("unsupported", in: unsupportedFolder)
        unsupported.setUsageMonitoring(true)
        await unsupported.startIfNeeded()
        try await waitUntil("Unsupported endpoint was not marked unavailable") { unsupported.usageState.error != nil }
        precondition(unsupported.isReady && unsupported.usageState.snapshot == nil)
        precondition(unsupported.usageCompactText == "额度暂不可用")
        await unsupported.send("TEST_STREAM")
        precondition(unsupported.isReady && unsupported.messages.last?.content == "连接成功。x² 的导数是 2x。")
        precondition(service.usageState.snapshot?.primary?.remainingPercent == 70, "Separate service instances must not share quota state")
        unsupported.shutdown()
        precondition(unsupported.usageState.snapshot == nil && !unsupported.usageState.isRefreshing)
        print("PASS unsupported quota endpoint keeps chat usable and service quota state isolated")

        try setQuotaMode("after-turn", in: folder)
        await service.send("TEST_STREAM")
        precondition(!service.isGenerating)
        precondition(service.messages.count == 2)
        precondition(service.messages[1].content == "连接成功。x² 的导数是 2x。")
        try await waitUntil("Completed turn did not refresh the quota") { service.usageState.snapshot?.primary?.remainingPercent == 65 }
        precondition(service.usageState.snapshot?.secondary?.remainingPercent == 52)
        print("PASS completed turn refreshes quota without affecting the response")
        print("PASS fragmented UTF-8 JSONL, streaming, completed item deduplication")
        service.clearConversation()
        let image = folder.appendingPathComponent("synthetic.png")
        try Data([137, 80, 78, 71]).write(to: image)
        await service.send("TEST_IMAGE", imageURLs: [image])
        precondition(service.messages.last?.content == "图片输入已收到。")
        precondition(!service.messages.contains { $0.content.contains(image.path) })
        let beforeInvalid = service.messages.count
        await service.send("TEST_IMAGE", imageURLs: [folder.appendingPathComponent("missing.png")])
        precondition(service.errorMessage != nil && service.messages.count == beforeInvalid)
        service.clearConversation()
        print("PASS structured image input, no path in history, invalid image retains conversation")
        let pending = Task { await service.send("TEST_WAIT") }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(service.isGenerating)
        service.stopGeneration()
        await pending.value
        precondition(!service.isGenerating)
        precondition(service.messages.last?.role == "user")
        print("PASS interrupt and empty-answer cleanup")
        // Clearing also ensures old prompts are not replayed into a new conversation.
        service.clearConversation()
        await service.send("TEST_APPROVAL")
        precondition(!service.isGenerating)
        precondition(service.errorMessage?.contains("不支持") == true)
        print("PASS tool approval declined and generation stopped")
        service.clearConversation()
        await service.send("TEST_FAIL")
        precondition(service.authRequired && !service.isReady)
        precondition(service.errorMessage?.contains("登录") == true)
        precondition(service.usageState.snapshot == nil && service.usageState.updatedAt == nil)
        precondition(service.usageState.error?.contains("登录") == true)
        precondition(!service.usageCompactText.contains("65%"), "Expired account must never retain its quota")
        print("PASS expired login is actionable and immediately clears the account quota")
        service.clearConversation()
        for index in 0..<45 { service.appendLocalReply(question: "Q \(index)", answer: "A \(index)") }
        precondition(service.messages.count == 80)
        let restored = CodexService(cliURL: root.appendingPathComponent("Tests/CodexMockServer.py"), dataDirectory: folder)
        precondition(restored.messages.count == 80 && restored.messages.first?.content == "Q 5")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("online-history.json").path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("PASS separate 80-message history and 0600 permissions")
        restored.shutdown()
        await service.startIfNeeded()
        try await waitUntil("Quota did not recover after reconnect") { service.usageState.snapshot != nil }
        precondition(service.isReady && !service.authRequired)
        service.shutdown()
        precondition(service.usageState.snapshot == nil && service.usageState.updatedAt == nil)
        precondition(!service.isReady && !service.usageState.isRefreshing)
        precondition(service.usageState.error?.contains("断开") == true)
        print("PASS reconnect reloads quota and shutdown clears its sample and refresh state")
        print("All CodexService protocol checks passed.")
    }
}
