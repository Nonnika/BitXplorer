import Foundation

/// 文件/文件夹的数据模型
struct FileItem: Identifiable, Equatable {
    /// 以 URL 作为行身份：刷新后 LazyVStack 按 URL 复用行，滚动位置不重置
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
        self.isDirectory = url.hasDirectoryPath

        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey
        ])

        self.size = resourceValues?.fileSize.map(Int64.init)
        self.modificationDate = resourceValues?.contentModificationDate
        self.fileExtension = url.pathExtension
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
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

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}
