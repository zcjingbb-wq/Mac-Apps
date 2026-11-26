import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject private var compressor = ArchiveService.shared
    var onAnalyze: ((URL) -> Void)? = nil
    @State private var isDropTarget = false
    @State private var query = ""
    @State private var confirmClear = false
    @State private var isChoosingArchive = false

    private var fileActionsUnavailable: Bool {
        store.isImporting || compressor.isCompressing || isChoosingArchive
    }

    private var visibleItems: [ShelfItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? store.items : store.items.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件中转站").font(.system(size: 23, weight: .bold, design: .rounded))
                        .stashHighlightedText()
                    Text("支持拖放、搜索和 ZIP 压缩。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DwellMenu(target: "压缩文件为 ZIP") { dismiss in
                    DwellButton(target: "选择要压缩的文件", action: {
                        dismiss()
                        chooseCompressionSources()
                    }) {
                        Label("选择文件或文件夹…", systemImage: "folder.badge.plus")
                    }
                    DwellButton(target: "选择全部暂存项的压缩位置", action: {
                        dismiss()
                        chooseArchiveDestination(for: store.items.map { store.url(for: $0) })
                    }) {
                        Label("压缩全部暂存项…", systemImage: "archivebox")
                    }
                    .disabled(store.items.isEmpty)
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("将文件或文件夹压缩为 ZIP")
                .accessibilityLabel("压缩文件为 ZIP")
                .disabled(fileActionsUnavailable)
                DwellButton(target: "添加暂存文件", action: store.importWithPanel) {
                    Label("添加", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .stashGlassPrimaryButton()
                .disabled(fileActionsUnavailable)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找暂存文件", text: $query).textFieldStyle(.plain)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DwellButton(target: "清空文件搜索", action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                        .buttonStyle(.plain).help("清空搜索")
                }
            }
            .font(.system(size: 12)).padding(9)
            .stashGlassSurface(cornerRadius: 9)

            if compressor.isCompressing || !compressor.statusText.isEmpty || compressor.errorMessage != nil || compressor.outputURL != nil {
                compressionFeedback
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isDropTarget ? Color.primary.opacity(0.10) : Color.clear)
                    .stashGlassSurface(cornerRadius: 14)
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(isDropTarget ? 0.45 : 0.12), style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: [5, 4]))

                if store.items.isEmpty {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.07)).frame(width: 62, height: 62)
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 25)).foregroundStyle(Color.primary)
                        }
                        Text(isDropTarget ? "松手以暂存文件" : "把文件拖到这里")
                            .font(.system(size: 15, weight: .semibold))
                            .stashHighlightedText()
                        Text("文件与文件夹都可以\n只保存一份副本，原文件留在原处")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineSpacing(4)
                    }.padding(24)
                } else if visibleItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("没有找到这个文件").font(.system(size: 13))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleItems) { item in
                                ShelfItemRow(
                                    item: item,
                                    store: store,
                                    onAnalyze: onAnalyze,
                                    onCompress: { chooseArchiveDestination(for: [store.url(for: item)]) },
                                    fileActionsUnavailable: fileActionsUnavailable
                                )
                            }
                        }.padding(7)
                    }
                }
                if store.isImporting {
                    RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在整理文件…").font(.system(size: 12, weight: .medium))
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: receiveDrop)

            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                }
                .font(.system(size: 11)).lineLimit(5)
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            } else if let message = store.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack {
                Label("\(store.items.count) 项 · \(totalSize)", systemImage: "internaldrive")
                    .fontWeight(.semibold).monospacedDigit().stashHighlightedText()
                Spacer()
                if !store.items.isEmpty {
                    DwellButton(target: "清空暂存", action: { confirmClear = true }) { Text("清空暂存") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(fileActionsUnavailable)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 340)
        .confirmationDialog("清空暂存区？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("将暂存副本放入废纸篓", role: .destructive) {
                if !fileActionsUnavailable { store.clear() }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("只移除暂存副本，原文件会保留。") }
    }

    private var compressionFeedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                if compressor.isCompressing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: compressor.errorMessage != nil ? "exclamationmark.circle.fill" : (compressor.outputURL != nil ? "checkmark.circle.fill" : "info.circle"))
                        .foregroundStyle(compressor.errorMessage == nil ? Color.primary : .orange)
                }
                Text(compressor.errorMessage ?? compressor.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if compressor.isCompressing {
                    Button("取消") { compressor.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityLabel("取消文件压缩")
                } else {
                    DwellButton(target: "关闭压缩结果", action: compressor.clearFeedback) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭压缩结果")
                }
            }
            if !compressor.isCompressing, let output = compressor.outputURL {
                Text(output.lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 14) {
                    DwellButton(target: "在访达中显示 ZIP 压缩包", action: {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }) {
                        Label("在访达中显示", systemImage: "folder")
                    }
                    .accessibilityLabel("在访达中显示 ZIP 压缩包")
                    Button("加入暂存站", systemImage: "tray.and.arrow.down") {
                        Task { await store.importURLs([output]) }
                    }
                    .accessibilityLabel("将 ZIP 压缩包加入暂存站")
                    .disabled(store.isImporting)
                }
                .font(.system(size: 11)).buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashGlassSurface(cornerRadius: 10, emphasis: true)
    }

    private func chooseCompressionSources() {
        guard !fileActionsUnavailable else { return }
        compressor.clearFeedback()
        isChoosingArchive = true
        let panel = NSOpenPanel()
        panel.title = "选择要压缩的文件"
        panel.prompt = "下一步"
        panel.message = "可同时选择文件和文件夹；压缩后保留原文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginInLanxia { response in
            Task { @MainActor in
                isChoosingArchive = false
                if response == .OK {
                    chooseArchiveDestination(for: panel.urls)
                }
            }
        }
    }

    private func chooseArchiveDestination(for urls: [URL]) {
        guard !urls.isEmpty, !fileActionsUnavailable else { return }
        compressor.clearFeedback()
        isChoosingArchive = true
        let panel = NSSavePanel()
        panel.title = "保存 ZIP 压缩包"
        panel.prompt = "压缩并保存"
        panel.message = "原文件会保留，已有同名文件不会被覆盖。请使用新的压缩包名称。"
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = urls.count == 1 ? "\(urls[0].lastPathComponent).zip" : "暂存文件.zip"
        panel.beginInLanxia { response in
            Task { @MainActor in
                isChoosingArchive = false
                guard response == .OK, let destination = panel.url else { return }
                NotificationCenter.default.post(name: .init("StashCatShowCompression"), object: nil)
                await compressor.compress(urls: urls, destination: destination)
            }
        }
    }

    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: store.items.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file)
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !fileActionsUnavailable else { return false }
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in supported {
                if let url = await droppedURL(provider) { urls.append(url) }
            }
            guard !fileActionsUnavailable else { return }
            if urls.isEmpty { store.errorMessage = "没有读到可用的文件，请使用添加按钮重试。" }
            else { await store.importURLs(urls) }
        }
        return true
    }

    private func droppedURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                let url: URL?
                if let value = value as? URL { url = value }
                else if let value = value as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                else if let value = value as? String { url = URL(string: value) }
                else { url = nil }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    var onAnalyze: ((URL) -> Void)? = nil
    let onCompress: () -> Void
    let fileActionsUnavailable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: store.url(for: item).path))
                .resizable().interpolation(.high).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .stashHighlightedText()
                Text("\(item.isDirectory ? "文件夹 · " : "")\(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) · \(item.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            DwellButton(target: "压缩「\(item.name)」为 ZIP", action: onCompress) {
                Image(systemName: "archivebox").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("压缩为 ZIP")
            .accessibilityLabel("压缩「\(item.name)」为 ZIP")
            .disabled(fileActionsUnavailable)
            DwellButton(target: "复制文件「\(item.name)」", action: { store.copy(item) }) {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("复制文件，随后可粘贴")
            DwellButton(target: "在访达中显示「\(item.name)」", action: { store.reveal(item) }) {
                Image(systemName: "arrow.up.right.square").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("在访达中显示")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .stashGlassSurface(cornerRadius: 9)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(store.url(for: item)) }
        .onDrag {
            NSItemProvider(contentsOf: store.url(for: item)) ?? NSItemProvider(object: store.url(for: item) as NSURL)
        }
        .contextMenu {
            if let onAnalyze, !item.isDirectory {
                Button("读取给 AI", systemImage: "doc.text.magnifyingglass") { onAnalyze(store.url(for: item)) }
                Divider()
            }
            Button("打开", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(store.url(for: item)) }
            Button("复制文件", systemImage: "doc.on.doc") { store.copy(item) }
            Button("在访达中显示", systemImage: "folder") { store.reveal(item) }
            Button("压缩为 ZIP…", systemImage: "archivebox", action: onCompress)
                .disabled(fileActionsUnavailable)
            Divider()
            Button("移除暂存副本", systemImage: "trash", role: .destructive) {
                if !fileActionsUnavailable { store.remove(item) }
            }
            .disabled(fileActionsUnavailable)
        }
        .help("可拖出到其他应用 · 双击打开")
    }
}
