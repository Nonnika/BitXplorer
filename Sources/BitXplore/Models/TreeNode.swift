import Foundation
import Observation

/// 侧边栏目录树节点
@MainActor
@Observable
final class TreeNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let symbolName: String
    let isDirectory: Bool
    /// 位于 iCloud 云盘（含开启了「桌面与文稿」同步的文件夹），侧边栏右侧显示云标
    let isICloud: Bool

    var children: [TreeNode]?
    var isLoading = false
    private(set) var hasLoadedChildren = false

    init(
        url: URL,
        name: String? = nil,
        symbolName: String = "folder",
        isDirectory: Bool = true
    ) {
        self.url = url.standardizedFileURL
        self.name = name ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
        self.symbolName = symbolName
        self.isDirectory = isDirectory
        self.isICloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            || url.path.contains("/Library/Mobile Documents/")
    }

    func loadChildren() async {
        guard isDirectory, !hasLoadedChildren, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let targetURL = self.url
        let subdirectoryURLs = await Task.detached(priority: .userInitiated) { () -> [URL] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []

            return contents
                .filter { url in
                    guard !url.lastPathComponent.hasPrefix(".") else { return false }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
        }.value

        let loaded = subdirectoryURLs.map { TreeNode(url: $0) }
        children = loaded.isEmpty ? nil : loaded
        hasLoadedChildren = true
    }

    static func defaultRoots() -> [TreeNode] {
        [
            TreeNode(
                url: FileManager.default.homeDirectoryForCurrentUser,
                name: "个人目录",
                symbolName: "house"
            ),
            TreeNode(
                url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                name: "应用程序",
                symbolName: "square.grid.2x2"
            ),
            TreeNode(
                url: URL(fileURLWithPath: "/Users", isDirectory: true),
                name: "用户",
                symbolName: "person.2"
            ),
            TreeNode(
                url: URL(fileURLWithPath: "/", isDirectory: true),
                name: "Macintosh HD",
                symbolName: "internaldrive"
            ),
        ]
    }
}

/// 侧边栏「快速访问」条目（用户可增删、排序、换图标），以 JSON 存在 @AppStorage
struct SidebarFavorite: Codable, Hashable {
    var path: String
    var symbol: String

    static let storageKey = "sidebarFavorites"

    /// 从未保存过（空数据）时的默认条目，同 Finder
    static let defaults = ["Desktop": "menubar.dock.rectangle", "Documents": "doc", "Downloads": "arrow.down.circle"]
        .sorted { $0.key < $1.key }
        .map { SidebarFavorite(path: NSHomeDirectory() + "/" + $0.key, symbol: $0.value) }

    static func decode(_ data: Data) -> [SidebarFavorite] {
        data.isEmpty ? defaults : (try? JSONDecoder().decode([SidebarFavorite].self, from: data)) ?? defaults
    }

    static func encode(_ list: [SidebarFavorite]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }

    /// 加入（已存在则不重复）；index 为插入位置，nil 追加到末尾
    static func adding(_ urls: [URL], to data: Data, at index: Int? = nil) -> Data {
        var list = decode(data)
        var position = min(index ?? list.count, list.count)
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !list.contains(where: { $0.path == path }) else { continue }
            list.insert(SidebarFavorite(path: path, symbol: "folder"), at: position)
            position += 1
        }
        return encode(list)
    }
}
