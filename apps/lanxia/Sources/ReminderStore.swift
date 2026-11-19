import AppKit
import Combine
import Foundation
import UserNotifications

enum ReminderRecurrence: String, Codable, CaseIterable, Identifiable, Sendable {
    case once, daily, weekly
    var id: String { rawValue }
    var title: String {
        switch self { case .once: "仅一次"; case .daily: "每天"; case .weekly: "每周" }
    }
}

struct ReminderItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var notes: String
    let createdAt: Date
    /// First unacknowledged occurrence. Repeating reminders keep their original wall-clock cadence.
    var scheduledDate: Date
    let recurrence: ReminderRecurrence
    let timeZoneIdentifier: String
    var completedAt: Date?
    var snoozedUntil: Date?

    var dueDate: Date { snoozedUntil ?? scheduledDate }
    var isCompleted: Bool { completedAt != nil }
    var notificationID: String { "StashCat.reminder." + id.uuidString }
    var notificationIDs: [String] { [notificationID, notificationID + ".snooze"] }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    /// Omitting date fields gives the system a true daily/weekly repeating trigger.
    var recurringComponents: DateComponents {
        let fields: Set<Calendar.Component> = recurrence == .weekly ? [.weekday, .hour, .minute] : [.hour, .minute]
        var result = calendar.dateComponents(fields, from: scheduledDate)
        result.calendar = calendar
        result.timeZone = calendar.timeZone
        result.second = 0
        return result
    }

    func nextOccurrence(after date: Date) -> Date? {
        guard recurrence != .once else { return nil }
        return calendar.nextDate(after: date, matching: recurringComponents,
                                 matchingPolicy: .nextTimePreservingSmallerComponents,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
}

struct ReminderAuthorizationSnapshot: Sendable, Equatable {
    enum Status: Sendable { case notDetermined, denied, authorized, provisional, unavailable }
    let status: Status
    var alertsEnabled = false
    var soundsEnabled = false
    var canSchedule: Bool { status == .authorized || status == .provisional }
}

@MainActor
protocol ReminderNotificationScheduling: AnyObject {
    func configure(onOpen: @escaping @MainActor (UUID) -> Void)
    func authorization() async -> ReminderAuthorizationSnapshot
    func requestAuthorization() async throws
    func replaceAll(with items: [ReminderItem], now: Date) async throws
}

private enum ReminderError: LocalizedError {
    case invalidTitle, invalidDate, tooLong, invalidIndex, locked, busy
    var errorDescription: String? {
        switch self {
        case .invalidTitle: "请先填写提醒标题。"
        case .invalidDate: "请选择至少 5 秒以后的时间。重复提醒会从下次匹配的时刻开始。"
        case .tooLong: "标题最多 120 个字，备注最多 1000 个字。"
        case .invalidIndex: "日程清单内容不完整或格式不正确，原文件已保留。"
        case .locked: "日程清单暂时无法修改，请先备份并检查 reminders.json。"
        case .busy: "正在保存上一项日程，请稍后再试。"
        }
    }
}

struct ReminderDraft: Identifiable {
    let id = UUID()
    let title: String
    let notes: String
}

private struct ReminderIndex: Codable { let version: Int; let items: [ReminderItem] }

@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var permissionStatus = "正在检查通知权限…"
    @Published private(set) var authorization = ReminderAuthorizationSnapshot(status: .notDetermined)
    @Published private(set) var statusText = "日程保存在这台 Mac 上"
    @Published private(set) var currentDate: Date
    @Published private(set) var isBusy = false
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var authorizationHint: String?
    @Published var errorMessage: String?
    @Published private(set) var pendingDraft: ReminderDraft?
    /// Observers can react to due items independently of system notification permission.
    var onDue: (@MainActor (ReminderItem) -> Void)?
    /// Open the existing companion panel's reminders tab when a notification is clicked.
    var onOpen: (@MainActor (UUID) -> Void)? {
        didSet {
            if let callback = onOpen, let id = pendingOpenID {
                pendingOpenID = nil
                callback(id)
            }
        }
    }

    let storageURL: URL
    private let scheduler: any ReminderNotificationScheduling
    private let clock: () -> Date
    private var canMutate = true
    private var started = false
    private var pendingOpenID: UUID?
    private var timerTask: Task<Void, Never>?
    private var authorizationWaitTask: Task<Void, Never>?
    private var draftObserver: NSObjectProtocol?
    private var announced: [UUID: Date] = [:]
    private var isSyncing = false
    private var needsSync = false

    var upcoming: [ReminderItem] { items.filter { !$0.isCompleted }.sorted { $0.dueDate < $1.dueDate } }
    var completed: [ReminderItem] { items.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }
    var due: [ReminderItem] { upcoming.filter { $0.dueDate <= currentDate } }
    var dueCount: Int { due.count }

    init(root: URL? = nil, scheduler: (any ReminderNotificationScheduling)? = nil, now: @escaping () -> Date = Date.init) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = root ?? support.appendingPathComponent("StashCat", isDirectory: true)
        storageURL = folder.appendingPathComponent("reminders.json")
        self.scheduler = scheduler ?? SystemReminderScheduler()
        clock = now
        currentDate = now()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: storageURL.path) {
                // Existing notes may contain private mail context; repair older permissive modes.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
                let index = try JSONDecoder().decode(ReminderIndex.self, from: Data(contentsOf: storageURL))
                guard index.version == 1, Set(index.items.map(\.id)).count == index.items.count,
                      index.items.allSatisfy(Self.isValid) else { throw ReminderError.invalidIndex }
                items = index.items
            }
        } catch {
            canMutate = false
            errorMessage = "未能读取日程，已暂停修改以保护原清单。\n\(error.localizedDescription)\n位置：\(storageURL.path)"
        }
        updateStatus()
        // Attach before didFinishLaunching so a cold-start notification click is not lost.
        self.scheduler.configure { [weak self] id in
            guard let self else { return }
            if let callback = self.onOpen { callback(id) }
            else { self.pendingOpenID = id }
        }
        // Listen at store level so a mail -> reminder draft is retained even before its tab mounts.
        draftObserver = NotificationCenter.default.addObserver(forName: .init("StashCatPrepareReminder"), object: nil, queue: .main) { [weak self] notification in
            guard let title = notification.userInfo?["title"] as? String else { return }
            let notes = notification.userInfo?["notes"] as? String ?? ""
            Task { @MainActor [weak self] in self?.prepareDraft(title: title, notes: notes) }
        }
    }

    deinit {
        timerTask?.cancel()
        authorizationWaitTask?.cancel()
        if let draftObserver { NotificationCenter.default.removeObserver(draftObserver) }
    }

    /// Prepares an editable form; it deliberately does not add or schedule a reminder.
    func prepareDraft(title: String, notes: String = "") {
        pendingDraft = ReminderDraft(title: String(title.prefix(120)), notes: String(notes.prefix(1000)))
    }

    func clearDraft() { pendingDraft = nil }

    /// Safe to call at launch. This checks settings; it never asks for notification permission.
    func start() async {
        guard !started else { return }
        started = true
        await refreshAuthorization()
        checkDue()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                self.checkDue()
            }
        }
    }

    func refreshAuthorization() async {
        authorization = await scheduler.authorization()
        if authorization.status != .notDetermined {
            isRequestingAuthorization = false
            authorizationHint = nil
            authorizationWaitTask?.cancel()
            authorizationWaitTask = nil
        }
        switch authorization.status {
        case .notDetermined:
            permissionStatus = isRequestingAuthorization
                ? "等待 macOS 通知选择 · 可刷新状态或打开通知设置"
                : "尚未开启系统通知 · 可在菜单栏查看到期事项"
        case .denied: permissionStatus = "系统通知已关闭 · 可在菜单栏查看到期事项"
        case .authorized:
            permissionStatus = authorization.alertsEnabled ? "系统通知已开启" : "通知已授权 · 请在系统设置中开启横幅"
        case .provisional: permissionStatus = "静默通知已开启 · 可在系统设置中启用横幅"
        case .unavailable: permissionStatus = "系统通知暂不可用 · 可在菜单栏查看到期事项"
        }
        await syncNotifications()
        checkDue()
    }

    /// Only call in response to the user's "开启通知" click.
    func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        authorizationHint = nil
        permissionStatus = "等待 macOS 通知选择 · 可刷新状态或打开通知设置"
        // macOS can leave the request pending while its permission notice is suppressed.
        // Keep the rest of the page usable and never submit duplicate permission requests.
        authorizationWaitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.isRequestingAuthorization else { return }
            await self.refreshAuthorization()
            if self.authorization.status == .notDetermined && self.isRequestingAuthorization {
                self.authorizationHint = "系统尚未返回选择结果。屏幕共享、镜像或专注模式可能隐藏提示；可在通知设置中处理，再刷新状态。App 运行中的到期提示仍可用。"
            }
        }
        defer {
            isRequestingAuthorization = false
            authorizationWaitTask?.cancel()
            authorizationWaitTask = nil
        }
        do { try await scheduler.requestAuthorization() }
        catch { errorMessage = "无法开启系统通知：\(error.localizedDescription)。日程仍可保存在本机。" }
        isRequestingAuthorization = false
        await refreshAuthorization()
    }

    /// Recurring items start at the next matching time, rather than a user-selected far-future date.
    @discardableResult
    func add(title: String, notes: String = "", date: Date, recurrence: ReminderRecurrence = .once) async throws -> ReminderItem {
        guard !isBusy else { throw ReminderError.busy }
        guard canMutate else { throw ReminderError.locked }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw ReminderError.invalidTitle }
        guard cleanTitle.count <= 120, cleanNotes.count <= 1000 else { throw ReminderError.tooLong }
        let now = clock()
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw ReminderError.invalidDate }
        var item = ReminderItem(id: UUID(), title: cleanTitle, notes: cleanNotes, createdAt: now,
                                scheduledDate: date, recurrence: recurrence,
                                timeZoneIdentifier: TimeZone.current.identifier)
        if recurrence != .once {
            guard let next = item.nextOccurrence(after: now.addingTimeInterval(5)) else { throw ReminderError.invalidDate }
            item.scheduledDate = next
        }
        guard item.scheduledDate.timeIntervalSince(now) >= 5, Self.isValid(item) else { throw ReminderError.invalidDate }
        isBusy = true
        defer { isBusy = false }
        try persist([item] + items)
        errorMessage = nil
        await syncNotifications()
        checkDue()
        return item
    }

    /// For a repeating reminder this acknowledges the current occurrence and keeps the schedule.
    func complete(_ item: ReminderItem) async {
        await mutate(item) { value in
            value.snoozedUntil = nil
            if value.recurrence == .once { value.completedAt = self.clock() }
            else { value.scheduledDate = value.nextOccurrence(after: self.clock()) ?? value.scheduledDate }
        }
    }

    func remove(_ item: ReminderItem) async {
        guard !isBusy, canMutate, items.contains(where: { $0.id == item.id }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try persist(items.filter { $0.id != item.id })
            announced.removeValue(forKey: item.id)
            await syncNotifications()
            checkDue()
        } catch { errorMessage = "未能移除日程：\(error.localizedDescription)" }
    }

    func snooze(_ item: ReminderItem, minutes: Int = 10) async {
        guard (1...1440).contains(minutes) else { return }
        await mutate(item) { value in
            guard !value.isCompleted else { return }
            let desired = self.clock().addingTimeInterval(Double(minutes) * 60)
            // Preserve the next normal occurrence if a snooze crosses the recurrence boundary.
            value.snoozedUntil = value.nextOccurrence(after: self.clock()).map { min(desired, $0) } ?? desired
        }
    }

    /// Public for wake-from-sleep integration and deterministic tests.
    func checkDue() {
        currentDate = clock()
        updateStatus()
        for item in due where announced[item.id] != item.dueDate {
            announced[item.id] = item.dueDate
            onDue?(item)
        }
    }

    func openSystemNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    private func mutate(_ item: ReminderItem, change: (inout ReminderItem) -> Void) async {
        guard !isBusy, canMutate, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        isBusy = true
        defer { isBusy = false }
        var next = items
        change(&next[index])
        do {
            try persist(next)
            errorMessage = nil
            announced.removeValue(forKey: item.id)
            await syncNotifications()
            checkDue()
        } catch { errorMessage = "日程保存失败：\(error.localizedDescription)" }
    }

    private func syncNotifications() async {
        guard canMutate else { return }
        // A permission refresh can overlap an add/remove at an await point. Always finish with
        // the newest persisted snapshot, so an older call cannot resurrect a removed alert.
        if isSyncing { needsSync = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsSync = false
            do { try await scheduler.replaceAll(with: authorization.canSchedule ? upcoming : [], now: clock()) }
            catch { errorMessage = "日程已保存在本机，但系统通知排程失败：\(error.localizedDescription)。App 运行时仍会显示到期事项。" }
        } while needsSync
    }

    private func persist(_ next: [ReminderItem]) throws {
        guard canMutate else { throw ReminderError.locked }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ReminderIndex(version: 1, items: next)).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        items = next
        updateStatus()
    }

    private func updateStatus() {
        let pending = items.filter { !$0.isCompleted }
        let overdue = pending.filter { $0.dueDate <= currentDate }.count
        statusText = pending.isEmpty ? "还没有待办提醒" : "\(pending.count) 条待办" + (overdue > 0 ? " · \(overdue) 条已到期" : " · 下一项 " + Self.compactDate(pending.map(\.dueDate).min()!))
    }

    static func compactDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func isValid(_ item: ReminderItem) -> Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.title.count <= 120 && item.notes.count <= 1000
        && item.createdAt.timeIntervalSinceReferenceDate.isFinite && item.scheduledDate.timeIntervalSinceReferenceDate.isFinite
        && (item.completedAt?.timeIntervalSinceReferenceDate.isFinite ?? true) && (item.snoozedUntil?.timeIntervalSinceReferenceDate.isFinite ?? true)
        && TimeZone(identifier: item.timeZoneIdentifier) != nil
    }
}

@MainActor
private final class SystemReminderScheduler: ReminderNotificationScheduling {
    private let center: UNUserNotificationCenter?
    private let delegate = ReminderNotificationDelegate()

    init() {
        // Command-line tests have no app bundle; UNUserNotificationCenter.current() may abort there.
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func configure(onOpen: @escaping @MainActor (UUID) -> Void) {
        delegate.onOpen = onOpen
        center?.delegate = delegate
    }

    func authorization() async -> ReminderAuthorizationSnapshot {
        guard let center else { return .init(status: .unavailable) }
        let settings = await center.notificationSettings()
        let status: ReminderAuthorizationSnapshot.Status
        switch settings.authorizationStatus {
        case .notDetermined: status = .notDetermined
        case .denied: status = .denied
        case .authorized: status = .authorized
        case .provisional: status = .provisional
        case .ephemeral: status = .authorized
        @unknown default: status = .unavailable
        }
        return .init(status: status, alertsEnabled: settings.alertSetting == .enabled,
                     soundsEnabled: settings.soundSetting == .enabled)
    }

    func requestAuthorization() async throws {
        guard let center else { throw CocoaError(.featureUnsupported) }
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func replaceAll(with items: [ReminderItem], now: Date) async throws {
        guard let center else { return }
        let previous = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("StashCat.reminder.") }
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }.filter { $0.hasPrefix("StashCat.reminder.") }
        let activeIDs = Set(items.flatMap(\.notificationIDs))
        center.removePendingNotificationRequests(withIdentifiers: previous.filter { !activeIDs.contains($0) })
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { !activeIDs.contains($0) })
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.notes.isEmpty ? "到时间啦。点击查看日程，完成或稍后提醒。" : item.notes
            content.sound = .default
            content.userInfo = ["reminderID": item.id.uuidString]
            content.threadIdentifier = "StashCat.reminders"
            if item.recurrence == .once {
                // Expired one-off reminders remain visible in-app; do not emit a misleading late banner.
                if item.dueDate > now {
                    try await center.add(Self.request(identifier: item.notificationID, content: content, date: item.dueDate, calendar: item.calendar))
                } else { center.removePendingNotificationRequests(withIdentifiers: item.notificationIDs) }
            } else {
                try await center.add(UNNotificationRequest(identifier: item.notificationID, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: item.recurringComponents, repeats: true)))
                if let snooze = item.snoozedUntil, snooze > now {
                    try await center.add(Self.request(identifier: item.notificationID + ".snooze", content: content, date: snooze, calendar: item.calendar))
                } else { center.removePendingNotificationRequests(withIdentifiers: [item.notificationID + ".snooze"]) }
            }
        }
    }

    private static func request(identifier: String, content: UNNotificationContent, date: Date, calendar: Calendar) -> UNNotificationRequest {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: identifier, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
}

private final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    @MainActor var onOpen: (@MainActor (UUID) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["reminderID"] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()
        guard let id, response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        Task { @MainActor [weak self] in self?.onOpen?(id) }
    }
}
