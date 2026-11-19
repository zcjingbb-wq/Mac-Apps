import AppKit
import SwiftUI

/// A single, user-selected screenshot is previewed here before an explicit AI handoff.
/// No capture, submission or screen-control action runs merely by opening this page.
struct ScreenAssistantView: View {
    @ObservedObject var capture: ScreenCaptureService
    let provider: ChatProvider
    let isBusy: Bool
    let onUseCapture: (URL, String) -> Void
    let onBack: () -> Void

    @State private var question = ""

    private var captureInProgress: Bool { capture.isSelecting || capture.isCapturing }
    private var controlsBusy: Bool { captureInProgress || isBusy }
    private var defaultQuestion: String {
        "请根据这张截图的可见范围识别题目，并逐步解释解法。若截图包含多个题目，请先概括各题，再按顺序讲解；若内容不完整或不清楚，请明确指出，不要推测被遮挡的内容。"
    }

    var body: some View {
        let previewImage = capture.previewURL.flatMap { NSImage(contentsOf: $0) }
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

                VStack(alignment: .leading, spacing: 9) {
                    Text("选一张屏幕截图，一起看题。")
                        .font(.system(size: 13, weight: .semibold)).stashHighlightedText()
                    Text("通过系统选择器选择窗口或屏幕，截取一次画面。先预览，再确认交给当前 AI 分析。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    HStack(spacing: 12) {
                        Button { capture.chooseContent() } label: {
                            Label(capture.previewURL == nil ? "选择窗口或屏幕" : "重新选择", systemImage: "rectangle.on.rectangle")
                        }.disabled(controlsBusy)
                        Spacer(minLength: 0)
                        if captureInProgress {
                            Button("停止") { capture.cancel() }
                                .accessibilityLabel("停止截取屏幕")
                        } else if capture.previewURL != nil || capture.errorMessage != nil {
                            Button("清除") { capture.clear() }
                                .disabled(isBusy).accessibilityLabel("清除截图")
                        }
                    }.font(.system(size: 11))
                    if captureInProgress {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(capture.statusText).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    Text("macOS 可能要求屏幕录制权限，请自行确认。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .stashGlassSurface(cornerRadius: 15)

                if let previewImage {
                    previewCard(previewImage)
                } else if capture.previewURL != nil {
                    Label("截图预览暂不可用，请重新选择。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }

                if let error = capture.errorMessage {
                    VStack(alignment: .leading, spacing: 7) {
                        Label { Text(error).textSelection(.enabled) } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }.foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("打开屏幕录制设置") { capture.openPrivacySettings() }
                    }.font(.system(size: 10)).padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .stashGlassSurface(cornerRadius: 12)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("想问什么？").font(.system(size: 12, weight: .semibold)).stashHighlightedText()
                    TextField("留空则识别题目并逐步解释", text: $question, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .lineLimit(2...4).padding(10)
                        .stashGlassSurface(cornerRadius: 12)
                        .disabled(controlsBusy)
                        .accessibilityLabel("针对截图的问题，留空则识别题目并解释")
                    Text(provider == .deepseek
                         ? "点击下方按钮会将截图识别出的文字及你的问题发送至 DeepSeek。图形和公式可能识别不完整。"
                         : "点击下方按钮后，会把这张预览图和你的问题发送至 OpenAI，由 Codex 分析。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)

                    Button {
                        guard !controlsBusy, let url = capture.previewURL,
                              NSImage(contentsOf: url) != nil else { return }
                        let enteredQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        let prompt = enteredQuestion.isEmpty ? defaultQuestion
                            : enteredQuestion + "\n\n请只根据截图中可见的内容分析；不清楚或被遮挡的部分请明确说明。"
                        onUseCapture(url, prompt)
                    } label: {
                        Label(provider == .deepseek ? "用 DeepSeek 分析这张图" : "发送此截图给 Codex", systemImage: "arrow.up.circle")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .stashGlassSurface(cornerRadius: 12, emphasis: true)
                    .disabled(controlsBusy || previewImage == nil)
                    .help(previewImage == nil ? "先选择窗口或屏幕，确认截图预览后再分析" : "只分析当前预览的这一次截图")

                    if isBusy {
                        Text("正在处理当前任务，请稍候。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("图片仅临时保存；发送后的识别文字和回答留在当前模式聊天记录，可清空。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .stashGlassSurface(cornerRadius: 15)
            }.padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(CatTheme.teal)
        .onDisappear { capture.cancel() }
    }

    private func previewCard(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("待分析的单次截图预览")
            HStack(spacing: 6) {
                Label("截图预览", systemImage: "photo")
                Spacer(minLength: 0)
                if let capturedAt = capture.capturedAt {
                    Text(capturedAt.formatted(date: .abbreviated, time: .standard))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .stashGlassSurface(cornerRadius: 15)
    }
}
