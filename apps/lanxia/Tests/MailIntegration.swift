import Foundation

/// Explicitly invoked live, read-only integration. Never prints subjects, senders or bodies.
@main
enum MailIntegration {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.contains("--live") else { print("Mail integration skipped (pass --live to access the connected Outlook account)."); return }
        let snapshot = try await OutlookBridge.fetch(accountEmail: "") { print($0) }
        guard !snapshot.messages.isEmpty, !snapshot.folders.isEmpty else { fatalError("Live Outlook returned no mailbox data") }
        let unread = snapshot.messages.filter { !$0.isRead }.count
        let fullBodies = snapshot.messages.filter(\.hasFullBody).count
        print("LIVE_OUTLOOK_OK messages=\(snapshot.messages.count) folders=\(snapshot.folders.count) unread=\(unread) fullBodies=\(fullBodies) coverageWarnings=\(snapshot.folderErrors.count)")
        print("Read-only endpoints: get_profile, list_mail_folders, list_messages. No inference turns; no OAuth credentials exported.")
    }
}
