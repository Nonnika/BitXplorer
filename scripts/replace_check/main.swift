// 命令面板批量替换与语法高亮自检：swiftc TextReplace.swift CommandSyntax.swift main.swift，见 run.sh
import Foundation

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}
func parse(_ s: String) -> TextReplace? { try? TextReplace.parse(s).get() }
func error(_ s: String) -> TextReplace.ParseError? {
    if case .failure(let e) = TextReplace.parse(s) { e } else { nil }
}

// 解析
check(parse("a.txt/foo/bar") == TextReplace(paths: [.text("a.txt")], target: [.text("foo")], replacement: [.text("bar")]), "基本三段")
check(parse("a.txt/foo/")?.replacement == [], "替换为空即删除")
check(parse("a.txt/foo/bar/")?.replacement == [.text("bar")], "结尾多一个 /")
check(parse("sub\\/a.txt/a\\/b/\\$5\\\\")?.paths == [.text("sub/a.txt")], "\\/ 为字面斜杠")
check(parse("a/a\\/b/\\$5\\\\")?.replacement == [.text("$5\\")], "\\$ 与 \\\\")
check(parse("a/\\*x/y")?.target == [.text("\\*x")], "其他 \\x 原样保留")
check(parse("$(/*.md/f)/x/y")?.paths == [.command("/*.md/f")], "$(…) 内的 / 不分段")
check(parse("$(/a\\(b/f)/x/y")?.paths == [.command("/a\\(b/f")], "$(…) 内转义原样交给内层")
check(parse("$(/(a)/f)/x/y")?.paths == [.command("/(a)/f")], "嵌套括号")
check(parse("a/v1/$FILENAME-$DATETIME(yy/mm/dd)")?.replacement == [.fileName, .text("-"), .dateTime("yy/mm/dd")], "变量")
check(parse("a/x/$DATETIME")?.replacement == [.dateTime("yy-mm-dd")], "默认日期格式")
check(error("a/foo") == .incomplete && error("$(/a") == .incomplete && error("a/x/$FILEN") == .incomplete, "未输完")
check(error("a/x/$") == .incomplete, "刚输入 $")
check(error("a/x/$FOO") != nil && error("a/x/$ y") != nil, "未知变量 / 孤立 $")
check(error("a/x/y/z") != nil && error("/x/y") != nil && error("a//y") != nil, "字段过多 / 缺路径 / 缺目标")
check(error("$FILENAME/x/y") != nil && error("a$(/b)/x/y") != nil && error("a/$(/b)/y") != nil, "变量位置不合法")

// 日期
let date = DateComponents(calendar: .current, year: 2005, month: 9, day: 1).date!
check(TextReplace.format(date, "yy/mm/dd") == "2005/09/01", "双字母")
check(TextReplace.format(date, "y.m.d") == "05.9.1", "单字母")
check(TextReplace.format(date, "yymmdd") == "20050901", "省略分隔符")
check(TextReplace.format(date, "YY年MM月DD日") == "2005年09月01日", "大写与其他分隔符")
check(TextReplace.format(date, "\\y\\)yy") == "y)2005", "格式中的转义")

// 执行
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.sh")
let link = dir.appendingPathComponent("link.txt"), bin = dir.appendingPathComponent("bin")
try! "foo foo bar".write(to: a, atomically: true, encoding: .utf8)
try! "echo foo".write(to: b, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.path)
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
try! Data([0xff, 0xfe, 0x66, 0x6f, 0x6f]).write(to: bin)
let all = [a, b, link, bin, dir]
func run(_ s: String, write: Bool) throws(TextReplace.ParseError) -> [TextReplace.Change] {
    try parse(s)!.run(now: date, write: write, command: { _ in all }, resolve: { $0 == "a.txt" ? a : nil })
}
func text(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }

let preview = try! run("$(*)/foo/[$FILENAME]", write: false)
check(preview.map(\.count) == [2, 1] && text(a) == "foo foo bar", "预览：计数、去重链接、跳过二进制与文件夹，不写文件")
_ = try! run("$(*)/foo/[$FILENAME]", write: true)
check(text(a) == "[a.txt] [a.txt] bar" && text(b) == "echo [b.sh]", "写回，$FILENAME 按文件展开")
check((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "符号链接保持为链接")
let mode = (try! FileManager.default.attributesOfItem(atPath: b.path)[.posixPermissions] as! NSNumber).intValue
check(mode == 0o755, "保留可执行权限")
check((try? run("a.txt/[a.txt]/$DATETIME(y.m.d)", write: true))?.first?.count == 2 && text(a) == "05.9.1 05.9.1 bar", "普通路径 + 日期")
check((try? run("nope/x/y", write: false)) == nil, "找不到路径")

// 语法高亮：把每个片段写成「文字:类别首字母」便于比对
func hl(_ s: String, isPath: (String) -> Bool = { _ in false }) -> [String] {
    let c = Array(s)
    return CommandSyntax.tokens(s, isPath: isPath).map { t in
        String(c[t.range]) + ":" + String(String(describing: t.kind).prefix(3))
    }
}
check(hl("/a*\\*b/d:2/x") == ["/:sep", "*:wil", "\\*:esc", "/:sep", "d:2:key", "/:sep", "x:err"], "搜索：通配、转义、选项与错误")
check(hl("/Users/me", isPath: { _ in true }) == [] && hl("~/x") == [], "路径不着色")
check(hl("%s/$(/*.md/f)/a\\/b/$FILENAME") == ["%s:key", "/:sep", "$(:var", "/:sep", "*:wil", "/:sep", "f:key", "):var", "/:sep", "\\/:esc", "/:sep", "$FILENAME:var"], "替换：内嵌命令按搜索着色")
check(hl("%s/a/b/$DATETIME(yy-m)") == ["%s:key", "/:sep", "/:sep", "/:sep", "$DATETIME:var", "(:var", "y:key", "y:key", "-:arg", "m:key", "):var"], "日期格式")
check(hl("%s/a/b/$FOO") .last == "$FOO:err" && hl("%s/a/b/$FILE").last == "$FILE:var" && hl("%s/a/$ x").contains("$:err"), "未知变量标红，打一半不标")
check(hl("%s/$(/a") == ["%s:key", "/:sep", "$(:var", "/:sep"], "括号未闭合")
check(hl("%s/$(/a\\)b/f)/x/y")[4] == "\\):esc", "内嵌搜索的转义")
check(hl("%s/$(~/My\\ File)/x/y") == ["%s:key", "/:sep", "$(:var", "\\ :esc", "):var", "/:sep", "/:sep"], "内嵌路径的转义")
check(hl("%s/a/x/$DATETIME(y\\)m)").suffix(5) == ["(:var", "y:key", "\\):esc", "m:key", "):var"], "日期格式的转义")
print("replace_check OK")
