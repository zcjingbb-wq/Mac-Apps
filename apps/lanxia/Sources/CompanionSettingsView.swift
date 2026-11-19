import SwiftUI

struct CompanionSettingsView: View {
    @ObservedObject var chat: ChatCoordinator
    @ObservedObject var voiceInput: VoiceInputService
    let onDisableAI: () -> Void
    let onBack: () -> Void
    let onClose: () -> Void
    @State private var apiKey = ""
    @State private var keyMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28).stashGlassSurface(cornerRadius: 14)
                }.help("回到初始页")
                Text("偏好设置").font(.system(size: 16, weight: .bold, design: .rounded))
                    .stashHighlightedText()
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28).stashGlassSurface(cornerRadius: 14)
                }.help("收起面板")
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.3).padding(.horizontal, 16)
            ScrollView {
                if chat.isEnabled { providerSettings }
                SettingsView(voiceInput: voiceInput, isAIEnabled: chat.isEnabled)
            }
        }.stashGlassPanelEdge()
            .tint(CatTheme.teal)
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .stashGlassSurface(cornerRadius: 10, emphasis: true)
                Text("AI 提供方").font(.system(size: 13, weight: .semibold))
                    .stashHighlightedText()
            }
            Picker("聊天模式", selection: Binding(get: { chat.provider }, set: { chat.switchProvider($0) })) {
                ForEach(ChatProvider.allCases) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(chat.provider == .deepseek ? "通过 DeepSeek Harness 连接 DeepSeek API" : "通过官方 Codex 连接，使用账号额度")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if chat.provider == .deepseek {
                deepseekSettings
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.modelName).font(.system(size: 11, weight: .semibold))
                        .stashHighlightedText()
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Text(chat.codex.usageCompactText)
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .stashHighlightedText()
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .stashGlassSurface(cornerRadius: 13, emphasis: true)
                        .accessibilityLabel("Codex 剩余额度：\(chat.codex.usageCompactText)")
                        .help(chat.codex.usageDetailText)
                }
                Text(chat.codex.usageDetailText)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(chat.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Codex 和 DeepSeek 的聊天记录在本机分别保存。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                if chat.authRequired { Button("登录 OpenAI / Codex") { Task { await chat.signIn() } } }
                if let error = chat.errorMessage { Text(error).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled) }
                HStack(spacing: 12) {
                    Button("检查连接") { Task { await chat.startIfNeeded() } }
                    Button("刷新额度") { Task { await chat.codex.refreshUsage() } }
                }.font(.system(size: 11, weight: .medium)).controlSize(.small)
            }
            Button("关闭本次运行的 AI", action: onDisableAI)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 20)
        .padding(.horizontal, 16).padding(.top, 13)
    }

    private var deepseekSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key 保存在 macOS 钥匙串。发送问题时会使用你的 DeepSeek API 额度。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            SecureField(chat.deepseek.hasAPIKey ? "输入新 Key（已保存一个）" : "DeepSeek API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存 API Key") {
                    do {
                        try chat.deepseek.saveAPIKey(apiKey)
                        apiKey = ""
                        keyMessage = "已保存。"
                        Task { await chat.startIfNeeded() }
                    } catch { keyMessage = error.localizedDescription }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isGenerating)
                if chat.deepseek.hasAPIKey {
                    Button("移除 API Key") {
                        do {
                            try chat.deepseek.removeAPIKey()
                            keyMessage = "已移除。"
                        } catch { keyMessage = error.localizedDescription }
                    }.disabled(chat.isGenerating)
                }
                Spacer()
                Link("DeepSeek API 平台", destination: URL(string: "https://platform.deepseek.com/")!)
            }
            if let keyMessage {
                Text(keyMessage).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }
}
