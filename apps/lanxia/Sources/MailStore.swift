import AppKit
import Combine
import Foundation

struct MailFolder: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let totalItemCount: Int
}

/// Plain text only. Connector identifiers stay local and are never interpreted as instructions.
struct MailItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let subject: String
    let senderName: String
    let senderAddress: String
    let receivedDateTime: String
    let isRead: Bool
    let hasAttachments: Bool
    let bodyPreview: String
    let bodyText: String?
    let webLink: String
    let folderID: String
    let folderPath: String
    var category: String? = nil
    var priority: String? = nil
    var summary: String? = nil

    var receivedAt: Date? { MailDates.parse(receivedDateTime) }
    var displaySubject: String { subject.isEmpty ? "（无主题）" : subject }
    var displaySender: String { senderName.isEmpty ? senderAddress : senderName }
    var plainBody: String { MailText.readableMarkdown(bodyText?.isEmpty == false ? bodyText! : bodyPreview) }
    var hasFullBody: Bool { bodyText?.isEmpty == false }

    /// Restrict links to Microsoft's mail websites; imported arbitrary schemes never open.
    var safeWebURL: URL? {
        guard let url = URL(string: webLink), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["outlook.live.com", "outlook.office.com", "outlook.office365.com"].contains(host) else { return nil }
        return url
    }
}

struct MailSnapshot: Codable, Sendable {
    let version: Int
    let accountEmail: String
    let syncedAt: String
    let source: String?
    let complete: Bool
    let folders: [MailFolder]
    let messages: [MailItem]
    let folderErrors: [String]
}

enum MailCategory: String, CaseIterable, Identifiable, Sendable {
    case education, security, finance, subscriptions, personal, sent, junk, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .education: return "学习 / 申请"
        case .security: return "账号 / 安全"
        case .finance: return "账单 / 订单"
        case .subscriptions: return "订阅 / 推广"
        case .personal: return "个人往来"
        case .sent: return "已发送"
        case .junk: return "垃圾邮件"
        case .other: return "其他通知"
        }
    }
    var symbol: String {
        switch self {
        case .education: return "graduationcap"
        case .security: return "lock.shield"
        case .finance: return "creditcard"
        case .subscriptions: return "newspaper"
        case .personal: return "person.2"
        case .sent: return "paperplane"
        case .junk: return "tray.and.arrow.down"
        case .other: return "envelope"
        }
    }
}

enum MailPriority: String, CaseIterable, Identifiable, Sendable {
    case attention, historical, normal, low
    var id: String { rawValue }
    var title: String {
        switch self { case .attention: return "近期可能需处理"; case .historical: return "历史待核对"; case .normal: return "一般"; case .low: return "低优先级" }
    }
}

struct MailAnalysis: Sendable {
    let category: MailCategory
    let priority: MailPriority
    let summary: String
    let reason: String
    let dateHint: Date?
}

struct MailFilter: Equatable {
    var query = ""
    var category: MailCategory?
    var folderID: String?
    var priority: MailPriority?
    var unreadOnly = false
    var attachmentsOnly = false
}

enum MailDates {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

enum MailClassifier {
    static let defaultActionKeywords = ["请回复", "请确认", "请提交", "材料缺失", "截止", "即将到期", "面试", "待付款", "action required", "missing documents", "application incomplete", "reply requested", "deadline", "interview", "payment due", "please confirm", "please respond", "please submit"]

    static func analyze(_ mail: MailItem, actionKeywords: [String] = defaultActionKeywords, now: Date = Date()) -> MailAnalysis {
        let header = "\(mail.subject) \(mail.senderName) \(mail.senderAddress)".lowercased()
        // Reading the plain text does not load HTML, tracking pixels, links or attachments.
        let body = String(mail.plainBody.prefix(64_000))
        let text = header + " " + body.lowercased()
        let folder = mail.folderPath.lowercased()
        func matches(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        let category: MailCategory
        if ["junk", "spam", "垃圾"].contains(where: folder.contains) { category = .junk }
        else if ["sent", "已发送", "寄件备份"].contains(where: folder.contains) { category = .sent }
        else if matches(["verification code", "security alert", "sign-in", "验证码", "安全提醒", "异常登录", "password reset", "重置密码"]) { category = .security }
        else if matches(["admission", "university", "college", "application status", "scholarship", "interview", "课程", "大学", "留学", "录取", "申请材料", "面试", "考试", "托福", "ielts", "toefl"]) { category = .education }
        else if matches(["invoice", "receipt", "payment", "order confirmation", "账单", "付款", "发票", "订单", "收据", "退款"]) { category = .finance }
        else if matches(["unsubscribe", "newsletter", "sale ends", "退订", "取消订阅", "优惠", "限时折扣"]) { category = .subscriptions }
        else if header.hasPrefix("re:") || header.hasPrefix("回复:") || header.hasPrefix("回复：") { category = .personal }
        else { category = .other }

        // A match is a triage suggestion, not proof that the user owes an action.
        // A link path such as /admissions/deadlines is navigation, not a request to act.
        // Sender addresses also do not establish that an action was requested.
        let actionText = (mail.subject + " " + body).lowercased().replacingOccurrences(
            of: "(?i)\\b(?:https?://|www\\.)\\S+|\\b[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}/\\S*",
            with: " ", options: .regularExpression)
        let matchedKeyword = actionKeywords.first { !$0.isEmpty && actionText.contains($0.lowercased()) }
        let priority: MailPriority
        let reason: String
        let verificationCode = matches(["verification code", "one-time code", "one time password", "验证码", "一次性密码"])
        let directRequest = ["action required", "missing documents", "application incomplete", "please submit", "please respond", "请提交", "请回复", "材料缺失"].contains { mail.subject.localizedCaseInsensitiveContains($0) }
        // An unsubscribe footer alone also appears in legitimate school notices. Only the
        // category or explicit marketing language in the header lowers the priority.
        let promotionalHeader = ["newsletter", "sale ends", "discount", "special offer", "highest-quality", "registration is now open", "registration now open", "优惠", "折扣", "促销", "限时特惠"].contains(where: header.contains)
        let promotional = !directRequest && (category == .subscriptions || promotionalHeader)
        if category == .junk || category == .sent {
            priority = .low; reason = "根据原文件夹归类"
        } else if verificationCode {
            priority = .low; reason = "包含一次性验证码用语，不列入持续待办"
        } else if promotional {
            priority = .low; reason = "包含订阅或推广用语，仍可在分类中查看"
        } else if let keyword = matchedKeyword {
            if let receivedAt = mail.receivedAt, receivedAt >= now.addingTimeInterval(-30 * 86_400) {
                priority = .attention; reason = "近 30 天邮件包含「\(keyword)」，请核对是否仍需处理"
            } else {
                priority = .historical; reason = "较早邮件包含「\(keyword)」，未当作当前待办；请按需核对"
            }
        } else {
            priority = .normal; reason = "未命中处理关键词"
        }
        let summary = extractSummary(body, fallback: mail.displaySubject, keywords: actionKeywords)
        return MailAnalysis(category: category, priority: priority, summary: summary, reason: reason, dateHint: explicitDate(in: mail.subject + " " + body))
    }

    static func extractSummary(_ text: String, fallback: String, keywords: [String]) -> String {
        let lines = MailText.readableMarkdown(text).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") && !$0.lowercased().hasPrefix("unsubscribe") }
        guard !lines.isEmpty else { return String(fallback.prefix(220)) }
        var selected = [lines[0]]
        if let action = lines.dropFirst().first(where: { line in keywords.contains { !$0.isEmpty && line.localizedCaseInsensitiveContains($0) } }), action != selected[0] {
            selected.append(action)
        } else if lines.count > 1 { selected.append(lines[1]) }
        return String(selected.joined(separator: " · ").prefix(260))
    }

    /// Only explicit YYYY-MM-DD dates become hints. Never invent a deadline from relative prose.
    static func explicitDate(in text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])([12][0-9]{3})[-/年]([0-9]{1,2})[-/月]([0-9]{1,2})(?:日)?(?![0-9])") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
            guard parts.count == 3 else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9)
            guard let date = calendar.date(from: components) else { continue }
            let actual = calendar.dateComponents([.year, .month, .day], from: date)
            if actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2] { return date }
        }
        return nil
    }
}

@MainActor
final class MailStore: ObservableObject {
    @Published private(set) var messages: [MailItem] = []
    @Published private(set) var folders: [MailFolder] = []
    @Published private(set) var snapshot: MailSnapshot?
    @Published private(set) var statusText = "尚未载入 Outlook 邮件"
    @Published var errorMessage: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var actionKeywords: [String]
    @Published private(set) var analyses: [String: MailAnalysis] = [:]

    let snapshotURL: URL
    private let preferencesURL: URL
    private let syncHandler: (@Sendable (String) async throws -> MailSnapshot)?

    init(rootURL: URL? = nil, syncHandler: (@Sendable (String) async throws -> MailSnapshot)? = nil) {
        let envRoot = ProcessInfo.processInfo.environment["STASHCAT_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let root = rootURL ?? envRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StashCat", isDirectory: true)
        snapshotURL = root.appendingPathComponent("outlook-mailbox.json")
        preferencesURL = root.appendingPathComponent("outlook-rules.json")
        self.syncHandler = syncHandler
        actionKeywords = (try? Data(contentsOf: preferencesURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? MailClassifier.defaultActionKeywords
        reloadSnapshot()
    }

    var unreadCount: Int { messages.filter { !$0.isRead }.count }
    var attentionCount: Int { messages.filter { analysis(for: $0).priority == .attention }.count }
    var historicalCount: Int { messages.filter { analysis(for: $0).priority == .historical }.count }
    var accountEmail: String { snapshot?.accountEmail ?? "" }
    var syncedAt: Date? { snapshot.flatMap { MailDates.parse($0.syncedAt) } }
    var coverageText: String {
        guard let snapshot else { return "连接 Outlook 后可整理邮件" }
        if !snapshot.folderErrors.isEmpty { return "\(messages.count) 封 · \(folders.count) 个文件夹 · 有覆盖差异" }
        return "\(messages.count) 封 · \(folders.count) 个文件夹 · \(snapshot.complete ? "已遍历可访问文件夹" : "部分邮件")"
    }
    var sourceText: String { snapshot?.source ?? "导入的 Outlook 快照" }

    func analysis(for item: MailItem) -> MailAnalysis { analyses[item.id] ?? MailClassifier.analyze(item, actionKeywords: actionKeywords) }

    func filtered(_ filter: MailFilter) -> [MailItem] {
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.filter { item in
            let analysis = analysis(for: item)
            return (filter.category == nil || analysis.category == filter.category)
                && (filter.folderID == nil || item.folderID == filter.folderID)
                && (filter.priority == nil || analysis.priority == filter.priority)
                && (!filter.unreadOnly || !item.isRead)
                && (!filter.attachmentsOnly || item.hasAttachments)
                && (query.isEmpty || [item.subject, item.senderName, item.senderAddress, item.bodyPreview, item.bodyText ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var attentionItems: [MailItem] {
        messages.filter { analysis(for: $0).priority == .attention }
            .sorted { a, b in a.isRead != b.isRead ? !a.isRead : a.receivedDateTime > b.receivedDateTime }
    }

    func dateHintItems(now: Date = Date()) -> [MailItem] {
        let start = Calendar.current.startOfDay(for: now)
        return messages.filter { item in
            guard let date = analysis(for: item).dateHint else { return false }
            let priority = analysis(for: item).priority
            return date >= start && (priority == .attention || priority == .normal)
                && (item.receivedAt ?? .distantPast) >= now.addingTimeInterval(-30 * 86_400)
        }.sorted { analysis(for: $0).dateHint! < analysis(for: $1).dateHint! }
    }

    var digestText: String {
        guard !messages.isEmpty else { return "尚无可整理的邮件。" }
        let groups = Dictionary(grouping: messages) { analysis(for: $0).category }
        let categories = MailCategory.allCases.compactMap { category -> String? in
            guard let count = groups[category]?.count, count > 0 else { return nil }
            return "\(category.title) \(count) 封"
        }.joined(separator: "；")
        var lines = ["已整理 \(messages.count) 封，未读 \(unreadCount) 封。", categories + "。",
                     "近 30 天可能需处理 \(attentionCount) 封；历史待核对 \(historicalCount) 封。依据文字规则，需核对原文。"]
        for item in attentionItems.prefix(6) {
            lines.append("• \(item.displaySubject)\n  \(analysis(for: item).summary)")
        }
        return lines.joined(separator: "\n\n")
    }

    func reloadSnapshot() {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        do {
            let data = try Data(contentsOf: snapshotURL)
            guard data.count <= 256_000_000 else { throw MailError.invalidSnapshot }
            let decoded = try JSONDecoder().decode(MailSnapshot.self, from: data)
            try validate(decoded)
            apply(decoded)
            errorMessage = nil
        } catch {
            errorMessage = "Outlook 快照未能读取；原文件与已载入邮件保留。\(error.localizedDescription)"
        }
    }

    /// Called only after the user asks to refresh. Never requests access during launch.
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true; errorMessage = nil; statusText = "正在通过 Outlook 只读连接刷新…"
        defer { isSyncing = false }
        do {
            let updated: MailSnapshot
            if let syncHandler { updated = try await syncHandler(accountEmail) }
            else { updated = try await OutlookBridge.fetch(accountEmail: accountEmail) { [weak self] in self?.statusText = $0 } }
            try validate(updated)
            if !accountEmail.isEmpty && updated.accountEmail.caseInsensitiveCompare(accountEmail) != .orderedSame { throw MailError.accountMismatch }
            if updated.messages.isEmpty && !messages.isEmpty { throw MailError.emptyRefresh }
            try persist(updated)
            apply(updated)
        } catch {
            statusText = snapshot == nil ? "Outlook 连接尚未完成" : "保留上次整理结果 · 刷新未完成"
            errorMessage = error.localizedDescription
        }
    }

    func importSnapshot(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 256_000_000 else { throw MailError.invalidSnapshot }
            let updated = try JSONDecoder().decode(MailSnapshot.self, from: data)
            try validate(updated)
            try persist(updated)
            apply(updated)
            errorMessage = nil
        } catch { errorMessage = "未导入：\(error.localizedDescription)" }
    }

    func updateActionKeywords(_ value: String) {
        let keywords = Array(Set(value.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 80 })).sorted()
        do {
            try writePrivate(JSONEncoder().encode(keywords), to: preferencesURL)
            actionKeywords = keywords
            rebuildAnalyses()
            errorMessage = nil
        } catch { errorMessage = "处理关键词未保存，请检查文件权限。" }
    }

    private func validate(_ value: MailSnapshot) throws {
        guard value.version == 1, !value.accountEmail.isEmpty, MailDates.parse(value.syncedAt) != nil,
              value.messages.allSatisfy({ !$0.id.isEmpty }), value.folders.allSatisfy({ !$0.id.isEmpty }) else { throw MailError.invalidSnapshot }
    }

    private func apply(_ value: MailSnapshot) {
        snapshot = value
        folders = value.folders.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var seen = Set<String>()
        messages = value.messages.filter { seen.insert($0.id).inserted }
            .sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }
        rebuildAnalyses()
        statusText = "Outlook 已整理 · \(messages.count) 封"
    }

    private func rebuildAnalyses() {
        analyses = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, MailClassifier.analyze($0, actionKeywords: actionKeywords)) })
    }

    private func persist(_ value: MailSnapshot) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(value), to: snapshotURL)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum MailError: LocalizedError {
    case invalidSnapshot, accountMismatch, emptyRefresh
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "邮件快照格式不兼容或内容不完整。"
        case .accountMismatch: return "刷新返回了另一个账号，已保留现有邮件。请在 Outlook 中选择相同账号。"
        case .emptyRefresh: return "Outlook 未返回邮件，已保留上次快照；请检查账号、权限及 Outlook 版本的接口支持。"
        }
    }
}
