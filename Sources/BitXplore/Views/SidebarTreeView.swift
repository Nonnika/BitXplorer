import SwiftUI

/// 原生 macOS 27 侧边栏：「快速访问」（用户自定义的扁平列表）+「位置」（目录树）
struct SidebarTreeView: View {
    let roots: [TreeNode]
    @Binding var currentURL: URL
    let onSelect: (URL) -> Void

    @AppStorage(SidebarFavorite.storageKey) private var favoritesData = Data()
    /// 快速访问节点缓存：每次渲染重建会换 id，选中状态会丢
    @State private var favoriteNodes: [TreeNode] = []
    @State private var selection: TreeNode.ID?
    /// 正在更改图标的快速访问条目（路径）
    @State private var iconEditingPath: String?

    private var favorites: [SidebarFavorite] { SidebarFavorite.decode(favoritesData) }
    private var allNodes: [TreeNode] { favoriteNodes + roots }

    var body: some View {
        List(selection: $selection) {
            Section("快速访问") {
                ForEach(favoriteNodes) { node in
                    row(node)
                        .contextMenu {
                            Button("更改图标…") { iconEditingPath = node.url.path }
                            Button("从快速访问中移除") { removeFavorite(node.url.path) }
                        }
                }
                .onMove { from, to in
                    var list = favorites
                    list.move(fromOffsets: from, toOffset: to)
                    favoritesData = SidebarFavorite.encode(list)
                }
                // 把文件夹拖进来即加入，落点决定位置
                .dropDestination(for: URL.self) { urls, index in
                    let folders = urls.filter { url in
                        var isDir: ObjCBool = false
                        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    }
                    favoritesData = SidebarFavorite.adding(folders, to: favoritesData, at: index)
                }
            }

            Section("位置") {
                OutlineGroup(roots, children: \.children) { node in
                    row(node)
                        .task(id: node.id) {
                            await node.loadChildren()
                        }
                        .contextMenu {
                            Button("添加到快速访问") {
                                favoritesData = SidebarFavorite.adding([node.url], to: favoritesData)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            rebuildFavorites()
            syncSelectionFromCurrentURL()
        }
        .onChange(of: favoritesData) {
            rebuildFavorites()
            syncSelectionFromCurrentURL()
        }
        .onChange(of: currentURL) {
            syncSelectionFromCurrentURL()
        }
        .onChange(of: selection) { _, newID in
            guard let id = newID,
                  let node = findNode(id: id, in: allNodes),
                  node.url.standardizedFileURL.path != currentURL.standardizedFileURL.path else {
                return
            }
            onSelect(node.url)
        }
        .sheet(isPresented: Binding(get: { iconEditingPath != nil }, set: { if !$0 { iconEditingPath = nil } })) {
            if let path = iconEditingPath {
                SymbolPicker(current: favorites.first { $0.path == path }?.symbol ?? "folder") { symbol in
                    var list = favorites
                    if let i = list.firstIndex(where: { $0.path == path }) { list[i].symbol = symbol }
                    favoritesData = SidebarFavorite.encode(list)
                }
            }
        }
    }

    private func row(_ node: TreeNode) -> some View {
        HStack(spacing: 6) {
            Label(node.name, systemImage: node.symbolName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if node.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if node.isICloud {
                Image(systemName: "icloud")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("iCloud 云盘")
            }
        }
    }

    /// 快速访问是扁平列表，不加载子目录；已不存在的文件夹不显示（记录保留，恢复后重新出现）
    private func rebuildFavorites() {
        favoriteNodes = favorites
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { favorite in
                let url = URL(fileURLWithPath: favorite.path, isDirectory: true)
                let name = favorite.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: favorite.path)
                return TreeNode(url: url, name: name, symbolName: favorite.symbol)
            }
    }

    private func removeFavorite(_ path: String) {
        favoritesData = SidebarFavorite.encode(favorites.filter { $0.path != path })
    }

    private func syncSelectionFromCurrentURL() {
        let targetPath = currentURL.standardizedFileURL.path
        if let currentID = selection,
           let currentNode = findNode(id: currentID, in: allNodes),
           currentNode.url.standardizedFileURL.path == targetPath {
            return
        }
        selection = findNode(matchingPath: targetPath, in: allNodes)?.id
    }

    private func findNode(id: TreeNode.ID, in nodes: [TreeNode]) -> TreeNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if let children = node.children,
               let match = findNode(id: id, in: children) {
                return match
            }
        }
        return nil
    }

    private func findNode(matchingPath path: String, in nodes: [TreeNode]) -> TreeNode? {
        for node in nodes {
            if node.url.standardizedFileURL.path == path {
                return node
            }
            if let children = node.children,
               let match = findNode(matchingPath: path, in: children) {
                return match
            }
        }
        return nil
    }
}

/// 快速访问图标选择：常用 SF Symbols 网格，也可直接输入任意符号名
private struct SymbolPicker: View {
    let current: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customName = ""

    private static let symbols = [
        "folder", "folder.fill", "house", "desktopcomputer", "menubar.dock.rectangle", "doc", "doc.text",
        "arrow.down.circle", "photo", "film", "music.note", "book", "books.vertical", "briefcase",
        "hammer", "wrench.and.screwdriver", "terminal", "chevron.left.forwardslash.chevron.right",
        "gamecontroller", "paintbrush", "camera", "archivebox", "tray.full", "shippingbox", "icloud",
        "star", "heart", "flag", "bookmark", "tag", "graduationcap", "globe", "server.rack",
        "externaldrive", "lock", "person", "person.2", "cart", "gearshape", "puzzlepiece", "leaf", "sparkles",
    ]

    private var customIsValid: Bool {
        NSImage(systemSymbolName: customName.trimmingCharacters(in: .whitespaces), accessibilityDescription: nil) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择图标")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8), spacing: 8) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        pick(symbol)
                    } label: {
                        Image(systemName: symbol)
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .background(symbol == current ? Color.accentColor.opacity(0.2) : .clear,
                                        in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                    .accessibilityLabel(symbol)
                }
            }

            HStack {
                TextField("其他 SF Symbol 名称，如 folder.badge.gearshape", text: $customName)
                    .onSubmit { if customIsValid { pick(customName) } }
                if customIsValid {
                    Image(systemName: customName.trimmingCharacters(in: .whitespaces))
                }
                Button("使用") { pick(customName) }
                    .disabled(!customIsValid)
            }

            HStack {
                Button("恢复默认") { pick("folder") }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func pick(_ symbol: String) {
        onPick(symbol.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
