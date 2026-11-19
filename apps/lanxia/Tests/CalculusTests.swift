import Foundation

@main
struct CalculusTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fatalError("Calculus test failed: \(message)") }
    }
    static func result(_ query: String) -> CalculusResult {
        guard let result = CalculusEngine.solve(query) else { fatalError("No result for \(query)") }
        return result
    }
    static func numeric(_ query: String, _ expected: Double, tolerance: Double = 1e-7) {
        let result = result(query)
        let tail = result.answer.components(separatedBy: "≈").last!.trimmingCharacters(in: .whitespaces)
        guard let actual = Double(tail) else { fatalError("Expected numeric result: \(query): \(result.answer)") }
        check(abs(actual - expected) < tolerance, "\(query): \(actual), expected \(expected)")
    }
    static func rejects(_ query: String) {
        let result = result(query)
        check(result.title == "本地数学助手", "Should reject \(query): \(result.answer)")
    }
    static func main() {
        check(CalculusEngine.solve("今天心情有点低落") == nil, "Ordinary chat must pass through")
        check(CalculusEngine.solve("帮我整理明天的计划") == nil, "Ordinary planning must pass through")
        check(result("求导 x^3 + 2*x").answer == "f′(x) = 3 * x^2 + 2", "Polynomial derivative")
        check(result("对 sin(x) 求导").answer == "f′(x) = cos(x)", "Chinese postfix derivative")
        check(result("求导 sin(2*x)").answer == "f′(x) = cos(2 * x) * 2", "Chain rule")
        check(result("求导 -x^2").answer == "f′(x) = -(2 * x)", "Unary minus below exponent")
        check(result("求导 (-x)^2").answer == "f′(x) = -(2 * -x)", "Parenthesized negative base")
        check(result("求导 x^-2").answer == "f′(x) = -2 * x^(-3)", "Negative exponent")
        check(result("求导 2^3^2").answer == "f′(x) = 0", "Constant derivative")
        check(result("积分 x^2").answer.contains("0.333333333333 * x^3 + C"), "Power antiderivative")
        check(result("积分 1/x").answer == "∫ f(x) dx = ln(abs(x)) + C", "Reciprocal integral")
        check(result("积分 sin(2*x)").answer.contains("-cos(2 * x) / 2"), "Affine sine integral")
        check(result("积分 (x+1)^2").answer.contains("x^2"), "Polynomial expansion")
        check(result("积分 exp(2*x+3)").answer.contains("exp(2 * x + 3) / 2"), "Affine exponential integral")
        check(result("积分 ln(x)").answer.contains("x * ln(x) - x"), "Log integral")
        numeric("定积分 x^2 从 0 到 1", 1.0 / 3)
        numeric("∫_0^1 x^2 dx", 1.0 / 3)
        numeric("∫_{-pi}^{pi} cos(x) dx", 0)
        numeric("定积分 x^2 从 1 到 0", -1.0 / 3)
        numeric("定积分 -x^2 从 0 到 1", -1.0 / 3)
        numeric("定积分 (-x)^2 从 0 到 1", 1.0 / 3)
        numeric("定积分 2^3^2 从 0 到 1", 512)
        numeric("定积分 2^-2 从 0 到 1", 0.25)
        numeric("定积分 2x + 3(x+1) 从 0 到 1", 5.5)
        numeric("定积分 sin(x) 从 0 到 pi", 2)
        numeric("定积分 exp(x) 从 0 到 1", M_E - 1)
        numeric("定积分 sqrt(x) 从 0 到 1", 2.0 / 3)
        numeric("定积分 1/(1+x*x) 从 -1 到 1", Double.pi / 2)
        numeric("定积分 ln(x) 从 1 到 e", 1)
        numeric("定积分 x 从 -2 到 -1", -1.5)
        numeric("定积分 x 从 3 到 3", 0)
        // Interior poles, endpoint poles and undefined real domains must not produce normal integrals.
        rejects("定积分 1/x 从 -1 到 1")
        rejects("定积分 1/x 从 0 到 1")
        rejects("定积分 1/(x-0.1234567) 从 0 到 1")
        rejects("定积分 1/(x-0.3)^2 从 0 到 1")
        rejects("定积分 tan(x) 从 0 到 pi")
        rejects("定积分 ln(x) 从 0 到 1")
        rejects("定积分 sqrt(x) 从 -1 到 1")
        rejects("定积分 x^-0.5 从 -1 到 1")
        rejects("定积分 1/x 从 0 到 0")
        rejects("定积分 exp(1000*x) 从 0 到 1")
        rejects("定积分 cos(512*pi*x) 从 0 到 1")
        rejects("定积分 x 从 x 到 1")
        rejects("求导 x / 0")
        rejects("求导 ln(-1)")
        rejects("求导 abs(x)")
        rejects("积分 sin(x*x)")
        for malformed in ["求导", "求导 x+", "积分 sin x", "求导 (x+1", "求导 x^^2", "积分 y", "求导 1..2", "求导 1e999", "求导 x);system(1)"] {
            rejects(malformed)
        }
        rejects("求导 " + String(repeating: "(", count: 100) + "x" + String(repeating: ")", count: 100))
        rejects("求导 " + String(repeating: "x+", count: 1100))
        print("CalculusTests: \(count) assertions passed")
    }
}
