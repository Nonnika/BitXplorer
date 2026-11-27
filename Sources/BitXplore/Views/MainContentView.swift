import SwiftUI
import AppKit

/// 主内容视图 - 整合原生工具栏、搜索，承载单栏/双栏（⌘D）文件面板
struct MainContentView: View {
    @Binding var panes: [Pane]
    @Binding var activePane: Int
    let isDualPane: Bool
    /// 双栏时左栏占比（⌘[ / ⌘] 或拖动分隔条调整）
    @Binding var splitFraction: CGFloat
    /// ⌘F 递增，聚焦工具栏搜索框
    let searchFocusTrigger: Int
    /// ⌘⌥P 递增，开/关命令面板
    let paletteTrigger: Int
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var showHiddenFiles: Bool
    let fsService: FileSystemService
    /// App 级操作（粘贴/废纸篓）完成后递增，触发重新加载
    let refreshTick: Int
    let onNewFolder: () -> Void

    /// 递增即请求把键盘焦点交给 activePane 的列表（初值 1：启动时聚焦左栏）。
    /// SwiftUI 的 FocusState 无法可靠地把 AppKit 第一响应者移到 Table 上，由 PaneProbe 直接 makeFirstResponder
    @State private var focusRequest = 1
    @FocusState private var searchFocused: Bool
    @State private var showPalette = false

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
        GeometryReader { geo in
            HStack(spacing: 0) {
                paneView(0)
                    .frame(width: isDualPane ? geo.size.width * splitFraction : nil)
                if isDualPane {
                    Divider()
                        .overlay {
                            // 加宽的不可见拖拽区；双击恢复等分
                            Color.clear
                                .frame(width: 8)
                                .contentShape(Rectangle())
                                .pointerStyle(.columnResize)
                                .gesture(DragGesture(coordinateSpace: .named("split")).onChanged { value in
                                    splitFraction = Self.clampSplit(value.location.x / geo.size.width)
                                })
                                .onTapGesture(count: 2) { withAnimation(.snappy) { splitFraction = 0.5 } }
                        }
                        .zIndex(1)  // 拖拽区盖在右栏之上，两侧各 4pt 都可抓
                    paneView(1)
                }
            }
            .coordinateSpace(name: "split")
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
                .help("新建文件夹 (⌘N)")
            }
        }
        .searchable(text: active.searchText, placement: .toolbar, prompt: "搜索")
        .searchFocused($searchFocused)
        .onChange(of: searchFocusTrigger) { searchFocused = true }
        .overlay(alignment: .top) {
            if showPalette {
                ZStack(alignment: .top) {
                    // 点面板外任意处关闭
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showPalette = false }
                    CommandPalette(isPresented: $showPalette, currentURL: active.wrappedValue.currentURL) { url in
                        active.wrappedValue.open(url)
                    }
                    .padding(.top, 48)
                }
            }
        }
        .onChange(of: paletteTrigger) { showPalette.toggle() }
        // 面板关闭后把键盘焦点还给活动栏
        .onChange(of: showPalette) { if !showPalette { focusRequest += 1 } }
        // 开/关双栏（⌘D/⌘W）后把键盘焦点交给活动栏
        .onChange(of: isDualPane) { focusRequest += 1 }
    }

    /// 分栏占比范围，保证两栏都留有可用宽度
    static func clampSplit(_ fraction: CGFloat) -> CGFloat { min(max(fraction, 0.2), 0.8) }

    private func paneView(_ index: Int) -> some View {
        PaneView(
            pane: $panes[index],
            isActive: isDualPane && activePane == index,
            onActivate: { activePane = index },
            onSwitch: { target in
                guard isDualPane else { return false }
                activePane = target
                focusRequest += 1
                return true
            },
            onOpenInOtherPane: isDualPane ? { url in
                panes[1 - index].navigate(to: url)
                activePane = 1 - index
                focusRequest += 1
            } : nil,
            onTableRebuilt: { if activePane == index { focusRequest += 1 } },
            focusRequest: focusRequest,
            wantsFocus: activePane == index,
            clipboardURLs: $clipboardURLs,
            clipboardIsCut: $clipboardIsCut,
            showHiddenFiles: $showHiddenFiles,
            fsService: fsService,
            refreshTick: refreshTick
        )
        .frame(maxWidth: .infinity)
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
    let onOpenInOtherPane: ((URL) -> Void)?
    /// 换目录/改搜索会重建 Table（见 FileListView 的 .id），旧表上的键盘焦点随之丢失，需要交还给新表
    let onTableRebuilt: () -> Void
    let focusRequest: Int
    let wantsFocus: Bool
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
                    renameTrigger: pane.renameTrigger,
                    onOpenInOtherPane: onOpenInOtherPane
                )
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
                    onNavigate: { pane.open($0) }
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
        .overlay { PaneProbe(onMouseDown: onActivate, focusRequest: focusRequest, wantsFocus: wantsFocus) }
        // 返回上一级时选中刚离开的文件夹，方便继续用方向键浏览
        .onChange(of: pane.currentURL) { old, new in
            let cameFrom = old.deletingLastPathComponent().standardizedFileURL == new.standardizedFileURL ? old : nil
            loadFiles(clearSelection: true, select: pane.pendingSelection ?? cameFrom)
            pane.pendingSelection = nil
            onTableRebuilt()
        }
        .onChange(of: pane.searchText) { onTableRebuilt() }
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
            // 诊断：排查 Table 崩溃时，终端里能看到崩溃前最后的列表变化
            print("[BitXplore] load \(url.path): \(pane.files.count) → \(items.count)")
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
                            print("[BitXplore] watch \(url.path): \(pane.files.count) → \(updated.count)")
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

/// 覆盖整个面板的透明探针（hitTest 返回 nil，不拦截任何点击）：
/// 1. 本地监听鼠标按下，落在本栏范围内即回调激活；
/// 2. 收到新的 focusRequest 且本栏是目标时，找到本栏范围内的 NSTableView 并设为第一响应者；
/// 3. 窗口内无焦点时按 ↑↓，聚焦本栏（活动栏）列表并选中可见的第一行
private struct PaneProbe: NSViewRepresentable {
    let onMouseDown: () -> Void
    let focusRequest: Int
    let wantsFocus: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.onMouseDown = onMouseDown
        view.update(focusRequest: focusRequest, wantsFocus: wantsFocus)
    }

    final class ProbeView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?
        private var keyMonitor: Any?
        private var focusRequest = 0
        private var handledRequest = 0
        private var wantsFocus = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(focusRequest: Int, wantsFocus: Bool) {
            self.focusRequest = focusRequest
            self.wantsFocus = wantsFocus
            if !wantsFocus { handledRequest = focusRequest }  // 请求不是给本栏的，作废
            focusIfNeeded()
        }

        private func focusIfNeeded() {
            guard wantsFocus, focusRequest != handledRequest, window != nil else { return }
            handledRequest = focusRequest
            // 等 SwiftUI 本轮布局完成（新开的右栏此刻还没放进窗口）
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, let table = self.paneTable(),
                      !(window.firstResponder is NSText)  // 正在搜索框/路径栏/重命名里输入时不抢焦点
                else { return }
                window.makeFirstResponder(table)
            }
        }

        /// 本栏范围内的文件列表（SwiftUI Table 底层的 NSTableView）
        private func paneTable() -> NSTableView? {
            guard let window else { return nil }
            let paneRect = convert(bounds, to: nil)
            return Self.tables(in: window.contentView).first { table in
                let box = table.enclosingScrollView ?? table
                let frame = box.convert(box.bounds, to: nil)
                return paneRect.contains(NSPoint(x: frame.midX, y: frame.midY))
            }
        }

        /// 窗口里没有任何列表/输入框获得焦点时按 ↑↓：聚焦活动栏列表并选中可见的第一行。
        /// 侧边栏（NSOutlineView 也是 NSTableView）、文件列表或输入框有焦点时不干预
        private func handleArrowWithoutFocus(_ event: NSEvent) -> Bool {
            guard wantsFocus, let window, event.window === window, window.isKeyWindow,
                  event.keyCode == 125 || event.keyCode == 126,  // ↓ ↑
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(window.firstResponder is NSText), !(window.firstResponder is NSTableView),
                  let table = paneTable(), table.numberOfRows > 0
            else { return false }

            // 可见区域要扣掉被工具栏/表头遮住的内容边距
            var visible = table.visibleRect
            if let insets = table.enclosingScrollView?.contentInsets {
                visible.origin.y += insets.top
                visible.size.height -= insets.top + insets.bottom
            }
            let rows = table.rows(in: visible)
            var row = max(rows.location, 0)
            if row < table.numberOfRows, table.rect(ofRow: row).minY < visible.minY, row + 1 < table.numberOfRows {
                row += 1  // 第一行只露出一部分时取下一行
            }
            window.makeFirstResponder(table)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        }

        private static func tables(in view: NSView?) -> [NSTableView] {
            guard let view else { return [] }
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }

        override func viewDidMoveToWindow() {
            focusIfNeeded()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            monitor = nil
            keyMonitor = nil
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleArrowWithoutFocus(event) ?? false }
                return handled ? nil : event
            }
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
