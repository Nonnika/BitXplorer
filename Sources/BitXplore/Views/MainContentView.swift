import SwiftUI
import AppKit

/// 主内容视图 - 整合原生工具栏、搜索，承载单栏/双栏（⌘D）文件面板
struct MainContentView: View {
    @Binding var panes: [Pane]
    @Binding var activePane: Int
    let isDualPane: Bool
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var showHiddenFiles: Bool
    let fsService: FileSystemService
    /// App 级操作（粘贴/废纸篓）完成后递增，触发重新加载
    let refreshTick: Int
    let onNewFolder: () -> Void

    /// 两栏文件列表的键盘焦点；与 activePane 双向同步
    @FocusState private var focusedPane: Int?

    private var active: Binding<Pane> { $panes[activePane] }

    private var currentFolderName: String {
        let url = active.wrappedValue.currentURL
        return url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }

    private var ancestorURLs: [URL] {
        var result: [URL] = []
        var url = active.wrappedValue.currentURL.standardizedFileURL
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            result.append(url)
        }
        return result
    }

    var body: some View {
        HSplitView {
            paneView(0)
            if isDualPane {
                paneView(1)
            }
        }
        .navigationTitle(currentFolderName)
        .navigationDocument(active.wrappedValue.currentURL)
        .toolbarTitleMenu {
            ForEach(ancestorURLs, id: \.self) { url in
                Button {
                    active.wrappedValue.navigate(to: url)
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
                active.wrappedValue.isEditingPath = true
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    active.wrappedValue.goUp()
                } label: {
                    Label("上一级目录", systemImage: "chevron.left")
                }
                .disabled(!active.wrappedValue.canGoUp)
                .help("上一级目录 (⌘↑)")

                Button {
                    active.wrappedValue.goDown()
                } label: {
                    Label("下一级目录", systemImage: "chevron.right")
                }
                .disabled(!active.wrappedValue.canGoDown)
                .help("下一级目录 (⌘↓)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewFolder) {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                .help("新建文件夹 (⌘⇧N)")
            }
        }
        .searchable(text: active.searchText, placement: .toolbar, prompt: "搜索")
        .defaultFocus($focusedPane, 0)
        // 开/关双栏后把键盘焦点交给活动栏，⌘←/→ 立即可用
        .onChange(of: isDualPane) { focusedPane = activePane }
        .onChange(of: focusedPane) {
            if let focusedPane, isDualPane { activePane = focusedPane }
        }
        // 仅当焦点已在某栏列表时才跟随（⌘←/→、⌘W），避免抢走搜索框/路径编辑框的焦点
        .onChange(of: activePane) {
            if focusedPane != nil { focusedPane = activePane }
        }
    }

    private func paneView(_ index: Int) -> some View {
        PaneView(
            pane: $panes[index],
            isActive: isDualPane && activePane == index,
            onActivate: { activePane = index },
            onSwitch: { target in
                guard isDualPane else { return false }
                activePane = target
                focusedPane = target
                return true
            },
            focusedPane: $focusedPane,
            index: index,
            clipboardURLs: $clipboardURLs,
            clipboardIsCut: $clipboardIsCut,
            showHiddenFiles: $showHiddenFiles,
            fsService: fsService,
            refreshTick: refreshTick
        )
        .frame(minWidth: 300, maxWidth: .infinity)
    }
}

/// 单个文件面板：文件列表 + 路径栏 + 状态栏，自带目录加载与监视
struct PaneView: View {
    @Binding var pane: Pane
    /// 双栏模式下的活动面板（单栏时恒为 false，不显示高亮）
    let isActive: Bool
    let onActivate: () -> Void
    /// ⌘←/⌘→ 切换到目标栏，单栏时返回 false 不拦截按键
    let onSwitch: (Int) -> Bool
    var focusedPane: FocusState<Int?>.Binding
    let index: Int
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var showHiddenFiles: Bool
    let fsService: FileSystemService
    let refreshTick: Int

    @State private var isLoading = false
    @State private var loadToken = 0
    @State private var watcherSource: DispatchSourceFileSystemObject?
    @State private var watcherPath: String?
    @State private var watcherDebounce: DispatchWorkItem?

    /// 搜索过滤后的文件列表
    var displayedFiles: [FileItem] {
        guard !pane.searchText.isEmpty else { return pane.files }
        return pane.files.filter { $0.name.localizedCaseInsensitiveContains(pane.searchText) }
    }

    /// 状态栏统计
    var selectedStats: (count: Int, size: Int64) {
        let selected = pane.files.filter { pane.selectedURLs.contains($0.url) }
        let totalSize: Int64 = selected.reduce(0) { $0 + ($1.size ?? 0) }
        return (selected.count, totalSize)
    }

    var body: some View {
        Group {
            if isLoading && pane.files.isEmpty {
                ProgressView("正在加载...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileListView(
                    files: displayedFiles,
                    searchText: pane.searchText,
                    selectedURLs: $pane.selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    currentURL: $pane.currentURL,
                    showHiddenFiles: $showHiddenFiles,
                    onNavigate: { pane.navigate(to: $0) },
                    fsService: fsService,
                    onRefresh: { loadFiles(clearSelection: false) },
                    newFolderTrigger: pane.newFolderTrigger,
                    renameTrigger: pane.renameTrigger
                )
                .focused(focusedPane, equals: index)
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                    guard press.modifiers.intersection([.command, .shift, .option, .control]) == .command
                    else { return .ignored }
                    return onSwitch(press.key == .leftArrow ? 0 : 1) ? .handled : .ignored
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                BreadcrumbBar(
                    currentURL: $pane.currentURL,
                    isEditingPath: $pane.isEditingPath,
                    onNavigate: { pane.navigate(to: $0) }
                )
                Divider()
                statusBar
            }
            .overlay(alignment: .top) {
                if isActive {
                    Rectangle().fill(.tint).frame(height: 2)
                }
            }
        }
        // 鼠标在本栏任意位置按下（列表/空白/路径栏/状态栏）即激活本栏
        .overlay { MouseDownProbe(onMouseDown: onActivate) }
        // 返回上一级时选中刚离开的文件夹，方便继续用方向键浏览
        .onChange(of: pane.currentURL) { old, new in
            let cameFrom = old.deletingLastPathComponent().standardizedFileURL == new.standardizedFileURL ? old : nil
            loadFiles(clearSelection: true, select: cameFrom)
        }
        .onChange(of: showHiddenFiles) { loadFiles(clearSelection: false) }
        .onChange(of: refreshTick) { loadFiles(clearSelection: false) }
        .onAppear { loadFiles(clearSelection: true) }
        .onDisappear { stopWatcher() }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if pane.searchText.isEmpty {
                Text("\(pane.files.count) 个项目")
            } else {
                Text("\(displayedFiles.count) / \(pane.files.count) 个项目")
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
    private func loadFiles(clearSelection: Bool, select: URL? = nil) {
        loadToken += 1
        let token = loadToken
        let url = pane.currentURL
        let showHidden = showHiddenFiles
        let service = fsService
        if clearSelection {
            pane.selectedURLs = []
            pane.searchText = ""
        }
        isLoading = true
        Task {
            let items = (try? await Task.detached(priority: .userInitiated) {
                try service.listDirectory(at: url, showHidden: showHidden)
            }.value) ?? []
            guard token == loadToken else { return }
            pane.files = items
            if let select, let match = items.first(where: { $0.url.standardizedFileURL == select.standardizedFileURL }) {
                pane.selectedURLs = [match.url]
            } else if !clearSelection {
                let existing = Set(items.map(\.url))
                pane.selectedURLs = pane.selectedURLs.intersection(existing)
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
        let path = pane.currentURL.path
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
                let url = pane.currentURL
                let showHidden = showHiddenFiles
                let service = fsService
                Task.detached(priority: .utility) {
                    let updated = (try? service.listDirectory(at: url, showHidden: showHidden)) ?? []
                    await MainActor.run {
                        guard url == pane.currentURL, updated != pane.files else { return }
                        let existing = Set(updated.map(\.url))
                        withAnimation(.easeInOut(duration: 0.1)) {
                            pane.files = updated
                            pane.selectedURLs = pane.selectedURLs.intersection(existing)
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

/// 透明探针：本地监听鼠标按下，落在自身范围内即回调；hitTest 返回 nil，不拦截任何点击
private struct MouseDownProbe: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) { view.onMouseDown = onMouseDown }

    final class ProbeView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window,
                       self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.onMouseDown?()
                    }
                }
                return event
            }
        }
    }
}
