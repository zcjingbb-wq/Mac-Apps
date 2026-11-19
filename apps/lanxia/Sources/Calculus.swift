import Foundation

/// Deterministic, offline calculus. No model output is treated as an evaluated expression.
struct CalculusResult {
    let title: String
    let answer: String
    let steps: String
}

enum CalculusEngine {
    static func solve(_ query: String) -> CalculusResult? {
        guard let request = MathRequest(query) else { return nil }
        do {
            var parser = try MathParser(request.expression)
            let expression = try parser.parse()
            try expression.checkConstantDomains()
            switch request.operation {
            case .derivative:
                let result = try expression.derivative().simplified
                return CalculusResult(title: "本地求导", answer: "f′(x) = \(result.rendered)",
                    steps: "原式：f(x) = \(expression.rendered)\n使用幂函数、乘积、商和链式法则进行符号求导。\n结果适用于原函数可微且各项有定义的区间；未自动求出完整定义域。")
            case .integral:
                guard let result = expression.antiderivative() else {
                    return unsupported("此原函数暂不能用内置规则求出。可尝试展开多项式，或提供上下限进行数值积分。")
                }
                return CalculusResult(title: "本地不定积分", answer: "∫ f(x) dx = \(result.simplified.rendered) + C",
                    steps: "被积函数：\(expression.rendered)\n使用线性、幂函数及常见初等函数积分规则。\nC 为任意常数；结果在被积函数有定义的各连续区间分别成立。")
            case .definite(let lower, let upper):
                let a = try parseBound(lower)
                let b = try parseBound(upper)
                let result = try NumericalIntegral.compute(expression, from: a, to: b)
                return CalculusResult(title: "本地定积分", answer: "∫[\(MathFormat.number(a)), \(MathFormat.number(b))] \(expression.rendered) dx ≈ \(MathFormat.number(result.value))",
                    steps: "先检查整个区间的函数定义域，再使用自适应 Simpson 数值积分。\n估计绝对误差：\(String(format: "%.2g", result.error))（数值估计，非严格数学证明）。\n本工具只处理有限区间的正常积分，不计算反常积分、主值或复数结果。")
            }
        } catch {
            return unsupported((error as? MathFailure)?.message ?? "无法处理这个表达式。")
        }
    }

    private static func unsupported(_ reason: String) -> CalculusResult {
        CalculusResult(title: "本地数学助手", answer: reason,
            steps: "可输入：求导 x^3 + 2*x；对 sin(x) 求导；积分 x^2；定积分 x^2 从 0 到 1；∫_0^1 x^2 dx。\n仅支持一个变量 x、实数、pi/e、四则运算、^ 和 sin/cos/tan/exp/ln/log/sqrt/abs。函数参数请加括号。")
    }

    private static func parseBound(_ text: String) throws -> Double {
        var parser = try MathParser(text)
        let expression = try parser.parse()
        guard !expression.dependsOnX else { throw MathFailure("积分上下限必须是有限常数，不能含 x。") }
        let value = try expression.evaluate(0)
        guard value.isFinite, abs(value) <= 1e10 else { throw MathFailure("积分上下限过大或不是有限实数。") }
        return value
    }
}

private struct MathFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct MathRequest {
    enum Operation { case derivative, integral, definite(String, String) }
    let operation: Operation
    let expression: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "²", with: "^2").replacingOccurrences(of: "³", with: "^3")
        guard text.count <= 2000 else {
            if text.contains("求导") || text.contains("积分") || text.contains("∫") {
                operation = .derivative; expression = "__too_long__"; return
            }
            return nil
        }
        for prefix in ["请帮我", "帮我", "请", "计算一下", "计算", "求一下"] {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ?？。"))
        // Bounds containing spaces are supported in the Chinese form, e.g. 从 -pi / 2 到 pi / 2.
        if let parts = Self.capture(#"^(?:求)?定积分\s*(.+?)\s*从\s*(.+?)\s*到\s*(.+)$"#, text) {
            operation = .definite(parts[1], parts[2]); expression = Self.clean(parts[0]); return
        }
        if let parts = Self.capture(#"^(?:求)?定积分\s*(.+?)\s*[,，]\s*(.+?)\s*[,，]\s*(.+)$"#, text) {
            operation = .definite(parts[1], parts[2]); expression = Self.clean(parts[0]); return
        }
        // Unambiguous compact bounds: ∫_0^1 x^2 dx, ∫_{-pi}^{pi} sin(x) dx.
        if let parts = Self.capture(#"^∫_\{([^}]+)\}\^\{([^}]+)\}\s*(.+?)\s*d\s*x$"#, text) {
            operation = .definite(parts[0], parts[1]); expression = Self.clean(parts[2]); return
        }
        if let parts = Self.capture(#"^∫_([^\s\^]+)\^([^\s]+)\s+(.+?)\s*d\s*x$"#, text) {
            operation = .definite(parts[0], parts[1]); expression = Self.clean(parts[2]); return
        }
        if text.contains("求导") || text.contains("导数") || text.lowercased().hasPrefix("differentiate ") {
            operation = .derivative
            expression = Self.clean(text.replacingOccurrences(of: "求导", with: "").replacingOccurrences(of: "导数", with: "")
                .replacingOccurrences(of: "differentiate ", with: "", options: .caseInsensitive))
            return
        }
        if text.contains("积分") || text.hasPrefix("∫") || text.lowercased().hasPrefix("integrate ") {
            operation = .integral
            expression = Self.clean(text.replacingOccurrences(of: "不定积分", with: "").replacingOccurrences(of: "积分", with: "")
                .replacingOccurrences(of: "∫", with: "").replacingOccurrences(of: "integrate ", with: "", options: .caseInsensitive))
            return
        }
        return nil
    }

    private static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("对") { text.removeFirst() }
        if text.hasPrefix("求") { text.removeFirst() }
        text = text.replacingOccurrences(of: #"\s*d\s*x\s*$"#, with: "", options: .regularExpression)
        if text.hasSuffix("的") { text.removeLast() }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " :：="))
    }

    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

private enum MathToken: Equatable {
    case number(Double), name(String), plus, minus, star, slash, power, left, right, end
}

private struct MathParser {
    private let tokens: [MathToken]
    private var index = 0
    private var depth = 0

    init(_ source: String) throws {
        guard !source.isEmpty, source.count <= 1200 else { throw MathFailure("表达式为空或过长，请只输入要计算的函数。") }
        let chars = Array(source.lowercased())
        var result: [MathToken] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            switch ch {
            case "+": result.append(.plus); i += 1
            case "-": result.append(.minus); i += 1
            case "*": result.append(.star); i += 1
            case "/": result.append(.slash); i += 1
            case "^": result.append(.power); i += 1
            case "(": result.append(.left); i += 1
            case ")": result.append(.right); i += 1
            case "0"..."9", ".":
                let start = i
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                // Scientific notation requires a digit after e and an optional sign.
                if i < chars.count && chars[i] == "e" {
                    var j = i + 1
                    if j < chars.count && (chars[j] == "+" || chars[j] == "-") { j += 1 }
                    if j < chars.count && chars[j].isNumber {
                        i = j + 1
                        while i < chars.count && chars[i].isNumber { i += 1 }
                    }
                }
                guard let value = Double(String(chars[start..<i])), value.isFinite else { throw MathFailure("数字格式有误或超出范围。") }
                result.append(.number(value))
            case "a"..."z":
                let start = i
                while i < chars.count && chars[i].isASCII && chars[i].isLetter { i += 1 }
                result.append(.name(String(chars[start..<i])))
            default: throw MathFailure("表达式含不支持的字符“\(ch)”。请使用 x 和数学运算符。")
            }
            guard result.count <= 500 else { throw MathFailure("表达式过于复杂，请分成较小的式子。") }
        }
        tokens = result + [.end]
    }

    mutating func parse() throws -> MathExpr {
        let result = try addition()
        guard current == .end else { throw MathFailure("表达式未完整解析，请检查括号和运算符。") }
        return result
    }
    private var current: MathToken { tokens[index] }
    private mutating func take() -> MathToken { defer { index += 1 }; return current }
    private mutating func addition() throws -> MathExpr {
        var left = try multiplication()
        while current == .plus || current == .minus {
            let op = take(); let right = try multiplication()
            left = op == .plus ? .add(left, right) : .subtract(left, right)
        }
        return left
    }
    private mutating func multiplication() throws -> MathExpr {
        var left = try unary()
        while true {
            if current == .star || current == .slash {
                let op = take(); let right = try unary()
                left = op == .star ? .multiply(left, right) : .divide(left, right)
            } else if startsAtom(current) {
                left = .multiply(left, try unary())
            } else { return left }
        }
    }
    private func startsAtom(_ token: MathToken) -> Bool {
        switch token { case .number, .name, .left: return true; default: return false }
    }
    // Power binds more tightly than unary minus; powers associate to the right.
    private mutating func unary() throws -> MathExpr {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 60 else { throw MathFailure("括号或运算符嵌套过深。") }
        if current == .plus { _ = take(); return try unary() }
        if current == .minus { _ = take(); return .negate(try unary()) }
        return try power()
    }
    private mutating func power() throws -> MathExpr {
        let left = try atom()
        if current == .power { _ = take(); return .power(left, try unary()) }
        return left
    }
    private mutating func atom() throws -> MathExpr {
        switch take() {
        case .number(let value): return .constant(value)
        case .name("x"): return .variable
        case .name("pi"): return .constant(.pi)
        case .name("e"): return .constant(M_E)
        case .name(let name):
            guard ["sin", "cos", "tan", "exp", "ln", "log", "sqrt", "abs"].contains(name) else {
                throw MathFailure("不支持“\(name)”。只允许变量 x 和列出的函数。")
            }
            guard current == .left else { throw MathFailure("函数 \(name) 的参数需要括号，例如 \(name)(x)。") }
            _ = take(); let argument = try addition()
            guard current == .right else { throw MathFailure("函数参数缺少右括号。") }
            _ = take(); return .function(name == "log" ? "ln" : name, argument)
        case .left:
            let value = try addition()
            guard current == .right else { throw MathFailure("缺少右括号。") }
            _ = take(); return value
        default: throw MathFailure("这里需要数字、x 或括号内的表达式。")
        }
    }
}

private indirect enum MathExpr {
    case constant(Double), variable
    case add(MathExpr, MathExpr), subtract(MathExpr, MathExpr), multiply(MathExpr, MathExpr)
    case divide(MathExpr, MathExpr), power(MathExpr, MathExpr), negate(MathExpr), function(String, MathExpr)

    var dependsOnX: Bool {
        switch self {
        case .constant: return false
        case .variable: return true
        case .negate(let a), .function(_, let a): return a.dependsOnX
        case .add(let a, let b), .subtract(let a, let b), .multiply(let a, let b), .divide(let a, let b), .power(let a, let b): return a.dependsOnX || b.dependsOnX
        }
    }
    func checkConstantDomains() throws {
        if !dependsOnX { _ = try evaluate(0); return }
        switch self {
        case .negate(let a), .function(_, let a): try a.checkConstantDomains()
        case .divide(let a, let b):
            try a.checkConstantDomains(); try b.checkConstantDomains()
            if b.constant == 0 { throw MathFailure("分母恒为零，表达式没有定义。") }
        case .add(let a, let b), .subtract(let a, let b), .multiply(let a, let b), .power(let a, let b):
            try a.checkConstantDomains(); try b.checkConstantDomains()
        default: break
        }
    }
    var constant: Double? {
        guard !dependsOnX else { return nil }
        return try? evaluate(0)
    }
    func evaluate(_ x: Double) throws -> Double {
        let value: Double
        switch self {
        case .constant(let c): value = c
        case .variable: value = x
        case .add(let a, let b): value = try a.evaluate(x) + b.evaluate(x)
        case .subtract(let a, let b): value = try a.evaluate(x) - b.evaluate(x)
        case .multiply(let a, let b): value = try a.evaluate(x) * b.evaluate(x)
        case .divide(let a, let b):
            let denominator = try b.evaluate(x)
            guard denominator != 0 else { throw MathFailure("函数在区间内有除以零的点，不能作为正常定积分计算。") }
            value = try a.evaluate(x) / denominator
        case .power(let a, let b): value = try Foundation.pow(a.evaluate(x), b.evaluate(x))
        case .negate(let a): value = try -a.evaluate(x)
        case .function(let name, let a):
            let argument = try a.evaluate(x)
            switch name {
            case "sin": value = sin(argument)
            case "cos": value = cos(argument)
            case "tan":
                guard abs(cos(argument)) > 1e-14 else { throw MathFailure("tan 在此处无定义。") }
                value = tan(argument)
            case "exp": value = exp(argument)
            case "ln": value = log(argument)
            case "sqrt": value = sqrt(argument)
            case "abs": value = abs(argument)
            default: throw MathFailure("未知函数。")
            }
        }
        guard value.isFinite else { throw MathFailure("表达式在所需点没有有限实数值，或数值超出范围。") }
        return value
    }

    func derivative() throws -> MathExpr {
        let zero = MathExpr.constant(0), one = MathExpr.constant(1)
        switch self {
        case .constant: return zero
        case .variable: return one
        case .add(let a, let b): return .add(try a.derivative(), try b.derivative())
        case .subtract(let a, let b): return .subtract(try a.derivative(), try b.derivative())
        case .negate(let a): return .negate(try a.derivative())
        case .multiply(let a, let b): return .add(.multiply(try a.derivative(), b), .multiply(a, try b.derivative()))
        case .divide(let a, let b): return .divide(.subtract(.multiply(try a.derivative(), b), .multiply(a, try b.derivative())), .power(b, .constant(2)))
        case .power(let a, let b):
            if let exponent = b.constant {
                if exponent == 0 { return zero }
                return .multiply(.multiply(.constant(exponent), .power(a, .constant(exponent - 1))), try a.derivative())
            }
            // The logarithmic rule assumes a positive base in the real domain.
            return .multiply(self, .add(.multiply(try b.derivative(), .function("ln", a)), .divide(.multiply(b, try a.derivative()), a)))
        case .function(let name, let a):
            let outer: MathExpr
            switch name {
            case "sin": outer = .function("cos", a)
            case "cos": outer = .negate(.function("sin", a))
            case "tan": outer = .divide(one, .power(.function("cos", a), .constant(2)))
            case "exp": outer = .function("exp", a)
            case "ln": outer = .divide(one, a)
            case "sqrt": outer = .divide(one, .multiply(.constant(2), .function("sqrt", a)))
            case "abs": throw MathFailure("abs 的导数需要分段并检查不可导点，当前不自动求导；可输入具体分段函数。")
            default: throw MathFailure("该函数暂不支持求导。")
            }
            return .multiply(outer, try a.derivative())
        }
    }

    func antiderivative() -> MathExpr? {
        if let c = constant { return .multiply(.constant(c), .variable) }
        // Expand modest polynomials, including (x+1)^3 and x*x.
        if let coefficients = polynomial, coefficients.count <= 33 {
            var result = MathExpr.constant(0)
            for (power, coefficient) in coefficients.enumerated() where coefficient != 0 {
                result = .add(result, .multiply(.constant(coefficient / Double(power + 1)), .power(.variable, .constant(Double(power + 1)))))
            }
            return result.simplified
        }
        switch self {
        case .add(let a, let b):
            guard let ia = a.antiderivative(), let ib = b.antiderivative() else { return nil }; return .add(ia, ib)
        case .subtract(let a, let b):
            guard let ia = a.antiderivative(), let ib = b.antiderivative() else { return nil }; return .subtract(ia, ib)
        case .negate(let a): return a.antiderivative().map { .negate($0) }
        case .multiply(let a, let b):
            if let c = a.constant, let integral = b.antiderivative() { return .multiply(.constant(c), integral) }
            if let c = b.constant, let integral = a.antiderivative() { return .multiply(.constant(c), integral) }
            return nil
        case .divide(let a, let b):
            if let c = b.constant, c != 0, let integral = a.antiderivative() { return .divide(integral, .constant(c)) }
            if let c = a.constant, let slope = b.affineSlope, slope != 0 {
                return .multiply(.constant(c / slope), .function("ln", .function("abs", b)))
            }
            return nil
        case .power(let base, let exponent):
            guard let n = exponent.constant, let slope = base.affineSlope, slope != 0 else { return nil }
            if n == -1 { return .divide(.function("ln", .function("abs", base)), .constant(slope)) }
            return .divide(.power(base, .constant(n + 1)), .constant(slope * (n + 1)))
        case .function(let name, let a):
            guard let slope = a.affineSlope, slope != 0 else { return nil }
            let primitive: MathExpr
            switch name {
            case "sin": primitive = .negate(.function("cos", a))
            case "cos": primitive = .function("sin", a)
            case "tan": primitive = .negate(.function("ln", .function("abs", .function("cos", a))))
            case "exp": primitive = .function("exp", a)
            case "ln": primitive = .subtract(.multiply(a, .function("ln", a)), a)
            case "sqrt": primitive = .multiply(.constant(2.0 / 3.0), .power(a, .constant(1.5)))
            default: return nil
            }
            return .divide(primitive, .constant(slope))
        default: return nil
        }
    }

    private var affineSlope: Double? {
        guard let p = polynomial, p.count <= 2 else { return nil }
        return p.count == 2 ? p[1] : 0
    }
    private var polynomial: [Double]? {
        switch self {
        case .constant(let c): return [c]
        case .variable: return [0, 1]
        case .negate(let a): return a.polynomial?.map { -$0 }
        case .add(let a, let b), .subtract(let a, let b):
            guard let pa = a.polynomial, let pb = b.polynomial else { return nil }
            var result = Array(repeating: 0.0, count: max(pa.count, pb.count))
            for i in pa.indices { result[i] += pa[i] }
            let sign: Double
            if case .subtract = self { sign = -1 } else { sign = 1 }
            for i in pb.indices { result[i] += sign * pb[i] }
            guard result.allSatisfy(\.isFinite) else { return nil }
            while result.count > 1 && result.last == 0 { result.removeLast() }
            return result
        case .multiply(let a, let b):
            guard let pa = a.polynomial, let pb = b.polynomial, pa.count + pb.count <= 34 else { return nil }
            let result = Self.polynomialProduct(pa, pb)
            return result.allSatisfy(\.isFinite) ? result : nil
        case .divide(let a, let b):
            guard let pa = a.polynomial, let c = b.constant, c != 0 else { return nil }; return pa.map { $0 / c }
        case .power(let a, let b):
            guard let n = b.constant, n >= 0, n <= 32, n.rounded() == n, let pa = a.polynomial,
                  Double(pa.count - 1) * n <= 32 else { return nil }
            var result = [1.0]
            for _ in 0..<Int(n) {
                result = Self.polynomialProduct(result, pa)
                guard result.allSatisfy(\.isFinite) else { return nil }
            }
            return result
        default:
            return constant.map { [$0] }
        }
    }
    private static func polynomialProduct(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: a.count + b.count - 1)
        for i in a.indices { for j in b.indices { result[i + j] += a[i] * b[j] } }
        return result
    }

    var simplified: MathExpr {
        switch self {
        case .constant, .variable: return self
        case .negate(let a):
            let a = a.simplified
            if case .constant(let c) = a { return .constant(-c) }
            if case .negate(let nested) = a { return nested }
            return .negate(a)
        case .function(let name, let a):
            let result = MathExpr.function(name, a.simplified)
            return result.constant.map { .constant($0) } ?? result
        case .add(let a, let b):
            let a = a.simplified, b = b.simplified
            if a.constant == 0 { return b }; if b.constant == 0 { return a }
            let result = MathExpr.add(a, b); return result.constant.map { .constant($0) } ?? result
        case .subtract(let a, let b):
            let a = a.simplified, b = b.simplified
            if b.constant == 0 { return a }; if a.constant == 0 { return .negate(b).simplified }
            let result = MathExpr.subtract(a, b); return result.constant.map { .constant($0) } ?? result
        case .multiply(let a, let b):
            let a = a.simplified, b = b.simplified
            if a.constant == 0 || b.constant == 0 { return .constant(0) }
            if a.constant == 1 { return b }; if b.constant == 1 { return a }
            if a.constant == -1 { return .negate(b).simplified }; if b.constant == -1 { return .negate(a).simplified }
            let result = MathExpr.multiply(a, b); return result.constant.map { .constant($0) } ?? result
        case .divide(let a, let b):
            let a = a.simplified, b = b.simplified
            if b.constant == 1 { return a }
            if a.constant == 0, b.constant != 0 { return .constant(0) }
            let result = MathExpr.divide(a, b); return result.constant.map { .constant($0) } ?? result
        case .power(let a, let b):
            let a = a.simplified, b = b.simplified
            if b.constant == 1 { return a }; if b.constant == 0 { return .constant(1) }
            let result = MathExpr.power(a, b); return result.constant.map { .constant($0) } ?? result
        }
    }

    var rendered: String { render(parentPrecedence: 0) }
    private var precedence: Int {
        switch self { case .add, .subtract: return 1; case .multiply, .divide: return 2; case .negate: return 3; case .power: return 4; default: return 5 }
    }
    private func render(parentPrecedence: Int) -> String {
        let text: String
        switch self {
        case .constant(let c): text = MathFormat.number(c)
        case .variable: text = "x"
        case .add(let a, let b): text = "\(a.render(parentPrecedence: 1)) + \(b.render(parentPrecedence: 1))"
        case .subtract(let a, let b): text = "\(a.render(parentPrecedence: 1)) - \(b.render(parentPrecedence: 2))"
        case .multiply(let a, let b): text = "\(a.render(parentPrecedence: 2)) * \(b.render(parentPrecedence: 2))"
        case .divide(let a, let b): text = "\(a.render(parentPrecedence: 2)) / \(b.render(parentPrecedence: 3))"
        case .power(let a, let b): text = "\(a.render(parentPrecedence: 5))^\(b.render(parentPrecedence: 4))"
        case .negate(let a): text = "-\(a.render(parentPrecedence: 3))"
        case .function(let name, let a): text = "\(name)(\(a.rendered))"
        }
        // Negative constants need parentheses in a power's base or exponent.
        let negativeConstant: Bool
        if case .constant(let c) = self { negativeConstant = c < 0 } else { negativeConstant = false }
        return precedence < parentPrecedence || (negativeConstant && parentPrecedence >= 4) ? "(\(text))" : text
    }
}

private enum MathFormat {
    static func number(_ number: Double) -> String {
        if number == 0 { return "0" }
        if number == Double.pi { return "pi" }
        if number == M_E { return "e" }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), number)
    }
}

private struct MathInterval {
    let low: Double
    let high: Double
    init(_ low: Double, _ high: Double) throws {
        guard low.isFinite, high.isFinite, low <= high else { throw MathFailure("区间计算超出数值范围。") }
        self.low = low; self.high = high
    }
    var containsZero: Bool { low <= 0 && high >= 0 }
    static func product(_ a: Self, _ b: Self) throws -> Self {
        let values = [a.low * b.low, a.low * b.high, a.high * b.low, a.high * b.high]
        return try Self(values.min()!, values.max()!)
    }
}

private extension MathExpr {
    /// Conservative range enclosure, used to reject poles and real-domain violations.
    func interval(_ x: MathInterval) throws -> MathInterval {
        switch self {
        case .constant(let c): return try MathInterval(c, c)
        case .variable: return x
        case .negate(let a): let a = try a.interval(x); return try MathInterval(-a.high, -a.low)
        case .add(let a, let b): let a = try a.interval(x), b = try b.interval(x); return try MathInterval(a.low + b.low, a.high + b.high)
        case .subtract(let a, let b): let a = try a.interval(x), b = try b.interval(x); return try MathInterval(a.low - b.high, a.high - b.low)
        case .multiply(let a, let b): return try MathInterval.product(a.interval(x), b.interval(x))
        case .divide(let a, let b):
            let a = try a.interval(x), b = try b.interval(x)
            guard !b.containsZero else { throw MathFailure("区间内可能存在除零或奇点。") }
            return try MathInterval.product(a, MathInterval(1 / b.high, 1 / b.low))
        case .power(let a, let b):
            let a = try a.interval(x)
            if let n = b.constant {
                if n.rounded() == n {
                    if n < 0 && a.containsZero { throw MathFailure("负幂在零点产生奇点。") }
                    if n == 0 { return try MathInterval(1, 1) }
                    guard abs(n) <= 10000 else { throw MathFailure("幂指数过大。") }
                    let endpoints = [pow(a.low, n), pow(a.high, n)]
                    let low = (n > 0 && Int(n) % 2 == 0 && a.containsZero) ? 0 : endpoints.min()!
                    return try MathInterval(low, endpoints.max()!)
                }
                guard a.low >= 0, n > 0 || a.low > 0 else { throw MathFailure("非整数幂在区间内可能没有有限实数值。") }
                let endpoints = [pow(a.low, n), pow(a.high, n)]
                return try MathInterval(endpoints.min()!, endpoints.max()!)
            }
            guard a.low > 0 else { throw MathFailure("变量指数需要底数在整个区间内为正。") }
            let b = try b.interval(x)
            let exponent = try MathInterval.product(MathInterval(log(a.low), log(a.high)), b)
            return try MathInterval(exp(exponent.low), exp(exponent.high))
        case .function(let name, let argument):
            let a = try argument.interval(x)
            switch name {
            case "ln":
                guard a.low > 0 else { throw MathFailure("ln/log 的参数须在整个闭区间内大于零。") }
                return try MathInterval(log(a.low), log(a.high))
            case "sqrt":
                guard a.low >= 0 else { throw MathFailure("sqrt 的参数在区间内可能为负。") }
                return try MathInterval(sqrt(a.low), sqrt(a.high))
            case "exp": return try MathInterval(exp(a.low), exp(a.high))
            case "abs": return try MathInterval(a.containsZero ? 0 : min(abs(a.low), abs(a.high)), max(abs(a.low), abs(a.high)))
            case "tan":
                let firstPole = ceil((a.low - .pi / 2) / .pi)
                let lastPole = floor((a.high - .pi / 2) / .pi)
                guard firstPole > lastPole else { throw MathFailure("tan 在积分区间内有奇点。") }
                return try MathInterval(tan(a.low), tan(a.high))
            case "sin", "cos":
                guard a.high - a.low < 2 * .pi else { return try MathInterval(-1, 1) }
                let fn: (Double) -> Double = name == "sin" ? { sin($0) } : { cos($0) }
                var low = min(fn(a.low), fn(a.high)), high = max(fn(a.low), fn(a.high))
                let maximumPhase = name == "sin" ? Double.pi / 2 : 0
                let minimumPhase = maximumPhase + .pi
                if ceil((a.low - maximumPhase) / (2 * .pi)) <= floor((a.high - maximumPhase) / (2 * .pi)) { high = 1 }
                if ceil((a.low - minimumPhase) / (2 * .pi)) <= floor((a.high - minimumPhase) / (2 * .pi)) { low = -1 }
                return try MathInterval(low, high)
            default: throw MathFailure("未知函数。")
            }
        }
    }
}

private enum NumericalIntegral {
    struct Result { let value: Double; let error: Double }
    static func compute(_ expression: MathExpr, from a: Double, to b: Double) throws -> Result {
        guard abs(b - a) <= 1e8 else { throw MathFailure("积分区间过大，请缩小区间。") }
        let lower = min(a, b), upper = max(a, b)
        // Check endpoints even for a zero-width interval; do not hide 1/0 as zero.
        _ = try expression.evaluate(lower); _ = try expression.evaluate(upper)
        if lower == upper { return Result(value: 0, error: 0) }
        var validationBudget = 30000
        func validate(_ low: Double, _ high: Double, _ depth: Int) throws {
            validationBudget -= 1
            guard validationBudget > 0 else { throw MathFailure("无法在计算限制内确认区间连续性，请缩小区间或化简表达式。") }
            do { _ = try expression.interval(MathInterval(low, high)) }
            catch {
                guard depth < 18 else { throw MathFailure("无法确认区间内没有奇点或定义域错误；本工具不计算反常积分。") }
                let mid = low + (high - low) / 2
                _ = try expression.evaluate(mid)
                try validate(low, mid, depth + 1); try validate(mid, high, depth + 1)
            }
        }
        try validate(lower, upper, 0)
        var samples = 0
        func value(_ x: Double) throws -> Double {
            samples += 1
            guard samples <= 150000 else { throw MathFailure("积分未在计算限制内收敛，可能振荡过快或接近奇点。") }
            return try expression.evaluate(x)
        }
        func simpson(_ a: Double, _ b: Double, _ fa: Double, _ fm: Double, _ fb: Double) -> Double {
            (b - a) * (fa + 4 * fm + fb) / 6
        }
        func recurse(_ a: Double, _ b: Double, _ fa: Double, _ fm: Double, _ fb: Double,
                     _ whole: Double, _ tolerance: Double, _ depth: Int) throws -> Result {
            let mid = a + (b - a) / 2
            let fl = try value(a + (mid - a) / 2), fr = try value(mid + (b - mid) / 2)
            let left = simpson(a, mid, fa, fl, fm), right = simpson(mid, b, fm, fr, fb)
            let delta = left + right - whole
            guard delta.isFinite else { throw MathFailure("积分计算超出数值范围。") }
            if abs(delta) <= 15 * tolerance { return Result(value: left + right + delta / 15, error: abs(delta) / 15) }
            guard depth < 24 else { throw MathFailure("积分误差未达到容差，拒绝返回可能不可靠的结果。") }
            // Avoid assigning sub-machine absolute budgets at a nonsmooth but finite endpoint.
            // Summed estimated error is checked again after all panels complete.
            let childTolerance = max(tolerance / 2, 1e-14)
            let l = try recurse(a, mid, fa, fl, fm, left, childTolerance, depth + 1)
            let r = try recurse(mid, b, fm, fr, fb, right, childTolerance, depth + 1)
            return Result(value: l.value + r.value, error: l.error + r.error)
        }
        // Coprime initial meshes provide an independent check against periodic sample aliasing.
        func integrate(panels: Int) throws -> Result {
            var total = 0.0, error = 0.0
            for i in 0..<panels {
                let left = lower + (upper - lower) * Double(i) / Double(panels)
                let right = lower + (upper - lower) * Double(i + 1) / Double(panels)
                let fa = try value(left), fm = try value(left + (right - left) / 2), fb = try value(right)
                let whole = simpson(left, right, fa, fm, fb)
                let result = try recurse(left, right, fa, fm, fb, whole, 1e-8 / Double(panels), 0)
                total += result.value; error += result.error
            }
            return Result(value: total, error: error)
        }
        let first = try integrate(panels: 64)
        let second = try integrate(panels: 67)
        guard first.value.isFinite, second.value.isFinite else { throw MathFailure("积分结果超出数值范围。") }
        guard first.error <= 1e-7, second.error <= 1e-7 else { throw MathFailure("累计积分误差超出容差，请缩小区间。") }
        guard abs(first.value - second.value) <= max(1e-7, 4 * (first.error + second.error)) else {
            throw MathFailure("两次独立网格的结果不一致，函数可能振荡过快；请缩小积分区间。")
        }
        return Result(value: a <= b ? second.value : -second.value, error: max(second.error, abs(first.value - second.value)))
    }
}
