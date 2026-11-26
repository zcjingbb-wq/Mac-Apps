import Foundation
import Darwin

enum HarnessError: LocalizedError, Equatable {
    case missingKey, invalidKeyFormat, keychainError, rejectedKey, insufficientBalance
    case missingRuntime, launchFailed, interrupted, protocolError, timeout, remoteError, rateLimited, emptyAnswer
    case invalidImage, imageLimitExceeded

    var errorDescription: String? {
        switch self {
        case .missingKey: return "请在偏好设置中添加 DeepSeek API Key。"
        case .invalidKeyFormat: return "请输入完整的 DeepSeek API Key。"
        case .keychainError: return "无法访问 macOS 钥匙串，请检查登录钥匙串后重试。"
        case .rejectedKey: return "DeepSeek 拒绝了此 API Key，请在偏好设置中更新。"
        case .insufficientBalance: return "DeepSeek API 账户余额不足，请检查账户余额。"
        case .missingRuntime: return "未找到随羽安装的 DeepSeek Harness 运行组件。"
        case .launchFailed: return "无法启动 DeepSeek Harness。"
        case .interrupted: return "DeepSeek Harness 提前退出，请重试。"
        case .protocolError: return "DeepSeek Harness 返回了无效的运行状态。"
        case .timeout: return "DeepSeek 请求超时，请检查网络后重试。"
        case .remoteError: return "DeepSeek 未能完成请求，请检查网络和 API 账户后重试。"
        case .rateLimited: return "DeepSeek API 请求暂时受限，请稍后重试。"
        case .emptyAnswer: return "DeepSeek 没有返回可显示的回答。"
        case .invalidImage: return "无法读取待发送的图片，请重新选择后再试。"
        case .imageLimitExceeded: return "每次最多发送 4 张图片，处理后的图片合计不能超过 20 MB。"
        }
    }

    static func fromRemote(_ value: [String: Any]) -> HarnessError {
        // Error bodies may contain request data or credentials. Use them only to classify.
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let encoded = String(data: data, encoding: .utf8)?.lowercased() else { return .remoteError }
        if encoded.contains("\"auth\"") || encoded.contains("unauthorized") || encoded.contains("invalid api key")
            || encoded.contains("authentication fails") { return .rejectedKey }
        if encoded.contains("\"quota\"") || encoded.contains("insufficient balance") { return .insufficientBalance }
        if encoded.contains("\"rate_limit\"") || encoded.contains("rate limit") { return .rateLimited }
        return .remoteError
    }
}

struct HarnessRuntime {
    let root: URL

    static var bundled: HarnessRuntime? {
        Bundle.main.resourceURL.map { .init(root: $0.appendingPathComponent("Harness", isDirectory: true)) }
    }

    var node: URL { root.appendingPathComponent("bin/node") }
    var entry: URL { root.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js") }
    var patch: URL { root.appendingPathComponent("chat.patch.yml") }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: node.path)
            && FileManager.default.isReadableFile(atPath: entry.path)
            && FileManager.default.isReadableFile(atPath: patch.path)
    }
}

/// Reads only the private PNG/JPEG representations prepared by the attachment store.
struct HarnessPromptImage: Sendable {
    let mimeType: String
    let data: String

    static func load(_ urls: [URL]) throws -> [HarnessPromptImage] {
        guard urls.count <= 4 else { throw HarnessError.imageLimitExceeded }
        var remaining = 20 * 1_024 * 1_024
        return try urls.map { url in
            guard url.isFileURL else { throw HarnessError.invalidImage }
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
            guard descriptor >= 0 else { throw HarnessError.invalidImage }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
                throw HarnessError.invalidImage
            }
            guard info.st_size <= remaining else { throw HarnessError.imageLimitExceeded }
            guard let bytes = try? file.read(upToCount: remaining + 1), !bytes.isEmpty else {
                throw HarnessError.invalidImage
            }
            guard bytes.count <= remaining else { throw HarnessError.imageLimitExceeded }
            let mimeType: String
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { mimeType = "image/png" }
            else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { mimeType = "image/jpeg" }
            else { throw HarnessError.invalidImage }
            remaining -= bytes.count
            return HarnessPromptImage(mimeType: mimeType, data: bytes.base64EncodedString())
        }
    }
}

/// One SDK subprocess per submitted turn, with a private launch environment and no open port.
@MainActor
final class HarnessTransport {
    let sessionID = "session-\(UUID().uuidString.lowercased())"
    let workspace: URL

    private let privateDirectory: URL
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()
    private var requestID = 0
    private var pending: CheckedContinuation<[String: Any], Error>?
    private var requestTimeout: Task<Void, Never>?
    private var lastText: String?
    private var terminalReason: [String: Any]?
    private var unexpectedTool = false
    private var closed = false

    init(runtime: HarnessRuntime, apiKey: String) throws {
        let launchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-Harness-\(UUID().uuidString)", isDirectory: true)
        privateDirectory = launchDirectory
        workspace = launchDirectory.appendingPathComponent("workspace", isDirectory: true).resolvingSymlinksInPath()
        let state = launchDirectory.appendingPathComponent("state", isDirectory: true)
        let child = Process()
        process = child
        let upstream = Pipe()
        let downstream = Pipe()
        input = upstream.fileHandleForWriting
        output = downstream.fileHandleForReading
        do {
            let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: false, attributes: permissions)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: permissions)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: permissions)
            child.executableURL = runtime.node
            child.arguments = [runtime.entry.path, "--profile", "sdk-minimal", "--patch", runtime.patch.path]
            child.currentDirectoryURL = workspace
            child.environment = [
                "HOME": state.path,
                "DSH_HOME": state.path,
                "TMPDIR": launchDirectory.path,
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "NODE_DISABLE_COMPILE_CACHE": "1",
                "DEEPSEEK_API_KEY": apiKey
            ]
            child.standardInput = upstream
            child.standardOutput = downstream
            child.standardError = FileHandle.nullDevice
            try child.run()
        } catch {
            try? FileManager.default.removeItem(at: launchDirectory)
            throw HarnessError.launchFailed
        }
        output.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.receive(bytes) }
        }
    }

    func request(_ method: String, _ parameters: [String: Any] = [:], timeoutSeconds: UInt64) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !closed, pending == nil else { throw HarnessError.interrupted }
        requestID += 1
        let currentRequest = requestID
        var frame = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": currentRequest, "method": method, "params": parameters
        ], options: .withoutEscapingSlashes)
        frame.append(10)
        let bytes = frame

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pending = continuation
                self.requestTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000) }
                    catch { return }
                    self?.finish(.failure(HarnessError.timeout))
                }
                // Image frames can exceed the pipe buffer. Use a separate descriptor so
                // cancellation can close the transport while the background write unwinds.
                let descriptor = dup(self.input.fileDescriptor)
                guard descriptor >= 0 else {
                    self.finish(.failure(HarnessError.interrupted))
                    return
                }
                guard fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else {
                    Darwin.close(descriptor)
                    self.finish(.failure(HarnessError.interrupted))
                    return
                }
                let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    defer { try? writer.close() }
                    do { try writer.write(contentsOf: bytes) }
                    catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.requestID == currentRequest else { return }
                            self.finish(.failure(HarnessError.interrupted))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    func finalAnswer() throws -> String {
        guard !unexpectedTool else { throw HarnessError.protocolError }
        guard let terminalReason else { throw HarnessError.protocolError }
        guard let reason = terminalReason["kind"] as? String else { throw HarnessError.protocolError }
        if reason == "error" { throw HarnessError.fromRemote(terminalReason) }
        guard reason == "completed" || reason == "max-tokens" else { throw HarnessError.interrupted }
        guard let lastText, !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarnessError.emptyAnswer
        }
        return lastText
    }

    func close() {
        guard !closed else { return }
        closed = true
        output.readabilityHandler = nil
        finish(.failure(CancellationError()))
        // This one-shot runtime has no retained session state. Terminate a pending
        // network request immediately, including when the app itself is about to exit.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.close()
        try? output.close()
        try? FileManager.default.removeItem(at: privateDirectory)
    }

    private func receive(_ bytes: Data) {
        guard !closed else { return }
        guard !bytes.isEmpty else {
            finish(.failure(HarnessError.interrupted))
            return
        }
        buffer.append(bytes)
        guard buffer.count <= 4_194_304 else {
            finish(.failure(HarnessError.protocolError))
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let payload = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                finish(.failure(HarnessError.protocolError))
                return
            }
            handle(payload)
        }
    }

    private func handle(_ payload: [String: Any]) {
        if let method = payload["method"] as? String {
            guard method == "session.event",
                  let params = payload["params"] as? [String: Any],
                  params["sessionId"] as? String == sessionID,
                  let event = params["event"] as? [String: Any],
                  let data = event["data"] as? [String: Any] else { return }

            switch event["type"] as? String {
            case "assistant/message":
                let message = data["message"] as? [String: Any]
                let blocks = (message?["content"] ?? data["content"]) as? [[String: Any]] ?? []
                if blocks.contains(where: { $0["type"] as? String == "tool_use" || $0["type"] as? String == "tool-call" }) {
                    unexpectedTool = true
                }
                let content = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined()
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = content }
            case "tool/call":
                unexpectedTool = true
            case "turn/end":
                terminalReason = data["reason"] as? [String: Any]
            default: break
            }
            return
        }

        guard payload["id"] as? Int == requestID else { return }
        if let error = payload["error"] as? [String: Any] { finish(.failure(HarnessError.fromRemote(error))) }
        else if let result = payload["result"] as? [String: Any] { finish(.success(result)) }
        else { finish(.failure(HarnessError.protocolError)) }
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        requestTimeout?.cancel()
        requestTimeout = nil
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
