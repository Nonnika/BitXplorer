// ZipArchive 自检：swiftc 直接编译源文件，无测试框架。
// 运行：scripts/zip_check/run.sh
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
func names(_ items: [FileItem]) -> [String] { items.map { $0.name + ($0.isDirectory ? "/" : "") }.sorted() }

for zipName in ["deflate.zip", "stored.zip"] {
    let zip = root.appendingPathComponent(zipName)
    guard let (z, inner) = ZipArchive.split(zip) else { fatalError("split failed") }
    assert(z.path == zip.path && inner == "", "split root")

    // zip -D 不写目录条目：目录必须从文件路径前缀推导
    let top = try ZipArchive.list(zip: zip, inner: "", showHidden: false)
    assert(names(top) == ["a.txt", "中文目录/"], "\(zipName) top: \(names(top))")
    let withHidden = try ZipArchive.list(zip: zip, inner: "", showHidden: true)
    assert(names(withHidden) == [".hidden", "a.txt", "中文目录/"], "\(zipName) hidden: \(names(withHidden))")

    let sub = zip.appendingPathComponent("中文目录/深层", isDirectory: true)
    let (_, subInner) = ZipArchive.split(sub)!
    assert(subInner == "中文目录/深层", "inner: \(subInner)")
    let deep = try ZipArchive.list(zip: zip, inner: subInner, showHidden: false)
    assert(names(deep) == ["b.txt"], "\(zipName) deep: \(names(deep))")

    let extracted = try ZipArchive.extract(zip: zip, inner: "中文目录/深层/b.txt")
    let expected = try Data(contentsOf: root.appendingPathComponent("src/中文目录/深层/b.txt"))
    let got = try Data(contentsOf: extracted)
    assert(got == expected, "\(zipName) extract mismatch")
    assert(deep[0].size == Int64(expected.count), "size")
}

// 解出整个目录（含 -9 压缩下的空文件）
let deflate = root.appendingPathComponent("deflate.zip")
let dirOut = try ZipArchive.extract(zip: deflate, inner: "中文目录")
let fm = FileManager.default
assert(fm.fileExists(atPath: dirOut.appendingPathComponent("深层/b.txt").path), "dir extract")
let empty = try Data(contentsOf: dirOut.appendingPathComponent("empty.txt"))
assert(empty.isEmpty, "empty file")

// 加入压缩包：放进子目录、同名替换、以 - 开头的文件名
let addSrc = root.appendingPathComponent("add")
try fm.createDirectory(at: addSrc, withIntermediateDirectories: true)
try "new".write(to: addSrc.appendingPathComponent("-new.txt"), atomically: true, encoding: .utf8)
try "replaced".write(to: addSrc.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
try ZipArchive.add([addSrc.appendingPathComponent("-new.txt"), addSrc.appendingPathComponent("b.txt")],
                   to: deflate, inner: "中文目录/深层")
let afterAdd = try ZipArchive.list(zip: deflate, inner: "中文目录/深层", showHidden: false)
assert(names(afterAdd) == ["-new.txt", "b.txt"], "add: \(names(afterAdd))")
let replaced = try String(contentsOf: ZipArchive.extract(zip: deflate, inner: "中文目录/深层/b.txt"), encoding: .utf8)
assert(replaced == "replaced", "replace: \(replaced)")

// zip slip：../ 条目不得写出目标目录
let slip = try ZipArchive.extract(zip: root.appendingPathComponent("slip.zip"), inner: "ok")
assert(fm.fileExists(atPath: slip.appendingPathComponent("a.txt").path), "slip ok entry")
assert(!fm.fileExists(atPath: slip.deletingLastPathComponent().appendingPathComponent("evil.txt").path), "zip slip escaped")

// 右键菜单：压缩（单项/多项、不重名）、解压到同名文件夹、创建副本
let svc = FileSystemService()
let work = root.appendingPathComponent("menu")
try fm.createDirectory(at: work.appendingPathComponent("目录"), withIntermediateDirectories: true)
try "x".write(to: work.appendingPathComponent("目录/x.txt"), atomically: true, encoding: .utf8)
try "y".write(to: work.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
let one = svc.compress([work.appendingPathComponent("目录")])
assert(one?.lastPathComponent == "目录.zip", "compress single: \(String(describing: one))")
let one2 = svc.compress([work.appendingPathComponent("目录")])
assert(one2?.lastPathComponent == "目录 2.zip", "compress unique: \(String(describing: one2))")
let multi = svc.compress([work.appendingPathComponent("目录"), work.appendingPathComponent("y.txt")])
assert(multi?.lastPathComponent == "归档.zip", "compress multi")
let listed = try ZipArchive.list(zip: multi!, inner: "", showHidden: false)
assert(names(listed) == ["y.txt", "目录/"], "archive content: \(names(listed))")
let unpacked = svc.extractZip(one!)
// 单个顶层项目直接放出（不套一层同名文件夹）；「目录」已存在 → 「目录 2」
assert(unpacked?.lastPathComponent == "目录 2", "extract dest: \(String(describing: unpacked))")
assert(fm.fileExists(atPath: unpacked!.appendingPathComponent("x.txt").path), "extract content")
// 多个顶层项目放进以压缩包命名的文件夹
let unpackedMulti = svc.extractZip(multi!)
assert(unpackedMulti?.lastPathComponent == "归档", "extract multi: \(String(describing: unpackedMulti))")
assert(fm.fileExists(atPath: unpackedMulti!.appendingPathComponent("y.txt").path), "extract multi content")
let dup = svc.duplicate([work.appendingPathComponent("y.txt")])
assert(dup.first?.lastPathComponent == "y 副本.txt", "duplicate: \(dup)")

// 命令面板/路径栏的路径解析：引号、~、file://、相对路径、反斜杠转义、zip 包内路径
let spaced = root.appendingPathComponent("with space")
try fm.createDirectory(at: spaced, withIntermediateDirectories: true)
func resolved(_ s: String) -> String? { FileSystemService.resolve(s, relativeTo: root)?.path }
let rootPath = root.standardizedFileURL.path
assert(resolved("  \"\(spaced.path)\"  ") == spaced.standardizedFileURL.path, "quoted")
assert(resolved(spaced.path.replacingOccurrences(of: " ", with: "\\ ")) == spaced.standardizedFileURL.path, "escaped")
assert(resolved(spaced.absoluteString) == spaced.standardizedFileURL.path, "file url")
assert(resolved("with space/../src") == rootPath + "/src", "relative")
assert(resolved("~") == NSHomeDirectory(), "tilde")
assert(resolved("deflate.zip/中文目录") == rootPath + "/deflate.zip/中文目录", "zip inner")
assert(resolved("nope/missing") == nil && resolved("   ") == nil, "missing")

// 非 zip 路径不受影响；损坏文件抛错而不是崩溃
assert(ZipArchive.split(root.appendingPathComponent("src/a.txt")) == nil)
do { _ = try ZipArchive.entries(of: root.appendingPathComponent("broken.zip")); assertionFailure("should throw") }
catch {}
print("zip_check OK")
