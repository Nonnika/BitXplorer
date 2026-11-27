import SwiftUI

/// 主内容视图 - 整合原生工具栏、搜索、文件列表、路径栏与状态栏
struct MainContentView: View {
    @Binding var currentURL: URL
    @Binding var files: [FileItem]
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var showHiddenFiles: Bool
    @Binding var isEditingPath: Bool
    @ObservedObject var navigationState: NavigationState
    let fsService: FileSystemService
    /// App 级操作（粘贴/废纸篓）完成后递增，触发重新加载
    let refreshTick: Int
    let newFolderTrigger: Int
    let renameTrigger: Int
    let onNewFolder: () -> Void

    @State private var isLoading = false
    @State private var loadToken = 0
    @State private var searchText = ""
    @State private var watcherSource: DispatchSourceFileSystemObject?
    @State private var watcherPath: String?
    @State private var watcherDebounce: DispatchWorkItem?

    private var currentFolderName: String {
        currentURL.path == "/" ? "Macintosh HD" : currentURL.lastPathComponent
    }

    private var ancestorURLs: [URL] {
        var result: [URL] = []
        var url = currentURL.standardizedFileURL
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            result.append(url)
        }
        return result
    }

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

    private func navigate(to url: URL) {
        navigationState.invalidate()
        currentURL = url
    }

    var body: some View {
        Group {
            if isLoading && files.isEmpty {
                ProgressView("正在加载...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileListView(
                    files: displayedFiles,
                    searchText: searchText,
                    selectedURLs: $selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    currentURL: $currentURL,
                    showHiddenFiles: $showHiddenFiles,
                    onNavigate: navigate(to:),
                    fsService: fsService,
                    onRefresh: { loadFiles(clearSelection: false) },
                    newFolderTrigger: newFolderTrigger,
                    renameTrigger: renameTrigger
                )
            }
        }
        .navigationTitle(currentFolderName)
        .navigationDocument(currentURL)
        .toolbarTitleMenu {
            ForEach(ancestorURLs, id: \.self) { url in
                Button {
                    navigate(to: url)
                } label: {
                    Label(
                        url.path == "/" ? "Macintosh HD" : url.lastPathComponent,
                        systemImage: url.path == "/" ? "internaldrive" : "folder"
                    )
                }
            }

            if !ancestorURLs.isEmpty {
                Divider()
            }

            Button("前往文件夹…") {
                isEditingPath = true
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if let url = navigationState.goUp(from: currentURL) {
                        currentURL = url
                    }
                } label: {
                    Label("上一级目录", systemImage: "chevron.left")
                }
                .disabled(!navigationState.canGoUp(current: currentURL))
                .help("上一级目录 (⌘↑)")

                Button {
                    if let url = navigationState.goDown() {
                        currentURL = url
                    }
                } label: {
                    Label("下一级目录", systemImage: "chevron.right")
                }
                .disabled(!navigationState.canGoDown())
                .help("下一级目录 (⌘↓)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewFolder) {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                .help("新建文件夹 (⌘⇧N)")
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索")
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                BreadcrumbBar(
                    currentURL: $currentURL,
                    isEditingPath: $isEditingPath,
                    onNavigate: navigate(to:)
                )
                Divider()
                statusBar
            }
        }
        .onChange(of: currentURL) { loadFiles(clearSelection: true) }
        .onChange(of: showHiddenFiles) { loadFiles(clearSelection: false) }
        .onChange(of: refreshTick) { loadFiles(clearSelection: false) }
        .onAppear { loadFiles(clearSelection: true) }
        .onDisappear { stopWatcher() }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if searchText.isEmpty {
                Text("\(files.count) 个项目")
            } else {
                Text("\(displayedFiles.count) / \(files.count) 个项目")
            }

            if selectedStats.count > 0 {
                Text("·")
                Text("已选 \(selectedStats.count) 个")
                    .foregroundStyle(.primary)

                if selectedStats.size > 0 {
                    Text(FileItem.bytes(selectedStats.size))
                }
            }

            Spacer()
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// 后台线程枚举目录；token 使快速连续导航时旧的慢结果被丢弃
    private func loadFiles(clearSelection: Bool) {
        loadToken += 1
        let token = loadToken
        let url = currentURL
        let showHidden = showHiddenFiles
        let service = fsService
        if clearSelection {
            selectedURLs = []
            searchText = ""
        }
        isLoading = true
        Task {
            let items = (try? await Task.detached(priority: .userInitiated) {
                try service.listDirectory(at: url, showHidden: showHidden)
            }.value) ?? []
            guard token == loadToken else { return }
            files = items
            if !clearSelection {
                let existing = Set(items.map(\.url))
                selectedURLs = selectedURLs.intersection(existing)
            }
            isLoading = false
            startWatcher()
        }
    }

    /// 停止并清理目录监视器
    private func stopWatcher() {
        watcherDebounce?.cancel()
        watcherDebounce = nil
        watcherSource?.cancel()
        watcherSource = nil
        watcherPath = nil
    }

    /// 监视当前目录变化，外部文件新增/删除时自动刷新列表
    private func startWatcher() {
        let path = currentURL.path
        guard watcherPath != path else { return }
        stopWatcher()
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
                        guard url == currentURL, updated != files else { return }
                        let existing = Set(updated.map(\.url))
                        withAnimation(.easeInOut(duration: 0.1)) {
                            files = updated
                            selectedURLs = selectedURLs.intersection(existing)
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
