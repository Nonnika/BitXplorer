import SwiftUI

/// 右侧文件区固定配色：深黑背景 + 浅灰分界线（不随系统外观切换）
extension Color {
    static let panelBackground = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let panelLine = Color(red: 0.35, green: 0.35, blue: 0.35)
}

// MARK: - Liquid Glass 适配：macOS 26+（含 27）新设计语言，旧系统回退原深色外观。
// 系统接管的工具栏/侧栏/右键菜单随 SDK 自动换新，无需处理；这里只管自绘控件。
extension View {
    /// 标题栏内嵌控件底（面包屑/搜索）：玻璃胶囊 ↔ 系统外观描边框（标题栏随系统外观，不用深色面板色）
    @ViewBuilder
    func glassControlBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            self
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    /// 横条底（面包屑/状态栏）：整条玻璃 ↔ 纯深色
    @ViewBuilder
    func glassStripBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            self.background(Color.panelBackground)
        }
    }
}

/// 主内容视图 - 整合面包屑、搜索、文件列表、状态栏
struct MainContentView: View {
    @Binding var currentURL: URL
    @Binding var files: [FileItem]
    @Binding var sortOption: SortOption
    @Binding var sortDirection: SortDirection
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var showHiddenFiles: Bool
    let navigationState: NavigationState
    let fsService: FileSystemService
    /// App 级操作（粘贴/废纸篓）完成后递增，触发重新加载
    let refreshTick: Int

    @State private var isLoading = false
    @State private var loadToken = 0
    @State private var searchText = ""
    @State private var isRenaming = false
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @State private var watcherSource: DispatchSourceFileSystemObject?
    @State private var watcherPath: String?
    @State private var watcherDebounce: DispatchWorkItem?
    @FocusState private var renameFieldFocused: Bool

    /// 搜索过滤后的文件列表
    var displayedFiles: [FileItem] {
        guard !searchText.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// 状态栏统计
    var selectedStats: (count: Int, size: Int64) {
        let selected = files.filter { selectedURLs.contains($0.url) }
        let totalSize: Int64 = selected.reduce(0) { $0 + ($1.size ?? 0) }
        return (selected.count, totalSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 文件列表（仅在首载/空目录加载时展示 spinner，避免整块视图反复重建）
            if isLoading && files.isEmpty {
                Spacer()
                ProgressView("正在加载...")
                Spacer()
            } else {
                FileListView(
                    files: Binding(get: { displayedFiles }, set: { files = $0 }),
                    sortOption: $sortOption,
                    sortDirection: $sortDirection,
                    selectedURLs: $selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    currentURL: $currentURL,
                    showHiddenFiles: $showHiddenFiles,
                    onNavigate: { url in
                        navigationState.push(currentURL)
                        currentURL = url
                    },
                    fsService: fsService,
                    isRenaming: $isRenaming,
                    renameTarget: $renameTarget,
                    renameText: $renameText,
                    renameFieldFocused: $renameFieldFocused,
                    onRefresh: { loadFiles() }
                )
            }

            // 状态栏
            statusBar
        }
        // 工具栏放在 .environment(\.colorScheme, .dark) 之前：
        // 标题栏随系统外观，不被详情区的强制深色污染（浅色模式下文字/玻璃才是浅色版）
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: {
                    if let url = navigationState.goBack(from: currentURL) {
                        currentURL = url
                    }
                }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigationState.canGoBack())
                .help("后退")

                Button(action: {
                    if let url = navigationState.goForward(from: currentURL) {
                        currentURL = url
                    }
                }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigationState.canGoForward())
                .help("前进")

                Button(action: {
                    navigationState.push(currentURL)
                    currentURL = currentURL.deletingLastPathComponent()
                }) {
                    Image(systemName: "arrow.up")
                }
                .disabled(currentURL.path == "/")
                .help("向上一层")
            }

            // 面包屑地址栏：放进标题栏，与导航按钮同在左侧；
            // 默认折叠成当前目录名，点击展开完整路径（无玻璃底，直接放标题栏上）
            ToolbarItem(placement: .navigation) {
                BreadcrumbBar(currentURL: $currentURL, onNavigate: { url in
                    navigationState.push(currentURL)
                    currentURL = url
                })
                .frame(height: 26)
            }

            // 搜索框：标题栏右侧
            ToolbarItem(placement: .primaryAction) {
                searchField
            }
        }
        .background(Color.panelBackground)
        .environment(\.colorScheme, .dark)
        .onChange(of: showHiddenFiles) { loadFiles() }
        .onChange(of: currentURL) { loadFiles() }
        .onChange(of: refreshTick) { loadFiles() }
        .onAppear { loadFiles() }
    }

    /// 标题栏右侧搜索框（固定宽度，工具栏内 TextField 会无限撑开）
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("搜索...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 200)
        .frame(height: 26)
        .glassControlBackground()
    }

    private var statusBar: some View {
        HStack {
            Text("\(files.count) 个项目")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if selectedStats.count > 0 {
                Text("  |  已选 \(selectedStats.count) 个")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)

                if selectedStats.size > 0 {
                    Text(FileItem.bytes(selectedStats.size))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .glassStripBackground()
    }

    /// 后台线程枚举目录；token 使快速连续导航时旧的慢结果被丢弃
    private func loadFiles() {
        loadToken += 1
        let token = loadToken
        let url = currentURL
        let showHidden = showHiddenFiles
        let service = fsService
        isLoading = true
        Task {
            let items = (try? await Task.detached(priority: .userInitiated) {
                try service.listDirectory(at: url, showHidden: showHidden)
            }.value) ?? []
            guard token == loadToken else { return }
            files = items
            selectedURLs = []
            searchText = ""
            isLoading = false
            startWatcher()
        }
    }

    /// 监视当前目录变化，外部文件新增/删除时自动刷新列表
    private func startWatcher() {
        let path = currentURL.path
        guard watcherPath != path else { return }
        watcherDebounce?.cancel()
        watcherSource?.cancel()
        watcherSource = nil
        watcherPath = path

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: .main
        )
        source.setEventHandler { [self] in
            // ponytail: 150ms 防抖合并写入风暴（构建目录、日志），极端乱序下可能应用旧快照，
            // 靠 url 匹配 + 内容 diff 兜底；如需严格一致改用串行 single-flight
            watcherDebounce?.cancel()
            let work = DispatchWorkItem { [self] in
                let url = currentURL
                let showHidden = showHiddenFiles
                let service = fsService
                Task.detached(priority: .utility) {
                    let updated = (try? service.listDirectory(at: url, showHidden: showHidden)) ?? []
                    await MainActor.run {
                        guard url == currentURL, updated.map(\.url) != files.map(\.url) else { return }
                        withAnimation(.easeInOut(duration: 0.1)) {
                            files = updated
                        }
                    }
                }
            }
            watcherDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcherSource = source
    }
}
