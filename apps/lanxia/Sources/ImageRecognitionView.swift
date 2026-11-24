import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageRecognitionView: View {
    @ObservedObject var store: AttachmentStore
    @ObservedObject var chat: ChatCoordinator
    let isSending: Bool
    let onAnalyze: (ChatAttachment, String) -> Void

    @State private var choosingImage = false
    @State private var importingImage = false
    @State private var dropTargeted = false
    @State private var question = ""
    @State private var copiedText = false

    private var item: ChatAttachment? { store.items.first }
    private var busy: Bool { store.isLoading || importingImage || choosingImage || isSending }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("识图")
                        .font(.system(size: 19, weight: .bold)).stashHighlightedText()
                    Spacer(minLength: 0)
                    Button("粘贴图片", systemImage: "clipboard", action: pasteImage).disabled(busy)
                    Button(item == nil ? "选择图片" : "更换图片", systemImage: "photo", action: chooseImage)
                        .stashGlassPrimaryButton()
                        .disabled(busy)
                }
                .controlSize(.small)
                preview

                if importingImage || store.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在本机识别…")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let item, let result = item.imageRecognition {
                    recognitionResult(result, notice: item.notice)
                    if chat.isEnabled {
                        aiActions(item)
                    }
                }
            }
            .padding(14)
        }
    }

    private var preview: some View {
        VStack(spacing: 5) {
            if let item, let url = item.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                    .accessibilityLabel("所选图片预览")
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Button {
                        store.clear()
                        copiedText = false
                        question = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除图片")
                    .disabled(busy)
                }
                if let result = item.imageRecognition {
                    Text("\(result.pixelWidth) × \(result.pixelHeight) 像素")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("拖入图片").font(.system(size: 13, weight: .semibold))
                Text("在本机提取文字和候选标签")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 100)
        .stashGlassSurface(cornerRadius: 14, emphasis: dropTargeted)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(dropTargeted ? 0.32 : 0), lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy else { return false }
            guard urls.count == 1, let url = urls.first, url.isFileURL else {
                store.errorMessage = "每次请选择一张本机图片。"
                return false
            }
            importImage(url)
            return true
        } isTargeted: { dropTargeted = $0 && !busy }
    }

    private func recognitionResult(_ result: ImageRecognitionResult, notice: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("识别文字").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !result.recognizedText.isEmpty {
                    Button(copiedText ? "已复制" : "复制文字", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copiedText = NSPasteboard.general.setString(result.recognizedText, forType: .string)
                    }.controlSize(.small)
                }
            }
            Text(result.recognizedText.isEmpty ? "未识别到文字。" : result.recognizedText)
                .font(.system(size: 12)).textSelection(.enabled)
            if !result.labels.isEmpty {
                Divider()
                Text("候选标签").font(.system(size: 12, weight: .semibold))
                Text(result.labels.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 14)
    }

    private func aiActions(_ item: ChatAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("关于这张图的问题（可选）", text: $question)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Text("点击解读会向 \(chat.provider.destinationName) 发送图片和识别结果。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if chat.authRequired {
                Text("请在偏好设置中连接当前 AI。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button("用 \(chat.provider.displayName) 解读", systemImage: "sparkles") {
                onAnalyze(item, question)
            }
            .stashGlassPrimaryButton()
            .controlSize(.small)
            .disabled(busy || chat.isGenerating || chat.authRequired)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 14)
    }

    private func chooseImage() {
        guard !busy else { return }
        choosingImage = true
        let panel = NSOpenPanel()
        panel.title = "选择要识别的图片"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        panel.begin { response in
            choosingImage = false
            NotificationCenter.default.post(name: .init("StashCatRevealCompanion"), object: nil)
            if response == .OK, let url = panel.url { importImage(url) }
        }
    }

    private func pasteImage() {
        guard !busy else { return }
        let clipboard = NSPasteboard.general
        let formats: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"), (.tiff, "tiff")
        ]
        if let (type, ext) = formats.first(where: { clipboard.types?.contains($0.0) == true }),
           let data = clipboard.data(forType: type), !data.isEmpty {
            guard Int64(data.count) <= AttachmentStore.maximumFileBytes else {
                store.errorMessage = "剪贴板图片不能超过 25 MiB。"
                return
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("StashCatImagePaste-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("剪贴板图片.\(ext)")
                try data.write(to: url)
                importImage(url, temporaryDirectory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                store.errorMessage = "无法准备剪贴板图片，请选择图片文件。"
            }
        } else if let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  urls.count == 1, let url = urls.first {
            importImage(url)
        } else {
            store.errorMessage = "剪贴板中没有一张可读取的图片。"
        }
    }

    private func importImage(_ url: URL, temporaryDirectory: URL? = nil) {
        guard !busy else {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            return
        }
        importingImage = true
        let previous = item?.id
        Task {
            defer {
                importingImage = false
                if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            }
            await store.add(urls: [url], imagesOnly: true)
            if let previous, store.items.count > 1 {
                store.remove(id: previous)
            }
            if store.items.first?.id != previous {
                copiedText = false
                question = ""
            }
        }
    }
}
