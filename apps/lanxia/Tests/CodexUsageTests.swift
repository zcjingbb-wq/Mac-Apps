import Foundation

@main
struct CodexUsageTests {
    private static var count = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1
    }

    private static func reading(_ primary: Any, secondary: Any = NSNull(), limitID: Any = "codex") -> [String: Any] {
        ["rateLimits": ["limitId": limitID, "primary": primary, "secondary": secondary]]
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_792_491_000)
        let future = now.addingTimeInterval(3_600)
        let main: [String: Any] = ["usedPercent": 18, "windowDurationMins": 300, "resetsAt": future.timeIntervalSince1970]
        let week: [String: Any] = ["usedPercent": 46, "windowDurationMins": 10_080, "resetsAt": future.addingTimeInterval(604_800).timeIntervalSince1970]
        let snapshot = CodexUsage.parse(reading(main, secondary: week))!
        expect(snapshot.primary?.usedPercent == 18, "usedPercent is consumed quota")
        expect(snapshot.primary?.remainingPercent == 82, "remaining quota is 100 minus used")
        expect(snapshot.secondary?.remainingPercent == 54, "secondary remaining quota")
        expect(snapshot.compactText == "5h 82% · 周 54%", "compact two-window display")
        expect(snapshot.primary?.resetsAt == future, "Unix reset timestamp is preserved")
        expect(snapshot.primary?.durationDescription(fallback: "主要周期") == "5 小时", "actual primary duration")
        expect(snapshot.secondary?.durationDescription(fallback: "次要周期") == "每周", "weekly duration")
        print("PASS used/remaining direction and real window metadata")

        let competing: [String: Any] = [
            "rateLimits": ["limitId": "other-product", "primary": ["usedPercent": 0, "windowDurationMins": 60]],
            "rateLimitsByLimitId": [
                "other-product": ["primary": ["usedPercent": 0]],
                "codex": ["limitId": "codex", "primary": main, "secondary": week]
            ]
        ]
        expect(CodexUsage.parse(competing) == snapshot, "the exact Codex bucket wins over legacy and other products")
        expect(CodexUsage.parse(["rateLimitsByLimitId": ["other-product": ["primary": main]]]) == nil, "never substitute another bucket")
        expect(CodexUsage.parse(["rateLimits": ["primary": main], "rateLimitsByLimitId": ["other-product": ["primary": main]]]) == nil, "authoritative map without Codex cannot fall back to legacy")
        expect(CodexUsage.parse(["rateLimits": ["primary": main], "rateLimitsByLimitId": ["codex": NSNull()]]) == nil, "explicitly absent Codex bucket remains absent")
        expect(CodexUsage.parse(["rateLimitsByLimitId": ["codex": ["limitId": "other-product", "primary": main]]]) == nil, "reject contradictory bucket identifiers")
        expect(CodexUsage.parse(reading(main, limitID: "other-product")) == nil, "legacy other-product bucket is not Codex")
        expect(CodexUsage.parse(["rateLimits": ["primary": main]])?.primary?.remainingPercent == 82, "legacy missing limit ID remains compatible")
        expect(CodexUsage.parse(["rateLimits": ["primary": main], "rateLimitsByLimitId": [:]])?.primary?.remainingPercent == 82, "empty map permits legacy response")
        expect(CodexUsage.parse(["rateLimits": ["primary": main], "rateLimitsByLimitId": NSNull()])?.primary?.remainingPercent == 82, "null optional map permits legacy response")
        print("PASS bucket selection and legacy compatibility")

        expect(CodexUsage.parse([:]) == nil, "missing response is unavailable")
        expect(CodexUsage.parse(["rateLimits": NSNull()]) == nil, "null response is unavailable")
        expect(CodexUsage.parse(reading(NSNull())) == nil, "null windows are unavailable")
        expect(CodexUsage.parse(reading([:])) == nil, "empty window is unavailable")
        expect(CodexUsage.parse(reading(["usedPercent": NSNull()])) == nil, "null percent is unknown")
        expect(CodexUsage.parse(reading(["usedPercent": true])) == nil, "JSON boolean is not numeric percentage")
        expect(CodexUsage.parse(reading(["usedPercent": NSNumber(value: false)])) == nil, "NSNumber boolean is not percentage")
        expect(CodexUsage.parse(reading(["usedPercent": "18"])) == nil, "numeric text is not silently coerced")
        expect(CodexUsage.parse(reading(["usedPercent": Double.nan])) == nil, "NaN is rejected")
        expect(CodexUsage.parse(reading(["usedPercent": Double.infinity])) == nil, "infinite percent is rejected")
        expect(CodexUsage.parse(reading(["usedPercent": -9]))?.primary?.remainingPercent == 100, "negative used percentage is clamped")
        expect(CodexUsage.parse(reading(["usedPercent": 150]))?.primary?.remainingPercent == 0, "over-100 used percentage is clamped")
        expect(CodexUsage.parse(reading(["usedPercent": 100]))?.primary?.remainingPercent == 0, "exhausted allowance is zero remaining")
        expect(CodexUsage.parse(reading(["usedPercent": 0]))?.primary?.remainingPercent == 100, "known unused allowance is 100 remaining")
        expect(CodexUsage.parse(reading(["usedPercent": 18.5]))?.primary?.remainingPercent == 81.5, "fractional percentages retain precision")
        expect(CodexUsage.percent(nil) == "--", "missing percentage remains explicit")
        expect(CodexUsage.percent(.nan) == "--", "non-finite display remains unknown")
        expect(CodexUsage.percent(81.5) == "81.5%", "fractional percentage formatting")
        let unknown = CodexUsage.parse(reading(["windowDurationMins": 300]))!
        expect(unknown.primary?.remainingPercent == nil, "duration does not invent percentage")
        expect(unknown.compactText == "5h --", "unknown usage is never shown as unused allowance")
        let onlySecondary = CodexUsage.parse(reading(NSNull(), secondary: week))!
        expect(onlySecondary.primary == nil && onlySecondary.secondary?.remainingPercent == 54, "secondary can be independently available")
        expect(onlySecondary.compactText == "周 54%", "absent primary does not add a fake window")
        expect(CodexUsage.parse(["rateLimits": ["limitId": "codex", "credits": ["unlimited": true]]]) == nil, "credits metadata never invents percentage")
        print("PASS null, numeric validity, clamping and explicit unknown data")

        for (minutes, label, description) in [(60, "1h", "1 小时"), (120, "2h", "2 小时"), (1_440, "1d", "1 天"), (2_880, "2d", "2 天"), (45, "45m", "45 分钟"), (43_200, "30d", "30 天")] {
            let window = CodexUsage.parse(reading(["usedPercent": 10, "windowDurationMins": minutes]))!.primary!
            expect(window.label(fallback: "周期1") == label, "label reflects actual \(minutes)-minute metadata")
            expect(window.durationDescription(fallback: "主要周期") == description, "detail reflects actual \(minutes)-minute metadata")
        }
        let noDuration = CodexUsage.parse(reading(["usedPercent": 12]))!.primary!
        expect(noDuration.label(fallback: "周期1") == "周期1", "unknown duration is not guessed as five hours")
        expect(noDuration.durationDescription(fallback: "主要周期").contains("未知"), "detail discloses unknown duration")
        for invalid: Any in [0, -1, 1.5, Double.infinity, Double.nan, 1e100, true, "300", NSNull()] {
            expect(CodexUsage.parse(reading(["usedPercent": 5, "windowDurationMins": invalid]))?.primary?.durationMinutes == nil, "invalid duration is unknown")
        }
        for invalid: Any in [0, -1, Double.infinity, Double.nan, 1e100, true, "1792491000", NSNull()] {
            expect(CodexUsage.parse(reading(["usedPercent": 5, "resetsAt": invalid]))?.primary?.resetsAt == nil, "invalid reset is unknown")
        }
        print("PASS duration labels and malformed reset/date fields")

        let loading = CodexUsageState()
        expect(loading.compactText(at: now) == "额度读取中", "initial loading is not a fabricated percentage")
        expect(loading.detailText(at: now).contains("正在读取"), "loading detail")
        var unavailable = CodexUsageState()
        unavailable.error = "当前服务未提供额度。"
        expect(unavailable.compactText(at: now) == "额度暂不可用", "failure without sample is unavailable")
        expect(unavailable.detailText(at: now).contains("当前服务未提供额度"), "failure reason is explained")
        var state = CodexUsageState(snapshot: snapshot, updatedAt: now)
        expect(state.compactText(at: now) == "5h 82% · 周 54%", "fresh sample remains compact")
        expect(!state.isStale(at: now.addingTimeInterval(179)), "fresh sample threshold")
        expect(state.isStale(at: now.addingTimeInterval(180)), "aged sample is explicitly stale")
        expect(state.compactText(at: now.addingTimeInterval(181)).hasPrefix("上次 "), "stale sample labeled as last reading")
        state.error = "额度刷新失败，请稍后重试。"
        expect(state.isStale(at: now), "failed refresh immediately marks retained sample stale")
        expect(state.detailText(at: now).contains("可能已变化"), "stale detail explains the limit")
        expect(state.detailText(at: now).contains("额度刷新失败"), "error and retained reading both explained")
        state.error = nil
        state.isRefreshing = true
        expect(state.detailText(at: now).contains("正在刷新"), "refresh status is announced")
        state.isRefreshing = false
        state.updatedAt = future
        expect(state.isStale(at: future), "reaching a reset date invalidates pre-reset percentages")
        expect(state.compactText(at: future).contains("82%"), "reset time never silently restores a quota to 100%")
        print("PASS stale/error/loading semantics without fabricated reset recovery")

        let freshState = CodexUsageState(snapshot: snapshot, updatedAt: now)
        let shanghai = freshState.detailText(at: now, timeZone: TimeZone(secondsFromGMT: 28_800)!)
        let utc = freshState.detailText(at: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let expectedLocal = DateFormatter()
        expectedLocal.locale = Locale(identifier: "zh_CN")
        expectedLocal.timeZone = TimeZone(secondsFromGMT: 28_800)!
        expectedLocal.dateFormat = "M月d日 HH:mm zzz"
        expect(shanghai.contains(expectedLocal.string(from: future)), "reset display uses supplied local timezone")
        expect(shanghai != utc, "reset display is not hardcoded to UTC")
        expect(freshState.detailText(at: now) == freshState.detailText(at: now, timeZone: .autoupdatingCurrent), "default timezone follows system changes")
        expect(shanghai.contains("剩余 82%（已用 18%）"), "detail explicitly states percentage direction")
        expect(shanghai.contains("上次更新"), "last successful sample date is visible")
        expect(shanghai.contains("缺失数据以 -- 显示"), "unknown values are explained accessibly")
        print("PASS localized reset times and accessible quota detail")
        print("All \(count) CodexUsage assertions passed.")
    }
}
