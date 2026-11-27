import Foundation

/// 文件/文件夹的数据模型
struct FileItem: Identifiable, Hashable, Sendable {
    /// 以 URL 作为行身份：刷新后按 URL 复用行，滚动位置与选区不重置
    var id: URL { url }

    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let fileExtension: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey
        ])

        self.isDirectory = resourceValues?.isDirectory ?? url.hasDirectoryPath
        self.size = resourceValues?.fileSize.map(Int64.init)
        self.modificationDate = resourceValues?.contentModificationDate
        self.fileExtension = url.pathExtension
    }

    @MainActor private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @MainActor private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 格式化字节数（状态栏也复用，避免每次渲染新建 formatter）
    @MainActor
    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: count)
    }

    /// 格式化文件大小
    @MainActor
    var formattedSize: String {
        guard let size = size, !isDirectory else { return "--" }
        return Self.bytes(size)
    }

    /// 格式化修改日期
    @MainActor
    var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return Self.dateFormatter.string(from: date)
    }

    /// 文件类型描述
    var fileTypeDisplay: String {
        if isDirectory { return "文件夹" }
        if fileExtension.isEmpty { return "文件" }
        return fileExtension.uppercased() + " 文件"
    }
}

/// SwiftUI Table 列排序比较器
struct FileSortComparator: SortComparator, Hashable, Sendable {
    enum Key: Hashable, Sendable {
        case name
        case date
        case kind
        case size
    }

    var key: Key
    var order: SortOrder = .forward

    init(_ key: Key, order: SortOrder = .forward) {
        self.key = key
        self.order = order
    }

    func compare(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        if key == .name && lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory ? .orderedAscending : .orderedDescending
        }

        let base: ComparisonResult
        switch key {
        case .name:
            base = lhs.name.localizedStandardCompare(rhs.name)
        case .date:
            let lDate = lhs.modificationDate ?? .distantPast
            let rDate = rhs.modificationDate ?? .distantPast
            if lDate != rDate {
                base = lDate < rDate ? .orderedAscending : .orderedDescending
            } else {
                base = lhs.name.localizedStandardCompare(rhs.name)
            }
        case .kind:
            let kindOrder = lhs.fileTypeDisplay.localizedStandardCompare(rhs.fileTypeDisplay)
            base = kindOrder != .orderedSame ? kindOrder : lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            let lSize: Int64 = lhs.isDirectory ? -1 : (lhs.size ?? -1)
            let rSize: Int64 = rhs.isDirectory ? -1 : (rhs.size ?? -1)
            if lSize != rSize {
                base = lSize < rSize ? .orderedAscending : .orderedDescending
            } else {
                base = lhs.name.localizedStandardCompare(rhs.name)
            }
        }

        guard order == .reverse else { return base }
        switch base {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
