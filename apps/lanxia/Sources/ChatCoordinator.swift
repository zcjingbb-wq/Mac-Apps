import Foundation
import Combine

enum ChatProvider: String, CaseIterable, Identifiable {
    case deepseek
    case codex

    var id: String { rawValue }
    var displayName: String { self == .deepseek ? "DeepSeek Harness" : "OpenAI · Codex" }
    var destinationName: String { self == .deepseek ? "DeepSeek" : "OpenAI" }
}

@MainActor
final class ChatCoordinator: ObservableObject {
    let deepseek: AIService
    let codex: CodexService
    @Published private(set) var provider: ChatProvider
    @Published private(set) var isEnabled = false
    private var subscriptions = Set<AnyCancellable>()
    private var activeSend: UUID?
    private let defaults: UserDefaults
    private static let providerPreference = "onlineAIProvider"
    var onProviderSwitch: (() -> Void)?

    init(deepseek: AIService, codex: CodexService, defaults: UserDefaults = .standard) {
        self.deepseek = deepseek
        self.codex = codex
        self.defaults = defaults
        provider = defaults.string(forKey: Self.providerPreference).flatMap(ChatProvider.init(rawValue:)) ?? .deepseek
        deepseek.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        codex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var messages: [ChatMessage] { provider == .deepseek ? deepseek.messages : codex.messages }
    var isGenerating: Bool { isEnabled && (provider == .deepseek ? deepseek.isGenerating : codex.isGenerating) }
    var isReady: Bool { isEnabled && (provider == .deepseek ? deepseek.isReady : codex.isReady) }
    var statusText: String {
        guard isEnabled else { return "AI 未开启" }
        return provider == .deepseek ? deepseek.statusText : codex.statusText
    }
    var errorMessage: String? {
        guard isEnabled else { return nil }
        return provider == .deepseek ? deepseek.errorMessage : codex.errorMessage
    }
    var modelName: String { provider == .deepseek ? deepseek.modelName : codex.modelName }
    var authRequired: Bool { isEnabled && (provider == .deepseek ? deepseek.authRequired : codex.authRequired) }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        codex.setUsageMonitoring(enabled && provider == .codex)
        if !enabled {
            activeSend = nil
            deepseek.shutdown()
            codex.shutdown()
        }
    }

    func switchProvider(_ next: ChatProvider) {
        guard next != provider else { return }
        onProviderSwitch?()
        activeSend = nil
        codex.setUsageMonitoring(false)
        if provider == .deepseek { deepseek.shutdown() }
        else { codex.shutdown() }
        provider = next
        defaults.set(next.rawValue, forKey: Self.providerPreference)
        guard isEnabled else { return }
        codex.setUsageMonitoring(next == .codex)
        Task { await startIfNeeded() }
    }

    func startIfNeeded() async {
        guard isEnabled else { return }
        if provider == .deepseek { deepseek.startIfNeeded() }
        else { await codex.startIfNeeded() }
    }

    @discardableResult
    func send(_ question: String, imageURLs: [URL] = [], hasAttachments: Bool = false) async -> Bool {
        guard isEnabled, !isGenerating, activeSend == nil else { return false }
        let sendingProvider = provider
        let token = UUID()
        let previousLastID = messages.last?.id
        activeSend = token
        defer { if activeSend == token { activeSend = nil } }

        if provider == .deepseek { await deepseek.send(question, imageURLs: imageURLs) }
        else { await codex.send(question, imageURLs: imageURLs) }

        return isEnabled && activeSend == token && provider == sendingProvider && errorMessage == nil
            && messages.last?.role == "assistant" && messages.last?.id != previousLastID
            && messages.last?.content.isEmpty == false
    }

    func stopGeneration() {
        activeSend = nil
        if provider == .deepseek { deepseek.stopGeneration() }
        else { codex.stopGeneration() }
    }

    func clearConversation() {
        guard isEnabled else { return }
        stopGeneration()
        if provider == .deepseek { deepseek.clearConversation() }
        else { codex.clearConversation() }
    }

    func signIn() async {
        guard isEnabled, provider == .codex else { return }
        await codex.signIn()
    }

    func shutdown() { setEnabled(false) }
}
