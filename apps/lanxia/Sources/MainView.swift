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
    @ObservedObject var screenSession: ScreenSessionAssistant
    let onActivateAI: () -> Void
    let onDisableAI: () -> Void
    let onOpenChat: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
                    DwellButton(target: "打开聊天", action: onOpenChat) { Text("打开聊天") }
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
            .padding(.top, 10)

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

            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).font(.system(size: 11))
                .accessibilityLabel("退出 Wings").help("退出 Wings")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var voiceInput: VoiceInputService
    let isAIEnabled: Bool
    @AppStorage("voiceAllowNetworkRecognition") private var voiceAllowNetworkRecognition = false
    @AppStorage("dwellToOpenEnabled") private var dwellToOpenEnabled = true
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard("操作方式", icon: "cursorarrow") {
                Toggle("悬停 2 秒打开", isOn: $dwellToOpenEnabled)
                Text("停在功能键上可预览目标，进度条走完后打开。移开指针或滚动可取消。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
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
                DwellButton(target: "打开应用数据文件夹", action: {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.open(support.appendingPathComponent("StashCat"))
                }) { Text("打开应用数据文件夹") }
                Text("暂存站保存文件副本。移除暂存项时，副本会移到废纸篓。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Wings \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.3")")
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
