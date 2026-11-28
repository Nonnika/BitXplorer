import Foundation

/// 命令面板的语法高亮：把输入切成带类别的片段（按字符偏移）。
/// 规则跟随 FileSearch（`/名称/范围/类型`）与 TextReplace（`%s/路径/目标/替换`）的解析，只管着色；改语法时两边一起改
enum CommandSyntax {
    enum Kind: Hashable, Sendable { case keyword, separator, variable, escape, wildcard, argument, error }
    struct Token: Hashable, Sendable {
        let range: Range<Int>
        let kind: Kind
    }

    /// `isPath`：以 `/` 开头、含第二个 `/` 的输入是否为已存在的路径（面板此时按路径前往，不着色）
    static func tokens(_ text: String, isPath: (String) -> Bool = { _ in false }) -> [Token] {
        withoutActuallyEscaping(isPath) { isPath in
            var highlighter = Highlighter(chars: Array(text), isPath: isPath)
            highlighter.command(0, highlighter.chars.count)
            return highlighter.tokens
        }
    }

    /// 「神奇重命名」的查找 / 替换框：只有一段文字，`/` 是普通字符，变量与转义同 `%s`；`*` 只在查找框里是通配
    static func fieldTokens(_ text: String, isTarget: Bool) -> [Token] {
        var highlighter = Highlighter(chars: Array(text), isPath: { _ in false })
        highlighter.replace(0, highlighter.chars.count, splitsOnSlash: false, wildcardField: isTarget ? 0 : -1)
        return highlighter.tokens
    }
}

private struct Highlighter {
    typealias Kind = CommandSyntax.Kind
    let chars: [Character]
    let isPath: (String) -> Bool
    var tokens: [CommandSyntax.Token] = []

    mutating func add(_ start: Int, _ end: Int, _ kind: Kind) {
        if start < end { tokens.append(.init(range: start..<end, kind: kind)) }
    }

    /// 一条面板命令：`%s/` 替换、`/` 搜索，其余为路径（只标 `\x` 转义，路径解析会去掉反斜杠）
    mutating func command(_ start: Int, _ end: Int) {
        var i = start
        while i < end, chars[i].isWhitespace { i += 1 }
        let text = String(chars[i..<end])
        if text.hasPrefix("%s/") {
            add(i, i + 2, .keyword)
            replace(i + 2, end)
        } else if text.hasPrefix("/"), !(text.dropFirst().contains("/") && isPath(text)) {
            search(i, end)
        } else {
            while i < end {
                if chars[i] == "\\", i + 1 < end {
                    add(i, i + 2, .escape)
                    i += 1
                }
                i += 1
            }
        }
    }

    /// FileSearch 先按 `/` 切段再处理转义，所以 `\/` 不算转义
    mutating func search(_ start: Int, _ end: Int) {
        add(start, start + 1, .separator)
        var i = start + 1
        let nameEnd = chars[i..<end].firstIndex(of: "/") ?? end
        if String(chars[i..<nameEnd]).hasPrefix("$REGX(") {
            // 整段正则：结尾的 ) 之前都是表达式
            let close = chars[nameEnd - 1] == ")" && nameEnd - i > 6 ? nameEnd - 1 : nameEnd
            add(i, i + 6, .variable)
            group(i + 5, close) { _ in .argument }
            add(close, nameEnd, .variable)
            i = nameEnd
        }
        while i < end, chars[i] != "/" {
            if chars[i] == "\\", i + 1 < end, chars[i + 1] != "/" {
                add(i, i + 2, .escape)
                i += 2
                continue
            }
            if chars[i] == "*" { add(i, i + 1, .wildcard) }
            i += 1
        }
        while i < end {
            add(i, i + 1, .separator)
            i += 1
            let s = i
            while i < end, chars[i] != "/" { i += 1 }
            let option = String(chars[s..<i]).trimmingCharacters(in: .whitespaces).lowercased()
            guard !option.isEmpty else { continue }
            let valid = ["g", "f", "d"].contains(option) || (option.hasPrefix("d:") && (Int(option.dropFirst(2)) ?? 0) >= 1)
            add(s, i, valid ? .keyword : .error)
        }
    }

    /// `wildcardField`：数到第几个 `/` 之后的 `*` 是通配。`%s` 从紧跟的 `/` 开始，路径为 1、目标为 2
    mutating func replace(_ start: Int, _ end: Int, splitsOnSlash: Bool = true, wildcardField: Int = 2) {
        var i = start, field = 0
        while i < end {
            switch chars[i] {
            case "/" where splitsOnSlash:
                add(i, i + 1, .separator)
                field += 1
                i += 1
            case "*":
                if field == wildcardField { add(i, i + 1, .wildcard) }
                i += 1
            case "\\":
                if i + 1 < end, "/$*\\".contains(chars[i + 1]) { add(i, i + 2, .escape) }
                i += 2
            case "$":
                i = variable(i, end)
            default:
                i += 1
            }
        }
    }

    /// `$(命令)`、`$FILENAME`、`$SUFFIX`、`$DATETIME(格式)`、`$REGX(正则)`，返回其后的位置
    mutating func variable(_ start: Int, _ end: Int) -> Int {
        var i = start + 1
        if i < end, chars[i] == "(" {
            let close = groupEnd(i, end)
            add(start, i + 1, .variable)
            command(i + 1, close)
            add(close, min(close + 1, end), .variable)
            return min(close + 1, end)
        }
        while i < end, chars[i].isASCII, chars[i].isLetter || chars[i] == "_" { i += 1 }
        let name = String(chars[start + 1..<i])
        let known = ["FILENAME", "SUFFIX", "DATETIME", "REGX"]
        if known.contains(name) || (i == end && known.contains { $0.hasPrefix(name) }) {
            add(start, i, .variable)
        } else {
            add(start, max(i, start + 1), .error)
        }
        guard name == "DATETIME" || name == "REGX", i < end, chars[i] == "(" else { return i }
        let close = groupEnd(i, end)
        add(i, i + 1, .variable)
        let isDate = name == "DATETIME"
        group(i, close) { isDate && "ymdYMD".contains($0) ? .keyword : .argument }
        add(close, min(close + 1, end), .variable)
        return min(close + 1, end)
    }

    /// 括号内的内容（`open` 为左括号位置，不含）：`\x` 为转义，其余按 `kind` 着色
    mutating func group(_ open: Int, _ close: Int, kind: (Character) -> Kind) {
        var j = open + 1
        while j < close {
            if chars[j] == "\\", j + 1 < close {
                add(j, j + 2, .escape)
                j += 2
                continue
            }
            add(j, j + 1, kind(chars[j]))
            j += 1
        }
    }

    /// 与 `(` 配对的 `)` 的位置（跳过 `\x`），未闭合返回 end
    func groupEnd(_ open: Int, _ end: Int) -> Int {
        var depth = 0, i = open
        while i < end {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return end
    }
}
