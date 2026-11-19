import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A compact, read-only Outlook reader inside the independently movable panel.
struct MailView: View {
    @ObservedObject var store: MailStore
    var onCreateReminder: ((MailItem) -> Void)? = nil
    var onAnalyze: ((MailItem) -> Void)? = nil
    var analysisDisclosure: String = "使用顶部所选 AI；在线模式会把这封邮件正文发送给 OpenAI。"

    @State private var filter = MailFilter()
    @State private var selectedID: String?
    @State private var showOverview = true
    @State private var showRules = false
    @State private var ruleText = ""
    @State private var confirmOnlineSummary = false
    @State private var pendingAnalysis: MailItem?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let item = store.messages.first(where: { $0.id == selectedID }) {
                messageDetail(item)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionSummary
                        if let error = store.errorMessage {
                            Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                        }
                        if showOverview { overview } else { messageList }
                    }.padding(13)
                }
            }
        }
        .sheet(isPresented: $showRules) { rulesEditor }
        .alert("使用当前 AI 总结邮件？", isPresented: $confirmOnlineSummary) {
            Button("总结") { if let item = pendingAnalysis { onAnalyze?(item) }; pendingAnalysis = nil }
            Button("取消", role: .cancel) { pendingAnalysis = nil }
        } message: { Text(analysisDisclosure + "\n邮件按参考数据处理，请核对结论。") }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if selectedID != nil {
                Button { selectedID = nil } label: { Label("邮件", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 11))
            } else {
                Picker("显示", selection: $showOverview) {
                    Text("总览").tag(true)
                    Text("邮件").tag(false)
                }.pickerStyle(.segmented).frame(width: 125)
            }
            Spacer(minLength: 3)
            if store.isSyncing { ProgressView().controlSize(.small).frame(width: 14) }
            Button {
                Task { await store.sync() }
            } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.isSyncing).help("通过已连接的 Microsoft Outlook 刷新邮件")
                .accessibilityLabel("刷新 Outlook 邮件")
            Menu {
                Button("重新读取本地快照") { store.reloadSnapshot() }
                Button("导入邮件快照…") { importSnapshot() }
                Button("处理关键词…") { ruleText = store.actionKeywords.joined(separator: "，"); showRules = true }
                Button("打开 Outlook") { OutlookBridge.openOutlook() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 20).help("Outlook 选项")
        }
        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Microsoft Outlook", systemImage: "envelope.badge").font(.system(size: 13, weight: .semibold))
                    .stashHighlightedText()
                Spacer()
                if let date = store.syncedAt { Text(date, format: .dateTime.month().day().hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            Text(store.coverageText).font(.system(size: 10)).foregroundStyle(.secondary)
            if store.isSyncing { Text(store.statusText).font(.system(size: 10)).foregroundStyle(.secondary) }
            if !store.accountEmail.isEmpty { Text(store.accountEmail).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    Text("来源：\(store.sourceText)")
                    Text(store.statusText)
                    Text("按本地规则分组；摘要为原文摘录。打开邮件不会更改已读状态。")
                    if let snapshot = store.snapshot {
                        ForEach(Array(snapshot.folderErrors.enumerated()), id: \.offset) { _, error in Text(error) }
                    }
                }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 4)
            } label: { Text("来源与覆盖范围").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(11).stashGlassSurface(cornerRadius: 14)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                metric("全部", count: store.messages.count) { filter = MailFilter(); showOverview = false }
                metric("未读", count: store.unreadCount) { filter = MailFilter(unreadOnly: true); showOverview = false }
                metric("待核对", count: store.attentionCount) { filter = MailFilter(priority: .attention); showOverview = false }
            }
            Text("本地整理摘要").font(.system(size: 12, weight: .semibold)).stashHighlightedText()
            Text(store.digestText).font(.system(size: 10)).lineSpacing(4).textSelection(.enabled)
            if !store.messages.isEmpty {
                Text("分类浏览").font(.system(size: 12, weight: .semibold)).stashHighlightedText()
                let counts = Dictionary(grouping: store.messages) { store.analysis(for: $0).category }
                ForEach(MailCategory.allCases) { category in
                    if let count = counts[category]?.count {
                        Button {
                            filter = MailFilter(category: category); showOverview = false
                        } label: {
                            HStack {
                                Label(category.title, systemImage: category.symbol)
                                Spacer()
                                Text("\(count)").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 8))
                            }.font(.system(size: 11)).padding(9)
                                .stashGlassSurface(cornerRadius: 11)
                        }.buttonStyle(.plain)
                    }
                }
                let upcoming = store.dateHintItems()
                if !upcoming.isEmpty {
                    Text("邮件中的时间线索").font(.system(size: 12, weight: .semibold)).stashHighlightedText()
                    Text("只提取明确日期，可能是活动日期或引用内容；添加提醒前请确认。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    ForEach(Array(upcoming.prefix(4))) { item in
                        Button { selectedID = item.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displaySubject).lineLimit(2)
                                if let date = store.analysis(for: item).dateHint {
                                    Text(date, format: .dateTime.year().month().day()).foregroundStyle(.secondary)
                                }
                            }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func metric(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count)").font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit().stashHighlightedText()
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .stashGlassSurface(cornerRadius: 14)
        }.buttonStyle(.plain)
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索主题、发件人和正文", text: $filter.query).textFieldStyle(.plain).font(.system(size: 11))
                .padding(.horizontal, 10).padding(.vertical, 9)
                .stashGlassSurface(cornerRadius: 11, emphasis: true)
            HStack(spacing: 7) {
                Picker("分类", selection: $filter.category) {
                    Text("全部分类").tag(Optional<MailCategory>.none)
                    ForEach(MailCategory.allCases) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Picker("文件夹", selection: $filter.folderID) {
                    Text("全部文件夹").tag(Optional<String>.none)
                    ForEach(store.folders) { Text($0.path).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }.font(.system(size: 10))
            HStack(spacing: 8) {
                Toggle("仅未读", isOn: $filter.unreadOnly)
                Toggle("含附件", isOn: $filter.attachmentsOnly)
                Picker("优先级", selection: $filter.priority) {
                    Text("全部优先级").tag(Optional<MailPriority>.none)
                    ForEach(MailPriority.allCases) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden()
            }.font(.system(size: 9)).toggleStyle(.checkbox)
            let results = store.filtered(filter)
            HStack {
                Text("\(results.count) 封").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if filter != MailFilter() {
                    Button("重置筛选") { filter = MailFilter() }.font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            LazyVStack(spacing: 7) {
                ForEach(results) { item in messageRow(item) }
            }
            if results.isEmpty { Text("没有符合条件的邮件").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 18) }
        }
    }

    private func messageRow(_ item: MailItem) -> some View {
        let analysis = store.analysis(for: item)
        return Button { selectedID = item.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle().fill(item.isRead ? .clear : .primary).frame(width: 5, height: 5)
                    Text(item.displaySender).font(.system(size: 10, weight: item.isRead ? .regular : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = item.receivedAt { Text(date, format: .dateTime.month().day()).font(.system(size: 9)).foregroundStyle(.secondary) }
                    if item.hasAttachments { Image(systemName: "paperclip").font(.system(size: 9)) }
                }
                Text(item.displaySubject).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Text(analysis.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 5) {
                    Text(analysis.category.title)
                    if analysis.priority == .attention { Text("· 可能需处理") }
                    Spacer(minLength: 0)
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .stashGlassSurface(cornerRadius: 13)
        }.buttonStyle(.plain)
    }

    private func messageDetail(_ item: MailItem) -> some View {
        let analysis = store.analysis(for: item)
        return ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text(item.displaySubject).font(.system(size: 15, weight: .semibold))
                    .stashHighlightedText().textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displaySender)
                    Text(item.senderAddress)
                    if let date = item.receivedAt { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    Text("\(item.folderPath) · \(item.isRead ? "已读" : "未读")\(item.hasAttachments ? " · 含附件" : "")")
                }.font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(analysis.category.title)
                    Text("· \(analysis.priority.title)")
                }.font(.system(size: 10, weight: .medium))
                Text(analysis.reason).font(.system(size: 9)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文摘录 · 本地生成").font(.system(size: 10, weight: .semibold))
                    Text(analysis.summary).font(.system(size: 11)).lineSpacing(3).textSelection(.enabled)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .stashGlassSurface(cornerRadius: 13)
                HStack(spacing: 9) {
                    if onCreateReminder != nil {
                        Button { onCreateReminder?(item) } label: { Label("设为提醒", systemImage: "bell.badge") }
                    }
                    if let url = item.safeWebURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label("原邮件", systemImage: "arrow.up.right.square") }
                    }
                }.font(.system(size: 10)).buttonStyle(.bordered)
                if onAnalyze != nil {
                    Button {
                        pendingAnalysis = item; confirmOnlineSummary = true
                    } label: { Label("用当前 AI 总结", systemImage: "sparkles") }
                        .font(.system(size: 11)).buttonStyle(.bordered)
                    Text(analysisDisclosure).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Divider()
                Text(item.hasFullBody ? "正文 · 纯文本" : "正文预览 · 尚无完整正文")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(item.plainBody.isEmpty ? "此邮件未提供可读取的正文。" : item.plainBody)
                    .font(.system(size: 11)).lineSpacing(3).textSelection(.enabled)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("需要处理的关键词").font(.headline)
            Text("用逗号或换行分隔。匹配只提示你核对原文，不代表已有待办或确定的截止时间。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $ruleText).font(.system(size: 12)).frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.15)))
            HStack {
                Button("恢复默认") { ruleText = MailClassifier.defaultActionKeywords.joined(separator: "，") }
                Spacer()
                Button("取消") { showRules = false }
                Button("保存") { store.updateActionKeywords(ruleText); showRules = false }.keyboardShortcut(.defaultAction)
            }.font(.system(size: 11))
        }.padding(20).frame(width: 330)
    }

    private func importSnapshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 Outlook 邮件快照（outlook-mailbox.json）"
        panel.begin { response in
            if response == .OK, let url = panel.url { store.importSnapshot(from: url) }
        }
    }
}
