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
check(parse("a/\\nx/y")?.target == [.text("\\nx")], "其他 \\x 原样保留")
check(parse("a/\\*x/y")?.target == [.text("*x")] && parse("a/IMG_*.png/y")?.target == [.text("IMG_"), .wildcard, .text(".png")], "\\* 字面星号，* 通配")
check(parse("a/IMG_$REGX(\\d+)/y")?.target == [.text("IMG_"), .regex("\\d+")], "$REGX(…) 原样保留反斜杠")
check(parse("a/$REGX((a|b)\\))/y")?.target == [.regex("(a|b)\\)")], "$REGX 内嵌套括号与 \\)")
check(error("$REGX(a)/x/y") != nil && error("a/x/$REGX(a)") != nil, "$REGX 只能用于目标")
check(error("a/$REGX([/y") == .incomplete && error("a/$REGX([)/y") != nil && error("a/$REGX x/y") != nil && error("a/x$REGX/y") != nil, "正则有误 / 缺括号")
check(parse("$(/*.md/f)/x/y")?.paths == [.command("/*.md/f")], "$(…) 内的 / 不分段")
check(parse("$(/a\\(b/f)/x/y")?.paths == [.command("/a\\(b/f")], "$(…) 内转义原样交给内层")
check(parse("$(/(a)/f)/x/y")?.paths == [.command("/(a)/f")], "嵌套括号")
check(parse("a/v1/$FILENAME-$DATETIME(yy/mm/dd)")?.replacement == [.fileName, .text("-"), .dateTime("yy/mm/dd")], "变量")
check(parse("a/x/$DATETIME")?.replacement == [.dateTime("yy-mm-dd")], "默认日期格式")
check(error("a/foo") == .incomplete && error("$(/a") == .incomplete && error("a/x/$FILEN") == .incomplete, "未输完")
check(error("a/x/$") == .incomplete, "刚输入 $")
check(error("a/x/$FOO") != nil && error("a/x/$ y") != nil, "未知变量 / 孤立 $")
check(error("a/x/y/z") != nil && error("/x/y") != nil && error("a//y") != nil, "字段过多 / 缺路径 / 缺目标")
check(parse("a/.$SUFFIX/_$SUFFIX.$SUFFIX")?.replacement == [.text("_"), .suffix, .text("."), .suffix], "$SUFFIX")
check(error("$SUFFIX/x/y") != nil && error("a/x/$SUFF") == .incomplete, "$SUFFIX 不能用于路径，打一半不报错")
check((try? TextReplace.parse(target: "a/b", replacement: "$FILENAME/$SUFFIX").get())
      == TextReplace(paths: [], target: [.text("a/b")], replacement: [.fileName, .text("/"), .suffix]), "右键版：/ 为普通字符")
check((try? TextReplace.parse(target: "", replacement: "x").get()) == nil
      && (try? TextReplace.parse(target: "$(/a)", replacement: "x").get()) == nil, "右键版：目标为空、$(…) 报错")
check(error("$FILENAME/x/y") != nil && error("a$(/b)/x/y") != nil && error("a/$(/b)/y") != nil, "变量位置不合法")

// 日期
let date = DateComponents(calendar: .current, year: 2005, month: 9, day: 1).date!
check(TextReplace.format(date, "yy/mm/dd") == "2005/09/01", "双字母")
check(TextReplace.format(date, "y.m.d") == "05.9.1", "单字母")
check(TextReplace.format(date, "yymmdd") == "20050901", "省略分隔符")
check(TextReplace.format(date, "YY年MM月DD日") == "2005年09月01日", "大写与其他分隔符")
check(TextReplace.format(date, "\\y\\)yy") == "y)2005", "格式中的转义")

// 目标匹配：通配、正则、字面、空匹配
func renamed(_ s: String, _ name: String) -> String { parse("a/" + s)!.newName(for: name, now: date) }
check(renamed("IMG_$REGX(\\d+)/photo", "IMG_001.png") == "photo.png", "文字 + 正则")
check(renamed("*/x", "abc.png") == "x", "* 整名只替换一次")
check(renamed("*.png/$FILENAME.bak", "a.png") == "a.png.bak", "通配 + 变量")
check(renamed("$REGX(\\d)/#", "a1b22") == "a#b##", "全部匹配处")
check(renamed("$REGX(x*)/#", "abc") == "abc", "空匹配跳过")
check(renamed("img/x", "IMG.png") == "IMG.png" && renamed("a.c/x", "abc") == "abc", "字面、区分大小写，. 不是正则")
check(renamed("\\*/-", "a*b") == "a-b", "\\* 匹配星号")

// 执行：改文件名
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
func exists(_ name: String) -> Bool { fm.fileExists(atPath: file(name).path) }
for name in ["1.png", "a.txt", "b.txt", "x.md", "X.MD", "keep.txt"] { fm.createFile(atPath: file(name).path, contents: Data(name.utf8)) }
try! fm.createDirectory(at: file("1.png.d"), withIntermediateDirectories: true)
func run(_ s: String, _ urls: [URL] = [], write: Bool) throws(TextReplace.ParseError) -> [TextReplace.Change] {
    try parse(s)!.run(now: date, write: write, command: { _ in urls },
                      resolve: { p in fm.fileExists(atPath: file(p).path) ? file(p).standardizedFileURL : nil })
}

check((try? run("1.png/$FILENAME/1+$FILENAME", write: false))?.map(\.newName) == ["1+1.png"] && exists("1.png"), "预览不改名")
_ = try! run("1.png/$FILENAME/1+$FILENAME", write: true)
check(exists("1+1.png") && !exists("1.png") && (try? String(contentsOf: file("1+1.png"), encoding: .utf8)) == "1.png", "1.png → 1+1.png，内容不变")
check((try? run("1.png.d/d/x", write: false)) == nil, "路径为文件夹时报错")
check((try? run("$(*)/1/2", [file("1.png.d"), file("1+1.png")], write: false))?.map(\.newName) == ["2+2.png"], "$(…) 结果中的文件夹跳过，名称中所有目标都替换")
let clash = try! run("$(*)/.txt/-$DATETIME(yymmdd).txt", [file("a.txt"), file("a.txt"), file("keep.txt")], write: false)
check(clash.map(\.newName) == ["a-20050901.txt", "keep-20050901.txt"] && clash.allSatisfy { $0.problem == nil }, "去重、日期")
let same = try! run("$(*)/a/b", [file("a.txt"), file("b.txt")], write: true)
check(same.first?.problem == "已存在同名文件" && exists("a.txt") && exists("b.txt"), "与已有文件重名时跳过、不覆盖")
let twin = try! run("$(*)/$FILENAME/same", [file("a.txt"), file("keep.txt")], write: true)
check(twin.map(\.problem) == [nil, "与同批文件重名"] && exists("same") && exists("keep.txt"), "同批重名只改第一个")
check((try! run("$(*)/x.md/x\\/y", [file("x.md")], write: false)).first?.problem == "名称不合法", "新名含 /")
check((try! run("x.md/x.md/X.md", write: true)).first?.problem == nil, "只改大小写不算重名")
fm.createFile(atPath: file("photo.jpeg").path, contents: nil)
let ui = try! TextReplace.parse(target: ".$SUFFIX", replacement: "-$SUFFIX.jpg").get()
check(ui.rename([file("photo.jpeg")], write: true).map(\.newName) == ["photo-jpeg.jpg"] && exists("photo-jpeg.jpg"), "右键版改名、$SUFFIX 展开")
check(ui.rename([file("1.png.d")], write: false).isEmpty, "右键版也跳过文件夹")

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
check(hl("%s/a/b/$SUFFIX").last == "$SUFFIX:var", "$SUFFIX 着色")
check(hl("%s/a/b/$FOO") .last == "$FOO:err" && hl("%s/a/b/$FILE").last == "$FILE:var" && hl("%s/a/$ x").contains("$:err"), "未知变量标红，打一半不标")
func fhl(_ s: String, target: Bool) -> [String] {
    let c = Array(s)
    return CommandSyntax.fieldTokens(s, isTarget: target).map { String(c[$0.range]) + ":" + String(String(describing: $0.kind).prefix(3)) }
}
check(fhl("a/b\\/$SUFFIX $FOO $DATETIME(y)", target: false) == ["\\/:esc", "$SUFFIX:var", "$FOO:err", "$DATETIME:var", "(:var", "y:key", "):var"], "神奇重命名框：/ 不是分隔符")
check(fhl("*$REGX(\\d)", target: true) == ["*:wil", "$REGX:var", "(:var", "\\d:esc", "):var"] && fhl("*", target: false) == [], "* 只在查找框里是通配")
check(hl("%s/a/*/*") == ["%s:key", "/:sep", "/:sep", "*:wil", "/:sep"], "%s 只有目标里的 * 着色")
check(hl("/$REGX(^a\\d)/f") == ["/:sep", "$REGX(:var", "^:arg", "a:arg", "\\d:esc", "):var", "/:sep", "f:key"], "搜索正则")
check(hl("%s/$(/a") == ["%s:key", "/:sep", "$(:var", "/:sep"], "括号未闭合")
check(hl("%s/$(/a\\)b/f)/x/y")[4] == "\\):esc", "内嵌搜索的转义")
check(hl("%s/$(~/My\\ File)/x/y") == ["%s:key", "/:sep", "$(:var", "\\ :esc", "):var", "/:sep", "/:sep"], "内嵌路径的转义")
check(hl("%s/a/x/$DATETIME(y\\)m)").suffix(5) == ["(:var", "y:key", "\\):esc", "m:key", "):var"], "日期格式的转义")
print("replace_check OK")
