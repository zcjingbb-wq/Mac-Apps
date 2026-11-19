import Foundation
import UserNotifications

private enum ReminderTestError: Error { case failed(String), notificationsUnavailable }

@MainActor
private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
private final class FakeReminderScheduler: ReminderNotificationScheduling {
    var snapshot = ReminderAuthorizationSnapshot(status: .notDetermined)
    var requests = 0
    var reads = 0
    var failScheduling = false
    var scheduled: [ReminderItem] = []
    var pauseNext = false
    var continuation: CheckedContinuation<Void, Never>?
    var pauseAuthorization = false
    var authorizationContinuation: CheckedContinuation<Void, Never>?
    var onOpen: (@MainActor (UUID) -> Void)?
    func configure(onOpen: @escaping @MainActor (UUID) -> Void) { self.onOpen = onOpen }
    func authorization() async -> ReminderAuthorizationSnapshot { reads += 1; return snapshot }
    func requestAuthorization() async throws {
        requests += 1
        if pauseAuthorization {
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        snapshot = .init(status: .authorized, alertsEnabled: true, soundsEnabled: true)
    }
    func replaceAll(with items: [ReminderItem], now: Date) async throws {
        if failScheduling { throw ReminderTestError.notificationsUnavailable }
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { continuation = $0 }
        }
        scheduled = items
    }
}

@main
struct ReminderStoreTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("StashCatReminderTests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let initial = ISO8601DateFormatter().date(from: "2026-10-19T03:00:00Z")!
        let clock = TestClock(initial)
        let fake = FakeReminderScheduler()
        let store = ReminderStore(root: root, scheduler: fake, now: { clock.date })
        try require(store.items.isEmpty && fake.requests == 0, "Initialization must never ask for permission")
        await store.start()
        try require(fake.requests == 0 && fake.reads == 1, "Launch may read permission; it must not request it")
        try require(store.authorization.status == .notDetermined, "Read permission state must be visible")

        for (title, date, notes) in [("  \n", initial.addingTimeInterval(60), ""), ("past", initial.addingTimeInterval(-1), ""), (String(repeating: "x", count: 121), initial.addingTimeInterval(60), ""), ("long note", initial.addingTimeInterval(60), String(repeating: "n", count: 1001))] {
            do {
                try await store.add(title: title, notes: notes, date: date)
                throw ReminderTestError.failed("Invalid input should have failed")
            } catch is ReminderTestError { throw ReminderTestError.failed("Invalid input was accepted") }
            catch { }
        }
        try require(store.items.isEmpty, "Invalid reminders must not alter state")
        let once = try await store.add(title: "  提交作业 \n", notes: " 保留说明 ", date: initial.addingTimeInterval(60))
        try require(once.title == "提交作业" && once.notes == "保留说明", "Input should trim surrounding whitespace")
        try require(fake.scheduled.isEmpty, "Unapproved notification permission must not schedule alerts")
        try require(store.upcoming.count == 1 && store.completed.isEmpty, "Reminder should be active")
        try require(once.notificationID.hasPrefix("StashCat.reminder.") && Set(once.notificationIDs).count == 2, "Notification identifiers must be stable and scoped")
        let savedMode = try fm.attributesOfItem(atPath: store.storageURL.path)[.posixPermissions] as? NSNumber
        try require(savedMode?.intValue == 0o600, "Saved reminder notes must be owner-only readable and writable")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.storageURL.path)
        let reloaded = ReminderStore(root: root, scheduler: FakeReminderScheduler(), now: { clock.date })
        try require(reloaded.items == store.items, "Atomic JSON state must survive a fresh store")
        let repairedMode = try fm.attributesOfItem(atPath: store.storageURL.path)[.posixPermissions] as? NSNumber
        try require(repairedMode?.intValue == 0o600, "Loading an older reminder file must tighten permissions without changing its contents")
        store.prepareDraft(title: "邮件事项", notes: "用户确认时间后再添加")
        try require(store.pendingDraft?.title == "邮件事项" && store.items == [once], "Mail drafts must prefill a form without scheduling")
        store.clearDraft()
        try require(store.pendingDraft == nil, "Applied draft should be consumed")
        NotificationCenter.default.post(name: .init("StashCatPrepareReminder"), object: nil, userInfo: ["title": "从邮件准备提醒", "notes": "审阅后再添加"])
        for _ in 0..<20 where store.pendingDraft == nil { await Task.yield() }
        try require(store.pendingDraft?.title == "从邮件准备提醒" && store.items == [once], "Draft notification must work before reminder tab exists without auto-saving")
        store.clearDraft()
        let originalData = try Data(contentsOf: store.storageURL)
        try require(!originalData.isEmpty, "Persistent JSON should exist")

        var opened: UUID?
        store.onOpen = { opened = $0 }
        fake.onOpen?(once.id)
        try require(opened == once.id, "Notification clicks should route to root panel callback")
        fake.pauseAuthorization = true
        let authorizationTask = Task { await store.requestAuthorization() }
        for _ in 0..<100 where fake.authorizationContinuation == nil { await Task.yield() }
        try require(store.isRequestingAuthorization && fake.authorizationContinuation != nil, "Pending authorization must be visible")
        await store.requestAuthorization()
        try require(fake.requests == 1, "Repeated clicks must not start duplicate pending authorization requests")
        fake.authorizationContinuation?.resume()
        fake.authorizationContinuation = nil
        fake.pauseAuthorization = false
        await authorizationTask.value
        try require(!store.isRequestingAuthorization, "Returned authorization should clear pending state")
        try require(fake.requests == 1 && store.authorization.canSchedule, "Only explicit enable should request permission")
        try require(fake.scheduled == [once], "Authorization should schedule persisted reminders")
        var announcements: [UUID] = []
        store.onDue = { announcements.append($0.id) }
        clock.date = initial.addingTimeInterval(61)
        store.checkDue()
        store.checkDue()
        try require(store.dueCount == 1 && announcements == [once.id], "Due fallback must announce once per occurrence")
        await store.snooze(once)
        let snoozed = store.items.first { $0.id == once.id }!
        try require(snoozed.dueDate == clock.date.addingTimeInterval(600) && store.dueCount == 0, "Snooze should move this occurrence ten minutes forward")
        clock.date = snoozed.dueDate.addingTimeInterval(1)
        store.checkDue()
        try require(announcements == [once.id, once.id], "A snoozed occurrence should announce when its new time arrives")
        await store.complete(snoozed)
        try require(store.completed.count == 1 && store.upcoming.isEmpty && fake.scheduled.isEmpty, "Completing one-off should persist completion and cancel notification")
        try require(ReminderStore(root: root, scheduler: FakeReminderScheduler(), now: { clock.date }).completed.count == 1, "Completion should survive reload")

        let farFuture = clock.date.addingTimeInterval(60 * 60 * 24 * 30)
        let daily = try await store.add(title: "喝水", date: farFuture, recurrence: .daily)
        try require(daily.scheduledDate > clock.date && daily.scheduledDate.timeIntervalSince(clock.date) <= 24 * 3600 + 60, "Daily should begin at next matching time, regardless of selected date")
        try require(daily.recurringComponents.day == nil && daily.recurringComponents.hour != nil && daily.recurringComponents.second == 0, "Daily trigger must contain time fields without a calendar date")
        let weekly = try await store.add(title: "每周复盘", date: farFuture, recurrence: .weekly)
        try require(weekly.scheduledDate > clock.date && weekly.scheduledDate.timeIntervalSince(clock.date) <= 7 * 24 * 3600 + 60, "Weekly should begin at next matching weekday/time")
        try require(weekly.recurringComponents.weekday != nil && weekly.recurringComponents.day == nil, "Weekly trigger must use weekday rather than absolute date")
        clock.date = daily.scheduledDate.addingTimeInterval(2)
        store.checkDue()
        await store.snooze(daily)
        let dailySnooze = store.items.first { $0.id == daily.id }!
        try require(dailySnooze.scheduledDate == daily.scheduledDate && dailySnooze.snoozedUntil != nil, "Snooze must retain normal daily cadence")
        await store.complete(dailySnooze)
        let dailyAdvanced = store.items.first { $0.id == daily.id }!
        try require(dailyAdvanced.completedAt == nil && dailyAdvanced.snoozedUntil == nil && dailyAdvanced.scheduledDate > clock.date, "Completing recurring should advance rather than stop the series")
        try require(dailyAdvanced.recurringComponents.hour == daily.recurringComponents.hour && dailyAdvanced.recurringComponents.minute == daily.recurringComponents.minute, "Recurrence completion must retain wall-clock time")
        await store.remove(weekly)
        try require(!store.items.contains { $0.id == weekly.id } && !fake.scheduled.contains { $0.id == weekly.id }, "Removing a series must remove active schedule")

        fake.snapshot = .init(status: .denied)
        await store.refreshAuthorization()
        try require(fake.requests == 1 && fake.scheduled.isEmpty && store.permissionStatus.contains("关闭"), "Denial refresh should cancel schedules without prompting again")
        let denied = try await store.add(title: "关闭通知仍保存", date: clock.date.addingTimeInterval(60))
        clock.date = denied.dueDate.addingTimeInterval(1)
        store.checkDue()
        try require(announcements.contains(denied.id) && store.due.contains { $0.id == denied.id }, "Permission denial must retain in-app due fallback")
        fake.snapshot = .init(status: .authorized, alertsEnabled: true)
        fake.failScheduling = true
        await store.refreshAuthorization()
        let failedAlert = try await store.add(title: "系统故障也保留", date: clock.date.addingTimeInterval(60))
        try require(store.items.contains { $0.id == failedAlert.id } && store.errorMessage?.contains("排程失败") == true, "Scheduler failure must preserve data and surface honest warning")

        fake.failScheduling = false
        fake.pauseNext = true
        let overlappingRefresh = Task { await store.refreshAuthorization() }
        for _ in 0..<100 where fake.continuation == nil { await Task.yield() }
        try require(fake.continuation != nil, "Test scheduler should pause at an await point")
        await store.remove(failedAlert)
        fake.continuation?.resume()
        fake.continuation = nil
        await overlappingRefresh.value
        try require(!fake.scheduled.contains { $0.id == failedAlert.id }, "An overlapping permission refresh must not resurrect a removed notification")

        // A DST spring gap must preserve the minute, not drift every subsequent day.
        let iso = ISO8601DateFormatter()
        let dst = ReminderItem(id: UUID(), title: "DST", notes: "", createdAt: initial,
                               scheduledDate: iso.date(from: "2026-03-07T07:30:00Z")!, recurrence: .daily,
                               timeZoneIdentifier: "America/New_York")
        let nextDST = dst.nextOccurrence(after: iso.date(from: "2026-03-08T06:00:00Z")!)!
        try require(nextDST == iso.date(from: "2026-03-08T07:30:00Z")!, "A missing 02:30 should become 03:30 on DST transition day")
        let afterDST = dst.nextOccurrence(after: nextDST)!
        try require(afterDST == iso.date(from: "2026-03-09T06:30:00Z")!, "Normal days should return to 02:30 local time")

        let corruptRoot = root.appendingPathComponent("corrupt", isDirectory: true)
        try fm.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptURL = corruptRoot.appendingPathComponent("reminders.json")
        let corruptData = Data("{broken old reminders".utf8)
        try corruptData.write(to: corruptURL)
        let corrupt = ReminderStore(root: corruptRoot, scheduler: FakeReminderScheduler(), now: { clock.date })
        try require(corrupt.errorMessage != nil, "Unreadable state must be visible")
        do {
            try await corrupt.add(title: "不能覆盖原件", date: clock.date.addingTimeInterval(60))
            throw ReminderTestError.failed("Corrupt state should prevent writes")
        } catch is ReminderTestError { throw ReminderTestError.failed("Corrupt state was overwritten") }
        catch { }
        try require(try Data(contentsOf: corruptURL) == corruptData, "Corrupt source must not be overwritten")

        print("PASS: no automatic permission prompt, pending authorization feedback/deduplication, input validation, stable IDs, atomic reload, owner-only permissions and legacy-mode repair, click routing, permission enable/denial, due deduplication, snooze, one-off completion, daily/weekly recurrence, removal, scheduler-failure fallback, overlapping refresh/removal, mail drafts, DST, corrupt-state protection")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ReminderTestError.failed(message) }
    }
}
