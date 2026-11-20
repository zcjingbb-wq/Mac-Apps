import AppKit
import SwiftUI
import ServiceManagement

enum CatTheme {
    static let teal = Color(nsColor: .labelColor)
    static let ink = Color(nsColor: .labelColor)
    static let onAccent = Color(nsColor: .textBackgroundColor)
    static let muted = Color.secondary
    static let canvas = Color(nsColor: .windowBackgroundColor)
}

struct MenuShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var chat: ChatCoordinator
    @ObservedObject var reminders: ReminderStore
    @ObservedObject var screenSession: ScreenSessionAssistant
    let onActivateAI: () -> Void
    let onDisableAI: () -> Void
    let onOpen: (CompanionPage) -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: StatusBarIcon.image())
                    .accessibilityHidden(true)
                Text("蓝匣")
                    .font(.system(size: 17, weight: .bold))
                    .stashHighlightedText()
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("偏好设置")
                .help("偏好设置")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 29, height: 29)
                    .stashGlassSurface(cornerRadius: 9, emphasis: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.isEnabled ? chat.provider.displayName : "AI 已关闭")
                        .font(.system(size: 12, weight: .semibold))
                    Text(chat.isEnabled ? "本次运行已开启" : "开启后可聊天、读文件和分析屏幕")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if chat.isEnabled {
                    Button("关闭 AI", action: onDisableAI)
                    Button("打开聊天") { onOpen(.chat) }
                        .stashGlassPrimaryButton()
                } else {
                    Button("开启 AI", action: onActivateAI)
                        .stashGlassPrimaryButton()
                }
            }
            .controlSize(.small)
            .padding(10)
            .stashGlassSurface(cornerRadius: 15, emphasis: true)
            .padding(.horizontal, 16)

            if screenSession.capture.isRunning || screenSession.capture.isSelecting || screenSession.capture.isStopping {
                HStack {
                    Label("屏幕会话进行中", systemImage: "record.circle")
                    Spacer()
                    Button("停止屏幕会话") { screenSession.stop() }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }

            ShelfView(store: shelf)

            Divider().opacity(0.38).padding(.horizontal, 16)
            HStack(spacing: 20) {
                Button { onOpen(.reminders) } label: {
                    Label(reminders.dueCount > 0 ? "日程 · \(reminders.dueCount) 项到期" : "日程", systemImage: "calendar")
                }
                Button { onOpen(.mail) } label: { Label("Outlook 邮件", systemImage: "envelope") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .accessibilityLabel("退出蓝匣").help("退出蓝匣")
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
        }
        .frame(width: 420, height: 530)
        .tint(CatTheme.teal)
    }
}

struct SettingsView: View {
    @ObservedObject var voiceInput: VoiceInputService
    let isAIEnabled: Bool
    @AppStorage("voiceAllowNetworkRecognition") private var voiceAllowNetworkRecognition = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isAIEnabled {
                settingsCard("语音输入", icon: "waveform") {
                    Text("点击聊天输入框里的麦克风录音。识别后可先编辑，再点发送。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("允许 Apple 在线语音识别", isOn: $voiceAllowNetworkRecognition)
                    Text("打开后，当设备端识别不可用，音频可能发送至 Apple。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            settingsCard("启动与数据", icon: "externaldrive") {
                Toggle("登录 Mac 时启动", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Button("打开应用数据文件夹") {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.open(support.appendingPathComponent("StashCat"))
                }
                Text("暂存站保存文件副本。移除暂存项时，副本会移到废纸篓。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("蓝匣 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.1")")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
        }
        .padding(16).font(.system(size: 12))
        .toggleStyle(.switch).controlSize(.small)
        .onChange(of: voiceAllowNetworkRecognition) { _, _ in voiceInput.cancel() }
    }

    private func settingsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .stashHighlightedText()
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 20)
    }
}
