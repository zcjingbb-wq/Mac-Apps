import Foundation
import Speech

@main
@MainActor
struct VoiceInputTests {
    private static var assertions = 0

    static func main() async {
        await testPrivacyAndPermissions()
        await testPermissionCancellation()
        await testResultsAndCancellation()
        await testDeadlines()
        print("VoiceInputTests: \(assertions) assertions passed (fake audio; no microphone or permission requests)")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }

    private static func defaults() -> UserDefaults {
        let suite = "com.jingzicheng.stashcat.VoiceTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: suite)!
        value.removePersistentDomain(forName: suite)
        return value
    }

    private static func service(
        _ fake: FakeVoiceSession,
        defaults: UserDefaults? = nil,
        permissions: VoiceInputPermissions = VoiceInputPermissions(speech: { .authorized }, microphone: { true }),
        timing: VoiceInputTiming = VoiceInputTiming()
    ) -> VoiceInputService {
        VoiceInputService(defaults: defaults ?? self.defaults(), permissions: permissions, timing: timing, makeSession: { fake })
    }

    private static func testPrivacyAndPermissions() async {
        let fake = FakeVoiceSession()
        fake.supportsOnDeviceRecognition = false
        var speechCalls = 0
        var micCalls = 0
        let permissions = VoiceInputPermissions(speech: { speechCalls += 1; return .authorized }, microphone: { micCalls += 1; return true })
        let preferences = defaults()
        let input = service(fake, defaults: preferences, permissions: permissions)
        await input.start()
        check(fake.starts == 0, "Unsupported local recognition must not start capture by default")
        check(speechCalls == 0 && micCalls == 0, "Policy failure should not prompt for irrelevant permissions")
        check(input.errorMessage?.contains("当前没有启用麦克风") == true, "Explain the local capability boundary")
        check(!input.isPreparing && !input.isRecording && !input.isFinishing, "Policy failure returns to idle")

        preferences.set(true, forKey: "voiceAllowNetworkRecognition")
        await input.start()
        check(fake.starts == 1 && fake.requiresLocal == false, "Only explicit opt-in can select a network-only recognizer")
        check(speechCalls == 1 && micCalls == 1, "An allowed session checks both permissions")
        check(input.statusText.contains("Apple 在线"), "Disclose active online recognition")
        input.cancel()
        fake.supportsOnDeviceRecognition = true
        await input.start()
        check(fake.requiresLocal == true, "Prefer mandatory on-device recognition even when network opt-in exists")
        input.cancel()

        let unavailable = FakeVoiceSession()
        unavailable.isAvailable = false
        let inactive = service(unavailable)
        await inactive.start()
        check(unavailable.starts == 0 && inactive.errorMessage != nil, "Unavailable speech service must not start audio")

        var deniedMicCalls = 0
        let denied = service(FakeVoiceSession(), permissions: VoiceInputPermissions(speech: { .denied }, microphone: { deniedMicCalls += 1; return true }))
        await denied.start()
        check(deniedMicCalls == 0, "A denied speech permission must not request microphone access")
        check(denied.errorMessage?.contains("语音识别") == true, "Speech denial has actionable Chinese guidance")
        denied.clearError()
        check(denied.errorMessage == nil, "Error can be dismissed")

        let noMic = FakeVoiceSession()
        let deniedMic = service(noMic, permissions: VoiceInputPermissions(speech: { .authorized }, microphone: { false }))
        await deniedMic.start()
        check(noMic.starts == 0 && deniedMic.errorMessage?.contains("麦克风") == true, "Mic denial cannot start capture")

        let brokenMic = FakeVoiceSession()
        brokenMic.failStart = true
        let broken = service(brokenMic)
        await broken.start()
        check(brokenMic.cancels == 1 && broken.errorMessage != nil, "Engine startup failure must clean native resources")
        check(!broken.isRecording && !broken.isPreparing, "Engine startup failure returns to idle")
    }

    private static func testPermissionCancellation() async {
        let fake = FakeVoiceSession()
        var pendingSpeech: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        var micCalls = 0
        let input = service(fake, permissions: VoiceInputPermissions(speech: {
            await withCheckedContinuation { pendingSpeech = $0 }
        }, microphone: { micCalls += 1; return true }))
        var callbacks = 0
        input.onFinalTranscript = { _ in callbacks += 1 }
        let startTask = Task { await input.start() }
        await waitUntil { pendingSpeech != nil }
        check(input.isPreparing, "Permission wait is visible")
        input.cancel()
        pendingSpeech?.resume(returning: .authorized)
        await startTask.value
        check(fake.starts == 0 && micCalls == 0, "Cancel during speech permission prevents stale microphone work")
        check(callbacks == 0 && !input.isPreparing, "Cancelled permission session never produces text")

        var pendingMic: CheckedContinuation<Bool, Never>?
        let micFake = FakeVoiceSession()
        let micInput = service(micFake, permissions: VoiceInputPermissions(speech: { .authorized }, microphone: {
            await withCheckedContinuation { pendingMic = $0 }
        }))
        let micTask = Task { await micInput.start() }
        await waitUntil { pendingMic != nil }
        micInput.stop()
        pendingMic?.resume(returning: true)
        await micTask.value
        check(micFake.starts == 0, "Stop while preparing cancels instead of starting after consent")

        var cancelledPermission: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        let taskFake = FakeVoiceSession()
        let taskInput = service(taskFake, permissions: VoiceInputPermissions(speech: {
            await withCheckedContinuation { cancelledPermission = $0 }
        }, microphone: { true }))
        let cancelledTask = Task { await taskInput.start() }
        await waitUntil { cancelledPermission != nil }
        cancelledTask.cancel()
        cancelledPermission?.resume(returning: .authorized)
        await cancelledTask.value
        check(taskFake.starts == 0 && !taskInput.isPreparing, "Swift task cancellation also invalidates delayed permission")
    }

    private static func testResultsAndCancellation() async {
        let fake = FakeVoiceSession()
        let input = service(fake)
        var received: [String] = []
        input.onFinalTranscript = { received.append($0) }
        await input.start()
        check(input.isRecording && !input.isPreparing, "Successful authorized start records")
        await input.start()
        check(fake.starts == 1, "Repeated start must not overlap microphones")
        fake.emit(text: "  对 x 的平方求导  ")
        check(input.transcript == "对 x 的平方求导", "Partial text is trimmed for preview")
        fake.emit(text: "对 x 的平方求导。", final: true)
        fake.emit(text: "重复结果", final: true)
        check(received == ["对 x 的平方求导。"], "A final result is delivered exactly once")
        check(!input.isRecording && !input.isFinishing && fake.cancels == 1, "Final completion releases capture")
        await input.start()
        fake.emit(text: "不要发送这句话")
        input.cancel()
        fake.emit(text: "旧回调", final: true)
        check(received.count == 1 && input.transcript.isEmpty, "Cancel suppresses old final results and clears preview")

        let older = fake.receiver
        await input.start()
        older?(VoiceRecognitionEvent(text: "旧会话迟到", isFinal: true))
        check(input.isRecording && received.count == 1 && input.transcript.isEmpty, "Stale callbacks cannot finish a new session")
        fake.emit(text: "新会话", final: true)
        check(received.last == "新会话", "A new utterance still works after cancellation")

        await input.start()
        fake.emit(text: "   ", final: true)
        check(received.count == 2 && input.errorMessage != nil, "Empty final never dispatches a user request")
        await input.start()
        fake.emit(text: "部分结果")
        fake.emit(error: "服务暂不可用")
        check(received.count == 2 && input.errorMessage == "服务暂不可用", "Active recognition failure must not dispatch uncertain partial text")
        check(!input.isRecording && !input.isPreparing, "Recognition error cleans session state")

        await input.start()
        fake.emit(text: "停止前的内容")
        input.stop()
        check(input.isFinishing && !input.isRecording && fake.finishes > 0, "Stop immediately ends capture while keeping a final-result phase")
        fake.emit(error: "收尾时取消")
        check(received.last == "停止前的内容" && !input.isFinishing, "A stop-time framework error keeps an existing useful transcript")

        let instant = FakeVoiceSession()
        instant.immediateFinal = "立即完成"
        let immediate = service(instant)
        var instantText = ""
        immediate.onFinalTranscript = { instantText = $0 }
        await immediate.start()
        check(instantText == "立即完成" && !immediate.isRecording, "Synchronous completion cannot resurrect recording state")
    }

    private static func testDeadlines() async {
        let quick = VoiceInputTiming(silenceNanoseconds: 20_000_000, maximumDurationNanoseconds: 300_000_000, finalizationNanoseconds: 20_000_000)
        let fake = FakeVoiceSession()
        let input = service(fake, timing: quick)
        var received: [String] = []
        input.onFinalTranscript = { received.append($0) }
        await input.start()
        fake.emit(text: "一段话")
        await waitUntil { !received.isEmpty }
        check(received == ["一段话"] && fake.finishes > 0, "Silence finishes and bounded fallback retains partial speech")
        check(!input.isFinishing && !input.isRecording, "Silence path cleans timers and capture")
        fake.emit(text: "迟到最终结果", final: true)
        check(received.count == 1, "Deadline completion rejects late final callbacks")

        await input.start()
        fake.emit(text: "已取消的部分")
        input.stop()
        input.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(received.count == 1, "Cancel suppresses finalization timeout fallback")

        let shortLimit = VoiceInputTiming(silenceNanoseconds: 300_000_000, maximumDurationNanoseconds: 20_000_000, finalizationNanoseconds: 20_000_000)
        let silent = FakeVoiceSession()
        let silentInput = service(silent, timing: shortLimit)
        var silentCallbacks = 0
        silentInput.onFinalTranscript = { _ in silentCallbacks += 1 }
        await silentInput.start()
        await waitUntil { silentInput.errorMessage != nil }
        check(!silentInput.isRecording && !silentInput.isFinishing && silent.finishes > 0, "Maximum capture duration ends even without any transcript")
        check(silentCallbacks == 0 && silentInput.errorMessage?.contains("没有听清") == true, "Silent timeout cannot dispatch an empty request")
    }

    private static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("Timed out waiting for deterministic voice test state")
    }
}

@MainActor
private final class FakeVoiceSession: VoiceRecognitionSession {
    var supportsOnDeviceRecognition = true
    var isAvailable = true
    var starts = 0
    var finishes = 0
    var cancels = 0
    var requiresLocal: Bool?
    var failStart = false
    var immediateFinal: String?
    var receiver: (@MainActor (VoiceRecognitionEvent) -> Void)?

    func start(requiresOnDeviceRecognition: Bool, receive: @escaping @MainActor (VoiceRecognitionEvent) -> Void) throws {
        starts += 1
        requiresLocal = requiresOnDeviceRecognition
        receiver = receive
        if failStart { throw NSError(domain: "VoiceInputTest", code: 1) }
        if let immediateFinal { receive(VoiceRecognitionEvent(text: immediateFinal, isFinal: true)) }
    }

    func finishAudio() { finishes += 1 }
    func cancel() { cancels += 1 }
    func emit(text: String? = nil, final: Bool = false, error: String? = nil) {
        receiver?(VoiceRecognitionEvent(text: text, isFinal: final, errorMessage: error))
    }
}
