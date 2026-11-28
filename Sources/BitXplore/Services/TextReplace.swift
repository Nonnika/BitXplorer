import Foundation

/// 命令面板的批量替换：`%s/路径/目标/替换`
/// - 字段以 `/` 分隔；`\/` `\$` `\\` 表示字面字符，其余 `\x` 原样保留
/// - 路径：一个文件路径（相对当前目录），或 `$(命令)` 嵌入另一条面板命令取其结果，如 `$(/*.md/f)`
/// - 变量：`$FILENAME` 当前处理文件的名字（只用于目标 / 替换）；`$DATETIME(格式)` 今天的日期，
///   格式中 `yy` `mm` `dd` 为 2005 09 01，单个 `y` `m` `d` 为 05 9 1，其余字符原样输出（`\x` 输出字面 x）；省略括号即 `yy-mm-dd`
/// - 目标按字面、区分大小写匹配；只处理 UTF-8 文本文件，文件夹与无法读取的文件跳过
struct TextReplace: Hashable, Sendable {
    enum Piece: Hashable, Sendable { case text(String), fileName, dateTime(String), command(String) }

    enum ParseError: Error, Hashable {
        /// 还没输完（字段不足、括号未闭合、变量名打了一半），显示语法提示而非报错
        case incomplete
        case invalid(String)
    }

    struct Change: Hashable, Sendable {
        let url: URL
        let count: Int
        var failed = false
    }

    let paths: [Piece], target: [Piece], replacement: [Piece]

    private static let variables = ["FILENAME", "DATETIME"]

    /// 解析 `%s/` 之后的部分
    static func parse(_ input: some StringProtocol) -> Result<TextReplace, ParseError> {
        Result { () throws(ParseError) in
            var rest = Substring(input)
            var fields: [[Piece]] = []
            var more = true
            while more {
                let field: [Piece]
                (field, more) = try readField(&rest)
                fields.append(field)
            }
            if fields.count == 4, fields[3].isEmpty { fields.removeLast() }  // 允许结尾多一个 /
            guard fields.count >= 3 else { throw .incomplete }
            guard fields.count == 3 else { throw .invalid("字段过多：文本中的 / 需写作 \\/") }
            let (paths, target, replacement) = (fields[0], fields[1], fields[2])
            guard !paths.isEmpty else { throw .invalid("缺少文件路径") }
            guard !target.isEmpty else { throw .invalid("要替换的文本不能为空") }
            if paths.contains(.fileName) { throw .invalid("$FILENAME 只能用于目标与替换文本") }
            if paths.count > 1, paths.contains(where: \.isCommand) { throw .invalid("$(命令) 需独占路径字段") }
            if (target + replacement).contains(where: \.isCommand) { throw .invalid("$(命令) 只能用于路径字段") }
            return TextReplace(paths: paths, target: target, replacement: replacement)
        }
    }

    /// 读一个字段到未转义、不在括号里的 `/`；返回是否还有下一字段
    private static func readField(_ s: inout Substring) throws(ParseError) -> ([Piece], Bool) {
        var pieces: [Piece] = []
        var text = ""
        while let ch = s.popFirst() {
            switch ch {
            case "/":
                if !text.isEmpty { pieces.append(.text(text)) }
                return (pieces, true)
            case "\\":
                guard let next = s.popFirst() else { text.append(ch); break }
                if !"/$\\".contains(next) { text.append(ch) }
                text.append(next)
            case "$":
                if !text.isEmpty { pieces.append(.text(text)) }
                text = ""
                pieces.append(try readVariable(&s))
            default:
                text.append(ch)
            }
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return (pieces, false)
    }

    private static func readVariable(_ s: inout Substring) throws(ParseError) -> Piece {
        if s.first == "(" { return .command(try readGroup(&s)) }
        let name = String(s.prefix { $0.isASCII && ($0.isLetter || $0 == "_") })
        s.removeFirst(name.count)
        switch name {
        case "FILENAME": return .fileName
        case "DATETIME": return .dateTime(s.first == "(" ? try readGroup(&s) : "yy-mm-dd")
        case _ where s.isEmpty && variables.contains(where: { $0.hasPrefix(name) }): throw .incomplete
        case "": throw .invalid("$ 后需接变量名或 (命令)，字面的 $ 写作 \\$")
        default: throw .invalid("未知变量 $\(name)：可用 $FILENAME、$DATETIME(格式)、$(命令)")
        }
    }

    /// 读 `(…)` 内的原文（支持嵌套括号，`\x` 原样保留交给内层命令）
    private static func readGroup(_ s: inout Substring) throws(ParseError) -> String {
        s.removeFirst()
        var depth = 1, raw = ""
        while let ch = s.popFirst() {
            if ch == "\\", let next = s.popFirst() {
                raw += "\\\(next)"
                continue
            }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if depth == 0 { return raw }
            raw.append(ch)
        }
        throw .incomplete
    }

    static func expand(_ pieces: [Piece], fileName: String, now: Date) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .fileName: fileName
            case .dateTime(let pattern): format(now, pattern)
            case .command(let raw): "$(\(raw))"  // parse 已保证不会出现在文本里
            }
        }.joined()
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let (year, month, day) = (c.year ?? 0, c.month ?? 0, c.day ?? 0)
        var out = "", rest = Substring(pattern)
        while let ch = rest.first {
            if ch == "\\", rest.count > 1 {
                out.append(rest.dropFirst().first!)
                rest.removeFirst(2)
                continue
            }
            let run = rest.prefix { $0 == ch }
            rest.removeFirst(run.count)
            let full = run.count > 1
            switch ch.lowercased() {
            case "y": out += full ? String(year) : String(format: "%02d", year % 100)
            case "m": out += full ? String(format: "%02d", month) : String(month)
            case "d": out += full ? String(format: "%02d", day) : String(day)
            default: out += run
            }
        }
        return out
    }

    /// 列出每个文件的替换次数，`write` 为真时同时写回。
    /// `command` 执行 `$(…)` 内的面板命令，`resolve` 解析普通路径。写回前重新读取文件，预览后的外部修改不会被覆盖掉
    func run(
        now: Date = .now, write: Bool,
        command: (String) throws(ParseError) -> [URL],
        resolve: (String) -> URL?
    ) throws(ParseError) -> [Change] {
        let urls: [URL]
        if case .command(let raw)? = paths.first {
            urls = try command(raw)
        } else {
            let path = Self.expand(paths, fileName: "", now: now)
            guard let url = resolve(path) else { throw .invalid("找不到「\(path)」") }
            urls = [url]
        }
        var seen = Set<URL>(), changes: [Change] = []
        for url in urls where !Task.isCancelled {
            // 写到符号链接指向的真实文件，不把链接替换成普通文件
            let real = url.resolvingSymlinksInPath()
            guard seen.insert(real).inserted,
                  let content = try? String(contentsOf: real, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            let target = Self.expand(self.target, fileName: name, now: now)
            let count = content.components(separatedBy: target).count - 1
            guard count > 0 else { continue }
            var change = Change(url: url, count: count)
            if write {
                let replacement = Self.expand(self.replacement, fileName: name, now: now)
                do {
                    try content.replacingOccurrences(of: target, with: replacement)
                        .write(to: real, atomically: true, encoding: .utf8)
                } catch {
                    change.failed = true
                }
            }
            changes.append(change)
        }
        return changes
    }
}

private extension TextReplace.Piece {
    var isCommand: Bool { if case .command = self { true } else { false } }
}

extension TextReplace.ParseError {
    var message: String {
        switch self {
        case .incomplete: "%s/路径/目标/替换"
        case .invalid(let message): message
        }
    }
}
