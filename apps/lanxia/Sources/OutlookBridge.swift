import AppKit
import Foundation
import SystemConfiguration

/// Uses the public Codex App Server RPC as a connector client, never an inference prompt.
/// The installed Codex process owns authentication; no OAuth/token/config file is read here.
@MainActor
enum OutlookBridge {
    private static let connectorID = "connector_4aaab2856305417b993eca9a216aaf6e"

    static func fetch(accountEmail: String, progress: ((String) -> Void)? = nil) async throws -> MailSnapshot {
        let rpc = OutlookRPC()
        defer { rpc.close() }
        progress?("正在连接 Codex 的 Outlook 连接器…")
        try await rpc.connect()
        let thread = try await rpc.request("thread/start", [
            "cwd": rpc.workspace.path, "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
            "baseInstructions": "Read-only Outlook connector client. No model turns are started. Client invokes only get_profile, list_mail_folders and list_messages.",
            "config": ["features": ["apps": true, "shell_tool": false, "hooks": false, "memories": false]]
        ])
        guard let threadData = thread["thread"] as? [String: Any],
              let threadID = threadData["id"] as? String, threadData["ephemeral"] as? Bool == true else { throw OutlookError.unsupported }

        // Connector identity is verified using actual app metadata, not tool names guessed by AI.
        var cursor: String?
        var accessible = false
        var seenCursors = Set<String>()
        repeat {
            var params: [String: Any] = ["threadId": threadID, "limit": 100, "forceRefetch": true]
            if let cursor { params["cursor"] = cursor }
            let apps = try await rpc.request("app/list", params)
            if let entries = apps["data"] as? [[String: Any]] {
                accessible = accessible || entries.contains { $0["id"] as? String == connectorID && $0["isAccessible"] as? Bool == true && $0["isEnabled"] as? Bool == true }
            }
            if accessible { break }
            cursor = apps["nextCursor"] as? String
            if let cursor, !seenCursors.insert(cursor).inserted { throw OutlookError.pagination }
        } while cursor != nil
        guard accessible else { throw OutlookError.connectorUnavailable }

        progress?("正在核对 Outlook 账号…")
        let profile = try await rpc.readTool("get_profile", arguments: [:], threadID: threadID)
        guard let email = profile["email"] as? String, !email.isEmpty else { throw OutlookError.noAccount }
        guard accountEmail.isEmpty || email.caseInsensitiveCompare(accountEmail) == .orderedSame else { throw MailError.accountMismatch }

        let folderResult = try await rpc.readTool("list_mail_folders", arguments: ["top": 500, "include_hidden_folders": false], threadID: threadID)
        guard let rawFolders = folderResult["value"] as? [[String: Any]] else { throw OutlookError.invalidResponse }
        let folders = try rawFolders.map { raw -> MailFolder in
            guard let id = raw["id"] as? String, !id.isEmpty else { throw OutlookError.invalidResponse }
            let name = raw["display_name"] as? String ?? raw["displayName"] as? String ?? "未命名文件夹"
            return MailFolder(id: id, name: name, path: raw["path"] as? String ?? name,
                              totalItemCount: (raw["total_item_count"] as? NSNumber)?.intValue ?? 0)
        }
        guard !folders.isEmpty else { throw OutlookError.noFolders }
        var errors: [String] = []
        if folders.count >= 500 || folderResult["next_link"] is String {
            errors.append("文件夹列表达到接口上限，覆盖范围可能不完整。")
        }
        var messages: [MailItem] = []
        var seenIDs = Set<String>()
        for (folderIndex, folder) in folders.enumerated() {
            try Task.checkCancellation()
            var skip: Int?
            var offsets = Set<Int>()
            var folderCount = 0
            repeat {
                var arguments: [String: Any] = ["top": 100, "folder_id": folder.id, "order_by": "receivedDateTime desc"]
                if let skip { arguments["skip"] = skip }
                let page = try await rpc.readTool("list_messages", arguments: arguments, threadID: threadID)
                guard let values = page["value"] as? [[String: Any]] else { throw OutlookError.invalidResponse }
                folderCount += values.count
                for value in values {
                    guard let id = value["id"] as? String, !id.isEmpty else { throw OutlookError.invalidResponse }
                    if !seenIDs.insert(id).inserted { continue }
                    let address = (value["sender"] as? [String: Any])?["emailAddress"] as? [String: Any] ?? [:]
                    let body = value["body"] as? [String: Any]
                    let bodyContent = body?["content"] as? String
                    let plain = bodyContent.map { MailText.plainText($0, isHTML: (body?["contentType"] as? String)?.lowercased() == "html") }
                    messages.append(MailItem(id: id, subject: value["subject"] as? String ?? "",
                        senderName: address["name"] as? String ?? "", senderAddress: address["address"] as? String ?? "",
                        receivedDateTime: value["receivedDateTime"] as? String ?? "", isRead: value["isRead"] as? Bool ?? false,
                        hasAttachments: value["has_attachments"] as? Bool ?? value["hasAttachments"] as? Bool ?? false,
                        bodyPreview: value["bodyPreview"] as? String ?? "", bodyText: plain,
                        webLink: value["web_link"] as? String ?? value["webLink"] as? String ?? "",
                        folderID: folder.id, folderPath: folder.path))
                }
                progress?("正在读取 \(folderIndex + 1)/\(folders.count) 个文件夹 · 已读取 \(messages.count) 封")
                let hasMore = page["has_more"] as? Bool ?? false
                if hasMore {
                    guard !values.isEmpty, let next = (page["next_from_index"] as? NSNumber)?.intValue,
                          next > (skip ?? 0), offsets.insert(next).inserted else { throw OutlookError.pagination }
                    skip = next
                } else { skip = nil }
            } while skip != nil
            if folderCount != folder.totalItemCount {
                errors.append("\(folder.path)：接口报告 \(folder.totalItemCount) 封，实际读取 \(folderCount) 封；以实际可读取邮件为准。")
            }
        }
        return MailSnapshot(version: 1, accountEmail: email, syncedAt: MailDates.string(Date()),
                            source: "Microsoft Outlook 连接器 · Codex App Server 只读直连", complete: errors.isEmpty,
                            folders: folders, messages: messages, folderErrors: errors)
    }

    static func openOutlook() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://outlook.live.com/mail/") { NSWorkspace.shared.open(url) }
    }
}

enum MailText {
    /// Readable display/AI text only; the original bodyText in the snapshot is untouched.
    /// Remove image and link targets without fetching them or truncating substantive text.
    static func readableMarkdown(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "[\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}]", with: "", options: .regularExpression)
        // One nested pair covers ordinary parenthesized URL paths without swallowing prose.
        let target = "\\((?:[^()]|\\([^()]*\\))*\\)"
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]" + target, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\[[^\\]]*\\]", with: "", options: .regularExpression)
        for pattern in ["\\[([^\\]]*)\\]" + target, "\\[([^\\]]+)\\]\\[[^\\]]*\\]"] {
            guard let links = try? NSRegularExpression(pattern: pattern) else { continue }
            for link in links.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let labelRange = Range(link.range(at: 1), in: text), let fullRange = Range(link.range, in: text) else { continue }
                let label = String(text[labelRange]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                text.replaceSubrange(fullRange, with: label)
            }
        }
        text = text.replacingOccurrences(of: "(?i)<?(?:https?://|www\\.)[^\\s<>]+>?", with: "", options: .regularExpression)
        var lines: [String] = []
        let decorative = CharacterSet(charactersIn: " |:-—_=+*[]()!>·•.\t")
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Reference-link targets and Markdown table separators are presentation data.
            if line.range(of: "^\\[[^\\]]+\\]:", options: .regularExpression) != nil { continue }
            if line.trimmingCharacters(in: decorative).isEmpty { continue }
            if line.filter({ $0 == "|" }).count >= 3 || (line.hasPrefix("|") && line.hasSuffix("|") && line.contains(" | ")) {
                line = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
            line = line.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            for marker in ["**", "__", "~~", "`"] { line = line.replacingOccurrences(of: marker, with: "") }
            line = line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !line.trimmingCharacters(in: decorative).isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// Pure string cleanup. Never invokes a browser or NSAttributedString's HTML importer.
    static func plainText(_ source: String, isHTML: Bool) -> String {
        guard isHTML else { return source }
        var text = source
        for pattern in ["(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>", "(?is)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<(?:br\\b[^>]*|/p|/div|/tr|/li|/h[1-6])\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]*>", with: "", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let numberRange = Range(match.range(at: 1), in: text), let fullRange = Range(match.range, in: text) else { continue }
                let number = String(text[numberRange]); let hex = number.hasPrefix("x")
                if let value = UInt32(hex ? String(number.dropFirst()) : number, radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
                    text.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n[ \\t]*\n(?:[ \\t]*\n)+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Separate from CodexService: never calls turn/start and never exposes model-controlled tools.
@MainActor
private final class OutlookRPC {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var identity: UUID?
    let workspace: URL
    private static let allowedTools: Set<String> = ["get_profile", "list_mail_folders", "list_messages"]

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        workspace = root.appendingPathComponent("StashCat/OutlookWorkspace", isDirectory: true)
    }

    func connect() async throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let override = ProcessInfo.processInfo.environment["STASHCAT_CODEX_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        let candidates = [override].compactMap { $0 } + ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw OutlookError.noCodex }
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: path)
        let config = ["features.apps=true", "features.plugins=true", "features.shell_tool=false", "features.hooks=false", "features.memories=false", "features.multi_agent=false", "features.goals=false", "features.computer_use=false", "features.browser_use=false", "features.image_generation=false", "features.workspace_dependencies=false", "features.skill_search=false", "features.skip_host_skill_discovery=true", "web_search=\"disabled\"", "project_doc_max_bytes=0", "history.persistence=\"none\"", "approval_policy=\"never\"", "sandbox_mode=\"read-only\""]
        worker.arguments = ["app-server", "--listen", "stdio://"] + config.flatMap { ["-c", $0] }
        worker.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where (key.hasPrefix("CODEX_") && key != "CODEX_HOME") || key == "OPENAI_API_KEY" { environment.removeValue(forKey: key) }
        if let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            for (variable, prefix) in [("HTTP_PROXY", "HTTP"), ("HTTPS_PROXY", "HTTPS")] {
                guard environment[variable] == nil, environment[variable.lowercased()] == nil,
                      (settings[prefix + "Enable"] as? NSNumber)?.boolValue == true,
                      let host = settings[prefix + "Proxy"] as? String, !host.isEmpty,
                      let port = (settings[prefix + "Port"] as? NSNumber)?.intValue, (1...65535).contains(port) else { continue }
                var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = port
                environment[variable] = components.url?.absoluteString
            }
        }
        worker.environment = environment
        let input = Pipe(), output = Pipe(), diagnostics = Pipe()
        worker.standardInput = input; worker.standardOutput = output; worker.standardError = diagnostics
        stdin = input.fileHandleForWriting; stdout = output.fileHandleForReading; stderr = diagnostics.fileHandleForReading
        let token = UUID(); identity = token
        stdout?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.identity == token else { return }
                if !data.isEmpty { self.receive(data) }
            }
        }
        stderr?.readabilityHandler = { handle in _ = handle.availableData }
        worker.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.identity == token else { return }
                self.close(error: OutlookError.disconnected)
            }
        }
        process = worker
        do { try worker.run() } catch { close(); throw OutlookError.noCodex }
        _ = try await request("initialize", ["clientInfo": ["name": "stashcat-outlook", "title": "Wings 只读邮件", "version": "2.0.0"], "capabilities": ["experimentalApi": true]])
        try write(["method": "initialized"])
    }

    func readTool(_ name: String, arguments: [String: Any], threadID: String) async throws -> [String: Any] {
        guard Self.allowedTools.contains(name) else { throw OutlookError.unsupported }
        let result = try await request("mcpServer/tool/call", ["threadId": threadID, "server": "codex_apps", "tool": "microsoft_outlook_email.\(name)", "arguments": arguments])
        if result["isError"] as? Bool == true { throw OutlookError.toolFailed }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        for content in result["content"] as? [[String: Any]] ?? [] {
            if let text = content["text"] as? String, let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        }
        throw OutlookError.invalidResponse
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        nextID += 1; let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard !Task.isCancelled, let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id)
                waiting.resume(throwing: OutlookError.timeout)
            }
            do { try write(["id": id, "method": method, "params": params]) }
            catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard let stdin, process?.isRunning == true else { throw OutlookError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(0x0a)
        try stdin.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > 64_000_000 { close(error: OutlookError.invalidResponse); return }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if object["method"] != nil, let id = object["id"] {
                // Do not approve unknown filesystem, shell, network, OAuth or UI requests.
                try? write(["id": id, "error": ["code": -32601, "message": "This read-only mail client does not implement interactive tool or approval requests."]])
                continue
            }
            guard let id = (object["id"] as? NSNumber)?.intValue, let waiting = pending.removeValue(forKey: id) else { continue }
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = object["error"] as? [String: Any] {
                let message = (error["message"] as? String ?? "").lowercased()
                if message.contains("auth") || message.contains("login") || message.contains("401") { waiting.resume(throwing: OutlookError.connectorUnavailable) }
                else if message.contains("method") { waiting.resume(throwing: OutlookError.unsupported) }
                else { waiting.resume(throwing: OutlookError.toolFailed) }
            } else if let result = object["result"] as? [String: Any] { waiting.resume(returning: result) }
            else { waiting.resume(throwing: OutlookError.invalidResponse) }
        }
    }

    func close(error: Error = OutlookError.disconnected) {
        identity = nil
        stdout?.readabilityHandler = nil; stderr?.readabilityHandler = nil
        try? stdin?.close(); stdin = nil; stdout = nil; stderr = nil
        let worker = process; process = nil
        if let worker, worker.isRunning {
            worker.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
            }
        }
        let waiting = pending.values; pending = [:]
        timeouts.values.forEach { $0.cancel() }; timeouts = [:]
        waiting.forEach { $0.resume(throwing: error) }
    }
}

private enum OutlookError: LocalizedError {
    case noCodex, connectorUnavailable, noAccount, noFolders, unsupported, invalidResponse, toolFailed, pagination, timeout, disconnected
    var errorDescription: String? {
        switch self {
        case .noCodex: return "未找到可用的 Codex。请保留已登录的 Codex App 后重试。"
        case .connectorUnavailable: return "Microsoft Outlook 连接器尚未连接或登录已失效。请在 Codex 的插件中连接 Outlook，再回到这里刷新。"
        case .noAccount: return "Outlook 连接没有返回邮箱账号，请在 Codex 中重新连接 Outlook。"
        case .noFolders: return "Outlook 没有返回可读取的文件夹；上次邮件保留。"
        case .unsupported: return "当前 Codex 版本不支持所需的只读邮件接口，请更新 Codex 后重试。"
        case .invalidResponse: return "Outlook 返回的数据不完整，未覆盖上次邮件。"
        case .toolFailed: return "Outlook 只读请求失败。请检查网络及 Codex 中的 Outlook 连接后重试；上次邮件保留。"
        case .pagination: return "邮件分页未能继续，已停止刷新并保留上次完整结果。"
        case .timeout: return "Outlook 连接超过 90 秒，请检查网络后重试；上次邮件保留。"
        case .disconnected: return "Outlook 连接已结束，请再次刷新；上次邮件保留。"
        }
    }
}
