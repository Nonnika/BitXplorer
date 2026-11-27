import Foundation
import Compression

/// 只读浏览 zip：把 `/a/b.zip/sub/` 这种“穿过 zip 文件”的虚拟路径映射到包内条目。
/// 直接解析中央目录（含 ZIP64），不解压整包；打开包内文件时只解出该条目到临时目录。
enum ZipArchive {
    struct Entry {
        let name: String
        let method: Int
        let flags: Int
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        let date: Date?
    }

    enum ZipError: Error, Equatable { case malformed, encrypted, unsupportedMethod(Int) }

    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// 路径中第一个真实存在的 .zip 文件及其包内路径（"" 表示 zip 根目录）；普通路径返回 nil
    static func split(_ url: URL) -> (zip: URL, inner: String)? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.contains(where: { $0.lowercased().hasSuffix(".zip") }) else { return nil }
        var path = URL(fileURLWithPath: "/")
        for (i, part) in parts.enumerated().dropFirst() {
            path.appendPathComponent(part)
            var isDir: ObjCBool = false
            if isZip(path), FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue {
                return (path, parts[(i + 1)...].joined(separator: "/"))
            }
        }
        return nil
    }

    /// 列出包内某目录的直接子项。zip 常省略目录条目，所以目录从文件路径前缀推导
    static func list(zip: URL, inner: String, showHidden: Bool) throws -> [FileItem] {
        let prefix = inner.isEmpty ? "" : inner + "/"
        var children: [String: FileItem] = [:]
        for entry in try entries(of: zip) where entry.name.hasPrefix(prefix) {
            let rest = entry.name.dropFirst(prefix.count)
            guard let first = rest.split(separator: "/").first.map(String.init) else { continue }
            if !showHidden && (first.hasPrefix(".") || first == "__MACOSX") { continue }
            let isDir = rest.count > first.count  // 后面还有 "/"：是目录
            let url = zip.appendingPathComponent(prefix + first, isDirectory: isDir)
            if isDir {
                if children[first] == nil {
                    children[first] = FileItem(url: url, isDirectory: true, size: nil, modificationDate: entry.date)
                }
            } else {
                children[first] = FileItem(url: url, isDirectory: false, size: Int64(entry.size), modificationDate: entry.date)
            }
        }
        return Array(children.values)
    }

    /// 解出单个条目到临时目录并返回其 URL
    static func extract(zip: URL, inner: String) throws -> URL {
        guard let entry = try entries(of: zip).first(where: { $0.name == inner }) else { throw ZipError.malformed }
        guard entry.flags & 1 == 0 else { throw ZipError.encrypted }
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = try handle.read(upToCount: 30) ?? Data()
        guard try le(header, 0, 4) == 0x04034b50 else { throw ZipError.malformed }
        let dataStart = entry.localHeaderOffset + 30 + (try le(header, 26, 2)) + (try le(header, 28, 2))
        try handle.seek(toOffset: UInt64(dataStart))
        // ponytail: 整个条目读进内存解压，超大单文件会占同等内存；需要时改为 compression_stream 流式写盘
        let packed = try handle.read(upToCount: entry.compressedSize) ?? Data()
        guard packed.count == entry.compressedSize else { throw ZipError.malformed }

        let data: Data
        switch entry.method {
        case 0:
            data = packed
        case 8:  // deflate：Compression 的 ZLIB 即原始 DEFLATE
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                packed.withUnsafeBytes { src in
                    compression_decode_buffer(dst.baseAddress!, entry.size, src.baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size || entry.size == 0 else { throw ZipError.malformed }
            data = out
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitXplore-zip/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((inner as NSString).lastPathComponent)
        try data.write(to: dest)
        return dest
    }

    // MARK: - 中央目录解析（输入不可信：所有读取都做越界检查）

    static func entries(of zip: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())

        // EOCD 在文件尾部，后面最多跟 65535 字节注释
        let tailSize = min(fileSize, 22 + 65535)
        try handle.seek(toOffset: UInt64(fileSize - tailSize))
        let tail = try handle.read(upToCount: tailSize) ?? Data()
        guard tail.count >= 22,
              let eocd = try stride(from: tail.count - 22, through: 0, by: -1).first(where: { try le(tail, $0, 4) == 0x06054b50 })
        else { throw ZipError.malformed }

        var count = try le(tail, eocd + 10, 2)
        var cdSize = try le(tail, eocd + 12, 4)
        var cdOffset = try le(tail, eocd + 16, 4)

        // ZIP64：定位器紧挨在 EOCD 之前
        if count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            let locator = eocd - 20
            guard locator >= 0, try le(tail, locator, 4) == 0x07064b50 else { throw ZipError.malformed }
            try handle.seek(toOffset: UInt64(try le(tail, locator + 8, 8)))
            let z64 = try handle.read(upToCount: 56) ?? Data()
            guard try le(z64, 0, 4) == 0x06064b50 else { throw ZipError.malformed }
            count = try le(z64, 32, 8)
            cdSize = try le(z64, 40, 8)
            cdOffset = try le(z64, 48, 8)
        }
        guard cdOffset + cdSize <= fileSize else { throw ZipError.malformed }

        try handle.seek(toOffset: UInt64(cdOffset))
        let cd = try handle.read(upToCount: cdSize) ?? Data()
        var entries: [Entry] = []
        entries.reserveCapacity(min(count, 100_000))
        var p = 0
        for _ in 0..<count {
            guard try le(cd, p, 4) == 0x02014b50 else { throw ZipError.malformed }
            let flags = try le(cd, p + 8, 2)
            let nameLen = try le(cd, p + 28, 2)
            let extraLen = try le(cd, p + 30, 2)
            let commentLen = try le(cd, p + 32, 2)
            var compressed = try le(cd, p + 20, 4)
            var size = try le(cd, p + 24, 4)
            var offset = try le(cd, p + 42, 4)
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen <= cd.count else { throw ZipError.malformed }
            let nameData = cd.subdata(in: cd.startIndex + nameStart ..< cd.startIndex + nameStart + nameLen)

            // ZIP64 扩展字段（0x0001）：只包含被置为 0xFFFFFFFF 的那些值，按固定顺序
            var e = nameStart + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = try le(cd, e, 2), len = try le(cd, e + 2, 2)
                if id == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFFFFFF { size = try le(cd, q, 8); q += 8 }
                    if compressed == 0xFFFFFFFF { compressed = try le(cd, q, 8); q += 8 }
                    if offset == 0xFFFFFFFF { offset = try le(cd, q, 8) }
                }
                e += 4 + len
            }

            entries.append(Entry(
                name: decodeName(nameData, utf8Flag: flags & 0x800 != 0),
                method: try le(cd, p + 10, 2),
                flags: flags,
                compressedSize: compressed,
                size: size,
                localHeaderOffset: offset,
                date: dosDate(time: try le(cd, p + 12, 2), date: try le(cd, p + 14, 2))
            ))
            p = extraEnd + commentLen
        }
        return entries
    }

    /// 小端整数读取，越界抛错而不是崩溃
    private static func le(_ d: Data, _ offset: Int, _ n: Int) throws -> Int {
        guard offset >= 0, offset + n <= d.count else { throw ZipError.malformed }
        var v = 0
        for i in (0..<n).reversed() { v = v << 8 | Int(d[d.startIndex + offset + i]) }
        return v
    }

    /// 未标 UTF-8 的文件名：先试 UTF-8，再试 GB18030（Windows 中文压缩包常见），最后 DOS 拉丁
    private static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if utf8Flag || String(data: data, encoding: .utf8) != nil {
            return String(decoding: data, as: UTF8.self)
        }
        for cf in [CFStringEncodings.GB_18030_2000, .dosLatinUS] {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dosDate(time: Int, date: Int) -> Date? {
        DateComponents(calendar: .current,
                       year: (date >> 9) + 1980, month: (date >> 5) & 0xF, day: date & 0x1F,
                       hour: time >> 11, minute: (time >> 5) & 0x3F, second: (time & 0x1F) * 2).date
    }
}
