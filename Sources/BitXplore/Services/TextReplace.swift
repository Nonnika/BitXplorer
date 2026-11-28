import Foundation

/// 命令面板的批量改名：`%s/路径/目标/替换`，把文件名中的目标文字替换掉，如 `%s/.\/1.png/$FILENAME/1+$FILENAME` 把 1.png 改为 1+1.png
/// - 字段以 `/` 分隔；`\/` `\$` `\*` `\\` 表示字面字符，其余 `\x` 原样保留
/// - 路径：一个文件路径（相对当前目录），或 `$(命令)` 嵌入另一条面板命令取其结果，如 `$(/*.md/f)`；只改文件，文件夹跳过
/// - 变量：`$FILENAME` 当前处理文件的名字、`$SUFFIX` 其扩展名（1.png 为 png）——这两个只用于目标 / 替换；`$DATETIME(格式)` 今天的日期，
///   格式中 `yy` `mm` `dd` 为 2005 09 01，单个 `y` `m` `d` 为 05 9 1，其余字符原样输出（`\x` 输出字面 x）；省略括号即 `yy-mm-dd`
/// - 目标区分大小写，文件名中所有匹配处都替换：`*` 为通配（任意长度），`$REGX(正则)` 嵌入正则表达式，其余按字面；
///   二者只用于目标，可与文字、变量混用，如 `IMG_$REGX(\d+)`。替换文本按字面插入（不支持 $1 分组引用）
/// - 改名后与已有文件或同批其他文件重名、名称不合法时跳过该文件，不覆盖
struct TextReplace: Hashable, Sendable {
    enum Piece: Hashable, Sendable { case text(String), fileName, suffix, dateTime(String), command(String), wildcard, regex(String) }

    enum ParseError: Error, Hashable {
        /// 还没输完（字段不足、括号未闭合、变量名打了一半），显示语法提示而非报错
        case incomplete
        case invalid(String)
    }

    struct Change: Hashable, Sendable {
        let url: URL
        let newName: String
        /// 不能改名的原因（重名、名称不合法、改名失败）；nil 为可改 / 已改
        var problem: String?
    }

    let paths: [Piece], target: [Piece], replacement: [Piece]

    private static let variables = ["FILENAME", "SUFFIX", "DATETIME", "REGX"]

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
            if paths.contains(.fileName) || paths.contains(.suffix) { throw .invalid("$FILENAME、$SUFFIX 只能用于目标与替换文本") }
            if paths.count > 1, paths.contains(where: \.isCommand) { throw .invalid("$(命令) 需独占路径字段") }
            if paths.contains(where: \.isRegex) { throw .invalid("$REGX(…) 只能用于目标文本") }
            return try make(paths: paths, target: target, replacement: replacement)
        }
    }

    /// 右键「神奇重命名」：只有目标与替换两段，`/` 是普通字符，其余写法与 `%s` 相同；文件由调用方给出（见 `rename`）
    static func parse(target: String, replacement: String) -> Result<TextReplace, ParseError> {
        Result { () throws(ParseError) in
            var t = Substring(target), r = Substring(replacement)
            return try make(paths: [], target: readField(&t, splitsOnSlash: false).0,
                            replacement: readField(&r, splitsOnSlash: false).0)
        }
    }

    private static func make(paths: [Piece], target: [Piece], replacement: [Piece]) throws(ParseError) -> TextReplace {
        guard !target.isEmpty else { throw .invalid("要替换的文本不能为空") }
        if (target + replacement).contains(where: \.isCommand) { throw .invalid("$(命令) 只能用于路径字段") }
        if replacement.contains(where: \.isRegex) { throw .invalid("$REGX(…) 只能用于目标文本") }
        let op = TextReplace(paths: paths, target: target, replacement: replacement)
        // 正则写错在这里就报出来；变量会被转义，用任意文件名试编译即可
        do { _ = try NSRegularExpression(pattern: op.targetPattern(fileName: "x", now: .now)) } catch {
            throw .invalid("正则表达式有误：\(error.localizedDescription)")
        }
        return op
    }

    /// 读一个字段到未转义、不在括号里的 `/`；返回是否还有下一字段
    private static func readField(_ s: inout Substring, splitsOnSlash: Bool = true) throws(ParseError) -> ([Piece], Bool) {
        var pieces: [Piece] = []
        var text = ""
        while let ch = s.popFirst() {
            switch ch {
            case "/" where splitsOnSlash:
                if !text.isEmpty { pieces.append(.text(text)) }
                return (pieces, true)
            case "\\":
                guard let next = s.popFirst() else { text.append(ch); break }
                if !"/$*\\".contains(next) { text.append(ch) }
                text.append(next)
            case "*":
                if !text.isEmpty { pieces.append(.text(text)) }
                text = ""
                pieces.append(.wildcard)
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
        case "SUFFIX": return .suffix
        case "DATETIME": return .dateTime(s.first == "(" ? try readGroup(&s) : "yy-mm-dd")
        case "REGX":
            if s.first == "(" { return .regex(try readGroup(&s)) }
            throw s.isEmpty ? .incomplete : .invalid("$REGX 需写成 $REGX(正则表达式)")
        case _ where s.isEmpty && variables.contains(where: { $0.hasPrefix(name) }): throw .incomplete
        case "": throw .invalid("$ 后需接变量名或 (命令)，字面的 $ 写作 \\$")
        default: throw .invalid("未知变量 $\(name)：可用 $FILENAME、$SUFFIX、$DATETIME(格式)、$REGX(正则)、$(命令)")
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
            case .suffix: (fileName as NSString).pathExtension
            case .dateTime(let pattern): format(now, pattern)
            case .command(let raw): "$(\(raw))"  // parse 已保证不会出现在文本里
            case .wildcard: "*"  // 只有目标里 * 是通配，路径与替换里是字面的 *
            case .regex(let pattern): pattern  // parse 已保证只出现在目标里
            }
        }.joined()
    }

    /// 目标对应的正则：文字与变量转义，`*` 为 `.*`，`$REGX(…)` 原样嵌入
    func targetPattern(fileName: String, now: Date) -> String {
        target.map { piece in
            switch piece {
            case .wildcard: ".*"
            case .regex(let pattern): "(?:\(pattern))"
            default: NSRegularExpression.escapedPattern(for: Self.expand([piece], fileName: fileName, now: now))
            }
        }.joined()
    }

    /// 把文件名中所有非空匹配换成替换文本（字面插入）；跳过空匹配，否则 `*` 会在末尾再匹配一次空串
    func newName(for name: String, now: Date) -> String {
        guard let regex = try? NSRegularExpression(pattern: targetPattern(fileName: name, now: now)) else { return name }
        let replacement = Self.expand(self.replacement, fileName: name, now: now)
        var out = "", last = name.startIndex
        for match in regex.matches(in: name, range: NSRange(name.startIndex..., in: name)) where match.range.length > 0 {
            guard let range = Range(match.range, in: name) else { continue }
            out += name[last..<range.lowerBound] + replacement
            last = range.upperBound
        }
        return out + name[last...]
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

    /// 列出每个文件的新名字，`write` 为真时同时改名。
    /// `command` 执行 `$(…)` 内的面板命令，`resolve` 解析普通路径。改名时重新检查重名，预览后新出现的同名文件不会被覆盖
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
            if Self.isFolder(url) { throw .invalid("「\(url.lastPathComponent)」是文件夹，路径须指向文件") }
            urls = [url]
        }
        return rename(urls, now: now, write: write)
    }

    /// 对给定文件逐个算出新名字（文件夹跳过），`write` 为真时改名
    func rename(_ urls: [URL], now: Date = .now, write: Bool) -> [Change] {
        let fm = FileManager.default
        var seen = Set<URL>(), taken = Set<String>(), changes: [Change] = []
        for url in urls where !Task.isCancelled {
            guard seen.insert(url.standardizedFileURL).inserted, !Self.isFolder(url) else { continue }
            let name = url.lastPathComponent
            let newName = newName(for: name, now: now)
            guard newName != name else { continue }
            let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
            // 文件系统多不区分大小写：只改大小写（a.png → A.png）不算重名
            let key = destination.path.lowercased()
            var change = Change(url: url, newName: newName)
            if newName.isEmpty || newName.contains("/") || newName.contains(":") || newName == "." || newName == ".." {
                change.problem = "名称不合法"
            } else if !taken.insert(key).inserted {
                change.problem = "与同批文件重名"
            } else if fm.fileExists(atPath: destination.path), key != url.path.lowercased() {
                change.problem = "已存在同名文件"
            } else if write {
                do { try fm.moveItem(at: url, to: destination) } catch { change.problem = "改名失败" }
            }
            changes.append(change)
        }
        return changes
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

private extension TextReplace.Piece {
    var isCommand: Bool { if case .command = self { true } else { false } }
    var isRegex: Bool { if case .regex = self { true } else { false } }
}

extension TextReplace.ParseError {
    var message: String {
        switch self {
        case .incomplete: "%s/路径/目标/替换"
        case .invalid(let message): message
        }
    }
}
