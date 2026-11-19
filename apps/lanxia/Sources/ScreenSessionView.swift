import AppKit
import ImageIO
import SwiftUI

/// A user-started observation session. Leaving this view deliberately does not
/// stop it; the user can stop observation and answer generation separately.
struct ScreenSessionView: View {
    @ObservedObject var assistant: ScreenSessionAssistant
    @ObservedObject var chat: ChatCoordinator
    let onBack: () -> Void

    @State private var question = ""

    private var isSessionBusy: Bool {
        assistant.capture.isSelecting || assistant.capture.isStopping
    }
    private var canAnalyze: Bool {
        chat.isEnabled && !chat.authRequired && assistant.capture.isRunning && assistant.capture.latestFrame != nil
            && !isSessionBusy && !assistant.isAnalyzing && !chat.isGenerating
    }
    private var errors: [String] {
        var seen = Set<String>()
        return [assistant.capture.errorMessage, assistant.errorMessage]
            .compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: onBack) { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).help("返回初始页").accessibilityLabel("返回初始页")
                    Label("屏幕助手", systemImage: "viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                        .stashHighlightedText()
                    Spacer(minLength: 0)
                }
                sessionControls
                if !assistant.stopShortcutAvailable {
                    Text("停止快捷键暂不可用，请使用停止按钮或菜单栏中的停止入口。")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                if let frame = assistant.capture.latestFrame,
                   let image = NSImage(contentsOf: frame.imageURL) {
                    previewCard(image, url: frame.imageURL, capturedAt: frame.capturedAt,
                                appName: frame.windowTarget?.appName)
                }
                questionControls
                if assistant.isAnalyzing || !assistant.answerText.isEmpty {
                    answerCard
                }
                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(errors, id: \.self) { error in
                            Label { Text(error).textSelection(.enabled) } icon: {
                                Image(systemName: "exclamationmark.circle")
                            }
                        }
                    }.font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .stashGlassSurface(cornerRadius: 12)
                }
            }.padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(CatTheme.teal)
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(assistant.capture.isRunning ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(assistant.capture.statusText).font(.system(size: 11, weight: .medium))
                    .stashHighlightedText()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isSessionBusy { ProgressView().controlSize(.small) }
            }
            Text("选择要持续查看的窗口或屏幕。点击分析时提交当前预览。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            HStack(spacing: 12) {
                Button { assistant.start() } label: {
                    Label(assistant.capture.isRunning ? "重新选择" : "选择并开始", systemImage: "rectangle.on.rectangle")
                }
                .disabled(isSessionBusy || assistant.isAnalyzing || chat.isGenerating)
                Spacer(minLength: 0)
                Button { assistant.stop() } label: {
                    Label(assistant.capture.isStopping ? "正在停止…" : "停止会话", systemImage: "stop.circle")
                }
                .disabled(assistant.capture.isStopping
                          || (!assistant.capture.isRunning && !assistant.capture.isSelecting && !assistant.isAnalyzing))
            }.font(.system(size: 11))
            Text("离开此页或收起面板后会话继续；全局 ⌃⌥⌘. 或菜单中的“停止屏幕会话”可结束。macOS 可能要求屏幕录制权限，请自行确认。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 15)
    }

    private var questionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("想问什么？").font(.system(size: 12, weight: .semibold)).stashHighlightedText()
            TextField("留空则识别当前题目并解释解法", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...4)
                .padding(10).stashGlassSurface(cornerRadius: 12)
                .disabled(assistant.isAnalyzing)
                .accessibilityLabel("针对当前屏幕画面的问题")
            Text(chat.provider == .deepseek
                 ? "点击分析会将当前画面识别出的文字及你的问题发送至 DeepSeek。"
                 : "分析时会将当前选择的新画面和问题发送至 OpenAI，使用 Codex 账号额度。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            Button {
                guard canAnalyze else { return }
                Task { await assistant.analyze(question: question.trimmingCharacters(in: .whitespacesAndNewlines), chat: chat) }
            } label: {
                Label(chat.provider == .deepseek ? "用 DeepSeek 分析当前画面" : "用 Codex 分析当前画面", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.plain).stashGlassSurface(cornerRadius: 12, emphasis: true)
            .disabled(!canAnalyze)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 15)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(assistant.isAnalyzing ? "正在解答…" : "当前回答")
                    .font(.system(size: 12, weight: .semibold))
                    .stashHighlightedText()
                if assistant.isAnalyzing { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if assistant.isAnalyzing {
                    Button("停止回答") { assistant.stopAnswer() }
                        .font(.system(size: 10)).accessibilityLabel("停止当前屏幕回答")
                }
            }
            if let date = assistant.answerCapturedAt {
                Text("根据 \(date.formatted(date: .omitted, time: .standard)) 的画面回答")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if !assistant.answerText.isEmpty {
                Text(assistant.answerText).font(.system(size: 12)).lineSpacing(4)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 15)
    }

    private func previewCard(_ image: NSImage, url: URL, capturedAt: Date, appName: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 145)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("所选画面的最近预览")
            HStack(spacing: 6) {
                Text(appName ?? "显示器画面").lineLimit(1)
                Spacer(minLength: 0)
                if let dimensions = pixelDimensions(url) { Text(dimensions) }
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            Text("最近画面：\(capturedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 15)
    }

    private func pixelDimensions(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}
