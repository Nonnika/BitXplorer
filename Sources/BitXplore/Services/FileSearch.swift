import Foundation

/// 命令面板的文件搜索：`/名称[/范围][/类型]`
/// - 名称：不含 `*` 时为「包含」；含 `*` 时整个文件名按通配匹配，`\*` 表示字面的星号。均不区分大小写
/// - 范围：`g` 不限层级（默认）；`d:N` 最多 N 层，`d:1` 只搜当前目录
/// - 类型：`f` 只要文件，`d` 只要文件夹，默认都要。范围与类型写法互不冲突，顺序随意
struct FileSearch: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case any, file, folder }

    /// 按未转义的 `*` 切开后的字面片段（已去掉转义符）；只有一段即无通配
    let parts: [String]
    var maxDepth: Int?
    var kind = Kind.any

    var hasWildcard: Bool { parts.count > 1 }

    /// 解析 `/` 之后的部分；失败时返回给用户看的错误
    static func parse(_ input: some StringProtocol) -> Result<FileSearch, ParseError> {
        let segments = input.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var search = FileSearch(parts: splitPattern(segments.first ?? ""))
        var seenScope = false, seenKind = false
        for option in segments.dropFirst() where !option.isEmpty {
            switch option.lowercased() {
            case "g" where !seenScope:
                seenScope = true
            case let o where o.hasPrefix("d:") && !seenScope:
                guard let n = Int(o.dropFirst(2)), n >= 1 else { return .failure(.badDepth(option)) }
                search.maxDepth = n
                seenScope = true
            case "f" where !seenKind:
                search.kind = .file
                seenKind = true
            case "d" where !seenKind:
                search.kind = .folder
                seenKind = true
            default:
                return .failure(.unknownOption(option))
            }
        }
        return .success(search)
    }

    enum ParseError: Error, Hashable {
        case unknownOption(String), badDepth(String)

        var message: String {
            switch self {
            case .unknownOption(let o): "无法识别「\(o)」：范围用 g 或 d:层数，类型用 f 或 d"
            case .badDepth(let o): "「\(o)」的层数须为正整数，如 d:2"
            }
        }
    }

    /// `\x` 转义为字面 x；未转义的 `*` 作为分隔
    private static func splitPattern(_ pattern: String) -> [String] {
        var parts = [""]
        var escaping = false
        for ch in pattern {
            if escaping {
                parts[parts.count - 1].append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == "*" {
                parts.append("")
            } else {
                parts[parts.count - 1].append(ch)
            }
        }
        if escaping { parts[parts.count - 1].append("\\") }
        return parts
    }

    func matches(name: String) -> Bool {
        let options: String.CompareOptions = .caseInsensitive
        guard hasWildcard else {
            return parts[0].isEmpty || name.range(of: parts[0], options: options) != nil
        }
        // 首段贴着开头、末段贴着结尾，中间各段按顺序出现
        var rest = name[...]
        if let head = parts.first, !head.isEmpty {
            guard let r = rest.range(of: head, options: options.union(.anchored)) else { return false }
            rest = rest[r.upperBound...]
        }
        if let tail = parts.last, !tail.isEmpty {
            guard let r = rest.range(of: tail, options: options.union([.anchored, .backwards])) else { return false }
            rest = rest[..<r.lowerBound]
        }
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let r = rest.range(of: part, options: options) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    /// 在 `base` 下找前 `limit` 个匹配项，跳过隐藏文件与包内容（.app 等）
    // ponytail: 深度优先逐个遍历，个人目录这种大树上首屏较慢且偏向深层；需要时换 NSMetadataQuery（Spotlight 索引）
    func find(in base: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL, found.count < limit, !Task.isCancelled {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder, let maxDepth, enumerator.level >= maxDepth { enumerator.skipDescendants() }
            guard kind == .any || (kind == .folder) == isFolder else { continue }
            if matches(name: url.lastPathComponent) { found.append(url) }
        }
        return found
    }
}
