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

// 非 zip 路径不受影响；损坏文件抛错而不是崩溃
assert(ZipArchive.split(root.appendingPathComponent("src/a.txt")) == nil)
do { _ = try ZipArchive.entries(of: root.appendingPathComponent("broken.zip")); assertionFailure("should throw") }
catch {}
print("zip_check OK")
