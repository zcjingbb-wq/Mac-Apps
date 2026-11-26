import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu-bar panel for chat, files, reminders, mail and screen analysis.
struct CompanionView: View {
    @ObservedObject var navigation: PanelNavigation
    @ObservedObject var chat: ChatCoordinator
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var reminders: ReminderStore
    @ObservedObject var mail: MailStore
    @ObservedObject var voiceInput: VoiceInputService
    @ObservedObject var screenSession: ScreenSessionAssistant
    let onClose: () -> Void
    let onToggleExpanded: () -> Void
    let onActivateAI: () -> Void
    let onDisableAI: () -> Void
    let onMailReminder: (MailItem) -> Void
    let onMailAnalyze: (MailItem) -> Void
    @AppStorage("dwellToOpenEnabled") private var dwellToOpenEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dwellPreview = DwellPreview()
    @Namespace private var tabSelection

    private var page: CompanionPage {
        get { navigation.page }
        nonmutating set { navigation.page = newValue }
    }
    @State private var screenMode = "session"
    @State private var input = ""
    @State private var signingIn = false
    @State private var confirmClear = false
    @StateObject private var attachments = AttachmentStore()
    @StateObject private var recognizedImage = AttachmentStore()
    @State private var isSendingImageQuestion = false
    @StateObject private var screenCapture = ScreenCaptureService()
    @StateObject private var screenQuestion = ScreenQuestionService()
    @State private var attachmentError: String?
    @FocusState private var inputFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.22).padding(.horizontal, 16)
            ZStack {
                VStack(spacing: 0) {
                    if chat.isEnabled, page != .home, page != .settings { providerBar.padding(.top, 7) }
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if page == .screen && chat.authRequired { connectionNotice }
                    if page == .chat && chat.isEnabled {
                        connectionNotice
                        composer
                    }
                }
                .id(page)
                .transition(pageTransition)
            }
            .clipped()
            tabBar
        }
        .environment(\.dwellPreview, dwellPreview)
        .overlay(alignment: .top) {
            if let target = dwellPreview.target {
                Label("即将打开 · \(target)", systemImage: "cursorarrow.motionlines")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 0.75))
                    .padding(.top, 37)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: dwellPreview.target)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: page)
        .stashGlassPanelEdge()
        .tint(CatTheme.teal)
        .environment(\.dwellToOpenEnabled, dwellToOpenEnabled)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            attachments.clear(); recognizedImage.clear(); screenCapture.cancel(); screenQuestion.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("StashCatEndScreenCapture"))) { _ in
            screenCapture.cancel()
            if screenQuestion.isPreparing { screenQuestion.cancel() }
        }
        .onChange(of: chat.provider) { _, _ in
            screenCapture.cancel(); screenQuestion.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("StashCatVoiceTranscript"))) { notification in
            guard let transcript = notification.userInfo?["text"] as? String else { return }
            receiveTranscript(transcript)
        }
        .onChange(of: chat.isEnabled) { _, enabled in
            if !enabled {
                screenCapture.cancel(); screenQuestion.cancel()
                if page == .chat || page == .screen { page = .files }
            }
        }
        .onChange(of: page) { _, newPage in
            if newPage != .chat { voiceInput.cancel() }
            if newPage != .screen {
                screenCapture.cancel()
                if screenQuestion.isPreparing { screenQuestion.cancel() }
            }
        }
        .onDisappear {
            voiceInput.cancel(); screenCapture.cancel()
            if screenQuestion.isPreparing { screenQuestion.cancel() }
        }
        .confirmationDialog("清空当前 AI 的对话？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空对话", role: .destructive) { chat.clearConversation() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只清空 \(chat.provider.displayName) 在羽中的记录。")
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .offset(x: 20).combined(with: .scale(scale: 0.985)).combined(with: .opacity),
            removal: .offset(x: -12).combined(with: .opacity)
        )
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .home:
            MenuShelfView(shelf: shelf, chat: chat, screenSession: screenSession,
                          onActivateAI: onActivateAI, onDisableAI: onDisableAI,
                          onOpenChat: { page = .chat })
        case .settings:
            CompanionSettingsView(chat: chat, voiceInput: voiceInput, onDisableAI: onDisableAI)
        case .chat: conversation
        case .image:
            ImageRecognitionView(store: recognizedImage, chat: chat, isSending: isSendingImageQuestion,
                                 onAnalyze: analyzeRecognizedImage)
        case .screen:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    screenModeButton("持续会话", mode: "session")
                    screenModeButton("单次截图", mode: "single")
                }.padding(.horizontal, 14).padding(.top, 10)
                if screenMode == "session" {
                    ScreenSessionView(assistant: screenSession, chat: chat, onBack: { page = .chat })
                } else {
                    if screenSession.capture.isRunning || screenSession.capture.isSelecting || screenSession.capture.isStopping {
                        HStack {
                            Text("持续会话正在使用屏幕共享，停止后可单次截图。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("停止持续会话") { screenSession.stop() }.font(.system(size: 10))
                        }.padding(.horizontal, 14).padding(.top, 8)
                    }
                    ScreenAssistantView(capture: screenCapture, provider: chat.provider,
                                        isBusy: chat.isGenerating || screenQuestion.isPreparing || chat.authRequired || screenSession.capture.isRunning || screenSession.capture.isSelecting || screenSession.capture.isStopping,
                                        onUseCapture: analyzeScreen, onBack: { page = .chat })
                        .overlay(alignment: .bottom) {
                            if let error = screenQuestion.errorMessage {
                                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                                    .padding(10).stashGlassSurface(cornerRadius: 10).padding(12)
                            }
                        }
                }
            }
        case .files:
            ScrollView {
                VStack(spacing: 0) {
                    if chat.isEnabled { fileAccessActions }
                    ShelfView(store: shelf, onAnalyze: chat.isEnabled ? { url in addAttachments([url]) } : nil).frame(minHeight: 385)
                }
            }
        case .reminders: ReminderView(store: reminders)
        case .mail:
            MailView(store: mail, onCreateReminder: onMailReminder,
                     onAnalyze: chat.isEnabled && !chat.authRequired && !chat.isGenerating ? onMailAnalyze : nil,
                     analysisDisclosure: "会将选中邮件的前 4200 字及主题、发件人和日期发送至 \(chat.provider.destinationName)。")
        }
    }

    private func screenModeButton(_ title: String, mode: String) -> some View {
        DwellButton(target: title, allowsDwell: screenMode != mode, action: { screenMode = mode }) {
            Text(title).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.primary.opacity(screenMode == mode ? 0.15 : 0.045), in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(screenMode == mode ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 9) {
            DwellButton(target: "首页", allowsDwell: page != .home, action: { page = .home }) {
                Image(systemName: "chevron.left")
                    .frame(width: 27, height: 27)
                    .stashGlassSurface(cornerRadius: 9)
            }
            .help("回到菜单栏首页")
            .accessibilityLabel("回到菜单栏首页")
            .disabled(page == .home)
            Image(nsImage: StatusBarIcon.image()).accessibilityHidden(true)
            Text("羽")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .stashHighlightedText()
            Text(page.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.primary.opacity(0.045), in: Capsule())
            Spacer(minLength: 2)
            if screenSession.capture.isRunning || screenSession.capture.isSelecting {
                Button { screenSession.stop() } label: { Image(systemName: "stop.circle.fill") }
                    .help("屏幕会话进行中，点击停止").accessibilityLabel("停止屏幕会话")
            }
            if chat.isEnabled {
                DwellButton(target: "屏幕助手", allowsDwell: page != .screen, action: { page = .screen }) { Image(systemName: "viewfinder") }
                    .help("选择屏幕内容，预览后向 AI 提问").accessibilityLabel("屏幕助手")
            }
            DwellButton(target: "偏好设置", allowsDwell: page != .settings, action: { page = .settings }) { Image(systemName: "slider.horizontal.3") }
                .help("偏好设置").accessibilityLabel("偏好设置")
            let sizeAction = navigation.isExpanded ? "恢复紧凑面板" : "展开主面板"
            DwellButton(target: sizeAction, action: onToggleExpanded) {
                Image(systemName: navigation.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.help(sizeAction).accessibilityLabel(sizeAction)
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("收起面板").accessibilityLabel("收起面板")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var providerBar: some View {
        HStack(spacing: 5) {
            DwellMenu(target: "选择 AI 提供方") { dismiss in
                ForEach(ChatProvider.allCases) { provider in
                    Button {
                        dismiss()
                        chat.switchProvider(provider)
                    } label: {
                        if provider == chat.provider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else { Text(provider.displayName) }
                    }
                }
                if chat.provider == .codex {
                    Divider()
                    Button("刷新 Codex 额度") { dismiss(); Task { await chat.codex.refreshUsage() } }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: chat.provider == .deepseek ? "sparkles" : "network")
                    Text(chat.provider.displayName)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11, weight: .semibold))
                .stashHighlightedText()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .stashGlassSurface(cornerRadius: 18, emphasis: true)
            }
            .buttonStyle(.plain).fixedSize()
            .help("在 DeepSeek Harness 与 OpenAI Codex 之间切换")
            .accessibilityLabel("\(chat.provider.displayName)，切换 AI")
            if chat.provider == .codex {
                Button { Task { await chat.codex.refreshUsage() } } label: {
                    Text(chat.codex.usageCompactText)
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .stashHighlightedText()
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .stashGlassSurface(cornerRadius: 18)
                }
                .buttonStyle(.plain).foregroundStyle(CatTheme.teal)
                .layoutPriority(1)
                .help("\(chat.codex.usageDetailText)\n点击刷新额度。")
                .accessibilityLabel("Codex 剩余额度：\(chat.codex.usageCompactText)，刷新额度")
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Circle().fill(chat.isReady ? CatTheme.teal : Color.orange).frame(width: 5, height: 5)
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
                Text(chat.isReady ? "就绪" : "待连接")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 11)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                Text(chat.isGenerating ? "正在回应…" : chat.modelName)
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !chat.messages.isEmpty {
                    DwellButton(target: "清空对话确认", action: { confirmClear = true }) { Text("清空") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10)).foregroundStyle(.secondary).disabled(chat.isGenerating)
                }
            }.padding(.horizontal, 17).padding(.top, 10).padding(.bottom, 5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 11) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("新对话")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .stashHighlightedText()
                                Text(chat.provider == .deepseek ? "向 DeepSeek 提问，或选择文件后发送。" : "向 Codex 提问，或添加图片与文件。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                            }.padding(.vertical, 24)
                        }
                        ForEach(chat.messages) { message in
                            CompanionMessageView(message: message, providerName: chat.provider.displayName,
                                                 streaming: chat.isGenerating && message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                        if chat.isGenerating && (chat.messages.last?.role != "assistant" || chat.messages.last?.content.isEmpty == true) {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("正在生成回答…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                        Color.clear.frame(height: 1).id("companionBottom")
                    }.padding(.horizontal, 16).padding(.vertical, 9)
                }
                .onAppear { proxy.scrollTo("companionBottom", anchor: .bottom) }
                .onChange(of: chat.messages.last?.content) { _, _ in proxy.scrollTo("companionBottom", anchor: .bottom) }
                .onChange(of: chat.isGenerating) { _, _ in proxy.scrollTo("companionBottom", anchor: .bottom) }
                .onChange(of: chat.provider) { _, _ in proxy.scrollTo("companionBottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var connectionNotice: some View {
        if chat.authRequired && chat.provider == .deepseek {
            HStack(alignment: .center, spacing: 8) {
                Text("在偏好设置中添加 DeepSeek API Key 后即可聊天。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                DwellButton(target: "偏好设置", action: { page = .settings }) { Text("偏好设置") }
                    .controlSize(.small)
            }
            .padding(10).stashGlassSurface(cornerRadius: 12)
            .padding(.horizontal, 14).padding(.top, 5)
        } else if chat.authRequired {
            VStack(alignment: .leading, spacing: 7) {
                Text(chat.errorMessage ?? "登录 OpenAI 后，即可在这里与 Codex 对话。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(4)
                HStack {
                    Text(signingIn ? "等待浏览器完成登录…" : "使用你自己的 OpenAI 账号")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 3)
                    Button(signingIn ? "登录中…" : "登录 OpenAI") {
                        signingIn = true
                        Task { await chat.signIn(); signingIn = false }
                    }.font(.system(size: 10, weight: .medium)).disabled(signingIn)
                }
            }.padding(10).stashGlassSurface(cornerRadius: 12)
                .padding(.horizontal, 14).padding(.top, 5)
        } else if let error = chat.errorMessage {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).textSelection(.enabled).lineLimit(3)
                Spacer(minLength: 2)
                Button("重试") { Task { await chat.startIfNeeded() } }
            }.font(.system(size: 10)).padding(10)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 14).padding(.top, 5)
        } else if !chat.isReady {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(chat.statusText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 17).padding(.top, 5)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            voiceInputNotice
            if !attachments.items.isEmpty {
                AttachmentTrayView(store: attachments, disabled: chat.isGenerating || voiceInputActive)
                Text(chat.provider == .deepseek
                     ? "发送时会把最多 4000 字附件摘录发送至 DeepSeek。图片仅发送识别文字和基础标签。"
                     : "发送时会把所选图片与最多 16000 字附件摘录发送至 OpenAI。")
                    .font(.system(size: 8)).foregroundStyle(.secondary).lineSpacing(2)
            }
            if attachments.isLoading {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在读取附件…").font(.system(size: 9)); Spacer() }
            }
            if let error = attachmentError ?? attachments.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { attachmentError = nil; attachments.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.system(size: 8)).accessibilityLabel("关闭附件提示")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                DwellMenu(target: "添加附件") { dismiss in
                    DwellButton(target: "读取文件", action: { dismiss(); chooseAttachments(imagesOnly: false) }) { Text("读取文件…") }
                    DwellButton(target: "识别图片", action: { dismiss(); chooseAttachments(imagesOnly: true) }) { Text("识别图片…") }
                    DwellButton(target: "读取屏幕", action: { dismiss(); page = .screen }) { Text("读取屏幕…") }
                } label: { Image(systemName: "paperclip").font(.system(size: 13)).frame(width: 22, height: 29) }
                    .buttonStyle(.plain).fixedSize().disabled(chat.isGenerating || attachments.isLoading || attachments.items.count >= 4 || voiceInputActive)
                    .help("读取文件或识别图片").accessibilityLabel("添加文件或图片附件")
                TextField(chat.authRequired ? "请先配置 \(chat.provider.destinationName)…" : "输入问题…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1...4)
                    .focused($inputFocused).onSubmit { submitInput() }
                    .padding(.vertical, 7)
                    .disabled(voiceInputActive)
                Button(action: toggleVoiceInput) {
                    Group {
                        if voiceInput.isPreparing || voiceInput.isFinishing { ProgressView().controlSize(.mini) }
                        else { Image(systemName: voiceInput.isRecording ? "stop.circle.fill" : "mic") }
                    }
                    .font(.system(size: 14)).frame(width: 26, height: 29)
                    .foregroundStyle(voiceInputActive ? Color.orange : Color.secondary)
                }.buttonStyle(.plain)
                    .disabled(!voiceInputActive && (chat.isGenerating || chat.authRequired || attachments.isLoading))
                    .help(voiceInputActive ? (voiceInput.isRecording ? "结束语音输入" : "取消语音输入") : "点击说话，识别后可编辑")
                    .accessibilityLabel(voiceInputActive ? (voiceInput.isRecording ? "结束语音输入" : "取消语音输入") : "开始语音输入")
                if chat.isGenerating {
                    Button { chat.stopGeneration() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12))
                            .frame(width: 29, height: 29)
                            .stashGlassSurface(cornerRadius: 10)
                    }.buttonStyle(.plain).help("停止生成").accessibilityLabel("停止生成")
                } else {
                    Button(action: submitInput) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(CatTheme.onAccent).frame(width: 29, height: 29)
                            .background(CatTheme.teal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.24), lineWidth: 0.7)
                                    .allowsHitTesting(false)
                            }
                    }.buttonStyle(.plain).accessibilityLabel("发送消息")
                        .disabled((input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.items.isEmpty) || chat.authRequired || attachments.isLoading || voiceInputActive)
                }
            }.padding(9).stashGlassSurface(cornerRadius: 18, emphasis: true)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(inputFocused ? 0.25 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            Text(voiceInputActive ? (voiceInput.isRecording ? "正在听你说话，点击麦克风结束" : voiceInput.statusText) : "Enter 发送 · 内容将发送至 \(chat.provider.destinationName)")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 10)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !chat.isGenerating, !attachments.isLoading, !voiceInputActive else { return false }
            addAttachments(files)
            return true
        }
    }

    private var voiceInputActive: Bool { voiceInput.isRecording || voiceInput.isPreparing || voiceInput.isFinishing }

    @ViewBuilder private var voiceInputNotice: some View {
        if voiceInputActive {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: voiceInput.isRecording ? "waveform" : "mic")
                    Text(voiceInput.statusText).lineLimit(2)
                    Spacer(minLength: 2)
                    Button("取消") { voiceInput.cancel() }.buttonStyle(.plain)
                        .accessibilityLabel("取消语音输入")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if !voiceInput.transcript.isEmpty {
                    Text(voiceInput.transcript).font(.system(size: 11)).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("当前识别：\(voiceInput.transcript)")
                }
                if voiceInput.isRecording {
                    Text("识别后填入输入框，可编辑后发送。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.padding(9).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        if let error = voiceInput.errorMessage {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "mic.slash").foregroundStyle(.orange)
                Text(error).textSelection(.enabled).lineLimit(4)
                Spacer(minLength: 0)
                Button { voiceInput.clearError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭语音输入提示")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func toggleVoiceInput() {
        guard chat.isEnabled else { return }
        if voiceInput.isPreparing || voiceInput.isFinishing { voiceInput.cancel() }
        else if voiceInput.isRecording { voiceInput.stop() }
        else {
            inputFocused = false
            NSApp.activate()
            Task { await voiceInput.start() }
        }
    }

    private func receiveTranscript(_ value: String) {
        let transcript = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chat.isEnabled, !transcript.isEmpty else { return }
        page = .chat
        let draft = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = draft.isEmpty ? transcript : draft + "\n" + transcript
        inputFocused = true
    }

    private var tabBar: some View {
        HStack(spacing: 5) {
            ForEach(CompanionPage.allCases.filter { $0 != .screen && $0 != .settings && ($0 != .chat || chat.isEnabled) }) { tab in
                DwellButton(target: tab.title, allowsDwell: page != tab, action: { page = tab }) {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: page == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(.system(size: 10, weight: page == tab ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(page == tab ? CatTheme.teal : Color.secondary)
                    .background {
                        if page == tab {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.primary.opacity(0.075))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.6)
                                }
                                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }.padding(4)
            .stashGlassSurface(cornerRadius: 18, emphasis: true)
            .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 10)
    }

    private func submitInput() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chat.isEnabled, (!question.isEmpty || !attachments.items.isEmpty), !chat.isGenerating, !chat.authRequired, !attachments.isLoading, !voiceInputActive else { return }
        if !attachments.items.isEmpty {
            do {
                let batch = attachments.items
                let submittingProvider = chat.provider
                let prepared = try AttachmentPrompt.prepare(question: question, items: batch, online: submittingProvider == .codex)
                attachmentError = nil
                input = ""
                page = .chat
                Task {
                    guard chat.isEnabled, chat.provider == submittingProvider else { if input.isEmpty { input = question }; return }
                    let success = await chat.send(prepared.text, imageURLs: prepared.imageURLs, hasAttachments: true)
                    if success { for item in batch { attachments.remove(id: item.id) } }
                }
            } catch { attachmentError = error.localizedDescription }
            return
        }
        input = ""
        submit(question)
    }

    private var fileAccessActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("读取与识别").font(.system(size: 13, weight: .semibold)).stashHighlightedText()
            Text("选择文件或图片，预览内容后向当前 AI 提问。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                DwellButton(target: "读取文件", action: { chooseAttachments(imagesOnly: false) }) { Label("读取文件", systemImage: "doc.text.magnifyingglass") }
                DwellButton(target: "识图", action: { page = .image }) { Label("识图", systemImage: "photo.viewfinder") }
            }.font(.system(size: 11)).disabled(chat.isGenerating || attachments.isLoading || attachments.items.count >= 4)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .stashGlassSurface(cornerRadius: 15)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }

    private func chooseAttachments(imagesOnly: Bool) {
        guard chat.isEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = imagesOnly ? "选择要识别的图片" : "选择要读取的文件"
        panel.message = "只读取你选中的文件，添加后可先预览，再发送给当前 AI。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if imagesOnly { panel.allowedContentTypes = [.image] }
        panel.beginInLanxia { result in
            guard result == .OK else { return }
            addAttachments(panel.urls)
        }
    }

    private func addAttachments(_ urls: [URL]) {
        guard chat.isEnabled, !chat.isGenerating else { return }
        page = .chat
        attachmentError = nil
        Task { await attachments.add(urls: urls) }
    }

    private func analyzeRecognizedImage(_ item: ChatAttachment, _ question: String) {
        guard page == .image, recognizedImage.items.first?.id == item.id, item.imageURL != nil,
              chat.isEnabled, !chat.isGenerating, !chat.authRequired, !isSendingImageQuestion else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = chat.provider
        do {
            let prepared = try AttachmentPrompt.prepare(
                question: trimmed.isEmpty ? "请描述这张图片的主要内容，提取重要文字，并指出不确定的地方。" : trimmed,
                items: [item], online: true)
            recognizedImage.errorMessage = nil
            isSendingImageQuestion = true
            page = .chat
            Task {
                defer { isSendingImageQuestion = false }
                guard chat.isEnabled, chat.provider == provider else { return }
                await chat.send(prepared.text, imageURLs: prepared.imageURLs, hasAttachments: true)
            }
        } catch {
            recognizedImage.errorMessage = error.localizedDescription
        }
    }

    private func analyzeScreen(_ url: URL, _ question: String) {
        guard chat.isEnabled, page == .screen, !chat.isGenerating, !chat.authRequired, !screenQuestion.isPreparing else { return }
        let provider = chat.provider
        Task {
            guard let prepared = await screenQuestion.prepare(url: url, question: question, online: provider == .codex) else { return }
            guard chat.isEnabled, page == .screen, chat.provider == provider, !chat.isGenerating, !chat.authRequired else {
                screenQuestion.finish(prepared.id)
                return
            }
            // This is the only send in this workflow. Normal draft text/files remain untouched.
            page = .chat
            await chat.send(prepared.prompt.text, imageURLs: prepared.prompt.imageURLs, hasAttachments: true)
            screenQuestion.finish(prepared.id)
        }
    }

    private func submit(_ question: String) {
        guard chat.isEnabled, !chat.isGenerating, !chat.authRequired else { return }
        page = .chat
        Task { await chat.send(question) }
    }
}

@MainActor final class PanelNavigation: ObservableObject {
    @Published var page: CompanionPage = .home
    @Published var isExpanded = false
}

enum CompanionPage: String, CaseIterable, Identifiable {
    case home, chat, files, image, reminders, mail, screen, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "首页"
        case .settings: "偏好设置"
        case .chat: "聊天"
        case .files: "文件"
        case .image: "识图"
        case .reminders: "日程"
        case .mail: "邮件"
        case .screen: "屏幕"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .settings: "slider.horizontal.3"
        case .chat: "bubble.left.and.bubble.right"
        case .files: "tray"
        case .image: "photo.viewfinder"
        case .reminders: "calendar"
        case .mail: "envelope"
        case .screen: "viewfinder"
        }
    }
}

private struct CompanionMessageView: View {
    let message: ChatMessage
    let providerName: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : "pawprint.fill")
                Text(message.role == "user" ? "你" : providerName)
                    .fontWeight(.semibold).stashHighlightedText()
                Spacer(minLength: 3)
                if !message.content.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("复制内容").accessibilityLabel("复制消息")
                }
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            if !message.content.isEmpty {
                Group {
                    if streaming { Text(message.content) }
                    else { Text(formatted(message.content)) }
                }
                .font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12)
            .stashGlassSurface(cornerRadius: 14, emphasis: message.role == "user")
    }

    private func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
