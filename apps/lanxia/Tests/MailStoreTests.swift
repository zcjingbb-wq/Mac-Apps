import AppKit
import Foundation

@main
enum MailStoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }

    static let now = MailDates.parse("2026-10-19T04:00:00Z")!
    static func item(id: String = "1", subject: String = "Please confirm interview", body: String = "Please confirm your interview on 2026-10-25.\nBring the application form.", date: String = "2026-10-18T04:00:00Z", folder: String = "Inbox", read: Bool = false, attachment: Bool = false, link: String = "https://outlook.live.com/mail/0/id/test") -> MailItem {
        MailItem(id: id, subject: subject, senderName: "Example sender", senderAddress: "sender@example.invalid", receivedDateTime: date,
                 isRead: read, hasAttachments: attachment, bodyPreview: String(body.prefix(80)), bodyText: body, webLink: link, folderID: folder, folderPath: folder)
    }
    static func snapshot(_ messages: [MailItem], account: String = "test@example.invalid", version: Int = 1) -> MailSnapshot {
        MailSnapshot(version: version, accountEmail: account, syncedAt: "2026-10-19T04:00:00Z", source: "test fixture", complete: true,
                     folders: [MailFolder(id: "Inbox", name: "Inbox", path: "Inbox", totalItemCount: messages.count)], messages: messages, folderErrors: [])
    }

    @MainActor
    static func main() async throws {
        let recent = item()
        let analysis = MailClassifier.analyze(recent, now: now)
        check(analysis.category == .education, "education classification")
        check(analysis.priority == .attention, "recent explicit action")
        check(analysis.summary.contains("confirm"), "extract actually present source text")
        check(analysis.dateHint != nil, "explicit full date hint")
        check(MailClassifier.explicitDate(in: "2026-02-30") == nil, "reject invalid calendar date")
        check(MailClassifier.explicitDate(in: "tomorrow morning") == nil, "do not infer relative deadlines")
        check(MailClassifier.analyze(item(date: "2024-01-01T00:00:00Z"), now: now).priority == .historical, "old actions stay historical")
        let marketing = item(subject: "University newsletter", body: "Application deadline soon, please confirm. Unsubscribe.")
        check(MailClassifier.analyze(marketing, now: now).priority == .low, "marketing deadline not active action")
        let legitimate = item(subject: "Action required: application incomplete", body: "University admissions: please submit missing documents before the deadline.\nUnsubscribe from future news.")
        check(MailClassifier.analyze(legitimate, now: now).priority == .attention, "university action with unsubscribe footer remains visible")
        let navigation = item(subject: "University admissions information", body: "Read the guide at https://example.invalid/admissions/deadlines/?campaign=info for further information.")
        check(MailClassifier.analyze(navigation, now: now).priority == .normal, "URL path deadline is not a request")
        let bareNavigation = item(subject: "University admissions information", body: "Read example.invalid/admissions/deadlines for information.")
        check(MailClassifier.analyze(bareNavigation, now: now).priority == .normal, "bare website path deadline is not a request")
        let immersion = item(subject: "Get the highest-quality English language immersion", body: "See the university course deadline and special program.")
        check(MailClassifier.analyze(immersion, now: now).priority == .low, "immersion promotional subject is low priority")
        let registration = item(subject: "Spring SAT Registration Is Now Open", body: "Sign up for a spring SAT date before the deadline.")
        check(MailClassifier.analyze(registration, now: now).priority == .low, "SAT registration announcement is not a user-specific action")
        let code = item(subject: "Verification code", body: "Please confirm using your one-time code: SAMPLE")
        check(MailClassifier.analyze(code, now: now).priority == .low, "one-time code not lasting todo")
        check(MailClassifier.analyze(item(folder: "Sent Items"), now: now).category == .sent, "sent origin is authoritative")
        check(MailClassifier.analyze(item(folder: "Junk Email"), now: now).priority == .low, "junk origin is low")
        check(recent.safeWebURL != nil, "real Outlook web link")
        check(item(link: "file:///tmp/private").safeWebURL == nil, "block local file links")
        check(item(link: "javascript:alert(1)").safeWebURL == nil, "block script links")
        check(item(link: "https://outlook.live.com.attacker.invalid/").safeWebURL == nil, "block lookalike domains")
        check(item(link: "https://example.invalid/").safeWebURL == nil, "block imported arbitrary domains")
        let html = "<html><head><style>secret</style></head><body><p>Hello &amp; &#x4E16;&#30028;</p><script>hidden()</script><img src='https://tracker.invalid/pixel'><p>Next<br>Line</p></body></html>"
        let plain = MailText.plainText(html, isHTML: true)
        check(plain.contains("Hello & 世界"), "HTML entities decoded to plain text")
        check(!plain.contains("hidden") && !plain.contains("tracker") && !plain.contains("secret"), "no script style tracking markup")
        check(plain.contains("Next\nLine"), "HTML paragraph breaks")
        check(MailText.plainText("x < 3", isHTML: false) == "x < 3", "plain body preserved")
        let receiptMarkdown = "| | ![Apple](https://example.invalid/logo.png) | 收据 |\n---|---|---|---\n| 订单总额 | ¥99.00 | 付款日期 | 2026-10-19 |\n感谢您的购买。"
        let receiptSummary = MailClassifier.extractSummary(receiptMarkdown, fallback: "Receipt", keywords: [])
        check(receiptSummary.contains("收据") && receiptSummary.contains("¥99.00") && receiptSummary.contains("2026-10-19") && !receiptSummary.contains("https:") && !receiptSummary.contains("---") && !receiptSummary.contains("!["), "receipt excerpt removes decoration and keeps amounts and dates")
        let universityMarkdown = "\u{200B}\u{200C}\n| | [![University logo](https://example.invalid/long-logo.png)](https://example.invalid/home) | |\n|---|---|---|---|\nPlease [submit your documents](https://example.invalid/upload) by **2026-10-25**.\nYour reference is APPLICATION-123."
        let universityMail = item(body: universityMarkdown)
        let readable = universityMail.plainBody
        check(readable.contains("submit your documents") && readable.contains("2026-10-25") && readable.contains("APPLICATION-123") && !readable.contains("https:") && !readable.contains("\u{200B}") && universityMail.bodyText == universityMarkdown, "readable full body retains substance and unchanged original source")
        let multilineMarkdown = "| | [![College\nBoard](https://example.invalid/logo-\nlong.png)](https://example.invalid/home-\nevent) |\n| [Register\nNow](https://example.invalid/register-\nevTS123) | 2026-11-01 | $60 |\n|---|---|---|"
        let multilineReadable = MailText.readableMarkdown(multilineMarkdown)
        check(multilineReadable.contains("Register Now") && multilineReadable.contains("2026-11-01") && multilineReadable.contains("$60") && !multilineReadable.contains("College") && !multilineReadable.contains("https:") && !multilineReadable.contains("evTS123") && !multilineReadable.contains("[") && !multilineReadable.hasPrefix("|"), "multiline linked logos and wrapped URL targets are removed while labels and table values remain")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-mail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = snapshot([recent, item(id: "2", subject: "Receipt", body: "Order confirmation", read: true, attachment: true)])
        let store = MailStore(rootURL: root, syncHandler: { _ in initial })
        check(store.messages.isEmpty, "fresh store does not invent emails")
        await store.sync()
        check(store.messages.count == 2, "successful real structure loads")
        check(!store.isSyncing, "sync state settles")
        check(store.unreadCount == 1, "unread count")
        check(store.filtered(MailFilter(unreadOnly: true)).count == 1, "unread filter")
        check(store.filtered(MailFilter(attachmentsOnly: true)).count == 1, "attachment filter")
        check(store.filtered(MailFilter(query: "receipt")).count == 1, "case insensitive subject search")
        check(store.filtered(MailFilter(query: "application form")).count == 1, "full plain body search")
        check(store.filtered(MailFilter(category: .finance)).count == 1, "category filter")
        let mode = (try FileManager.default.attributesOfItem(atPath: store.snapshotURL.path)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "mail snapshot private mode")
        let reloaded = MailStore(rootURL: root)
        check(reloaded.messages.count == 2 && reloaded.messages[0].id == recent.id, "relaunch keeps messages")
        let original = try Data(contentsOf: store.snapshotURL)
        let mismatch = MailStore(rootURL: root, syncHandler: { _ in snapshot([item(id: "new")], account: "different@example.invalid") })
        await mismatch.sync()
        check(mismatch.messages.count == 2 && mismatch.errorMessage != nil, "account mismatch preserves old data")
        let afterMismatch = try Data(contentsOf: store.snapshotURL)
        check(afterMismatch == original, "account mismatch does not write disk")
        let failing = MailStore(rootURL: root, syncHandler: { _ in throw MailError.invalidSnapshot })
        await failing.sync()
        check(failing.messages.count == 2 && !failing.isSyncing && failing.errorMessage != nil, "network/format failure preserves snapshot")
        let empty = MailStore(rootURL: root, syncHandler: { _ in snapshot([]) })
        await empty.sync()
        check(empty.messages.count == 2 && empty.errorMessage != nil, "empty unsupported refresh does not clear mailbox")
        try Data("invalid".utf8).write(to: store.snapshotURL)
        store.reloadSnapshot()
        check(store.messages.count == 2 && store.errorMessage != nil, "corrupt disk file preserves in-memory data")
        let corruptData = try Data(contentsOf: store.snapshotURL)
        check(corruptData == Data("invalid".utf8), "corrupt file not destroyed")
        store.updateActionKeywords("banana, 香蕉\nbanana")
        check(store.actionKeywords == ["banana", "香蕉"], "configurable keywords trimmed and deduplicated")
        check(store.analysis(for: recent).priority == .normal, "rules change classification")
        print("MailStore: \(checks) checks passed")
    }
}
