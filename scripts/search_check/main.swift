// 命令面板文件搜索自检：swiftc FileSearch.swift main.swift，见 run.sh
import Foundation

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}
func parse(_ s: String) -> FileSearch? { try? FileSearch.parse(s).get() }
func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

// 解析
check(parse("abc") == FileSearch(parts: ["abc"]), "纯名称")
check(parse("a/d:2/f")?.maxDepth == 2 && parse("a/d:2/f")?.kind == .file, "范围 + 类型")
check(parse("a/d/d:3")?.kind == .folder && parse("a/d/d:3")?.maxDepth == 3, "类型在前也可")
check(parse("a/g")?.maxDepth == nil, "g 不限层级")
check(parse("a//f")?.kind == .file, "空段忽略")
check(parse("a/x") == nil && parse("a/d:0") == nil && parse("a/f/f") == nil, "非法选项")
check(parse("a\\*b")?.parts == ["a*b"], "\\* 为字面星号")
check(parse("*.md")?.parts == ["", ".md"], "通配切段")

// 匹配
let m = { (p: String, n: String) in parse(p)!.matches(name: n) }
check(m("read", "README.md") && !m("xyz", "README.md"), "包含、不区分大小写")
check(m("*.md", "README.md") && !m("*.md", "README.md.bak"), "通配须整名匹配")
check(m("IMG_*", "img_001.jpg") && !m("IMG_*", "my IMG_1"), "前缀通配")
check(m("a*b*c", "aXbYc") && !m("a*b*c", "acb"), "中间段按顺序")
check(m("a*a", "aa") && !m("a*a", "a"), "首尾段不重叠")
check(m("*", "anything"), "单个 *")
check(m("a\\*b", "xa*by") && !m("a\\*b", "aXb"), "字面星号")

// 遍历：层级与类型
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let all = parse("*")!
check(names(all.find(in: root, limit: 99)) == ["top.md", "sub", "mid.md", "deep", "low.md", "App.app"], "默认全部层级，跳过隐藏与包内")
var d1 = all; d1.maxDepth = 1
check(names(d1.find(in: root, limit: 99)) == ["top.md", "sub", "App.app"], "d:1 只看当前目录")
check(names(parse("*.md/d:2")!.find(in: root, limit: 99)) == ["top.md", "mid.md"], "d:2")
check(names(parse("*/d")!.find(in: root, limit: 99)) == ["sub", "deep", "App.app"], "只要文件夹")
check(names(parse("*/f")!.find(in: root, limit: 99)) == ["top.md", "mid.md", "low.md"], "只要文件")
check(all.find(in: root, limit: 2).count == 2, "数量上限")
print("search_check OK")
