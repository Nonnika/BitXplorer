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
