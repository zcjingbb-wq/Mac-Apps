import Foundation
import Combine
import Speech
import AVFoundation

/// One explicitly started utterance. Audio is never recorded before permissions
/// and the on-device/network policy have both been checked.
@MainActor
final class VoiceInputService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var transcript = ""
    @Published private(set) var statusText = "点击麦克风开始说话"
    @Published private(set) var errorMessage: String?

    var onFinalTranscript: ((String) -> Void)?

    private let defaults: UserDefaults
    private let permissions: VoiceInputPermissions
    private let makeSession: @MainActor () -> (any VoiceRecognitionSession)?
    private let timing: VoiceInputTiming
    private var session: (any VoiceRecognitionSession)?
    private var sessionID: UUID?
    private var silenceTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        permissions: VoiceInputPermissions = .live,
        timing: VoiceInputTiming = VoiceInputTiming(),
        makeSession: @escaping @MainActor () -> (any VoiceRecognitionSession)? = { AppleVoiceRecognitionSession() }
    ) {
        self.defaults = defaults
        self.permissions = permissions
        self.timing = timing
        self.makeSession = makeSession
    }

    func start() async {
        guard sessionID == nil, !Task.isCancelled else { return }
        let id = UUID()
        sessionID = id
        isPreparing = true
        transcript = ""
        errorMessage = nil
        statusText = "正在准备中文语音输入…"

        guard let newSession = makeSession() else {
            fail("此 Mac 暂时无法创建中文语音识别器。", id: id)
            return
        }
        session = newSession
        let onDevice = newSession.supportsOnDeviceRecognition
        guard onDevice || defaults.bool(forKey: "voiceAllowNetworkRecognition") else {
            fail("此 Mac 暂不支持本机中文识别。可先在系统设置中下载中文听写资源，或在 Wings 的语音设置中明确开启“允许 Apple 在线语音识别”后重试。当前没有启用麦克风。", id: id)
            return
        }
        guard newSession.isAvailable else {
            fail("系统中文语音识别暂不可用，请稍后重试；也可检查系统设置中的听写和语音资源。", id: id)
            return
        }

        statusText = "正在检查语音识别权限…"
        let authorization = await permissions.speech()
        guard sessionID == id, !Task.isCancelled else {
            if sessionID == id { cancel() }
            return
        }
        guard authorization == .authorized else {
            let reason = authorization == .restricted
                ? "语音识别受到系统限制，请检查屏幕使用时间或设备管理设置。"
                : "尚未允许语音识别。请在系统设置 → 隐私与安全性 → 语音识别中允许 Wings。"
            fail(reason, id: id)
            return
        }

        statusText = "正在检查麦克风权限…"
        let microphoneAllowed = await permissions.microphone()
        guard sessionID == id, !Task.isCancelled else {
            if sessionID == id { cancel() }
            return
        }
        guard microphoneAllowed else {
            fail("尚未允许麦克风。请在系统设置 → 隐私与安全性 → 麦克风中允许 Wings。", id: id)
            return
        }

        do {
            try newSession.start(requiresOnDeviceRecognition: onDevice) { [weak self] event in
                self?.receive(event, id: id)
            }
            guard sessionID == id else { return }
            isPreparing = false
            isRecording = true
            statusText = onDevice ? "正在听…（本机中文识别）" : "正在听…（Apple 在线识别）"
            limitTask = Task { [weak self, timing] in
                do { try await Task.sleep(nanoseconds: timing.maximumDurationNanoseconds) }
                catch { return }
                guard let self, self.sessionID == id else { return }
                self.stop()
            }
        } catch {
            fail("无法启动麦克风：\(error.localizedDescription)", id: id)
        }
    }

    /// Stops audio immediately, then gives the recognizer a bounded opportunity
    /// to return its final punctuation/result. A useful partial result is retained.
    func stop() {
        guard let id = sessionID else { return }
        if isPreparing {
            cancel()
            return
        }
        guard isRecording, !isFinishing else { return }
        isRecording = false
        isFinishing = true
        silenceTask?.cancel()
        silenceTask = nil
        limitTask?.cancel()
        limitTask = nil
        statusText = "正在确认识别结果…"
        session?.finishAudio()
        guard sessionID == id else { return }
        finalizationTask = Task { [weak self, timing] in
            do { try await Task.sleep(nanoseconds: timing.finalizationNanoseconds) }
            catch { return }
            self?.complete(id: id)
        }
    }

    /// Also invalidates callbacks and permissions belonging to the old utterance.
    /// A cancelled utterance can never call onFinalTranscript.
    func cancel() {
        sessionID = nil
        tearDown()
        transcript = ""
        errorMessage = nil
        statusText = "已取消语音输入"
    }

    func clearError() {
        errorMessage = nil
        if sessionID == nil { statusText = "点击麦克风开始说话" }
    }

    private func receive(_ event: VoiceRecognitionEvent, id: UUID) {
        guard sessionID == id else { return }
        if let text = event.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != transcript {
                transcript = trimmed
                if isRecording { scheduleSilenceDeadline(id: id) }
            }
        }
        if event.isFinal {
            complete(id: id)
        } else if let message = event.errorMessage {
            // An error after an explicit stop must not discard words already
            // recognized. During active capture, report the interruption instead.
            if isFinishing, !transcript.isEmpty { complete(id: id) }
            else { fail(message, id: id) }
        }
    }

    private func scheduleSilenceDeadline(id: UUID) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self, timing] in
            do { try await Task.sleep(nanoseconds: timing.silenceNanoseconds) }
            catch { return }
            guard let self, self.sessionID == id, self.isRecording else { return }
            self.stop()
        }
    }

    private func complete(id: UUID) {
        guard sessionID == id else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Invalidate before cancelling the native task or invoking client code:
        // either can synchronously cause another callback or start a new session.
        sessionID = nil
        tearDown()
        guard !text.isEmpty else {
            errorMessage = "没有听清内容，请靠近麦克风后再试一次。"
            statusText = "未识别到内容"
            return
        }
        errorMessage = nil
        statusText = "语音已识别"
        onFinalTranscript?(text)
    }

    private func fail(_ message: String, id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil
        tearDown()
        errorMessage = message
        statusText = "语音输入未完成"
    }

    private func tearDown() {
        silenceTask?.cancel()
        limitTask?.cancel()
        finalizationTask?.cancel()
        silenceTask = nil
        limitTask = nil
        finalizationTask = nil
        session?.cancel()
        session = nil
        isRecording = false
        isPreparing = false
        isFinishing = false
    }
}

/// Small seams allow lifecycle/privacy checks without opening a microphone or
/// displaying a permission prompt in the test process.
struct VoiceInputPermissions {
    var speech: () async -> SFSpeechRecognizerAuthorizationStatus
    var microphone: () async -> Bool

    static let live = VoiceInputPermissions(
        speech: {
            let current = SFSpeechRecognizer.authorizationStatus()
            guard current == .notDetermined else { return current }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        },
        microphone: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
            default: return false
            }
        }
    )
}

struct VoiceInputTiming {
    var silenceNanoseconds: UInt64 = 1_800_000_000
    var maximumDurationNanoseconds: UInt64 = 60_000_000_000
    var finalizationNanoseconds: UInt64 = 2_500_000_000
}

struct VoiceRecognitionEvent: Sendable {
    var text: String?
    var isFinal: Bool = false
    var errorMessage: String?
}

@MainActor
protocol VoiceRecognitionSession: AnyObject {
    var supportsOnDeviceRecognition: Bool { get }
    var isAvailable: Bool { get }
    func start(requiresOnDeviceRecognition: Bool, receive: @escaping @MainActor (VoiceRecognitionEvent) -> Void) throws
    func finishAudio()
    func cancel()
}

@MainActor
private final class AppleVoiceRecognitionSession: VoiceRecognitionSession {
    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var sink: VoiceAudioSink?
    private var hasTap = false

    var supportsOnDeviceRecognition: Bool { recognizer.supportsOnDeviceRecognition }
    var isAvailable: Bool { recognizer.isAvailable }

    init?() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else { return nil }
        self.recognizer = recognizer
    }

    func start(requiresOnDeviceRecognition: Bool, receive: @escaping @MainActor (VoiceRecognitionEvent) -> Void) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        request.taskHint = .dictation
        request.addsPunctuation = true
        let newSink = VoiceAudioSink(request: request)
        sink = newSink
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceMicrophoneError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            newSink.append(buffer)
        }
        hasTap = true
        task = recognizer.recognitionTask(with: request) { result, error in
            // Only copy Sendable value data into the main-actor callback. Audio
            // buffers and Speech framework objects stay on their native threads.
            let event = VoiceRecognitionEvent(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                errorMessage: error.map { "系统语音识别中断：\($0.localizedDescription)" }
            )
            Task { @MainActor in receive(event) }
        }
        engine.prepare()
        try engine.start()
    }

    func finishAudio() {
        if engine.isRunning { engine.stop() }
        removeTap()
        sink?.endAudio()
    }

    func cancel() {
        finishAudio()
        task?.cancel()
        task = nil
        sink = nil
    }

    private func removeTap() {
        guard hasTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        hasTap = false
    }
}

/// The audio render callback must not touch MainActor state. This lock only
/// serializes appending against endAudio during stop/cancel; no UI is called here.
private final class VoiceAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var acceptsAudio = true

    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if acceptsAudio { request.append(buffer) }
    }

    func endAudio() {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsAudio else { return }
        acceptsAudio = false
        request.endAudio()
    }
}

private enum VoiceMicrophoneError: LocalizedError {
    case noInput
    var errorDescription: String? { "没有可用的音频输入设备，请连接麦克风后重试。" }
}
