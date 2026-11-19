import SwiftUI

struct ReminderView: View {
    @ObservedObject var store: ReminderStore
    @State private var title = ""
    @State private var notes = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var recurrence: ReminderRecurrence = .once
    @State private var showCreate = true
    @State private var showCompleted = false
    @State private var formError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                permissionCard
                if let error = formError ?? store.errorMessage {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.circle")
                        Text(error).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button { formError = nil; store.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭日程提示")
                    }.font(.system(size: 10)).padding(10)
                        .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                }
                DisclosureGroup(isExpanded: $showCreate) {
                    createForm.padding(.top, 8)
                } label: {
                    Label("添加提醒", systemImage: "plus.circle").font(.system(size: 13, weight: .semibold))
                        .stashHighlightedText()
                }
                Divider().opacity(0.5)
                HStack {
                    Text("待办").font(.system(size: 12, weight: .semibold)).stashHighlightedText()
                    Spacer()
                    Text(store.statusText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                if store.upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("把要记住的事交给我。")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .stashHighlightedText()
                        Text("提醒只保存在本机，不会同步到 Outlook 日历。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                } else {
                    ForEach(store.upcoming) { reminder in reminderRow(reminder) }
                }
                if !store.completed.isEmpty {
                    DisclosureGroup(isExpanded: $showCompleted) {
                        VStack(spacing: 8) {
                            ForEach(store.completed) { reminder in reminderRow(reminder) }
                        }.padding(.top, 8)
                    } label: {
                        Text("已完成（\(store.completed.count)）").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("菜单栏首页会显示到期事项数量。系统通知需授权；休眠、专注模式或系统设置可能延后提示。每日／每周按创建时的时区重复。")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(.horizontal, 15).padding(.vertical, 13)
        }
        .task { await store.start() }
        .onAppear { applyDraft() }
        .onChange(of: store.pendingDraft?.id) { _, _ in applyDraft() }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.authorization.canSchedule ? "bell.badge" : "bell.slash")
                    .font(.system(size: 13))
                Text(store.permissionStatus).font(.system(size: 10)).lineSpacing(3)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if store.authorization.status == .notDetermined {
                    Button(store.isRequestingAuthorization ? "等待系统选择…" : "开启系统通知") {
                        Task { await store.requestAuthorization() }
                    }.font(.system(size: 10, weight: .medium))
                        .disabled(store.isRequestingAuthorization)
                    if store.isRequestingAuthorization {
                        Button("通知设置") { store.openSystemNotificationSettings() }
                            .font(.system(size: 10))
                    }
                } else if store.authorization.status == .denied || (store.authorization.canSchedule && !store.authorization.alertsEnabled) {
                    Button("打开通知设置") { store.openSystemNotificationSettings() }
                        .font(.system(size: 10, weight: .medium))
                }
                Button("刷新状态") { Task { await store.refreshAuthorization() } }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let hint = store.authorizationHint {
                Text(hint).font(.system(size: 9)).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .stashGlassSurface(cornerRadius: 14)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("提醒标题，例如：提交作业", text: $title)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 9).padding(.vertical, 8)
                .stashGlassSurface(cornerRadius: 10, emphasis: true)
                .accessibilityLabel("提醒标题")
            TextField("备注（可选）", text: $notes, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 11)).lineLimit(1...3)
                .padding(.horizontal, 9).padding(.vertical, 8)
                .stashGlassSurface(cornerRadius: 10, emphasis: true)
                .accessibilityLabel("提醒备注")
            Picker("重复", selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().font(.system(size: 11))
            DatePicker(recurrence == .daily ? "时刻" : (recurrence == .weekly ? "星期／时刻" : "日期／时间"),
                       selection: $date, displayedComponents: recurrence == .daily ? [.hourAndMinute] : [.date, .hourAndMinute])
                .datePickerStyle(.field).font(.system(size: 10))
                .environment(\.locale, Locale(identifier: "zh_CN"))
            if recurrence != .once {
                Text(recurrence == .daily ? "从下次选定时刻开始，每天重复。" : "按所选日期对应的星期及时间，每周重复；从下次匹配时刻开始。")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineSpacing(2)
            }
            HStack {
                Text("\(title.count)/120").font(.system(size: 9)).foregroundStyle(title.count > 120 ? Color.red : Color.secondary)
                Spacer()
                Button(store.isBusy ? "保存中…" : "添加提醒") { addReminder() }
                    .font(.system(size: 11, weight: .medium))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
        }
    }

    private func reminderRow(_ item: ReminderItem) -> some View {
        let overdue = !item.isCompleted && item.dueDate <= store.currentDate
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Button { Task { await store.complete(item) } } label: {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                }.buttonStyle(.plain)
                    .disabled(item.isCompleted || store.isBusy || (item.recurrence != .once && !overdue))
                    .help(item.recurrence == .once ? "标记完成" : "完成本次，保留后续重复提醒")
                    .accessibilityLabel(item.isCompleted ? "已完成" : "完成提醒 \(item.title)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 12, weight: .medium))
                        .strikethrough(item.isCompleted).foregroundStyle(item.isCompleted ? Color.secondary : Color.primary)
                        .lineLimit(3)
                    Text(scheduleLabel(item)).font(.system(size: 9)).foregroundStyle(.secondary)
                    if !item.notes.isEmpty {
                        Text(item.notes).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if overdue {
                    Text("已到期").font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.primary.opacity(0.1), in: Capsule())
                }
                Button { Task { await store.remove(item) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .disabled(store.isBusy).help("移除提醒").accessibilityLabel("移除提醒 \(item.title)")
            }
            if !item.isCompleted && overdue {
                HStack {
                    Spacer()
                    Button("10 分钟后提醒") { Task { await store.snooze(item) } }
                        .font(.system(size: 9)).disabled(store.isBusy)
                    if item.recurrence != .once {
                        Button("完成本次") { Task { await store.complete(item) } }
                            .font(.system(size: 9)).disabled(store.isBusy)
                    }
                }
            }
        }.padding(10).stashGlassSurface(cornerRadius: 13, emphasis: overdue)
    }

    private func scheduleLabel(_ item: ReminderItem) -> String {
        if let completed = item.completedAt { return "已完成 · " + ReminderStore.compactDate(completed) }
        if let snooze = item.snoozedUntil { return "稍后提醒 · " + ReminderStore.compactDate(snooze) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = item.calendar.timeZone
        formatter.dateFormat = item.recurrence == .daily ? "HH:mm" : item.recurrence == .weekly ? "EEEE HH:mm" : "MM/dd HH:mm"
        let prefix = item.recurrence == .once ? "" : item.recurrence.title + " · "
        return prefix + formatter.string(from: item.scheduledDate)
    }

    private func applyDraft() {
        guard let draft = store.pendingDraft else { return }
        title = draft.title
        notes = draft.notes
        date = Date().addingTimeInterval(3600)
        recurrence = .once
        showCreate = true
        formError = nil
        store.clearDraft()
    }

    private func addReminder() {
        formError = nil
        Task {
            do {
                try await store.add(title: title, notes: notes, date: date, recurrence: recurrence)
                title = ""
                notes = ""
                showCreate = false
            } catch { formError = error.localizedDescription }
        }
    }
}
