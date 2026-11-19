import Foundation
import CoreFoundation

/// Only the account's Codex bucket is shown. Other product/model buckets must never be
/// substituted for it, and an absent reading is not equivalent to an unused allowance.
struct CodexUsage: Equatable {
    struct Window: Equatable {
        let usedPercent: Double?
        let durationMinutes: Int?
        let resetsAt: Date?

        var remainingPercent: Double? { usedPercent.map { min(100, max(0, 100 - $0)) } }

        func label(fallback: String) -> String {
            guard let durationMinutes else { return fallback }
            if durationMinutes == 10_080 { return "周" }
            if durationMinutes % 1_440 == 0 { return "\(durationMinutes / 1_440)d" }
            if durationMinutes % 60 == 0 { return "\(durationMinutes / 60)h" }
            return "\(durationMinutes)m"
        }

        func durationDescription(fallback: String) -> String {
            guard let durationMinutes else { return fallback + "（周期长度未知）" }
            if durationMinutes == 10_080 { return "每周" }
            if durationMinutes % 1_440 == 0 { return "\(durationMinutes / 1_440) 天" }
            if durationMinutes % 60 == 0 { return "\(durationMinutes / 60) 小时" }
            return "\(durationMinutes) 分钟"
        }
    }

    let primary: Window?
    let secondary: Window?

    static func parse(_ payload: [String: Any]) -> CodexUsage? {
        let bucket: [String: Any]?
        if let byID = payload["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            // An explicitly returned multi-bucket map is authoritative, even when Codex
            // is unavailable. Falling back to its arbitrary first entry would be wrong.
            bucket = byID["codex"] as? [String: Any]
        } else {
            let legacy = payload["rateLimits"] as? [String: Any]
            if let limitID = legacy?["limitId"] as? String, limitID != "codex" { return nil }
            bucket = legacy
        }
        guard let bucket else { return nil }
        if let limitID = bucket["limitId"] as? String, limitID != "codex" { return nil }
        let primary = parseWindow(bucket["primary"])
        let secondary = parseWindow(bucket["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return CodexUsage(primary: primary, secondary: secondary)
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let raw, let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func parseWindow(_ raw: Any?) -> Window? {
        guard let values = raw as? [String: Any] else { return nil }
        let used = number(values["usedPercent"])
        let durationValue = number(values["windowDurationMins"])
        let duration = durationValue.flatMap { value -> Int? in
            guard value > 0, value <= 52_560_000, value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        let reset = number(values["resetsAt"]).flatMap { value -> Date? in
            guard value > 0, value <= 253_402_300_799 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        guard used != nil || duration != nil || reset != nil else { return nil }
        return Window(usedPercent: used.map { min(100, max(0, $0)) }, durationMinutes: duration, resetsAt: reset)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let formatter = NumberFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false
        return (formatter.string(from: NSNumber(value: value)) ?? "--") + "%"
    }

    var compactText: String {
        [(primary, "周期1"), (secondary, "周期2")].compactMap { window, fallback in
            window.map { $0.label(fallback: fallback) + " " + Self.percent($0.remainingPercent) }
        }.joined(separator: " · ")
    }
}

/// A reading is kept only in memory for the current connection/account. Failed refreshes
/// explicitly mark that reading as old; disconnecting or changing accounts clears it.
struct CodexUsageState: Equatable {
    var snapshot: CodexUsage?
    var updatedAt: Date?
    var error: String?
    var isRefreshing = false

    func isStale(at now: Date) -> Bool {
        guard snapshot != nil, let updatedAt else { return false }
        if error != nil || now.timeIntervalSince(updatedAt) >= 180 { return true }
        return [snapshot?.primary?.resetsAt, snapshot?.secondary?.resetsAt]
            .compactMap { $0 }.contains { $0 <= now }
    }

    func compactText(at now: Date = Date()) -> String {
        guard let snapshot else { return error == nil ? "额度读取中" : "额度暂不可用" }
        return (isStale(at: now) ? "上次 " : "") + snapshot.compactText
    }

    func detailText(at now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm zzz"
        var lines = ["Codex 账号剩余额度"]
        if let snapshot {
            for (window, name) in [(snapshot.primary, "主要周期"), (snapshot.secondary, "次要周期")] {
                guard let window else { continue }
                lines.append("\(window.durationDescription(fallback: name))：剩余 \(CodexUsage.percent(window.remainingPercent))（已用 \(CodexUsage.percent(window.usedPercent))）")
                lines.append("重置时间：" + (window.resetsAt.map { formatter.string(from: $0) } ?? "暂未提供"))
            }
            if let updatedAt { lines.append("上次更新：" + formatter.string(from: updatedAt)) }
            if isStale(at: now) { lines.append("当前显示上次成功读取的额度，可能已变化。") }
        } else {
            lines.append(error == nil ? "正在读取额度，请稍候。" : "服务暂未返回可用的 Codex 额度。")
        }
        if let error { lines.append(error) }
        if isRefreshing { lines.append("正在刷新…") }
        lines.append("百分比表示剩余用量；缺失数据以 -- 显示。点击可刷新。")
        return lines.joined(separator: "\n")
    }
}
